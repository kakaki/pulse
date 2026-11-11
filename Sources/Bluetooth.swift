import Foundation
import SwiftUI

/// Battery levels of connected Bluetooth devices (Magic Keyboard / Mouse / Trackpad, AirPods and their case).
/// Read from `system_profiler SPBluetoothDataType -json`, off the main thread, every 2 minutes
/// (every 15 s while the Battery panel is open).
@MainActor
@Observable
final class BluetoothBatteries {
    static let shared = BluetoothBatteries()

    struct Level: Hashable {
        enum Part: String { case main, left, right, `case` }
        let part: Part
        let percent: Double
        var title: String {
            switch part {
            case .main: ""
            case .left: String(localized: "Lewa")
            case .right: String(localized: "Prawa")
            case .case: String(localized: "Etui")
            }
        }
    }

    struct Device: Identifiable, Hashable {
        let id: String          // Bluetooth address
        let name: String
        let kind: String        // device_minorType: Keyboard, Mouse, Trackpad, Headphones, …
        let productID: String?
        let levels: [Level]
        /// Lowest level that matters for a warning (the AirPods case does not).
        var lowest: Double? { levels.filter { $0.part != .case }.map(\.percent).min() }

        var symbol: String {
            let k = kind.lowercased(), n = name.lowercased()
            if k.contains("keyboard") || n.contains("keyboard") { return "keyboard" }
            if k.contains("mouse") || n.contains("mouse") { return "magicmouse" }
            if k.contains("trackpad") || n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
            if n.contains("airpods max") { return "airpodsmax" }
            if n.contains("airpods pro") { return "airpodspro" }
            if n.contains("airpods") { return "airpods" }
            if k.contains("head") { return "headphones" }
            if k.contains("game") { return "gamecontroller" }
            return "dot.radiowaves.left.and.right"
        }
    }

    private(set) var devices: [Device] = []
    private(set) var loaded = false

    /// Open Battery panels: refresh more often while someone is looking.
    @ObservationIgnored var watchers = 0 {
        didSet { if watchers > 0 && oldValue == 0 { refresh() } }
    }
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var running = false
    /// Devices already warned about; re-armed when the level rises again.
    @ObservationIgnored private var warned: Set<String> = []

    func tick() {
        let every: TimeInterval = watchers > 0 ? 15 : 120
        if Date().timeIntervalSince(lastRefresh) >= every { refresh() }
    }

    func refresh() {
        guard !running else { return }
        running = true
        lastRefresh = Date()
        Task.detached(priority: .utility) {
            let devices = Self.read()
            await MainActor.run {
                let shared = BluetoothBatteries.shared
                shared.running = false
                shared.loaded = true
                if let devices {
                    if devices != shared.devices { shared.devices = devices }
                    shared.checkAlerts()
                }
            }
        }
    }

    private func checkAlerts() {
        let kind = Alerts.Kind.bluetooth
        for device in devices {
            guard let low = device.lowest else { continue }
            if low > kind.limit + 0.05 { warned.remove(device.id) }
            guard kind.isEnabled, low <= kind.limit, !warned.contains(device.id) else { continue }
            warned.insert(device.id)
            Alerts.shared.send(title: kind.title, body: String(localized: "\(device.name): \(Fmt.pct(low)) baterii."),
                               id: "bluetooth.\(device.id)")
        }
    }

    // MARK: - system_profiler

    private nonisolated static func read() -> [Device]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parse(data)
    }

    nonisolated static func parse(_ data: Data) -> [Device]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        var result: [Device] = []
        for controller in controllers {
            // Only connected devices: the levels of the others are old.
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let parts: [(String, Level.Part)] = [("device_batteryLevelMain", .main), ("device_batteryLevel", .main),
                                                          ("device_batteryLevelLeft", .left), ("device_batteryLevelRight", .right),
                                                          ("device_batteryLevelCase", .case)]
                    var levels: [Level] = []
                    for (key, part) in parts {
                        guard let text = info[key] as? String, !levels.contains(where: { $0.part == part }),
                              let n = Double(text.filter(\.isNumber)), n > 0 else { continue }
                        levels.append(Level(part: part, percent: min(n / 100, 1)))
                    }
                    guard !levels.isEmpty else { continue }
                    result.append(Device(id: info["device_address"] as? String ?? name, name: name,
                                         kind: info["device_minorType"] as? String ?? "", productID: info["device_productID"] as? String,
                                         levels: levels))
                }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// README screenshots (`--snapshot <dir> --demo`).
    func applyDemo() {
        devices = [
            Device(id: "demo-airpods", name: "AirPods Pro", kind: "Headphones", productID: nil,
                   levels: [.init(part: .left, percent: 0.8), .init(part: .right, percent: 0.75), .init(part: .case, percent: 0.52)]),
            Device(id: "demo-keyboard", name: "Magic Keyboard", kind: "Keyboard", productID: nil, levels: [.init(part: .main, percent: 0.64)]),
            Device(id: "demo-mouse", name: "Magic Mouse", kind: "Mouse", productID: nil, levels: [.init(part: .main, percent: 0.12)]),
        ]
        loaded = true
    }
}

// MARK: - Panel

struct BluetoothBatteriesCard: View {
    private let bt = BluetoothBatteries.shared
    /// Without a Mac battery the card is the whole panel, so it also says when nothing is connected.
    var showEmpty = false

    var body: some View {
        Group {
            if !bt.devices.isEmpty {
                Card {
                    SectionTitle(text: "Urządzenia Bluetooth")
                    VStack(spacing: 10) {
                        ForEach(bt.devices) { row($0) }
                    }
                }
            } else if showEmpty && bt.loaded {
                Card {
                    SectionTitle(text: "Urządzenia Bluetooth")
                    Text("Brak połączonych urządzeń z baterią.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { bt.watchers += 1 }
        .onDisappear { bt.watchers = max(0, bt.watchers - 1) }
    }

    private func row(_ d: BluetoothBatteries.Device) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: d.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 7, style: .continuous))
            VStack(spacing: 5) {
                HStack {
                    Text(verbatim: d.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    if d.levels.count == 1, let l = d.levels.first {
                        Text(verbatim: Fmt.pct(l.percent)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(color(l.percent))
                    }
                }
                if d.levels.count == 1, let l = d.levels.first {
                    LinearMeter(value: l.percent, colors: [color(l.percent).opacity(0.7), color(l.percent)], height: 5)
                } else {
                    HStack(spacing: 8) {
                        ForEach(d.levels, id: \.part) { l in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 3) {
                                    Text(verbatim: l.title).foregroundStyle(.secondary)
                                    Spacer(minLength: 2)
                                    Text(verbatim: Fmt.pct(l.percent)).fontWeight(.semibold).monospacedDigit().foregroundStyle(color(l.percent))
                                }
                                .font(.system(size: 10.5))
                                LinearMeter(value: l.percent, colors: [color(l.percent).opacity(0.7), color(l.percent)], height: 4)
                            }
                        }
                    }
                }
            }
        }
    }

    private func color(_ p: Double) -> Color {
        p <= 0.15 ? .red : (p <= 0.3 ? .orange : Module.battery.tint)
    }
}
