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

    /// Several processes with one name: asks first, then quits (or force quits) all of them.
    static func quitGroup(_ pids: [pid_t], name: String, force: Bool) {
        AppActions.closePopovers()
        let alert = NSAlert()
        alert.messageText = force ? String(localized: "Wymusić zakończenie wszystkich procesów „\(name)” (\(pids.count))?")
                                  : String(localized: "Zakończyć wszystkie procesy „\(name)” (\(pids.count))?")
        alert.informativeText = force ? String(localized: "Niezapisane zmiany w tej aplikacji zostaną utracone.")
                                      : String(localized: "Aplikacje mogą zapytać o zapisanie dokumentów.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: force ? String(localized: "Wymuś zakończenie") : String(localized: "Zakończ wszystkie"))
        alert.addButton(withTitle: String(localized: "Anuluj"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var failures = 0
        for pid in pids where canEnd(pid) {
            if let app = NSRunningApplication(processIdentifier: pid) {
                if !(force ? app.forceTerminate() : app.terminate()) && kill(pid, force ? SIGKILL : SIGTERM) != 0 { failures += 1 }
            } else if kill(pid, force ? SIGKILL : SIGTERM) != 0 {
                failures += 1
            }
        }
        if failures == pids.count { failed(name) }
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
    /// `group`: all processes of a grouped row; the actions then apply to all of them.
    func processMenu(pid: pid_t, name: String, group: [pid_t] = []) -> some View {
        contextMenu {
            if group.count > 1 {
                let ok = group.contains(where: ProcessActions.canEnd)
                Button("Zakończ wszystkie (\(group.count))…") { ProcessActions.quitGroup(group, name: name, force: false) }.disabled(!ok)
                Button("Wymuś zakończenie wszystkich…") { ProcessActions.quitGroup(group, name: name, force: true) }.disabled(!ok)
            } else {
                let ok = ProcessActions.canEnd(pid)
                Button("Zakończ") { ProcessActions.quit(pid, name: name) }.disabled(!ok)
                Button("Wymuś zakończenie…") { ProcessActions.forceQuit(pid, name: name) }.disabled(!ok)
            }
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
