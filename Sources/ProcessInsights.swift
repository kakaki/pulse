import AppKit
import Darwin
import SwiftUI
import UserNotifications

/// Background look at all processes, independent of open panels:
/// per-process CPU alerts ("Chrome Helper above 80% for 5 minutes") and the energy each app used in the last 24 h.
/// Samples every 10 s while there are alert rules, otherwise every 60 s (energy only, Apple Silicon).
@MainActor
@Observable
final class ProcessInsights {
    static let shared = ProcessInsights()

    // MARK: Rules

    struct Rule: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        /// Fraction of one core (1.0 = 100%).
        var limit: Double = 0.8
        var minutes: Int = 5
    }

    static let rulesKey = "processAlerts"
    private(set) var rules: [Rule] = []
    @ObservationIgnored private var highSince: [UUID: Date] = [:]
    @ObservationIgnored private var fired: Set<UUID> = []

    // MARK: Energy

    /// One hour of energy per app: [joules in total, joules while on battery].
    private struct Hour: Codable { var hour: Int; var apps: [String: [Double]] }
    private var hours: [Hour] = []
    struct AppEnergy: Identifiable { let name: String; let joules: Double; let batteryJoules: Double; var id: String { name } }

    @ObservationIgnored private let sampler = ProcessSampler()
    @ObservationIgnored private var lastSample: Date?
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var appNames: [pid_t: String] = [:]
    @ObservationIgnored private var demo = false

    static var measuresEnergy: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app-energy.json")
    }()

    private init() {
        reload()
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode([Hour].self, from: data) {
            hours = saved
        }
    }

    // MARK: Editing rules

    func reload() {
        if let data = UserDefaults.standard.data(forKey: Self.rulesKey), let saved = try? JSONDecoder().decode([Rule].self, from: data) {
            rules = saved
        } else {
            rules = []
        }
    }

    func setRules(_ list: [Rule]) {
        rules = list
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: Self.rulesKey) }
        let ids = Set(list.map(\.id))
        highSince = highSince.filter { ids.contains($0.key) }
        fired = fired.filter { ids.contains($0) }
    }

    func addRule(name: String) {
        guard !rules.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        setRules(rules + [Rule(name: name)])
    }

    // MARK: Sampling

    func tick(onBattery: Bool) {
        guard !demo else { return }
        let every: TimeInterval = rules.isEmpty ? 60 : 10
        guard rules.isEmpty == false || Self.measuresEnergy else { return }
        let now = Date()
        if let last = lastSample, now.timeIntervalSince(last) < every { return }
        let dt = lastSample.map { now.timeIntervalSince($0) } ?? 0
        lastSample = now
        let list = sampler.sample()
        guard dt > 0 else { return }

        var byName: [String: Double] = [:], byApp: [String: Double] = [:]
        var energy: [String: Double] = [:]
        if appNames.count > 3000 { appNames.removeAll() }
        for p in list {
            let app = appName(p.id, fallback: p.name)
            byName[p.name, default: 0] += p.cpu
            byApp[app, default: 0] += p.cpu
            // A sleep in between would count as one huge interval.
            if p.power > 0, dt < 600 { energy[app, default: 0] += p.power * dt }
        }
        checkRules(byName: byName, byApp: byApp, now: now)
        if !energy.isEmpty { addEnergy(energy, onBattery: onBattery) }
        let alive = Set(list.map(\.id))
        appNames = appNames.filter { alive.contains($0.key) }
    }

    /// The app a process belongs to: helpers inside "Google Chrome.app" count as Google Chrome.
    private func appName(_ pid: pid_t, fallback: String) -> String {
        if let known = appNames[pid] { return known }
        var buffer = [CChar](repeating: 0, count: 4096)
        var name = fallback
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if let range = path.range(of: ".app/") {
                let bundle = String(path[..<range.lowerBound])
                name = (bundle as NSString).lastPathComponent
                if let url = URL(string: "file://" + (bundle + ".app").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!),
                   let display = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !display.isEmpty {
                    name = display
                }
            }
        }
        appNames[pid] = name
        return name
    }

    private func checkRules(byName: [String: Double], byApp: [String: Double], now: Date) {
        for rule in rules {
            let key = rule.name.lowercased()
            let value = max(byName.first { $0.key.lowercased() == key }?.value ?? 0, byApp.first { $0.key.lowercased() == key }?.value ?? 0)
            if value >= rule.limit {
                let since = highSince[rule.id] ?? now
                highSince[rule.id] = since
                if !fired.contains(rule.id), now.timeIntervalSince(since) >= Double(rule.minutes) * 60 {
                    fired.insert(rule.id)
                    notify(rule, value: value)
                }
            } else {
                highSince[rule.id] = nil
                if value < rule.limit * 0.7 { fired.remove(rule.id) }
            }
        }
    }

    private func notify(_ rule: Rule, value: Double) {
        Alerts.shared.send(title: String(localized: "„\(rule.name)” obciąża procesor"),
                           body: String(localized: "\(Fmt.pct(value)) CPU od ponad \(rule.minutes) min (próg \(Fmt.pct(rule.limit)))."),
                           id: "process.\(rule.id.uuidString)", category: Alerts.processCategory, info: ["quitName": rule.name])
    }

    /// "Zakończ" in the notification: quits every process with that name or inside that app (apps may ask to save documents).
    static func quitAll(named name: String) {
        let key = name.lowercased()
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(max(count, 0))) where ProcessActions.canEnd(pid) {
            var match = ProcessSampler.name(for: pid).lowercased() == key
            if !match, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(cString: buffer).lowercased()
                match = path.contains("/\(key).app/")
            }
            guard match else { continue }
            if let app = NSRunningApplication(processIdentifier: pid) { app.terminate() } else { kill(pid, SIGTERM) }
        }
    }

    // MARK: Energy log

    private static func hourNow() -> Int { Int(Date().timeIntervalSince1970 / 3600) }

    private func addEnergy(_ energy: [String: Double], onBattery: Bool) {
        let h = Self.hourNow()
        if hours.last?.hour != h {
            hours.append(Hour(hour: h, apps: [:]))
            hours.removeAll { $0.hour <= h - 48 }
            // Tiny entries only bloat the file.
            if hours.count >= 2 { hours[hours.count - 2].apps = hours[hours.count - 2].apps.filter { $0.value[0] >= 1 } }
        }
        var apps = hours[hours.count - 1].apps
        for (name, j) in energy {
            var v = apps[name] ?? [0, 0]
            v[0] += j
            if onBattery { v[1] += j }
            apps[name] = v
        }
        hours[hours.count - 1].apps = apps
        if Date().timeIntervalSince(lastSave) > 600 { save() }
    }

    func save() {
        guard !demo else { return }
        lastSave = Date()
        guard let data = try? JSONEncoder().encode(hours) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// Apps by energy used in the last 24 h, most first.
    func ranking(limit: Int = 8) -> [AppEnergy] {
        let from = Self.hourNow() - 23
        var sum: [String: (Double, Double)] = [:]
        for h in hours where h.hour >= from {
            for (name, v) in h.apps {
                let s = sum[name] ?? (0, 0)
                sum[name] = (s.0 + v[0], s.1 + (v.count > 1 ? v[1] : 0))
            }
        }
        return sum.map { AppEnergy(name: $0.key, joules: $0.value.0, batteryJoules: $0.value.1) }
            .filter { $0.joules >= 36 }   // 0.01 Wh
            .sorted { $0.joules > $1.joules }
            .prefix(limit).map { $0 }
    }

    /// Hours with data in the last 24 h (the card says how much it covers).
    var coveredHours: Int { let from = Self.hourNow() - 23; return hours.filter { $0.hour >= from && !$0.apps.isEmpty }.count }

    func applyDemo() {
        demo = true
        let h = Self.hourNow()
        hours = [Hour(hour: h, apps: ["Safari": [21_000, 15_000], "Xcode": [38_000, 9_000], "Music": [5_400, 5_400],
                                      "Mail": [2_100, 1_500], "WindowServer": [12_000, 8_000], "Google Chrome": [17_500, 12_000]])]
        rules = [Rule(name: "Google Chrome Helper", limit: 0.8, minutes: 5)]
    }
}

