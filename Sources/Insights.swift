import AppKit
import Network
import SwiftUI
import UniformTypeIdentifiers

private let supportDir: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pulse", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

// MARK: - Disk space forecast

/// Free space on the system disk once an hour for 45 days; a straight line through the last two weeks says when it runs out.
@MainActor
@Observable
final class DiskTrend {
    static let shared = DiskTrend()

    private struct Sample: Codable { var t: Double; var free: Double }
    @ObservationIgnored private var samples: [Sample] = []
    /// Change of free space per day (negative: it shrinks).
    private(set) var perDay: Double?
    /// Days until the disk is full, when free space keeps shrinking.
    private(set) var daysLeft: Double?
    @ObservationIgnored private var demo = false
    private static let url = supportDir.appendingPathComponent("disk-trend.json")

    private init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode([Sample].self, from: data) {
            samples = saved
            compute(free: saved.last?.free ?? 0)
        }
    }

    func record(free: Int64) {
        guard !demo, free > 0 else { return }
        let now = Date().timeIntervalSince1970
        if let last = samples.last, now - last.t < 3600 { return }
        samples.append(Sample(t: now, free: Double(free)))
        samples.removeAll { now - $0.t > 45 * 86400 }
        if let data = try? JSONEncoder().encode(samples) { try? data.write(to: Self.url, options: .atomic) }
        compute(free: Double(free))
    }

    private func compute(free: Double) {
        let now = Date().timeIntervalSince1970
        let recent = samples.filter { now - $0.t <= 14 * 86400 }
        guard recent.count >= 8, let first = recent.first, let last = recent.last, last.t - first.t >= 2 * 86400 else {
            perDay = nil; daysLeft = nil; return
        }
        // Least squares: free = a + b·t
        let n = Double(recent.count)
        let mt = recent.reduce(0) { $0 + $1.t } / n, mf = recent.reduce(0) { $0 + $1.free } / n
        let cov = recent.reduce(0) { $0 + ($1.t - mt) * ($1.free - mf) }
        let varT = recent.reduce(0) { $0 + ($1.t - mt) * ($1.t - mt) }
        guard varT > 0 else { return }
        let slope = cov / varT * 86400
        perDay = slope
        // Ignore slow drifts (under ~50 MB a day).
        daysLeft = slope < -50_000_000 ? max(0, (free - 1_000_000_000) / -slope) : nil
    }

    var summary: (text: String, color: Color)? {
        guard let perDay else { return nil }
        if let days = daysLeft, days < 365 {
            let text = String(localized: "Ubywa ok. \(Fmt.file(Int64(-perDay))) dziennie – dysk zapełni się za ok. \(Int(days.rounded())) dni")
            return (text, days < 14 ? .red : (days < 60 ? .orange : .secondary))
        }
        if perDay < -50_000_000 { return (String(localized: "Ubywa ok. \(Fmt.file(Int64(-perDay))) dziennie"), .secondary) }
        return (String(localized: "Wolne miejsce się nie kurczy"), .secondary)
    }

    func applyDemo() { demo = true; perDay = -1_400_000_000; daysLeft = 215 }
}

// MARK: - Monthly network data

/// Data sent and received per billing period, also separately on expensive networks (iPhone hotspot, cellular), with an optional limit.
@MainActor
@Observable
final class NetworkUsage {
    static let shared = NetworkUsage()
    static let limitKey = "netLimit.gb"
    static let meteredKey = "netLimit.metered"
    static let startDayKey = "netLimit.startDay"

    struct Period: Codable, Equatable {
        var id: String
        var down: Double = 0
        var up: Double = 0
        var meteredDown: Double = 0
        var meteredUp: Double = 0
        /// Highest warning already sent in this period (80 or 100).
        var warned = 0
        var total: Double { down + up }
        var metered: Double { meteredDown + meteredUp }
    }

