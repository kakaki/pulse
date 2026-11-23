import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Confirmation panel (pairing code, incoming files)

/// A small floating panel with two buttons; answers false on Cancel, close or timeout.
@MainActor
final class SharePrompt {
    private var panel: NSPanel?
    private var answer: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private(set) var timedOut = false

    static func show(title: String, message: String, code: String?, ok: String, cancel: String, timeout: TimeInterval) -> SharePrompt {
        let prompt = SharePrompt()
        let view = SharePromptView(title: title, message: message, code: code, ok: ok, cancel: cancel) { [weak prompt] in prompt?.finish($0) }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        // A panel hides when its app is inactive, and a menu bar app often stays inactive.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view)
        panel.setContentSize(panel.contentView!.fittingSize)
        panel.center()
        NSApp.activate()
        panel.orderFrontRegardless()
        panel.makeKey()
        prompt.panel = panel
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak prompt] _ in
            MainActor.assumeIsolated { prompt?.finish(false) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak prompt] in
            MainActor.assumeIsolated {
                guard let prompt, prompt.answer == nil else { return }
                prompt.timedOut = true
                prompt.finish(false)
            }
        }
        return prompt
    }

    func result() async -> Bool {
        if let answer { return answer }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func dismiss() { finish(false) }

    private func finish(_ value: Bool) {
        guard answer == nil else { return }
        answer = value
        panel?.orderOut(nil)
        panel = nil
        for w in waiters { w.resume(returning: value) }
        waiters = []
    }
}

private struct SharePromptView: View {
    let title: String
    let message: String
    let code: String?
    let ok: String
    let cancel: String
    let answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: code == nil ? "arrow.down.doc" : "lock.shield")
                .font(.system(size: 30)).foregroundStyle(.tint)
            Text(verbatim: title).font(.headline).multilineTextAlignment(.center)
            if let code {
                Text(verbatim: code).font(.system(size: 34, weight: .bold, design: .monospaced))
            }
            Text(verbatim: message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(cancel) { answer(false) }.keyboardShortcut(.cancelAction)
                Button(ok) { answer(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - Menus

final class ActionMenuItem: NSMenuItem {
    private var handler: (() -> Void)?
    convenience init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: key)
        self.handler = handler
        target = self
        keyEquivalentModifierMask = []
    }
    @objc private func run() { handler?() }
}

@MainActor
enum ShareMenus {
    /// Chooser for the clipboard shortcut: one line per online computer, keys 1–9.
    static func chooser(peers: [SharePeer], infos: [String: [String: Any]]) -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: String(localized: "Pobierz schowek z"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (i, peer) in peers.enumerated() {
            let detail = infos[peer.id].map(describe) ?? ""
            let title = detail.isEmpty ? peer.name : "\(peer.name) — \(detail)"
            menu.addItem(ActionMenuItem(title, key: i < 9 ? "\(i + 1)" : "") { ShareCenter.shared.fetchClipboard(from: peer) })
        }
        return menu
    }

    /// "tekst 1,2 KB, 2 min temu".
    static func describe(_ info: [String: Any]) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(info["size"] as? Int ?? 0), countStyle: .file)
        var text: String
        switch info["kind"] as? String {
        case "text": text = String(localized: "tekst \(size)")
        case "image": text = String(localized: "obraz \(size)")
        case "off": return String(localized: "nie udostępnia")
        default: return String(localized: "pusty")
        }
        if let age = info["age"] as? Int {
            text += ", " + (age < 60 ? String(localized: "przed chwilą") : String(localized: "\(age / 60) min temu"))
        }
        return text
    }

    /// Menu of online computers for files dropped on the menu bar icon.
    static func sendMenu(_ urls: [URL]) -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: String(localized: "Wyślij do"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for peer in ShareCenter.shared.onlinePeers {
            menu.addItem(ActionMenuItem(peer.name) { ShareCenter.shared.send(urls, to: peer) })
        }
        return menu
    }

    /// ⌘V into the frontmost app (needs Accessibility access).
    static func pasteNow() {
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Global shortcut ⌃⌥⌘V

@MainActor
final class ShareHotkey {
    static let shared = ShareHotkey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func update(_ on: Bool) {
        if on, ref == nil { register() }
        if !on, let r = ref { UnregisterEventHotKey(r); ref = nil }
    }

    private func register() {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { ShareCenter.shared.takeClipboard() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5053_4856), id: 1)   // "PSHV"
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - Dropping files on the menu bar icon

/// Delegate of a status item's window: files dropped on the icon go to a paired computer chosen from a menu.
final class ShareDropTarget: NSObject, NSWindowDelegate, NSDraggingDestination {
    weak var button: NSStatusBarButton?

    @MainActor static func attach(to button: NSStatusBarButton) {
        guard let window = button.window else { return }
        let target = ShareDropTarget()
        target.button = button
        objc_setAssociatedObject(window, &key, target, .OBJC_ASSOCIATION_RETAIN)
        window.registerForDraggedTypes([.fileURL])
        window.delegate = target
    }
    nonisolated(unsafe) private static var key = 0

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated { ShareCenter.isOn && !ShareCenter.shared.onlinePeers.isEmpty }
            && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(sender) else { return [] }
        MainActor.assumeIsolated { button?.highlight(true) }
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) { MainActor.assumeIsolated { button?.highlight(false) } }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated { button?.highlight(false) }
        guard canAccept(sender),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let online = ShareCenter.shared.onlinePeers
                if online.count == 1 { ShareCenter.shared.send(urls, to: online[0]); return }
                guard let button = self.button else { return }
                ShareMenus.sendMenu(urls).popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            }
        }
        return true
    }
}