// MARK: - Battery panel card

struct AppEnergyCard: View {
    @Environment(SystemMonitor.self) private var m
    private let insights = ProcessInsights.shared

    var body: some View {
        let list = insights.ranking()
        Card {
            SectionTitle(text: "Energia aplikacji", trailing: String(localized: "ostatnie 24 h"))
            if list.isEmpty {
                Text("Zbieram dane – ranking pojawi się po kilku minutach.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                let top = max(list.first?.joules ?? 1, 1)
                VStack(spacing: 8) {
                    ForEach(list) { row($0, top: top) }
                }
                Text(footnote).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Battery energy in joules (full charge at the present voltage).
    private var batteryJoules: Double? {
        let b = m.battery
        guard b.present, let mah = b.maxCapacity, let v = b.voltage, mah > 0, v > 0 else { return nil }
        return Double(mah) / 1000 * v * 3600
    }

    private var footnote: String {
        let hours = insights.coveredHours
        let base = String(localized: "Szacunek macOS dla każdej aplikacji razem z jej procesami pomocniczymi.")
        guard hours < 23 else { return base }
        return base + " " + String(localized: "Dane z \(max(hours, 1)) h.")
    }

    private func row(_ a: ProcessInsights.AppEnergy, top: Double) -> some View {
        HStack(spacing: 8) {
            AppNameIcon(name: a.name).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: a.name).font(.system(size: 12)).lineLimit(1)
                LinearMeter(value: a.joules / top, colors: Module.battery.colors, height: 3)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 0) {
                Text(verbatim: Self.wh(a.joules)).fontWeight(.semibold)
                if let full = batteryJoules, a.batteryJoules > 0 {
                    Text(String(localized: "\(Self.percent(a.batteryJoules / full)) baterii")).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10.5)).monospacedDigit()
            .frame(width: 84, alignment: .trailing)
        }
    }

    static func wh(_ joules: Double) -> String {
        let wh = joules / 3600
        return wh >= 10 ? String(format: "%.0f Wh", wh) : String(format: wh >= 1 ? "%.1f Wh" : "%.2f Wh", wh)
    }

    static func percent(_ f: Double) -> String { f >= 0.095 ? Fmt.pct(f) : (f >= 0.01 ? String(format: "%.1f%%", f * 100) : "<1%") }
}

/// Icon of a running app with that name, or a generic one.
struct AppNameIcon: View {
    let name: String
    var body: some View {
        if let icon = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })?.icon {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Settings (CPU page)

struct ProcessAlertsSection: View {
    @Environment(SystemMonitor.self) private var m
    private let insights = ProcessInsights.shared
    @State private var newName = ""

    var body: some View {
        Section {
            ForEach(insights.rules) { rule in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(rule.name, systemImage: "bell.badge")
                        Spacer()
                        Button(role: .destructive) {
                            insights.setRules(insights.rules.filter { $0.id != rule.id })
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Usuń")
                    }
                    Stepper("Powyżej \(Fmt.pct(rule.limit)) CPU", value: binding(rule, \.limit), in: 0.1...8, step: 0.1)
                    Stepper("Przez \(rule.minutes) min", value: binding(rule, \.minutes), in: 1...60)
                }
            }
            HStack {
                TextField("Nazwa procesu lub aplikacji", text: $newName)
                    .onSubmit(add)
                Menu("Z listy") {
                    ForEach(suggestions, id: \.self) { name in
                        Button(name) { insights.addRule(name: name) }
                    }
                }
                .fixedSize()
                .onAppear { m.processWatchers += 1 }
                .onDisappear { m.processWatchers = max(0, m.processWatchers - 1) }
                Button("Dodaj", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Powiadomienia o procesach")
        } footer: {
            Text("Powiadomienie, gdy wybrany proces długo obciąża procesor, z przyciskiem „Zakończ”. 100% to jeden pełny rdzeń. Nazwa aplikacji (np. Google Chrome) obejmuje też jej procesy pomocnicze. Proces dodasz też z panelu CPU: prawy klik na procesie.")
        }
    }

    private var suggestions: [String] {
        Array(m.processes.sorted { $0.cpu > $1.cpu }.map(\.name).prefix(12))
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        insights.addRule(name: name)
        newName = ""
    }

    private func binding<T>(_ rule: ProcessInsights.Rule, _ path: WritableKeyPath<ProcessInsights.Rule, T>) -> Binding<T> {
        Binding {
            insights.rules.first { $0.id == rule.id }?[keyPath: path] ?? rule[keyPath: path]
        } set: { value in
            insights.setRules(insights.rules.map { var r = $0; if r.id == rule.id { r[keyPath: path] = value }; return r })
        }
    }
}
