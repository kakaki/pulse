import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var sigterm: DispatchSourceSignal?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Never end up with no menu bar item at all (e.g. after ⌘-dragging the last one out).
        let defaults = UserDefaults.standard
        if !Module.allCases.contains(where: { $0.isEnabled }) {
            defaults.set(true, forKey: Module.overview.enabledKey)
        }
        statusBar = StatusBarController(monitor: SystemMonitor.shared)
        _ = Updater.shared  // starts Sparkle (background checks) when a feed is configured
        if !CommandLine.arguments.contains("--snapshot") { Alerts.shared.requestAuthorization() }
        // Save history on SIGTERM too (pkill, logout), not only on a regular quit.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { MainActor.assumeIsolated { SystemMonitor.shared.history.saveFinal() }; exit(0) }
        term.resume()
        sigterm = term
        Snapshot.runIfRequested(monitor: SystemMonitor.shared)
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemMonitor.shared.history.saveFinal()
    }
}

extension Module {
    var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled }
    var currentMode: DisplayMode {
        let raw = UserDefaults.standard.string(forKey: modeKey) ?? defaultMode.rawValue
        return DisplayMode(rawValue: raw).flatMap { modes.contains($0) ? $0 : nil } ?? defaultMode
    }
}

@MainActor
enum AppActions {
    static var closePopovers: () -> Void = {}

    static func openSettings() {
        closePopovers()
        SettingsWindowController.shared.show()
    }
}

