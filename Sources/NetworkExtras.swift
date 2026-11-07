import AppKit
import CoreWLAN
import CoreLocation
import Network
import Observation

/// Extra network info gathered only while the network dropdown is open:
/// public IP, Wi‑Fi details and latency (TCP handshake time to 1.1.1.1).
@MainActor
@Observable
final class NetworkExtras: NSObject, CLLocationManagerDelegate {
    static let shared = NetworkExtras()

    struct WiFi: Equatable {
        var ssid: String?
        var rssi: Int
        var noise: Int
        var txRate: Double
        var channel: Int?
        var band: String?
        /// 0…4 bars from RSSI.
        var bars: Int { rssi >= -55 ? 4 : rssi >= -65 ? 3 : rssi >= -75 ? 2 : rssi >= -85 ? 1 : 0 }
        var quality: String { [String(localized: "Bardzo słaby"), String(localized: "Słaby"), String(localized: "Średni"), String(localized: "Dobry"), String(localized: "Doskonały")][bars] }
    }

    /// Per-app traffic (bytes/s) from `nettop`, busiest first.
    struct AppTraffic: Identifiable, Equatable {
        let id: pid_t
        let name: String
        let inRate: Double
        let outRate: Double
        var total: Double { inRate + outRate }
    }
    private(set) var apps: [AppTraffic] = []
    @ObservationIgnored private var prevBytes: [pid_t: (rx: UInt64, tx: UInt64)] = [:]
    @ObservationIgnored private var prevBytesTime: Date?

    private(set) var publicIP: String?
    private(set) var wifi: WiFi?
    private(set) var ping: Double?
    private(set) var pingHistory: [Double] = []
    private(set) var locationAuthorized = false

    @ObservationIgnored private var lastIPFetch: Date?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private lazy var location = CLLocationManager()
    @ObservationIgnored var watchers = 0 {
        didSet {
            if watchers > 0, loop == nil { start() }
            if watchers == 0 { loop?.cancel(); loop = nil }
        }
    }

    private func start() {
        location.delegate = self
        locationAuthorized = [.authorizedAlways, .authorized].contains(location.authorizationStatus)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// SSID is only readable with Location Services permission (macOS privacy rule).
    func requestSSIDAccess() {
        location.delegate = self
        location.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationAuthorized = [.authorizedAlways, .authorized].contains(status)
            self.readWiFi()
        }
    }

    func forceIPRefresh() { lastIPFetch = nil }

    private func refresh() async {
        readWiFi()
        if lastIPFetch == nil || Date().timeIntervalSince(lastIPFetch!) > 600 {
            lastIPFetch = Date()
            publicIP = await Self.fetchPublicIP()
        }
        async let traffic = Self.readNettop()
        let p = await Self.measureLatency()
        updateApps(await traffic)
        ping = p
        if let p {
            pingHistory.append(p)
            if pingHistory.count > 40 { pingHistory.removeFirst(pingHistory.count - 40) }
        }
    }

    private func updateApps(_ sample: [pid_t: (name: String, rx: UInt64, tx: UInt64)]) {
        let now = Date()
        defer {
            prevBytes = sample.mapValues { ($0.rx, $0.tx) }
            prevBytesTime = now
        }
        guard let t0 = prevBytesTime else { return }
        let dt = max(now.timeIntervalSince(t0), 0.5)
        var list: [AppTraffic] = []
        for (pid, cur) in sample {
            guard let prev = prevBytes[pid], cur.rx >= prev.rx, cur.tx >= prev.tx else { continue }
            let rin = Double(cur.rx - prev.rx) / dt, rout = Double(cur.tx - prev.tx) / dt
            guard rin + rout >= 1 else { continue }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? cur.name
            list.append(AppTraffic(id: pid, name: name, inRate: rin, outRate: rout))
        }
        apps = Array(list.sorted { $0.total > $1.total }.prefix(6))
    }

    /// Cumulative bytes per process ("name.pid,bytes_in,bytes_out,") – works without admin rights.
    private nonisolated static func readNettop() async -> [pid_t: (name: String, rx: UInt64, tx: UInt64)] {
        await Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            task.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return [:] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            var result: [pid_t: (name: String, rx: UInt64, tx: UInt64)] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
                let f = line.split(separator: ",", omittingEmptySubsequences: false)
                guard f.count >= 3, let dot = f[0].lastIndex(of: "."),
                      let pid = pid_t(f[0][f[0].index(after: dot)...]),
                      let rx = UInt64(f[1]), let tx = UInt64(f[2]) else { continue }
                result[pid] = (String(f[0][..<dot]), rx, tx)
            }
            return result
        }.value
    }

    private func readWiFi() {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn(), iface.rssiValue() != 0 else { wifi = nil; return }
        let ch = iface.wlanChannel()
        let band: String? = switch ch?.channelBand {
        case .band2GHz: "2,4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: nil
        }
        wifi = WiFi(ssid: iface.ssid(), rssi: iface.rssiValue(), noise: iface.noiseMeasurement(),
                    txRate: iface.transmitRate(), channel: ch?.channelNumber, band: band)
    }

    private static func fetchPublicIP() async -> String? {
        var req = URLRequest(url: URL(string: "https://api.ipify.org")!)
        req.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Milliseconds to complete a TCP handshake with 1.1.1.1:443, or nil on timeout.
    private static func measureLatency() async -> Double? {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: "1.1.1.1", port: 443, using: .tcp)
            let start = DispatchTime.now()
            let done = OSAllocatedUnfairLockBox()
            let finish: (Double?) -> Void = { v in
                guard done.claim() else { return }
                conn.cancel()
                cont.resume(returning: v)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }
}

/// One-shot flag usable from any thread.
final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
}

extension NetworkExtras {
    /// Fake values for README screenshots (`--demo`).
    func applyDemo() {
        apps = [
            AppTraffic(id: demoPID("Safari", 99902), name: "Safari", inRate: 980_000, outRate: 42_000),
            AppTraffic(id: demoPID("Music", 99903), name: "Music", inRate: 320_000, outRate: 6_000),
            AppTraffic(id: demoPID("Mail", 99904), name: "Mail", inRate: 54_000, outRate: 31_000),
            AppTraffic(id: 99908, name: "softwareupdated", inRate: 41_000, outRate: 2_000),
        ]
        publicIP = "203.0.113.42"
        wifi = nil
        pingHistory = demoSeries(40, base: 14, amp: 4, seed: 10)
        ping = pingHistory.last
    }
}
