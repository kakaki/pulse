import SwiftUI

/// "Free up memory": runs `/usr/sbin/purge` with administrator rights.
/// macOS shows its own password / Touch ID dialog; Pulse never sees the password.
@MainActor @Observable
final class MemoryPurge {
    static let shared = MemoryPurge()

    enum Result: Equatable { case freed(UInt64), nothing, failed(String) }

    private(set) var running = false
    private(set) var result: Result?
    private(set) var finishedAt: Date?

    func run(_ monitor: SystemMonitor) {
        guard !running else { return }
        running = true
        result = nil
        monitor.refresh()
        let before = monitor.memTotal - min(monitor.memUsed, monitor.memTotal)
        Task {
            let outcome = await Self.purge()
            // Counters settle a moment after purge returns.
            try? await Task.sleep(for: .milliseconds(600))
            monitor.refresh()
            let after = monitor.memTotal - min(monitor.memUsed, monitor.memTotal)
            switch outcome {
            case .success:
                result = after > before ? .freed(after - before) : .nothing
                finishedAt = Date()
            case .cancelled:
                result = nil
            case .failure(let message):
                result = .failed(message)
            }
            running = false
        }
    }

    private enum Outcome { case success, cancelled, failure(String) }

    private nonisolated static func purge() async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            do { try p.run() } catch { return .failure(error.localizedDescription) }
            p.waitUntilExit()
            if p.terminationStatus == 0 { return .success }
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if text.contains("-128") { return .cancelled }   // user cancelled the password dialog
            return .failure(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }
}

struct MemoryPurgeCard: View {
    @Environment(SystemMonitor.self) private var m
    @State private var purge = MemoryPurge.shared

    var body: some View {
        Card {
            HStack {
                SectionTitle(text: "Zwolnij pamięć")
                Spacer()
                if CommandLine.arguments.contains("--snapshot") {
                    // ImageRenderer can't draw AppKit-backed buttons.
                    Text("Zwolnij").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.white.opacity(0.1), in: Capsule())
                } else {
                    Button {
                        purge.run(m)
                    } label: {
                        if purge.running {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("Zwolnij")
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(purge.running)
                }
            }
            Group {
                switch purge.result {
                case .freed(let bytes):
                    Label(String(localized: "Zwolniono \(Fmt.memory(bytes))."), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Heat.load(0))
                case .nothing:
                    Label("Nie było czego zwolnić.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Label(String(localized: "Nie udało się: \(message)"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case nil:
                    Text("Czyści pamięć podręczną plików i nieaktywne strony (polecenie purge). macOS zapyta o hasło administratora. Pomaga głównie przy wysokim ciśnieniu pamięci – zwykle system radzi sobie sam.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
