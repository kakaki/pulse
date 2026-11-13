import AppKit
import SwiftUI

/// Notices when Pulse stops responding (the main thread is blocked for several seconds) and saves a `sample`
/// of the process to ~/Library/Logs/Pulse, so the cause can be found afterwards. Uses uptime, which stops while
/// the Mac sleeps, so sleep is not mistaken for a hang. At most one report per 10 minutes; the newest 5 are kept.
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()
    static let threshold: UInt64 = 6_000_000_000   // ns

    static let folder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Pulse", isDirectory: true)

    private let lock = NSLock()
    private var lastPong = DispatchTime.now().uptimeNanoseconds
    private var started = false

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        let thread = Thread { [self] in loop() }
        thread.name = "Pulse hang watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func loop() {
        var reported = false
        var lastReport: UInt64 = 0
        while true {
            DispatchQueue.main.async { [self] in
                lock.lock(); lastPong = DispatchTime.now().uptimeNanoseconds; lock.unlock()
            }
            Thread.sleep(forTimeInterval: 1)
            lock.lock(); let pong = lastPong; lock.unlock()
            let now = DispatchTime.now().uptimeNanoseconds
            let lag = now > pong ? now - pong : 0
            if lag < 2_000_000_000 { reported = false; continue }
            guard lag >= Self.threshold, !reported, lastReport == 0 || now - lastReport > 600_000_000_000 else { continue }
            reported = true
            lastReport = now
            writeReport()
        }
    }

    private func writeReport() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
            .replacingOccurrences(of: ":", with: "")
        let file = Self.folder.appendingPathComponent("Pulse-hang-\(stamp).txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(getpid())", "3", "-file", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return }
        let old = Self.reports().dropFirst(5)
        for url in old { try? FileManager.default.removeItem(at: url) }
    }

    /// Saved reports, newest first.
    static func reports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("Pulse-hang-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

/// Settings → General.
struct HangReportsSection: View {
    @State private var reports: [URL] = []

    var body: some View {
        Section {
            LabeledContent {
                if !reports.isEmpty {
                    Button("Pokaż w Finderze") {
                        NSWorkspace.shared.activateFileViewerSelecting([reports[0]])
                    }
                }
            } label: {
                Text("Raporty zawieszeń")
                Text(reports.first.flatMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
                    .map { String(localized: "\(reports.count) · ostatni \($0.formatted(date: .abbreviated, time: .shortened))") }
                     ?? String(localized: "Brak – Pulse ani razu nie przestał odpowiadać."))
            }
        } header: {
            Text("Diagnostyka")
        } footer: {
            Text("Gdy Pulse przestanie odpowiadać na dłużej niż 6 sekund, zapisuje raport w ~/Library/Logs/Pulse. Raport zostaje na tym Macu – możesz go przesłać, aby pomóc znaleźć przyczynę.")
        }
        .onAppear { reports = HangWatchdog.reports() }
    }
}
