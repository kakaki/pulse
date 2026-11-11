import Foundation
import IOKit
import Network
import SystemConfiguration

/// What one Mac shares with the other Macs on the local network.
/// Sent as JSON over a short TCP connection: the client writes "basic" or "full", the server answers and closes.
struct RemoteReport: Codable, Equatable {
    struct Fan: Codable, Equatable { var rpm: Double; var min: Double; var max: Double }
    struct Proc: Codable, Equatable { var name: String; var cpu: Double }

    var id: String
    var name: String
    var model: String
    var chip: String
    var version: String
    var cpu: Double
    var cpuHistory: [Double]
    var gpu: Double?
    var mem: Double
    var memTotal: UInt64
    /// 0 normal, 1 warning, 2 critical.
    var memPressure: Int
    var temp: Double?
    var tempHistory: [Double]
    var fans: [Fan]
    var power: Double?
    /// `ProcessInfo.ThermalState.rawValue`.
    var thermal: Int
    var netIn: Double
    var netOut: Double
    var uptime: Double
    /// Only in "full" answers, i.e. while someone has the Other Macs panel open.
    var processes: [Proc]?
}

/// Shares this Mac's readings over Bonjour and collects the readings of other Macs running Pulse.
@MainActor
@Observable
final class RemoteMacs {
    static let shared = RemoteMacs()
    static let serviceType = "_pulse-stats._tcp"
    static let shareKey = "remote.share"

    struct Peer: Identifiable {
        let id: String
        var report: RemoteReport
        var lastSeen: Date
        var isStale: Bool { Date().timeIntervalSince(lastSeen) > 20 }
    }

    private(set) var peers: [Peer] = []
    private(set) var listenerError: String?
    /// Whether the browser has found the service at all (false until the first result or on failure).
    private(set) var browserError: String?

    /// Open Other Macs panels: while > 0, peers are asked for their top processes and polled more often.
    /// Open Overview panels showing the Other Macs tile: peers are polled, without processes.
    @ObservationIgnored var overviewWatchers = 0 {
        didSet { if overviewWatchers > 0 && oldValue == 0 { lastPoll = .distantPast } }
    }

    @ObservationIgnored var panelWatchers = 0 {
        didSet { if panelWatchers > 0 && oldValue == 0 { lastPoll = .distantPast } }
    }

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var advertisedName = ""
    @ObservationIgnored private var browser: NWBrowser?
    /// Found services: key (the peer's id, or its service name) → endpoint.
    @ObservationIgnored private var endpoints: [String: NWEndpoint] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var lastPoll = Date.distantPast
    /// Until when a client asked for processes; while in the future this Mac samples its processes.
    @ObservationIgnored private var fullUntil = Date.distantPast
    @ObservationIgnored private var holdsProcessWatcher = false
    @ObservationIgnored private let queue = DispatchQueue(label: "local.pulse.remote")

