import Foundation
import SwiftUI
import UserNotifications

/// Threshold notifications (temperature, sustained CPU, memory pressure, low battery, low disk space).
@MainActor
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Alerts()

    enum Kind: String, CaseIterable, Identifiable {
        case temp, thermal, cpu, memory, battery, disk
        var id: String { rawValue }
        var title: String {
            switch self {
            case .temp: String(localized: "Wysoka temperatura")
            case .thermal: String(localized: "Spowolnienie termiczne")
            case .cpu: String(localized: "Długotrwałe obciążenie CPU")
            case .memory: String(localized: "Brak pamięci")
            case .battery: String(localized: "Niski poziom baterii")
            case .disk: String(localized: "Mało miejsca na dysku")
            }
        }
        var symbol: String {
            switch self {
            case .temp: "thermometer.high"
            case .thermal: "flame"
            case .cpu: "cpu"
            case .memory: "memorychip"
            case .battery: "battery.25percent"
            case .disk: "internaldrive"
            }
        }
        var enabledKey: String { "alerts.\(rawValue)" }
        var limitKey: String { "alerts.\(rawValue).limit" }
        var defaultEnabled: Bool { self != .cpu }
        /// temp °C, cpu fraction, battery fraction, disk free GB (memory has no limit).
        var defaultLimit: Double {
            switch self {
            case .temp: 95
            case .cpu: 0.9
            case .memory, .thermal: 0
            case .battery: 0.15
            case .disk: 10
            }
        }
        var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled }
        var limit: Double { UserDefaults.standard.object(forKey: limitKey) as? Double ?? defaultLimit }
    }

    /// Kinds that fired and have not yet cleared (re-armed once the value drops back with some margin).
    private var active: Set<Kind> = []
    private var lastSent: [Kind: Date] = [:]
    private var cpuHighSince: Date?
    private let cooldown: TimeInterval = 30 * 60

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(_ m: SystemMonitor) {
        let now = Date()
        // Temperature
        if let t = m.socMax ?? m.socAvg {
            check(.temp, firing: t >= Kind.temp.limit, clear: t < Kind.temp.limit - 8,
                  body: String(localized: "SoC ma \(Fmt.temp(t)) (próg \(Fmt.temp(Kind.temp.limit)))."))
        }
        // macOS thermal pressure (throttling)
        check(.thermal, firing: m.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
              clear: m.thermalState == .nominal,
              body: String(localized: "macOS ogranicza wydajność z powodu temperatury (stan: \(m.thermalState.title.lowercased()))."))
        // CPU above the limit for 2 minutes
        if m.cpu >= Kind.cpu.limit { cpuHighSince = cpuHighSince ?? now } else { cpuHighSince = nil }
        let sustained = cpuHighSince.map { now.timeIntervalSince($0) >= 120 } ?? false
        let top = m.topByCPU.first.map { String(localized: " Najwięcej zużywa: \($0.name).") } ?? ""
        check(.cpu, firing: sustained, clear: m.cpu < Kind.cpu.limit - 0.2,
              body: String(localized: "Procesor pracuje na \(Fmt.pct(m.cpu)) od ponad 2 minut.\(top)"))
        // Memory pressure
        check(.memory, firing: m.memPressure == .critical, clear: m.memPressure == .normal,
              body: String(localized: "Ciśnienie pamięci jest krytyczne. Zamknij nieużywane aplikacje."))
        // Battery
        if m.battery.present {
            let low = !m.battery.onAC && m.battery.percent <= Kind.battery.limit
            check(.battery, firing: low, clear: m.battery.onAC || m.battery.percent > Kind.battery.limit + 0.05,
                  body: "Bateria: \(Fmt.pct(m.battery.percent))" + (m.battery.minutesRemaining.map { ", zostało ok. \(Fmt.minutes($0))." } ?? "."))
        }
        // Disk
        if m.diskTotal > 0 {
            let freeGB = Double(m.diskFree) / 1e9
            check(.disk, firing: freeGB < Kind.disk.limit, clear: freeGB > Kind.disk.limit + 5,
                  body: String(localized: "Na dysku \(m.diskName) zostało \(Fmt.file(m.diskFree))."))
        }
    }

    private func check(_ kind: Kind, firing: Bool, clear: Bool, body: String) {
        if clear { active.remove(kind) }
        guard kind.isEnabled, firing, !active.contains(kind) else { return }
        if let last = lastSent[kind], Date().timeIntervalSince(last) < cooldown { return }
        active.insert(kind)
        lastSent[kind] = Date()
        send(title: kind.title, body: body, id: kind.rawValue)
    }

    func send(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "pulse.\(id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

struct AlertSettings: View {
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(statusText, systemImage: status == .authorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status == .authorized ? .green : .orange)
                    Spacer()
                    if status == .notDetermined {
                        Button("Zezwól") { Alerts.shared.requestAuthorization(); refreshSoon() }
                    } else if status == .denied {
                        Button("Otwórz Ustawienia systemowe") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                    Button("Wyślij test") {
                        Alerts.shared.send(title: "Pulse", body: String(localized: "Powiadomienia działają."), id: "test")
                    }
                }
            } footer: {
                Text("To samo powiadomienie nie pojawi się częściej niż co 30 minut ani ponownie, zanim wartość nie wróci do normy.")
            }
            ForEach(Alerts.Kind.allCases) { AlertRow(kind: $0) }
        }
        .formStyle(.grouped)
        .navigationTitle("Powiadomienia")
        .task { await refresh() }
    }

    private var statusText: String {
        switch status {
        case .authorized, .provisional: String(localized: "Powiadomienia włączone")
        case .denied: String(localized: "Powiadomienia wyłączone w systemie")
        default: String(localized: "Pulse nie ma jeszcze zgody na powiadomienia")
        }
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func refreshSoon() {
        Task { try? await Task.sleep(for: .seconds(2)); await refresh() }
    }
}

private struct AlertRow: View {
    let kind: Alerts.Kind
    @AppStorage private var enabled: Bool
    @AppStorage private var limit: Double

    init(kind: Alerts.Kind) {
        self.kind = kind
        _enabled = AppStorage(wrappedValue: kind.defaultEnabled, kind.enabledKey)
        _limit = AppStorage(wrappedValue: kind.defaultLimit, kind.limitKey)
    }

    var body: some View {
        Section {
            Toggle(isOn: $enabled) { Label(kind.title, systemImage: kind.symbol) }
            if enabled {
                switch kind {
                case .temp:
                    Stepper("Próg: \(Fmt.temp(limit))", value: $limit, in: 70...110, step: 5)
                case .cpu:
                    Stepper("Próg: \(Fmt.pct(limit)) przez 2 min", value: $limit, in: 0.5...1, step: 0.05)
                case .battery:
                    Stepper("Próg: \(Fmt.pct(limit))", value: $limit, in: 0.05...0.5, step: 0.05)
                case .disk:
                    Stepper("Gdy wolne < \(Int(limit)) GB", value: $limit, in: 5...200, step: 5)
                case .memory:
                    Text("Gdy macOS zgłosi krytyczne ciśnienie pamięci.").foregroundStyle(.secondary)
                case .thermal:
                    Text("Gdy macOS zacznie ograniczać wydajność z powodu temperatury (stan „poważny” lub „krytyczny”).").foregroundStyle(.secondary)
                }
            }
        }
    }
}
