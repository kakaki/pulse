import SwiftUI

/// Which module's details the overview dropdown shows below its tiles.
/// Shared with the status bar so a click on another value in the menu bar switches it.
@MainActor
@Observable
final class DropdownState {
    var selected: Module {
        didSet {
            UserDefaults.standard.set(selected.rawValue, forKey: "overview.selected")
            onChange?()
        }
    }
    /// Lets the status bar re-highlight the matching value in the menu bar.
    @ObservationIgnored var onChange: (() -> Void)?
    init(selected: Module? = nil) {
        self.selected = selected
            ?? UserDefaults.standard.string(forKey: "overview.selected").flatMap(Module.init(rawValue:))
            ?? .cpu
    }
}

struct ModuleDropdown: View {
    let module: Module
    var state: DropdownState

    var body: some View {
        VStack(spacing: 10) {
            DropdownHeader(module: module)
            FittingScroll {
                if module == .overview {
                    OverviewContent(state: state)
                } else {
                    ModuleDetail(module: module)
                }
            }
            DropdownFooter()
        }
        .padding(12)
        .frame(width: 340)
    }
}

/// Sizes to its content, but never taller than the screen allows (header + footer stay visible);
/// beyond that the content scrolls. Without this a tall panel (e.g. Network) got cut off at the top.
struct FittingScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0

    /// Visible screen height minus the menu bar gap, popover arrow, header, footer and paddings.
    private var maxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(300, screen - 150)
    }

    var body: some View {
        if CommandLine.arguments.contains("--snapshot") {
            content  // offscreen renders can't draw scroll views
        } else {
            scroll
        }
    }

    private var scroll: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .frame(height: min(height == 0 ? maxHeight : height, maxHeight))
    }
}

struct DropdownHeader: View {
    let module: Module
    @Environment(SystemMonitor.self) private var m
    @AppStorage("accent") private var accent = Accent.auto.rawValue  // re-render when the accent changes

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: module.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(LinearGradient(colors: module.accentColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: .rect(cornerRadius: 9, style: .continuous))
                .shadow(color: module.accentTint.opacity(0.35), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(module.title).font(.system(size: 14, weight: .bold))
                Text("\(m.chipName) · \(Fmt.memory(m.memTotal)) RAM")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 2)
    }
}

struct DropdownFooter: View {
    @Environment(SystemMonitor.self) private var m

    var body: some View {
        HStack(spacing: 8) {
            Label("Czas pracy \(Fmt.duration(m.uptime))", systemImage: "clock")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                AppActions.openSettings()
            } label: {
                Image(systemName: "gearshape.fill").frame(width: 16, height: 16)
            }
            .help("Ustawienia")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power").frame(width: 16, height: 16)
            }
            .help("Zakończ Pulse")
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .padding(.horizontal, 2)
    }
}

/// Which values the overview shows in the menu bar (user-selectable in Settings).
enum OverviewItem: String, CaseIterable, Identifiable {
    case cpu, gpu, mem, disk, temp, net, bat
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"; case .gpu: "GPU"; case .mem: String(localized: "Pamięć"); case .disk: String(localized: "Dysk")
        case .temp: String(localized: "Temperatura"); case .net: String(localized: "Sieć"); case .bat: String(localized: "Bateria")
        }
    }
    var key: String { "overview.show.\(rawValue)" }
    var defaultOn: Bool { [.cpu, .mem, .temp].contains(self) }
    var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultOn }

    /// Module whose panel this value opens.
    var module: Module {
        switch self {
        case .cpu: .cpu; case .gpu: .gpu; case .mem: .memory; case .disk: .disk
        case .temp: .sensors; case .net: .network; case .bat: .battery
        }
    }

    /// User-defined order (Settings → Przegląd), shared by the menu bar and the dropdown tiles.
    static var ordered: [OverviewItem] {
        let saved = (UserDefaults.standard.stringArray(forKey: "overview.order") ?? []).compactMap(OverviewItem.init(rawValue:))
        return saved + allCases.filter { !saved.contains($0) }
    }
    static func setOrder(_ items: [OverviewItem]) {
        UserDefaults.standard.set(items.map(\.rawValue), forKey: "overview.order")
    }

    /// Per-value menu bar style; nil = the overview's default style.
    var styleKey: String { "overview.style.\(rawValue)" }
    var style: DisplayMode? { UserDefaults.standard.string(forKey: styleKey).flatMap(DisplayMode.init(rawValue:)) }
    var labelKey: String { "overview.label.\(rawValue)" }
    var showsLabel: Bool { UserDefaults.standard.object(forKey: labelKey) as? Bool ?? true }
    var tileKey: String { "overview.tile.\(rawValue)" }
    var showsTile: Bool { UserDefaults.standard.object(forKey: tileKey) as? Bool ?? true }
}

/// Combined view: glass ring tiles for every module; tapping one swaps the detail below.
struct OverviewContent: View {
    @Environment(SystemMonitor.self) private var m
    var state: DropdownState
    @AppStorage("overview.pinned") private var pinned = ""
    @AppStorage("accent") private var accent = Accent.auto.rawValue
    @AppStorage("overview.order") private var orderData = Data()  // re-render on reorder
    private var selected: Module { state.selected }