    static let installID: String = {
        if let id = UserDefaults.standard.string(forKey: "remote.id") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "remote.id")
        return id
    }()

    static let nameKey = "remote.name"

    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    /// The name other Macs see: the one set in Settings, or the computer name.
    static var sharedName: String {
        let custom = (UserDefaults.standard.string(forKey: nameKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !custom.isEmpty else { return computerName }
        var name = custom
        while name.utf8.count > 63 { name.removeLast() }   // Bonjour limit
        return name
    }

    static let metricKey = "remote.metric"
    static let targetKey = "remote.target"
    static let targetNameKey = "remote.targetName"

    enum Metric: String, CaseIterable, Identifiable {
        case temp, cpu, mem, fan
        var id: Self { self }
        var title: String {
            switch self {
            case .temp: String(localized: "Temperatura")
            case .cpu: "CPU"
            case .mem: String(localized: "Pamięć")
            case .fan: String(localized: "Wentylator")
            }
        }
        static var current: Metric { Metric(rawValue: UserDefaults.standard.string(forKey: metricKey) ?? "") ?? .temp }
    }

    /// What the menu bar and the Overview tile show: the chosen value of the chosen Mac,
    /// or the highest one among all of them (the Mac you are most likely to hear).
    struct Summary { var text = "—"; var value = 0.0; var history: [Double] = []; var maxHistory: Double? = 100; var level: Double? }
    var summary: Summary {
        let target = UserDefaults.standard.string(forKey: Self.targetKey) ?? ""
        let live = peers.filter { !$0.isStale && (target.isEmpty || $0.id == target) }
        func fan(_ p: Peer) -> RemoteReport.Fan? { p.report.fans.max { $0.rpm < $1.rpm } }
        func fanFraction(_ f: RemoteReport.Fan) -> Double { f.max > f.min ? min(max((f.rpm - f.min) / (f.max - f.min), 0), 1) : 0 }
        var metric = Metric.current
        if metric == .temp && !live.contains(where: { $0.report.temp != nil }) { metric = .cpu }
        if metric == .fan && !live.contains(where: { fan($0) != nil }) { metric = .cpu }
        switch metric {
        case .temp:
            guard let hot = live.max(by: { ($0.report.temp ?? -1) < ($1.report.temp ?? -1) }), let t = hot.report.temp else { break }
            return Summary(text: Fmt.temp(t), value: t / 100, history: hot.report.tempHistory, maxHistory: 100, level: Severity.temp(t))
        case .cpu:
            guard let busy = live.max(by: { $0.report.cpu < $1.report.cpu }) else { break }
            return Summary(text: Fmt.pct(busy.report.cpu), value: busy.report.cpu, history: busy.report.cpuHistory, maxHistory: 1, level: busy.report.cpu)
        case .mem:
            guard let full = live.max(by: { $0.report.mem < $1.report.mem }) else { break }
            let level: Double = full.report.memPressure == 2 ? 1 : (full.report.memPressure == 1 ? 0.75 : 0)
            return Summary(text: Fmt.pct(full.report.mem), value: full.report.mem, history: [], maxHistory: 1, level: level)
        case .fan:
            guard let loud = live.max(by: { (fan($0).map(fanFraction) ?? -1) < (fan($1).map(fanFraction) ?? -1) }), let f = fan(loud) else { break }
            let rpm = f.rpm >= 1000 ? String(format: "%.1fk", f.rpm / 1000) : "\(Int(f.rpm))"
            return Summary(text: rpm, value: fanFraction(f), history: [], maxHistory: 1, level: nil)
        }
        return Summary()
    }

    /// "Mac mini (2024)" on Apple Silicon; derived from the model identifier on Intel ("Macmini8,1" → "Mac mini").
    static let modelName: String = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        defer { if entry != 0 { IOObjectRelease(entry) } }
        if entry != 0,
           let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
            let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            if !name.isEmpty { return name }
        }
        let model = Sysctl.string("hw.model") ?? "Mac"
        let names = [("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"), ("Macmini", "Mac mini"),
                     ("iMacPro", "iMac Pro"), ("iMac", "iMac"), ("MacPro", "Mac Pro")]
        return names.first { model.hasPrefix($0.0) }?.1 ?? model
    }()

    /// "Intel(R) Core(TM) i7-8700B CPU @ 3.20GHz" → "Core i7-8700B"; Apple chips stay as they are.
    static func shortChip(_ chip: String) -> String {
        var s = chip.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "")
        if let at = s.range(of: " @") { s = String(s[..<at.lowerBound]) }
        s = s.replacingOccurrences(of: " CPU", with: "").replacingOccurrences(of: "Intel ", with: "")
        return s.split(separator: " ").joined(separator: " ")
    }

    static func symbol(for model: String) -> String {
        let m = model.lowercased()
        if m.contains("mini") { return "macmini" }
        if m.contains("book") { return "laptopcomputer" }
        if m.contains("studio") { return "macstudio" }
        if m.contains("mac pro") { return "macpro.gen3" }
        return "desktopcomputer"
    }

    // MARK: - Called on every monitor refresh

    func tick(_ m: SystemMonitor) {
        let share = UserDefaults.standard.bool(forKey: Self.shareKey)
        // A new name in Settings: advertise again under it.
        if share, listener != nil, advertisedName != Self.sharedName { stopListener() }
        if share && listener == nil { startListener() }
        if !share && listener != nil { stopListener() }

        // Sample processes only while a remote panel is actually looking at them.
        let wantsProcesses = share && Date() < fullUntil
        if wantsProcesses != holdsProcessWatcher {
            holdsProcessWatcher = wantsProcesses
            m.processWatchers = max(0, m.processWatchers + (wantsProcesses ? 1 : -1))
        }

        let defaults = UserDefaults.standard
        let shown = defaults.object(forKey: Module.macs.enabledKey) == nil ? Module.macs.defaultEnabled : defaults.bool(forKey: Module.macs.enabledKey)
        let overview = defaults.object(forKey: Module.overview.enabledKey) == nil ? Module.overview.defaultEnabled : defaults.bool(forKey: Module.overview.enabledKey)
        let browse = shown || (overview && OverviewItem.macs.isOn) || panelWatchers > 0
            || (overviewWatchers > 0 && OverviewItem.macs.showsTile)
        if browse && browser == nil { startBrowser() }
        if !browse && browser != nil { stopBrowser() }
        if browse {
            let every: TimeInterval = panelWatchers > 0 ? 1.5 : (overviewWatchers > 0 ? 3 : 6)
            if Date().timeIntervalSince(lastPoll) >= every { lastPoll = Date(); poll() }
        }
        if UserDefaults.standard.bool(forKey: "remote.debug") {
            print("remote port=\(listener?.port?.rawValue ?? 0) share=\(listener != nil) browse=\(browser != nil) endpoints=\(endpoints.count) peers=\(peers.map { "\($0.report.name) cpu=\(Int($0.report.cpu * 100))% temp=\($0.report.temp.map { Int($0) } ?? -1) procs=\($0.report.processes?.count ?? -1)" }) summary=\(summary.text) err=\(browserError ?? listenerError ?? "-")")
        }
    }

    // MARK: - Sharing

    private func report(full: Bool) -> RemoteReport {
        let m = SystemMonitor.shared
        let pressure = m.memPressure == .critical ? 2 : (m.memPressure == .warning ? 1 : 0)
        return RemoteReport(
            id: Self.installID, name: Self.sharedName, model: Self.modelName, chip: m.chipName,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            cpu: m.cpu, cpuHistory: m.cpuHistory.map { $0.isFinite ? $0 : 0 }, gpu: m.gpu,
            mem: m.memFraction, memTotal: m.memTotal, memPressure: pressure,
            temp: m.socMax ?? m.socAvg, tempHistory: m.tempHistory.map { $0.isFinite ? $0 : 0 },
            fans: m.fans.map { .init(rpm: $0.rpm, min: $0.min, max: $0.max) }, power: m.systemPower,
            thermal: m.thermalState.rawValue, netIn: m.netIn, netOut: m.netOut, uptime: m.uptime,
            processes: full ? m.topByCPU.map { .init(name: $0.name, cpu: $0.cpu) } : nil)
    }

    fileprivate func payload(full: Bool) -> Data {
        if full { fullUntil = Date().addingTimeInterval(10) }
        return (try? JSONEncoder().encode(report(full: full))) ?? Data()
    }

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            let l = try NWListener(using: params)
            var txt = NWTXTRecord()
            txt["id"] = Self.installID
            advertisedName = Self.sharedName
            l.service = NWListener.Service(name: advertisedName, type: Self.serviceType, domain: nil, txtRecord: txt)
            let queue = queue
            l.newConnectionHandler = { connection in RemoteMacs.serve(connection, on: queue) }
            l.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let remote = RemoteMacs.shared
                            remote.listenerError = error.localizedDescription
                            remote.stopListener()   // the next tick starts it again
                        }
                    }
                }
            }
            l.start(queue: queue)
            listener = l
            listenerError = nil
        } catch {
            listenerError = error.localizedDescription
        }
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
    }

    private nonisolated static func serve(_ connection: NWConnection, on queue: DispatchQueue) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, error in
            guard error == nil else { connection.cancel(); return }
            let full = data.map { String(decoding: $0, as: UTF8.self).hasPrefix("full") } ?? false
            DispatchQueue.main.async {
                let body = MainActor.assumeIsolated { RemoteMacs.shared.payload(full: full) }
                connection.send(content: body, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    // MARK: - Finding and polling other Macs

    private func startBrowser() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            var found: [String: NWEndpoint] = [:]
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                var id: String?
                if case .bonjour(let txt) = result.metadata { id = txt["id"] }
                if id == RemoteMacs.installID { continue }   // this Mac
                found[id ?? name] = result.endpoint
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { RemoteMacs.shared.update(endpoints: found) }
            }
        }
        b.stateUpdateHandler = { state in
            let message: String? = switch state {
            case .failed(let error), .waiting(let error): error.localizedDescription
            default: nil
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { RemoteMacs.shared.browserError = message } }
        }
        b.start(queue: queue)
        browser = b
    }

    private func stopBrowser() {
        browser?.cancel()
        browser = nil
        endpoints = [:]
        peers = []
    }

    private func update(endpoints found: [String: NWEndpoint]) {
        endpoints = found
        peers.removeAll { found[$0.id] == nil }
        lastPoll = .distantPast
    }

    private func poll() {
        let full = panelWatchers > 0
        for (key, endpoint) in endpoints where !inFlight.contains(key) {
            inFlight.insert(key)
            Self.fetch(endpoint, full: full, on: queue) { report in
                MainActor.assumeIsolated { RemoteMacs.shared.received(report, key: key) }
            }
        }
    }

    private func received(_ report: RemoteReport?, key: String) {
        inFlight.remove(key)
        guard let report, endpoints[key] != nil else { return }
        let peer = Peer(id: key, report: report, lastSeen: Date())
        if let i = peers.firstIndex(where: { $0.id == key }) {
            peers[i] = peer
        } else {
            peers.append(peer)
            peers.sort { $0.report.name.localizedStandardCompare($1.report.name) == .orderedAscending }
        }
    }

    /// One request: connect, send "basic"/"full", read the JSON until the server closes. Calls back on the main queue.
    private nonisolated static func fetch(_ endpoint: NWEndpoint, full: Bool, on queue: DispatchQueue,
                                          done: @escaping @Sendable (RemoteReport?) -> Void) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let box = FetchBox(done: done)
        func finish(_ data: Data?) {
            guard box.claim() else { return }
            connection.cancel()
            let report = data.flatMap { try? JSONDecoder().decode(RemoteReport.self, from: $0) }
            DispatchQueue.main.async { box.done(report) }
        }
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data { box.buffer.append(data) }
                if box.buffer.count > 512 * 1024 { finish(nil); return }
                if isComplete || error != nil { finish(error == nil || !box.buffer.isEmpty ? box.buffer : nil) } else { read() }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data((full ? "full\n" : "basic\n").utf8), completion: .contentProcessed { _ in })
                read()
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 4) { finish(nil) }
    }
}