/// One NSStatusItem + popover per enabled module, iStat Menus style.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let monitor: SystemMonitor
    private var items: [Module: NSStatusItem] = [:]
    private var popovers: [Module: NSPopover] = [:]
    private var dropdownStates: [Module: DropdownState] = [:]
    private var lastHandledClick: TimeInterval = -1
    private var pulseTimer: Timer?
    private var pulsePhase = false
    private var visibilityObservers: [Module: NSKeyValueObservation] = [:]
    private var lastSignature = ""
    /// True while a full-screen app is in front or the display is mirrored (Settings → Ogólne).
    private var hiddenForPresentation = false

    init(monitor: SystemMonitor) {
        self.monitor = monitor
        super.init()
        AppActions.closePopovers = { [weak self] in self?.popovers.values.forEach { $0.performClose(nil) } }
        syncItems()
        monitor.onUpdate = { [weak self] in
            self?.renderImages()
            Alerts.shared.evaluate(monitor)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            ws.addObserver(self, selector: #selector(updatePresentation), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(updatePresentation), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Hide the menu bar items while a full-screen app is frontmost or the main display is mirrored.
    @objc private func updatePresentation() {
        // Space switches settle a moment after the notification.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let d = UserDefaults.standard
            let hide = (d.bool(forKey: "hide.fullscreen") && Self.frontmostIsFullScreen())
                || (d.bool(forKey: "hide.mirroring") && CGDisplayIsInMirrorSet(CGMainDisplayID()) != 0)
            guard hide != self.hiddenForPresentation else { return }
            self.hiddenForPresentation = hide
            if hide { self.popovers.values.forEach { $0.close() } }
            self.renderImages()
        }
    }

    /// The frontmost app has an on-screen window covering a whole display (window bounds need no permission).
    private static func frontmostIsFullScreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let screens = NSScreen.screens.map(\.frame.size)
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            let size = CGSize(width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            return screens.contains { abs($0.width - size.width) < 1 && abs($0.height - size.height) < 1 }
        }
    }

    private func signature() -> String {
        let d = UserDefaults.standard
        return Module.allCases.map { "\($0.rawValue):\($0.isEnabled):\($0.currentMode.rawValue)" }.joined(separator: ",")
            + "|\(d.bool(forKey: "showLabels"))|\(d.bool(forKey: "colorize"))|\(d.integer(forKey: "tempUnit"))"
            + "|" + OverviewItem.ordered.map { "\($0.rawValue)\($0.isOn ? 1 : 0)\($0.style?.rawValue ?? "")\($0.showsLabel ? 1 : 0)" }.joined(separator: ".")
            + "|\(d.bool(forKey: "hide.fullscreen"))\(d.bool(forKey: "hide.mirroring"))"
            + "|\(d.object(forKey: "pulseAlerts") as? Bool ?? true)|\(d.bool(forKey: "overview.separators"))|\(d.object(forKey: "overview.net.split") as? Bool ?? true)"
    }

    @objc private func defaultsChanged() {
        let s = signature()
        guard s != lastSignature else { return }
        syncItems()
        updatePresentation()
    }

    private func syncItems() {
        lastSignature = signature()
        // New status items appear to the left of existing ones, so create them right-to-left.
        for module in Module.allCases.reversed() {
            if module.isEnabled, items[module] == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.autosaveName = "pulse.\(module.rawValue)"
                item.behavior = .removalAllowed
                item.button?.target = self
                item.button?.action = #selector(togglePopover(_:))
                item.button?.identifier = NSUserInterfaceItemIdentifier(module.rawValue)
                item.button?.toolTip = module.title
                items[module] = item
                visibilityObservers[module] = item.observe(\.isVisible, options: [.new]) { _, change in
                    // User ⌘-dragged the item out of the menu bar.
                    if change.newValue == false {
                        Task { @MainActor in UserDefaults.standard.set(false, forKey: module.enabledKey) }
                    }
                }
            } else if !module.isEnabled, let item = items[module] {
                visibilityObservers[module] = nil
                popovers[module]?.performClose(nil)
                NSStatusBar.system.removeStatusItem(item)
                items[module] = nil
            }
        }
        renderImages()
    }

    private func renderImages() {
        let labels = UserDefaults.standard.bool(forKey: "showLabels")
        let colorize = UserDefaults.standard.bool(forKey: "colorize")
        let pulse = UserDefaults.standard.object(forKey: "pulseAlerts") as? Bool ?? true
        var anyCritical = false
        defer { updatePulse(active: pulse && anyCritical) }
        if hiddenForPresentation {
            for item in items.values { item.button?.isHidden = true; item.length = 0 }
            return
        }
        for (module, item) in items {
            item.button?.isHidden = false
            let dark = item.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var snapshot = StatusSnapshot.make(module, monitor)
            if module == .overview, popovers[module]?.isShown == true { snapshot.highlight = dropdownStates[module]?.selected }
            if snapshot.pulseLevel >= 0.9 { anyCritical = true }
            snapshot.dimCritical = pulse && pulsePhase
            let image = StatusRenderer.image(module: module, mode: module.currentMode,
                                             snapshot: snapshot, labels: labels,
                                             colorize: colorize, darkBar: dark)
            item.button?.image = image
            // Tighter than the default padding: on notched MacBooks every point of menu bar space counts.
            item.length = ceil(image.size.width) + 8
        }
    }

    /// Blink critical values (~0.7 s) while any item is over its critical threshold.
    private func updatePulse(active: Bool) {
        if active, pulseTimer == nil {
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pulsePhase.toggle()
                    self.renderImages()
                }
            }
        } else if !active, let timer = pulseTimer {
            timer.invalidate()
            pulseTimer = nil
            pulsePhase = false
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return handleClick(sender, at: nil) }
        // Already handled from popoverShouldClose (the open popover swallowed the mouse-down).
        if abs(event.timestamp - lastHandledClick) < 0.5 { return }
        handleClick(sender, at: event.locationInWindow)
    }

    private func handleClick(_ sender: NSStatusBarButton, at location: NSPoint?) {
        guard let raw = sender.identifier?.rawValue, let module = Module(rawValue: raw) else { return }

        // The overview item shows several values: open the panel of the one that was clicked.
        var target: Module?
        if module == .overview, let image = sender.image, let location {
            let point = sender.convert(location, from: nil)
            let x = point.x - (sender.bounds.width - image.size.width) / 2
            target = StatusRenderer.overviewCell(at: x, snapshot: .make(.overview, monitor), mode: module.currentMode)
        }

        if let open = popovers[module], open.isShown {
            // Same section again → close; another value of the overview → switch the open panel.
            if module == .overview, let target, let state = dropdownStates[module], state.selected != target {
                state.selected = target
            } else {
                open.close()
            }
            return
        }
        popovers.values.forEach { $0.close() }

        // A pinned module (overview tile → "Przypnij") always opens first.
        if module == .overview, let pinned = UserDefaults.standard.string(forKey: "overview.pinned").flatMap(Module.init(rawValue:)) {
            target = pinned
        }
        let popover = makePopover(for: module, opening: target)
        popovers[module] = popover
        NSApp.activate()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        renderImages()
    }

    /// A transient popover closes on any mouse-down outside it — including on our own menu bar items,
    /// before their action runs. Keep it open for those clicks; `togglePopover` then decides
    /// (same value → close, another overview value → switch, another item → swap popovers).
    /// The open popover consumes that mouse-down, so the button never sees it: handle the click here.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard let event = NSApp.currentEvent,
              [.leftMouseDown, .rightMouseDown].contains(event.type),
              let window = event.window,
              let button = items.values.compactMap(\.button).first(where: { $0.window === window })
        else { return true }
        lastHandledClick = event.timestamp
        let location = event.locationInWindow
        DispatchQueue.main.async { [weak self] in self?.handleClick(button, at: location) }
        return false
    }

    /// Drop the SwiftUI content of a closed popover; otherwise its (offscreen) charts keep
    /// re-laying out on every data refresh and burn CPU.
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
              let entry = popovers.first(where: { $0.value === popover }) else { return }
        popover.contentViewController = nil
        popovers[entry.key] = nil
        dropdownStates[entry.key] = nil
        renderImages()
    }

    private func makePopover(for module: Module, opening: Module? = nil) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let state = DropdownState(selected: opening)
        state.onChange = { [weak self] in self?.renderImages() }
        dropdownStates[module] = state
        let host = NSHostingController(rootView: ModuleDropdown(module: module, state: state).environment(monitor))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.delegate = self
        return popover
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environment(SystemMonitor.shared))
            let window = NSWindow(contentViewController: host)
            window.title = String(localized: "Pulse — Ustawienia")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 720, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
