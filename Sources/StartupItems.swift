import AppKit
import Darwin
import SwiftUI

/// Background items started by launchd (LaunchAgents and LaunchDaemons): what they are, whether they run now
/// and how much CPU time and memory they use. The user's own agents can be turned off and on again.
@MainActor
@Observable
final class StartupItems {
    static let shared = StartupItems()

    enum Scope: Int, Comparable {
        case user, allUsers, system
        static func < (a: Scope, b: Scope) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .user: String(localized: "Twoje konto")
            case .allUsers: String(localized: "Wszyscy użytkownicy")
            case .system: String(localized: "System (demon)")
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id: String          // plist path
        let label: String
        let name: String        // readable: app or program name
        let program: String?
        let scope: Scope
        var disabled: Bool
        var running = false
        /// CPU time since the process started (seconds) and memory now.
        var cpuSeconds: Double = 0
        var memory: UInt64 = 0
        var url: URL { URL(fileURLWithPath: id) }
    }

    private(set) var items: [Item] = []
    private(set) var scanning = false
    private(set) var lastScan: Date?
    private(set) var error: String?

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let list = Self.read()
            await MainActor.run {
                let s = StartupItems.shared
                s.items = list
                s.scanning = false
                s.lastScan = Date()
            }
        }
    }

    // MARK: Reading

    private nonisolated static func read() -> [Item] {
        let home = NSHomeDirectory()
        let dirs: [(String, Scope)] = [("\(home)/Library/LaunchAgents", .user), ("/Library/LaunchAgents", .allUsers),
                                        ("/Library/LaunchDaemons", .system)]
        let disabled = disabledLabels()
        let running = runningByPath()
        var result: [Item] = []
        for (dir, scope) in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let path = "\(dir)/\(file)"
                guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
                let label = dict["Label"] as? String ?? (file as NSString).deletingPathExtension
                let program = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
                var item = Item(id: path, label: label, name: readableName(label: label, program: program), program: program, scope: scope,
                                disabled: (dict["Disabled"] as? Bool ?? false) || (scope == .user && disabled.contains(label)))
                if let program, let usage = running[program] {
                    item.running = true
                    item.cpuSeconds = usage.cpu
                    item.memory = usage.memory
                }
                result.append(item)
            }
        }
        return result.sorted {
            if $0.running != $1.running { return $0.running }
            if $0.cpuSeconds != $1.cpuSeconds { return $0.cpuSeconds > $1.cpuSeconds }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// "Google Updater" from ".../GoogleUpdater.app/Contents/MacOS/GoogleUpdater", otherwise the program or label.
    private nonisolated static func readableName(label: String, program: String?) -> String {
        if let program, let range = program.range(of: ".app/") {
            return (String(program[..<range.lowerBound]) as NSString).lastPathComponent
        }
        if let program { return (program as NSString).lastPathComponent }
        return label
    }

    /// Labels the user turned off with `launchctl disable`.
    private nonisolated static func disabledLabels() -> Set<String> {
        let out = launchctl(["print-disabled", "gui/\(getuid())"]).output
        var set = Set<String>()
        for line in out.split(separator: "\n") where line.contains("=> disabled") || line.contains("=> true") {
            if let first = line.firstIndex(of: "\""), let last = line[line.index(after: first)...].firstIndex(of: "\"") {
                set.insert(String(line[line.index(after: first)..<last]))
            }
        }
        return set
    }

    /// Executable path → CPU time and memory, summed over processes started from it.
    private nonisolated static func runningByPath() -> [String: (cpu: Double, memory: UInt64)] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let tb = Double(info.numer) / Double(info.denom)
        var result: [String: (cpu: Double, memory: UInt64)] = [:]
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            let cpu = Double(usage.ri_user_time + usage.ri_system_time) * tb / 1e9
            let old = result[path] ?? (0, 0)
            result[path] = (old.cpu + cpu, old.memory + usage.ri_phys_footprint)
        }
        return result
    }

    private nonisolated static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Turning user agents off and on

    func setEnabled(_ item: Item, _ enabled: Bool) {
        guard item.scope == .user else { return }
        if !enabled {
            AppActions.closePopovers()
            let alert = NSAlert()
            alert.messageText = String(localized: "Wyłączyć „\(item.name)”?")
            alert.informativeText = String(localized: "Zostanie zatrzymany i nie uruchomi się przy następnym logowaniu. Aplikacja, która go dodała, może przestać się sama aktualizować lub synchronizować. Włączysz go z powrotem w tym samym miejscu.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Wyłącz"))
            alert.addButton(withTitle: String(localized: "Anuluj"))
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let domain = "gui/\(getuid())"
        let path = item.id, label = item.label
        Task.detached(priority: .userInitiated) {
            var failed = false
            if enabled {
                failed = Self.launchctl(["enable", "\(domain)/\(label)"]).status != 0
                _ = Self.launchctl(["bootstrap", domain, path])   // fails harmlessly when already loaded
            } else {
                failed = Self.launchctl(["disable", "\(domain)/\(label)"]).status != 0
                _ = Self.launchctl(["bootout", domain, path])
            }
            let result = failed
            await MainActor.run {
                StartupItems.shared.error = result ? String(localized: "Nie udało się zmienić „\(label)”.") : nil
                StartupItems.shared.scan()
            }
        }
    }

    func applyDemo() {
        items = [
            Item(id: "/demo/1", label: "com.google.GoogleUpdater.wake", name: "GoogleUpdater", program: nil, scope: .user, disabled: false,
                 running: true, cpuSeconds: 412, memory: 38 << 20),
            Item(id: "/demo/2", label: "com.adobe.ccxprocess", name: "Adobe Desktop Service", program: nil, scope: .allUsers, disabled: false,
                 running: true, cpuSeconds: 188, memory: 210 << 20),
            Item(id: "/demo/3", label: "com.microsoft.update.agent", name: "Microsoft AutoUpdate", program: nil, scope: .allUsers, disabled: false),
            Item(id: "/demo/4", label: "com.docker.helper", name: "Docker", program: nil, scope: .system, disabled: false,
                 running: true, cpuSeconds: 35, memory: 12 << 20),
        ]
        lastScan = Date()
    }
}