extension RemoteMacs {
    /// README screenshots (`--snapshot <dir> --demo`): two made-up Macs.
    func applyDemo() {
        let n = SystemMonitor.historyLength
        func report(_ id: String, _ name: String, _ model: String, _ chip: String, cpu: Double, temp: Double, fans: [RemoteReport.Fan],
                    seed: Double, procs: [(String, Double)]) -> Peer {
            Peer(id: id, report: RemoteReport(
                id: id, name: name, model: model, chip: chip, version: "1.11", cpu: cpu,
                cpuHistory: demoSeries(n, base: cpu, amp: 0.12, seed: seed), gpu: nil, mem: 0.71, memTotal: 16 << 30, memPressure: 0,
                temp: temp, tempHistory: demoSeries(n, base: temp, amp: 4, seed: seed + 1), fans: fans, power: 38,
                thermal: temp > 88 ? 2 : 0, netIn: 2_400_000, netOut: 310_000, uptime: 6 * 86400 + 3 * 3600,
                processes: procs.map { .init(name: $0.0, cpu: $0.1) }), lastSeen: Date())
        }
        peers = [
            report("demo-mini", "Mac mini (Biuro)", "Mac mini", "Intel(R) Core(TM) i7-8700B CPU @ 3.20GHz", cpu: 0.86, temp: 91,
                   fans: [.init(rpm: 2300, min: 1800, max: 4900)], seed: 11,
                   procs: [("com.docker.hyperkit", 3.1), ("gitlab-runner", 0.9), ("kernel_task", 0.4)]),
            report("demo-m4", "Mac mini M4", "Mac mini (2024)", "Apple M4", cpu: 0.18, temp: 52,
                   fans: [.init(rpm: 1000, min: 1000, max: 4900)], seed: 21,
                   procs: [("Xcode", 0.6), ("Safari", 0.2)]),
        ]
    }
}

/// Per-request state; only touched on the remote queue.
private final class FetchBox: @unchecked Sendable {
    let done: @Sendable (RemoteReport?) -> Void
    var buffer = Data()
    private var finished = false
    init(done: @escaping @Sendable (RemoteReport?) -> Void) { self.done = done }
    func claim() -> Bool {
        if finished { return false }
        finished = true
        return true
    }
}
