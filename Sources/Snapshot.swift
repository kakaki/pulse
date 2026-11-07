import SwiftUI

/// Debug helper: `Pulse --snapshot <dir>` renders every dropdown and menu bar style to PNG files and exits.
@MainActor
enum Snapshot {
    private static var started = false
    static func runIfRequested(monitor: SystemMonitor) {
        guard !started else { return }
        started = true
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        FileHandle.standardError.write("snapshot start\n".data(using: .utf8)!)
        Task { @MainActor in
            FileHandle.standardError.write("task running\n".data(using: .utf8)!)
            monitor.processWatchers += 1
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(700))
                monitor.refresh()
            }
            for s in monitor.sensors { print("sensor:", s.id, s.kind, String(format: "%.1f", s.value)) }
            print("gpu:", monitor.gpu ?? -1, "battery:", monitor.battery)
            let csv = monitor.history.csv().split(separator: "\n")
            print("csv:", csv.count, csv.prefix(2).joined(separator: " | "), "|", csv.last ?? "")
            print("thermal:", monitor.thermalState.title, "week:", monitor.history.series(.cpu, range: .week).count,
                  "month:", monitor.history.series(.cpu, range: .month).count)
            for mode in Module.overview.modes {
                let snap = StatusSnapshot.make(.overview, monitor)
                let w = StatusRenderer.image(module: .overview, mode: mode, snapshot: snap, labels: true).size.width
                let hits = stride(from: 0, to: w, by: 4).map { StatusRenderer.overviewCell(at: $0, snapshot: snap, mode: mode)?.rawValue ?? "-" }
                print("hit:", mode.rawValue, Int(w), snap.cells.map(\.label), hits.joined(separator: " "))
            }
            do {
                var snap = StatusSnapshot.make(.overview, monitor)
                snap.highlight = snap.cells.dropFirst().first?.module
                let bar = VStack(spacing: 6) {
                    ForEach(Module.overview.modes) { mode in
                        StatusContent(module: .overview, mode: mode, s: snap, labels: true, color: .white)
                            .fixedSize()
                    }
                }
                .padding(8).background(Color(white: 0.15))
                save(bar, dir.appendingPathComponent("overview-bar.png"))
            }
            for module in Module.allCases where module.isEnabled { let img = StatusRenderer.image(module: module, mode: module.currentMode, snapshot: .make(module, monitor), labels: UserDefaults.standard.bool(forKey: "showLabels")); print("width:", module.rawValue, module.currentMode.rawValue, img.size.width) }
            for scheme in [ColorScheme.dark, .light] {
                for module in Module.allCases {
                    let view = ModuleDropdown(module: module, state: DropdownState())
                        .environment(monitor)
                        .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.95))
                        .environment(\.colorScheme, scheme)
                    save(view, dir.appendingPathComponent("\(module.rawValue)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
            let bar = HStack(spacing: 14) {
                ForEach(Module.allCases) { module in
                    ForEach(module.modes) { mode in
                        Image(nsImage: StatusRenderer.image(module: module, mode: mode,
                                                            snapshot: .make(module, monitor), labels: true))
                            .renderingMode(.template)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(8)
            .background(Color(white: 0.15))
            save(bar, dir.appendingPathComponent("menubar.png"))
            exit(0)
        }
    }

    private static func save(_ view: some View, _ url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