    private(set) var periods: [Period] = []
    private(set) var isExpensive = false
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var demo = false
    private static let url = supportDir.appendingPathComponent("net-usage.json")

    static var limitGB: Double { UserDefaults.standard.double(forKey: limitKey) }
    static var meteredOnly: Bool { UserDefaults.standard.bool(forKey: meteredKey) }
    static var startDay: Int { min(max(UserDefaults.standard.integer(forKey: startDayKey), 1), 28) }

    private init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode([Period].self, from: data) {
            periods = saved
        }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let expensive = path.isExpensive
            DispatchQueue.main.async { MainActor.assumeIsolated { NetworkUsage.shared.isExpensive = expensive } }
        }
        m.start(queue: DispatchQueue(label: "local.pulse.netusage"))
        monitor = m
    }

    /// Start of the billing period containing `date`.
    static func periodStart(_ date: Date = Date()) -> Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day], from: date)
        let day = startDay
        if (c.day ?? 1) < day { c.month = (c.month ?? 1) - 1 }
        c.day = day
        return cal.date(from: c) ?? date
    }

    private static func id(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    var current: Period {
        let id = Self.id(Self.periodStart())
        return periods.last { $0.id == id } ?? Period(id: id)
    }

    var previous: Period? {
        let cal = Calendar.current
        guard let before = cal.date(byAdding: .day, value: -1, to: Self.periodStart()) else { return nil }
        let id = Self.id(Self.periodStart(before))
        return periods.last { $0.id == id }
    }

    /// Bytes that count against the limit.
    func counted(_ p: Period) -> Double { Self.meteredOnly ? p.metered : p.total }

    func add(down: UInt64, up: UInt64) {
        guard !demo, down + up > 0, down + up < 50_000_000_000 else { return }
        let id = Self.id(Self.periodStart())
        if periods.last?.id != id {
            periods.append(Period(id: id))
            if periods.count > 13 { periods.removeFirst(periods.count - 13) }
        }
        var p = periods[periods.count - 1]
        p.down += Double(down); p.up += Double(up)
        if isExpensive { p.meteredDown += Double(down); p.meteredUp += Double(up) }
        checkLimit(&p)
        periods[periods.count - 1] = p
        if Date().timeIntervalSince(lastSave) > 300 { save() }
    }

    private func checkLimit(_ p: inout Period) {
        let limit = Self.limitGB * 1e9
        guard limit > 0 else { return }
        let used = counted(p), fraction = used / limit
        let level = fraction >= 1 ? 100 : (fraction >= 0.8 ? 80 : 0)
        guard level > p.warned else { return }
        p.warned = level
        let scope = Self.meteredOnly ? String(localized: " (hotspot i sieci komórkowe)") : ""
        Alerts.shared.send(title: level == 100 ? String(localized: "Limit danych wykorzystany") : String(localized: "Wykorzystano 80% limitu danych"),
                           body: String(localized: "\(Fmt.file(Int64(used))) z \(Fmt.file(Int64(limit))) w tym okresie\(scope)."),
                           id: "netlimit")
    }

    func save() {
        guard !demo else { return }
        lastSave = Date()
        if let data = try? JSONEncoder().encode(periods) { try? data.write(to: Self.url, options: .atomic) }
    }

    func applyDemo() {
        demo = true
        let id = Self.id(Self.periodStart())
        periods = [Period(id: "demo-prev", down: 182e9, up: 21e9, meteredDown: 6.1e9, meteredUp: 0.7e9),
                   Period(id: id, down: 96.4e9, up: 11.2e9, meteredDown: 3.8e9, meteredUp: 0.4e9)]
    }
}

struct NetworkUsageCard: View {
    private let usage = NetworkUsage.shared
    @AppStorage(NetworkUsage.limitKey) private var limitGB = 0.0
    @AppStorage(NetworkUsage.meteredKey) private var meteredOnly = false
    @AppStorage(NetworkUsage.startDayKey) private var startDay = 1