    /// Same order as the menu bar values (Settings → Przegląd); hidden tiles are skipped.
    private var tiles: [Module] {
        OverviewItem.ordered.filter { $0.showsTile && ($0 != .bat || m.battery.present) }.map(\.module)
    }

    var body: some View {
        VStack(spacing: 10) {
            summary
            GlassEffectContainer(spacing: 6) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(tiles) { tile($0) }
                }
            }
            // The old content goes away at once and the popover resizes in one step; only the new
            // content fades in. (Animating both at once while the popover resizes made it jump.)
            ModuleDetail(module: selected)
                .id(selected)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.06)),
                                        removal: .identity))
        }
    }

    /// One-line status: load average, memory pressure, network and battery at a glance.
    private var summary: some View {
        HStack(spacing: 6) {
            Pill(text: "Load \(String(format: "%.2f", m.loadAverage.first ?? 0))", color: Heat.load(min((m.loadAverage.first ?? 0) / Double(max(m.coreCount, 1)), 1)))
            Pill(text: m.memPressure == .normal ? String(localized: "Pamięć OK") : (m.memPressure == .warning ? String(localized: "Pamięć ⚠︎") : String(localized: "Pamięć ‼︎")),
                 color: m.memPressure == .normal ? .green : (m.memPressure == .warning ? .orange : .red))
            Pill(text: "↓\(Fmt.rate(m.netIn, compact: true)) ↑\(Fmt.rate(m.netOut, compact: true))", color: .cyan)
            if m.thermalState != .nominal {
                Pill(text: "🔥 \(m.thermalState.title)", color: m.thermalState.color)
                    .help(m.thermalState.detail)
            }
            Spacer(minLength: 0)
        }
    }

    /// Network ring scaled logarithmically up to ~1 GB/s so both kB/s and MB/s are visible.
    private var netLevel: Double {
        let total = m.netIn + m.netOut
        return total > 1 ? min(log10(total) / 9, 1) : 0
    }

    private func value(_ module: Module) -> (Double, String, String) {
        switch module {
        case .cpu: (m.cpu, Fmt.pct(m.cpu), "CPU")
        case .gpu: (m.gpu ?? 0, m.gpu.map(Fmt.pct) ?? "—", "GPU")
        case .memory: (m.memFraction, Fmt.pct(m.memFraction), String(localized: "Pamięć"))
        case .disk: (m.diskFraction, Fmt.pct(m.diskFraction), String(localized: "Dysk"))
        case .sensors: ((m.socMax ?? 0) / 105, Fmt.temp(m.socMax ?? m.socAvg), String(localized: "Temp."))
        case .network: (netLevel, Fmt.rate(m.netIn, compact: true), String(localized: "Sieć"))
        case .battery: (m.battery.percent, Fmt.pct(m.battery.percent), String(localized: "Bateria"))
        case .overview: (0, "", "")
        }
    }

    private func tile(_ module: Module) -> some View {
        let (v, text, title) = value(module)
        let isOn = selected == module
        let isPinned = pinned == module.rawValue
        let colors = module.accentColors
        return Button { state.selected = module } label: {
            VStack(spacing: 4) {
                ZStack {
                    RingGauge(value: v, colors: colors, lineWidth: 4.5)
                    Text(text)
                        .font(.system(size: text.count > 4 ? 9 : 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                }
                .frame(width: 44, height: 44)
                MenuGraph(values: trend(module), maxValue: trendMax(module), opacity: 0.9, color: colors.last ?? .accentColor)
                    .frame(width: 46, height: 10)
                    .opacity(trend(module).count > 1 ? 1 : 0)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isOn ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .overlay(alignment: .topTrailing) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(colors.last ?? .accentColor)
                        .rotationEffect(.degrees(35))
                        .padding(6)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(isOn ? .regular.tint((colors.last ?? .accentColor).opacity(0.25)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button(isPinned ? String(localized: "Odepnij") : String(localized: "Przypnij – zawsze otwieraj ten moduł"),
                   systemImage: isPinned ? "pin.slash" : "pin") {
                pinned = isPinned ? "" : module.rawValue
            }
        }
        .help(isPinned ? String(localized: "Przypięty – Przegląd zawsze otwiera się na tym module") : String(localized: "Prawy klik: przypnij"))
    }

    /// Last ~2 minutes for the tile's mini chart.
    private func trend(_ module: Module) -> [Double] {
        switch module {
        case .cpu: m.cpuHistory
        case .gpu: m.gpuHistory
        case .memory: m.memHistory
        case .disk: m.readHistory
        case .sensors: m.tempHistory
        case .network: m.netInHistory
        case .battery: m.batteryHistory
        case .overview: []
        }
    }

    private func trendMax(_ module: Module) -> Double? {
        switch module {
        case .cpu, .gpu, .memory, .battery: 1
        case .sensors: 105
        default: nil
        }
    }
}
