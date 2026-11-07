import AppKit
import SwiftUI

/// Right-click actions for process rows: quit, force quit, open Activity Monitor.
@MainActor
enum ProcessActions {
    static func canEnd(_ pid: pid_t) -> Bool { pid > 1 && pid != getpid() && kill(pid, 0) == 0 }

    static func quit(_ pid: pid_t, name: String) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()   // regular apps may ask to save documents
        } else if kill(pid, SIGTERM) != 0 {
            failed(name)
        }
    }

    static func forceQuit(_ pid: pid_t, name: String) {
        AppActions.closePopovers()
        let alert = NSAlert()
        alert.messageText = String(localized: "Wymusić zakończenie „\(name)”?")
        alert.informativeText = String(localized: "Niezapisane zmiany w tej aplikacji zostaną utracone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Wymuś zakończenie"))
        alert.addButton(withTitle: String(localized: "Anuluj"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let app = NSRunningApplication(processIdentifier: pid), app.forceTerminate() { return }
        if kill(pid, SIGKILL) != 0 { failed(name) }
    }

    static func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        AppActions.closePopovers()
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private static func failed(_ name: String) {
        AppActions.closePopovers()
        let alert = NSAlert()
        alert.messageText = String(localized: "Nie można zakończyć „\(name)”")
        alert.informativeText = String(localized: "To proces systemowy lub innego użytkownika. Użyj Monitora aktywności.")
        NSApp.activate()
        alert.runModal()
    }
}

extension View {
    /// Context menu with process actions; no-op in snapshot mode.
    func processMenu(pid: pid_t, name: String) -> some View {
        contextMenu {
            let ok = ProcessActions.canEnd(pid)
            Button("Zakończ") { ProcessActions.quit(pid, name: name) }.disabled(!ok)
            Button("Wymuś zakończenie…") { ProcessActions.forceQuit(pid, name: name) }.disabled(!ok)
            Divider()
            Button("Pokaż w Monitorze aktywności") { ProcessActions.openActivityMonitor() }
        }
    }
}

/// Click to copy the value; shows a short confirmation in place of the value.
struct CopyableValue: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Group {
            if copied {
                Label("Skopiowano", systemImage: "checkmark").foregroundStyle(Heat.load(0))
            } else {
                Text(value).monospacedDigit()
            }
        }
        .fontWeight(.medium)
        .contentShape(Rectangle())
        .onTapGesture {
            guard value != "—" else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            Task { try? await Task.sleep(for: .seconds(1.2)); withAnimation { copied = false } }
        }
        .help(Text("Kliknij, aby skopiować"))
    }
}