    var body: some View {
        let p = usage.current
        Card {
            SectionTitle(text: "Dane w tym okresie", trailing: String(localized: "od \(NetworkUsage.periodStart().formatted(.dateTime.day().month(.abbreviated)))"))
            HStack(spacing: 8) {
                MiniStat(title: "Pobrano", value: Fmt.file(Int64(p.down)), color: Color(red: 0.35, green: 0.8, blue: 1.0), symbol: "arrow.down")
                MiniStat(title: "Wysłano", value: Fmt.file(Int64(p.up)), color: Color(red: 1.0, green: 0.45, blue: 0.6), symbol: "arrow.up")
            }
            if limitGB > 0 {
                let used = usage.counted(p), fraction = used / (limitGB * 1e9)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(meteredOnly ? "Limit (hotspot)" : "Limit").foregroundStyle(.secondary)
                        Spacer()
                        Text(verbatim: "\(Fmt.file(Int64(used))) / \(Fmt.file(Int64(limitGB * 1e9)))").fontWeight(.medium).monospacedDigit()
                            .foregroundStyle(fraction >= 1 ? .red : (fraction >= 0.8 ? .orange : .primary))
                    }
                    .font(.system(size: 11.5))
                    LinearMeter(value: min(fraction, 1), colors: fraction >= 0.8 ? [.orange, .red] : Module.network.colors, height: 6)
                }
            }
            VStack(spacing: 6) {
                if p.metered > 0 || usage.isExpensive {
                    InfoRow(title: usage.isExpensive ? String(localized: "Przez hotspot (teraz połączony)") : String(localized: "Przez hotspot"),
                            value: Fmt.file(Int64(p.metered)))
                }
                if let prev = usage.previous {
                    InfoRow(title: String(localized: "Poprzedni okres"), value: Fmt.file(Int64(prev.total)))
                }
            }
            if Snapshot.isRunning {
                Label("Limit i okres", systemImage: "slider.horizontal.3").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
            HStack {
                Menu {
                    Picker("Limit", selection: $limitGB) {
                        Text("Bez limitu").tag(0.0)
                        ForEach([5.0, 10, 20, 50, 100, 200, 500, 1000], id: \.self) { gb in
                            Text(verbatim: gb >= 1000 ? "1 TB" : "\(Int(gb)) GB").tag(gb)
                        }
                    }
                    .pickerStyle(.inline)
                    Toggle("Licz tylko hotspot i sieci komórkowe", isOn: $meteredOnly)
                    Picker("Początek okresu", selection: $startDay) {
                        ForEach(1...28, id: \.self) { Text(verbatim: "\($0).").tag($0) }
                    }
                } label: {
                    Label("Limit i okres", systemImage: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 11))
                Spacer()
            }
            }
        }
    }
}

// MARK: - Weekly summary

@MainActor
enum WeeklySummary {
    static let enabledKey = "alerts.weekly"
    private static let sentKey = "weekly.sent"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    @MainActor private static var lastCheck = Date.distantPast

    private static func weekID(_ date: Date) -> String {
        let c = Calendar(identifier: .iso8601).dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return "\(c.yearForWeekOfYear ?? 0)-\(c.weekOfYear ?? 0)"
    }

    /// Once per week, from Monday 9:00 (or later if the Mac was asleep), when there are at least two days of history.
    static func tick(_ m: SystemMonitor) {
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 60 else { return }
        lastCheck = now
        let d = UserDefaults.standard
        let week = weekID(now)
        guard let sent = d.string(forKey: sentKey) else { d.set(week, forKey: sentKey); return }   // first run: start next week
        guard sent != week, enabled else { return }
        let iso = Calendar(identifier: .iso8601)
        if iso.component(.weekday, from: now) == 2 && iso.component(.hour, from: now) < 9 { return }
        guard m.history.coarseSpanMinutes >= 2 * 1440, let body = compose(m) else { return }
        d.set(week, forKey: sentKey)
        Alerts.shared.send(title: String(localized: "Twój Mac w ostatnim tygodniu"), body: body, id: "weekly")
    }