// MARK: - Settings

struct ShareSettingsSection: View {
    @AppStorage(ShareCenter.onKey) private var on = false
    @AppStorage(ShareCenter.clipKey) private var clip = true
    @AppStorage(ShareCenter.filesKey) private var files = true
    @AppStorage(ShareCenter.notifyKey) private var notify = true
    @AppStorage(ShareCenter.pasteKey) private var paste = false
    @AppStorage(ShareCenter.hotkeyKey) private var hotkey = true
    private let share = ShareCenter.shared

    var body: some View {
        Section {
            Toggle(isOn: $on) {
                Text("Schowek i pliki")
                Text("Pobieraj na żądanie schowek z innego komputera z Pulse lub PulseWin i wysyłaj mu pliki. Działa tylko między sparowanymi komputerami, połączenie jest szyfrowane.")
            }
            .onChange(of: on) { share.apply() }
            if on {
                Toggle(isOn: $clip) {
                    Text("Udostępniaj mój schowek na żądanie")
                    Text("Skopiowany tekst lub obraz zostaje na tym Macu. Sparowany komputer pobiera go tylko wtedy, gdy ktoś przy nim o to poprosi.")
                }
                Toggle("Powiadamiaj, gdy ktoś pobierze mój schowek", isOn: $notify).disabled(!clip)
                Toggle("Przyjmuj pliki", isOn: $files)
                Toggle(isOn: $hotkey) {
                    Text("Skrót ⌃⌥⌘V pobiera schowek")
                    Text("Przy jednym sparowanym komputerze w sieci pobiera od razu, przy kilku pokazuje listę.")
                }
                .onChange(of: hotkey) { share.apply() }
                Toggle(isOn: $paste) {
                    Text("Od razu wklejaj pobrany schowek")
                    Text("Wymaga dostępu w Ustawieniach systemowych → Prywatność i ochrona → Dostępność.")
                }
                .onChange(of: paste) {
                    if paste && !AXIsProcessTrusted() {
                        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                    }
                }
                ForEach(share.paired) { peer in
                    HStack {
                        Image(systemName: peer.platform == "windows" ? "pc" : "desktopcomputer")
                            .foregroundStyle(share.isOnline(peer.id) ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: peer.name)
                            Text("Sparowano \(peer.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Zawsze przyjmuj pliki", isOn: Binding(get: { peer.autoAccept }, set: { share.setAutoAccept(peer.id, $0) }))
                            .toggleStyle(.checkbox).font(.caption)
                        Button("Usuń") { share.remove(peer.id) }
                    }
                }
                if !Snapshot.isRunning {
                    Menu("Sparuj z komputerem…") {
                        let list = share.nearby.values.sorted { $0.name < $1.name }
                        if list.isEmpty { Text("W sieci nie widać komputerów z włączoną opcją „Schowek i pliki”.") }
                        ForEach(list) { n in
                            Button(n.name + (share.peer(n.id) != nil ? " ✓" : "")) { share.pair(with: n) }
                        }
                    }
                }
                if let error = share.listenerError {
                    Text(verbatim: error).font(.callout).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Schowek i pliki")
        } footer: {
            Text("Parowanie: włącz opcję na obu komputerach, wybierz „Sparuj z komputerem…” i potwierdź ten sam kod na obu ekranach. Pliki przeciągnij na kartę komputera w panelu Inne komputery albo na ikonę Pulse w pasku menu; trafią do folderu Pobrane.")
        }
    }
}

// MARK: - Computer card: clipboard button, file drop, progress

struct ShareCardRow: View {
    let peerID: String
    private let share = ShareCenter.shared

    var body: some View {
        if let peer = share.peer(peerID), share.isOnline(peerID) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        share.fetchClipboard(from: peer)
                    } label: { Label("Pobierz schowek", systemImage: "doc.on.clipboard") }
                    Button {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = true
                        panel.canChooseDirectories = true
                        NSApp.activate(ignoringOtherApps: true)
                        if panel.runModal() == .OK { share.send(panel.urls, to: peer) }
                    } label: { Label("Wyślij pliki…", systemImage: "paperplane") }
                    Spacer()
                }
                .controlSize(.small)
                ForEach(share.transfers.filter { $0.peerID == peerID }) { t in
                    HStack(spacing: 8) {
                        Image(systemName: t.incoming ? "arrow.down.circle" : "arrow.up.circle").foregroundStyle(.secondary)
                        LinearMeter(value: t.fraction, colors: [.blue.opacity(0.7), .blue], height: 5)
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: t.total, countStyle: .file))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                        if !t.incoming {
                            Button { share.cancelTransfer(t.id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Files dropped on a paired computer's card are sent to it.
struct ShareDropModifier: ViewModifier {
    let peerID: String
    @State private var targeted = false

    func body(content: Content) -> some View {
        let share = ShareCenter.shared
        if let peer = share.peer(peerID), share.isOnline(peerID), !Snapshot.isRunning {
            content
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, lineWidth: 2)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.08)))
                            .overlay(Label("Upuść, aby wysłać do \(peer.name)", systemImage: "paperplane.fill").font(.callout.weight(.semibold)))
                            .allowsHitTesting(false)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    Task {
                        var urls: [URL] = []
                        for p in providers {
                            if let item = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                               let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                        }
                        if !urls.isEmpty { share.send(urls, to: peer) }
                    }
                    return true
                }
        } else {
            content
        }
    }
}