/// CPU panel: what starts in the background, collapsed until asked for.
struct StartupItemsCard: View {
    private let startup = StartupItems.shared
    @AppStorage("startup.expanded") private var expanded = false

    var body: some View {
        Card {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                if expanded { startup.scan() }
            } label: {
                HStack {
                    SectionTitle(text: "Działa w tle", trailing: summary)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                if startup.items.isEmpty {
                    HStack(spacing: 6) {
                        if startup.scanning { ProgressView().controlSize(.mini) }
                        Text(startup.scanning ? "Sprawdzam…" : "Brak agentów i demonów innych aplikacji.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(startup.items) { row($0) }
                    }
                }
                if let error = startup.error { Text(verbatim: error).font(.system(size: 10.5)).foregroundStyle(.red) }
                HStack(alignment: .top) {
                    Text("Programy innych aplikacji uruchamiane przy starcie (LaunchAgents i LaunchDaemons). Czas CPU liczy się od ich uruchomienia. Aplikacje otwierane przy logowaniu i zgody na działanie w tle zmienisz w Ustawieniach systemowych.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button {
                        AppActions.closePopovers()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless)
                        .help("Otwórz Ustawienia systemowe → Elementy logowania")
                }
            }
        }
        .onAppear { if expanded && startup.lastScan == nil { startup.scan() } }
    }

    private var summary: String? {
        guard startup.lastScan != nil else { return nil }
        let running = startup.items.filter(\.running).count
        return String(localized: "\(running) z \(startup.items.count) działa")
    }

    private func row(_ item: StartupItems.Item) -> some View {
        HStack(spacing: 8) {
            Circle().fill(item.running ? Color.green : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.name).font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(item.disabled ? .secondary : .primary)
                Text(verbatim: item.disabled ? String(localized: "wyłączony") + " · " + item.scope.title : item.scope.title)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(Text(verbatim: item.label + (item.program.map { "\n" + $0 } ?? "")))
            Spacer(minLength: 4)
            if item.running {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(verbatim: Self.cpuTime(item.cpuSeconds)).fontWeight(.medium)
                    Text(verbatim: Fmt.memory(item.memory)).foregroundStyle(.secondary)
                }
                .font(.system(size: 10.5)).monospacedDigit()
            }
            if Snapshot.isRunning {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            } else {
            Menu {
                if item.scope == .user {
                    if item.disabled {
                        Button("Włącz") { StartupItems.shared.setEnabled(item, true) }
                    } else {
                        Button("Wyłącz…") { StartupItems.shared.setEnabled(item, false) }
                    }
                    Divider()
                }
                Button("Pokaż plik w Finderze") {
                    AppActions.closePopovers()
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                if item.scope != .user {
                    Text("Wymaga uprawnień administratora – wyłączysz go w Ustawieniach systemowych → Elementy logowania")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            }
        }
    }

    /// "3 min 12 s", "45 s", "2 h 05 min".
    static func cpuTime(_ s: Double) -> String {
        let t = Int(s)
        if t >= 3600 { return "\(t / 3600) h \(String(format: "%02d", (t % 3600) / 60)) min" }
        if t >= 60 { return "\(t / 60) min \(t % 60) s" }
        return String(format: "%.0f s", s)
    }
}