    static func sendNow(_ m: SystemMonitor) {
        Alerts.shared.send(title: String(localized: "Twój Mac w ostatnim tygodniu"),
                           body: compose(m) ?? String(localized: "Za mało danych – podsumowanie potrzebuje co najmniej kilku godzin historii."),
                           id: "weekly.preview")
    }

    static func compose(_ m: SystemMonitor) -> String? {
        let week = 7 * 1440
        var lines: [String] = []
        if let cpu = m.history.stats(key: HistoryMetric.cpu.rawValue, fromMinutesAgo: week, toMinutesAgo: 0) {
            if let prev = m.history.stats(key: HistoryMetric.cpu.rawValue, fromMinutesAgo: 2 * week, toMinutesAgo: week), prev.minutes >= 1440 {
                lines.append(String(localized: "Procesor: średnio \(Fmt.pct(cpu.avg)) (tydzień wcześniej \(Fmt.pct(prev.avg)))"))
            } else {
                lines.append(String(localized: "Procesor: średnio \(Fmt.pct(cpu.avg))"))
            }
        }
        if let t = m.history.stats(key: HistoryMetric.temp.rawValue, fromMinutesAgo: week, toMinutesAgo: 0) {
            lines.append(String(localized: "Najwyższa temperatura: \(Fmt.temp(t.max))"))
        }
        if let w = SSDHealth.shared.writtenRecently(days: 7), w.bytes > 0 {
            lines.append(String(localized: "Zapis na SSD: \(Fmt.file(Int64(w.bytes)))"))
        }
        if m.battery.present {
            let log = BatteryLog.shared
            let charged = log.recentCharged(7).reduce(0) { $0 + $1.wh }
            let known = log.days.suffix(8).filter { $0.health != nil }
            if let h1 = known.last?.health, let h0 = known.first?.health {
                let change = (h1 - h0) * 100
                let delta = abs(change) < 0.05 ? "" : String(format: " (%@%.1f pkt)", change < 0 ? "−" : "+", abs(change))
                lines.append(String(localized: "Bateria: kondycja \(Fmt.pct(h1))\(delta), naładowano \(String(format: "%.0f Wh", charged))"))
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

// MARK: - Run a shortcut when a value crosses a threshold

@MainActor
@Observable
final class ShortcutTriggers {
    static let shared = ShortcutTriggers()
    static let key = "shortcutTriggers"

    enum Metric: String, Codable, CaseIterable, Identifiable {
        case temp, cpu, memory, batteryLow, diskFree
        var id: Self { self }
        var title: String {
            switch self {
            case .temp: String(localized: "Temperatura powyżej")
            case .cpu: String(localized: "CPU powyżej")
            case .memory: String(localized: "Pamięć powyżej")
            case .batteryLow: String(localized: "Bateria poniżej")
            case .diskFree: String(localized: "Wolne miejsce poniżej")
            }
        }
        var defaultLimit: Double {
            switch self { case .temp: 90; case .cpu: 0.9; case .memory: 0.9; case .batteryLow: 0.2; case .diskFree: 20 }
        }
        var range: ClosedRange<Double> {
            switch self { case .temp: 50...110; case .cpu: 0.3...1; case .memory: 0.5...0.98; case .batteryLow: 0.05...0.9; case .diskFree: 5...500 }
        }
        var step: Double {
            switch self { case .temp: 5; case .cpu, .memory, .batteryLow: 0.05; case .diskFree: 5 }
        }
        func format(_ v: Double) -> String {
            switch self { case .temp: Fmt.temp(v); case .diskFree: "\(Int(v)) GB"; default: Fmt.pct(v) }
        }
    }

    struct Rule: Codable, Identifiable, Equatable {
        var id = UUID()
        var metric: Metric = .temp
        var limit: Double = 90
        var shortcut = ""
    }

    private(set) var rules: [Rule] = []
    private(set) var shortcuts: [String] = []
    private(set) var lastRun: [UUID: Date] = [:]
    @ObservationIgnored private var since: [UUID: Date] = [:]
    @ObservationIgnored private var armed: Set<UUID> = []

    private init() { reload() }

    func reload() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Rule].self, from: data) {
            rules = saved
        } else {
            rules = []
        }
    }

    func setRules(_ list: [Rule]) {
        rules = list
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func loadShortcuts() {
        Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["list"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            await MainActor.run { ShortcutTriggers.shared.shortcuts = names }
        }
    }

    private func value(_ metric: Metric, _ m: SystemMonitor) -> Double? {
        switch metric {
        case .temp: m.socMax ?? m.socAvg
        case .cpu: m.cpu
        case .memory: m.memFraction
        case .batteryLow: m.battery.present && !m.battery.onAC ? m.battery.percent : nil
        case .diskFree: m.diskTotal > 0 ? Double(m.diskFree) / 1e9 : nil
        }
    }

    /// Fires after the value stays past the threshold for 30 s; again only after it went back with some margin.
    func evaluate(_ m: SystemMonitor) {
        guard !rules.isEmpty else { return }
        let now = Date()
        for r in rules where !r.shortcut.isEmpty {
            guard let v = value(r.metric, m) else { since[r.id] = nil; continue }
            let below = r.metric == .batteryLow || r.metric == .diskFree
            let past = below ? v <= r.limit : v >= r.limit
            let margin: Double = switch r.metric { case .temp: 5; case .diskFree: 5; default: 0.05 }
            let back = below ? v > r.limit + margin : v < r.limit - margin
            if back { armed.insert(r.id); since[r.id] = nil; continue }
            if lastRun[r.id] == nil, !armed.contains(r.id) { armed.insert(r.id) }
            guard past, armed.contains(r.id) else { continue }
            let start = since[r.id] ?? now
            since[r.id] = start
            guard now.timeIntervalSince(start) >= 30 else { continue }
            armed.remove(r.id)
            since[r.id] = nil
            run(r)
        }
    }

    func run(_ r: Rule) {
        lastRun[r.id] = Date()
        let name = r.shortcut
        Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }
}

struct ShortcutTriggersSection: View {
    private let triggers = ShortcutTriggers.shared

    var body: some View {
        Section {
            ForEach(triggers.rules) { rule in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("Gdy", selection: binding(rule, \.metric)) {
                            ForEach(ShortcutTriggers.Metric.allCases) { Text($0.title).tag($0) }
                        }
                        .onChange(of: rule.metric) { _, metric in update(rule.id) { $0.limit = metric.defaultLimit } }
                        Button(role: .destructive) {
                            triggers.setRules(triggers.rules.filter { $0.id != rule.id })
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    Stepper(rule.metric.format(rule.limit), value: binding(rule, \.limit), in: rule.metric.range, step: rule.metric.step)
                    Picker("Uruchom skrót", selection: binding(rule, \.shortcut)) {
                        Text("Wybierz…").tag("")
                        ForEach(names(including: rule.shortcut), id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    if let last = triggers.lastRun[rule.id] {
                        Text("Ostatnio uruchomiony: \(last.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Dodaj regułę") { triggers.setRules(triggers.rules + [ShortcutTriggers.Rule()]) }
                Spacer()
                Button("Otwórz Skróty") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }
            }
        } header: {
            Text("Skróty po przekroczeniu progu")
        } footer: {
            Text("Pulse uruchomi wybrany skrót, gdy wartość utrzyma się za progiem przez 30 sekund. Kolejny raz dopiero po powrocie do normy. Przykłady: włącz tryb niskiego zużycia energii przy słabej baterii, wyślij wiadomość przy przegrzaniu.")
        }
        .onAppear { triggers.loadShortcuts() }
    }

    private func names(including current: String) -> [String] {
        current.isEmpty || triggers.shortcuts.contains(current) ? triggers.shortcuts : [current] + triggers.shortcuts
    }

    private func update(_ id: UUID, _ change: (inout ShortcutTriggers.Rule) -> Void) {
        triggers.setRules(triggers.rules.map { var r = $0; if r.id == id { change(&r) }; return r })
    }

    private func binding<T>(_ rule: ShortcutTriggers.Rule, _ path: WritableKeyPath<ShortcutTriggers.Rule, T>) -> Binding<T> {
        Binding {
            triggers.rules.first { $0.id == rule.id }?[keyPath: path] ?? rule[keyPath: path]
        } set: { value in
            update(rule.id) { $0[keyPath: path] = value }
        }
    }
}

// MARK: - Presentation mode

/// Hides the values in the menu bar (only the Pulse icon stays) and silences Pulse's notifications.
/// Turned on by hand, or automatically while the display is mirrored (projector, AirPlay).
enum PresentationMode {
    static let onKey = "presentation.on"
    static let autoKey = "presentation.auto"
    static let mirroredKey = "presentation.mirrored"

    static var isActive: Bool {
        let d = UserDefaults.standard
        return d.bool(forKey: onKey) || (d.bool(forKey: autoKey) && d.bool(forKey: mirroredKey))
    }

    /// Kept in the defaults so that a change redraws the menu bar like any other setting.
    static func updateMirroring() {
        let mirrored = CGDisplayIsInMirrorSet(CGMainDisplayID()) != 0
        let d = UserDefaults.standard
        if d.bool(forKey: mirroredKey) != mirrored { d.set(mirrored, forKey: mirroredKey) }
    }

    static func set(_ on: Bool) {
        let d = UserDefaults.standard
        d.set(on, forKey: onKey)
        // Turning it off while it is on automatically also means "not now".
        if !on && isActive { d.set(false, forKey: autoKey) }
    }
}

struct PresentationButton: View {
    @AppStorage(PresentationMode.onKey) private var on = false
    @AppStorage(PresentationMode.autoKey) private var auto = false
    @AppStorage(PresentationMode.mirroredKey) private var mirrored = false

    var body: some View {
        let active = on || (auto && mirrored)
        Button {
            PresentationMode.set(!active)
        } label: {
            Image(systemName: active ? "eye.slash.fill" : "eye.slash")
                .foregroundStyle(active ? Color.purple : Color.primary)
                .frame(width: 16, height: 16)
        }
        .help(active ? String(localized: "Tryb prezentacji włączony – kliknij, aby wyłączyć")
                     : String(localized: "Tryb prezentacji: ukryj wartości i wycisz powiadomienia"))
    }
}

struct PresentationSettingsSection: View {
    @AppStorage(PresentationMode.onKey) private var on = false
    @AppStorage(PresentationMode.autoKey) private var auto = false

    var body: some View {
        Section {
            Toggle(isOn: $on) {
                Text("Tryb prezentacji")
                Text("W pasku menu zostaje tylko ikona Pulse, a powiadomienia Pulse milkną. Przełączysz go też przyciskiem z okiem w stopce okienka i w Skrótach.")
            }
            Toggle(isOn: $auto) {
                Text("Włączaj, gdy ekran jest dublowany")
                Text("Np. przy projektorze, telewizorze albo AirPlay w trybie dublowania.")
            }
        }
    }
}

// MARK: - Export / import settings

@MainActor
enum SettingsTransfer {
    private static let skippedPrefixes = ["NS", "SU", "Apple", "com.apple", "remote.id", "hang.", "weekly.sent", "presentation.mirrored",
                                          "presentation.on", "fan.", "WebKit", "_"]

    private static func portable(_ dict: [String: Any]) -> [String: Any] {
        dict.filter { key, _ in !skippedPrefixes.contains { key.hasPrefix($0) } }
    }

    static func exportSettings() {
        guard let id = Bundle.main.bundleIdentifier, let all = UserDefaults.standard.persistentDomain(forName: id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.propertyList]
        panel.nameFieldStringValue = "Pulse-ustawienia.plist"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: portable(all), format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
        } catch {
            NSSound.beep()
        }
    }

    static func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        guard let data = try? Data(contentsOf: url),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              dict.keys.contains(where: { $0.hasSuffix(".enabled") || $0 == "interval" }) else {
            alert.messageText = String(localized: "To nie jest plik ustawień Pulse")
            alert.runModal()
            return
        }
        let values = portable(dict)
        for (k, v) in values { UserDefaults.standard.set(v, forKey: k) }
        ProcessInsights.shared.reload()
        ShortcutTriggers.shared.reload()
        alert.messageText = String(localized: "Wczytano ustawienia")
        alert.informativeText = String(localized: "Zmienione ustawienia: \(values.count). Historia wykresów i dzienniki zostają bez zmian.")
        alert.runModal()
    }
}

// MARK: - Week heatmap (CPU panel)

struct WeekHeatmapCard: View {
    @Environment(SystemMonitor.self) private var m
    @AppStorage("heatmap.metric") private var metricRaw = HistoryMetric.cpu.rawValue

    private var metric: HistoryMetric { metricRaw == HistoryMetric.temp.rawValue ? .temp : .cpu }

    var body: some View {
        Card {
            HStack {
                SectionTitle(text: "Rytm tygodnia", trailing: Snapshot.isRunning ? metric.rawValue.uppercased() : nil)
                if !Snapshot.isRunning {
                Picker("", selection: $metricRaw) {
                    Text("CPU").tag(HistoryMetric.cpu.rawValue)
                    Text("Temp.").tag(HistoryMetric.temp.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                }
            }
            if m.history.coarseSpanMinutes < 2 * 1440 {
                Text("Mapa pojawi się po 2 dniach zbierania danych. Pokaże, o których godzinach Mac zwykle pracuje najciężej.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                grid(m.history.heatmap(key: metric.rawValue))
            }
        }
    }

    private func grid(_ data: [[Double]]) -> some View {
        let values = data.flatMap { $0 }.filter(\.isFinite)
        let lo = metric == .temp ? (values.min() ?? 30) : 0
        let hi = max(values.max() ?? 1, lo + (metric == .temp ? 5 : 0.05))
        let days = Self.weekdays
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<7, id: \.self) { row in
                HStack(spacing: 2) {
                    Text(verbatim: days[row]).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        let v = data[row][hour]
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(v.isFinite ? AnyShapeStyle(color(v).opacity(0.15 + 0.85 * (v - lo) / (hi - lo)))
                                             : AnyShapeStyle(.primary.opacity(0.05)))
                            .frame(height: 11)
                            .frame(maxWidth: .infinity)
                            .help(Text(verbatim: "\(days[row]) \(hour):00–\(hour + 1):00 · " + (v.isFinite ? metric.format(v) : "—")))
                    }
                }
            }
            HStack(spacing: 0) {
                Spacer().frame(width: 20)
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text(verbatim: "\(h)").font(.system(size: 9)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func color(_ v: Double) -> Color { metric == .temp ? Heat.color(v) : Module.cpu.tint }

    /// Monday first, in the app's language.
    private static var weekdays: [String] {
        let lang = Bundle.main.preferredLocalizations.first ?? "pl"
        if lang.hasPrefix("pl") { return ["Pn", "Wt", "Śr", "Cz", "Pt", "So", "Nd"] }
        let f = DateFormatter()
        f.locale = Locale(identifier: lang)
        let s = f.shortWeekdaySymbols ?? ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
        return Array(s[1...] + [s[0]]).map { String($0.prefix(2)).capitalized }
    }
}
