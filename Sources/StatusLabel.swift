import SwiftUI

/// One value shown by the overview item.
struct OverviewCell {
    /// Panel opened when this cell is clicked in the menu bar.
    var module: Module
    var label: String
    var text: String
    var value: Double
    var history: [Double]
    var maxHistory: Double?
    var level: Double?
    /// Own menu bar style (nil = the overview's style) and whether to show the small label.
    var mode: DisplayMode? = nil
    var showLabel = true
    /// Second line (network: ↑ upload over ↓ download) and its graph series.
    var text2: String? = nil
    var history2: [Double]? = nil
}

/// Severity 0…1 used to tint values when "colorize" is on (≥0.7 warning, ≥0.9 critical).
enum Severity {
    static func temp(_ t: Double?) -> Double? { t.map { max(0, ($0 - 50) / 45) } }
    static func memory(_ p: MemoryPressure) -> Double { p == .critical ? 1 : (p == .warning ? 0.75 : 0) }
    static func battery(_ b: BatteryInfo) -> Double? {
        guard b.present, !b.onAC else { return nil }
        return b.percent < 0.1 ? 1 : (b.percent < 0.2 ? 0.8 : 0)
    }
    static func color(_ level: Double?) -> Color? {
        guard let level else { return nil }
        if level >= 0.9 { return Color(red: 1.0, green: 0.27, blue: 0.23) }
        if level >= 0.7 { return Color(red: 1.0, green: 0.62, blue: 0.04) }
        return nil
    }
}

/// Plain-value snapshot of what one menu bar item shows (keeps rendering off the observable model).
struct StatusSnapshot {
    var value: Double = 0
    var text = "—"
    var text2: String? = nil
    var history: [Double] = []
    var history2: [Double]? = nil
    var maxHistory: Double? = 1
    var bars: [Double] = []
    var symbol: String? = nil
    var level: Double? = nil
    var cells: [OverviewCell] = []
    /// Overview: thin separators between values, and the value whose panel is open.
    var separators = false
    var highlight: Module? = nil
    /// Blink phase: critical values (level ≥ 0.9) are drawn faded while true.
    var dimCritical = false

    /// Highest severity in this item (decides whether the colored image is needed).
    var maxLevel: Double { ([level] + cells.map(\.level)).compactMap { $0 }.max() ?? 0 }
    /// Like maxLevel, but without disk usage (a full disk would otherwise blink forever).
    var pulseLevel: Double {
        (cells.filter { $0.module != .disk }.map(\.level) + [module == .disk ? nil : level]).compactMap { $0 }.max() ?? 0
    }
    var module: Module = .overview

    @MainActor
    static func make(_ module: Module, _ m: SystemMonitor) -> StatusSnapshot {
        var s = StatusSnapshot()
        s.module = module
        switch module {
        case .overview:
            let netTop = max((m.netInHistory.suffix(18).max() ?? 1), 1)
            s.separators = UserDefaults.standard.bool(forKey: "overview.separators")
            for item in OverviewItem.ordered where item.isOn {
                var cell: OverviewCell
                switch item {
                case .cpu: cell = .init(module: .cpu, label: "CPU", text: Fmt.pct(m.cpu), value: m.cpu, history: m.cpuHistory, maxHistory: 1, level: m.cpu)
                case .gpu: cell = .init(module: .gpu, label: "GPU", text: m.gpu.map(Fmt.pct) ?? "—", value: m.gpu ?? 0, history: m.gpuHistory, maxHistory: 1, level: m.gpu)
                case .mem: cell = .init(module: .memory, label: "MEM", text: Fmt.pct(m.memFraction), value: m.memFraction, history: m.memHistory, maxHistory: 1, level: Severity.memory(m.memPressure))
                case .disk:
                    let v = m.displayVolume
                    cell = .init(module: .disk, label: v.isSystem ? "SSD" : "EXT", text: DiskDisplay.text(v), value: DiskDisplay.fraction(v),
                                 history: m.readHistory, maxHistory: nil, level: v.usedFraction)
                case .temp:
                    let t = m.socMax ?? m.socAvg
                    cell = .init(module: .sensors, label: "TEMP", text: Fmt.temp(t), value: (t ?? 0) / 100, history: m.tempHistory, maxHistory: 100, level: Severity.temp(t))
                case .net:
                    if UserDefaults.standard.object(forKey: "overview.net.split") as? Bool ?? true {
                        let top = max((m.netInHistory + m.netOutHistory).suffix(36).max() ?? 1, 1)
                        cell = .init(module: .network, label: "NET", text: "↑ " + Fmt.rate(m.netOut, compact: true),
                                     value: min((m.netIn + m.netOut) / top, 1), history: m.netInHistory, maxHistory: top, level: nil)
                        cell.text2 = "↓ " + Fmt.rate(m.netIn, compact: true)
                        cell.history2 = m.netOutHistory
                    } else {
                        cell = .init(module: .network, label: "↓NET", text: Fmt.rate(m.netIn, compact: true), value: min(m.netIn / netTop, 1), history: m.netInHistory, maxHistory: nil, level: nil)
                    }
                case .bat:
                    guard m.battery.present else { continue }
                    cell = .init(module: .battery, label: "BAT", text: Fmt.pct(m.battery.percent), value: m.battery.percent, history: m.batteryHistory, maxHistory: 1, level: Severity.battery(m.battery))
                }
                cell.mode = item.style
                cell.showLabel = item.showsLabel
                s.cells.append(cell)
            }
            if s.cells.isEmpty { s.cells = [.init(module: .cpu, label: "CPU", text: Fmt.pct(m.cpu), value: m.cpu, history: m.cpuHistory, maxHistory: 1, level: m.cpu)] }
        case .cpu:
            s.value = m.cpu; s.text = Fmt.pct(m.cpu); s.history = m.cpuHistory; s.bars = m.cores; s.level = m.cpu
        case .gpu:
            s.value = m.gpu ?? 0; s.text = m.gpu.map(Fmt.pct) ?? "—"; s.history = m.gpuHistory; s.bars = [m.gpu ?? 0]; s.level = m.gpu
        case .memory:
            s.value = m.memFraction; s.text = Fmt.pct(m.memFraction); s.history = m.memHistory; s.bars = [m.memFraction]
            s.level = Severity.memory(m.memPressure)
        case .disk:
            let v = m.displayVolume
            s.value = DiskDisplay.fraction(v); s.text = DiskDisplay.text(v)
            s.history = m.readHistory; s.history2 = m.writeHistory; s.maxHistory = nil
            s.bars = [DiskDisplay.fraction(v)]; s.level = v.usedFraction
        case .network:
            s.text = "↑ " + Fmt.rate(m.netOut, compact: true)
            s.text2 = "↓ " + Fmt.rate(m.netIn, compact: true)
            s.history = m.netInHistory; s.history2 = m.netOutHistory; s.maxHistory = nil
        case .sensors:
            let t = m.socMax ?? m.socAvg
            s.text = Fmt.temp(t)
            s.value = (t ?? 0) / 100
            s.history = m.tempHistory; s.maxHistory = 100
            s.level = Severity.temp(t)
        case .battery:
            s.value = m.battery.percent
            s.text = m.battery.present ? Fmt.pct(m.battery.percent) : "AC"
            s.symbol = m.battery.isCharging ? "bolt.fill" : (m.battery.onAC ? "powerplug.fill" : nil)
            s.level = Severity.battery(m.battery)
        case .macs:
            // The hottest of the other Macs: the one you are most likely to hear.
            let live = RemoteMacs.shared.peers.filter { !$0.isStale }
            s.symbol = "desktopcomputer.and.macbook"
            if let hot = live.max(by: { ($0.report.temp ?? -1) < ($1.report.temp ?? -1) }), let t = hot.report.temp {
                s.text = Fmt.temp(t); s.value = t / 100
                s.history = hot.report.tempHistory; s.maxHistory = 100
                s.level = Severity.temp(t)
            } else if let busy = live.max(by: { $0.report.cpu < $1.report.cpu }) {
                s.text = Fmt.pct(busy.report.cpu); s.value = busy.report.cpu; s.level = busy.report.cpu
            } else {
                s.text = "—"
            }
        }
        return s
    }
}

@MainActor
enum StatusRenderer {
    /// Template (monochrome) image normally; when colorize is on and something is over threshold,
    /// a full-color image whose base color matches the menu bar appearance.
    static func image(module: Module, mode: DisplayMode, snapshot: StatusSnapshot, labels: Bool,
                      colorize: Bool = false, darkBar: Bool = true) -> NSImage {
        let tinted = colorize && snapshot.maxLevel >= 0.7
        let base: Color = tinted ? (darkBar ? .white : .black) : .black
        let renderer = ImageRenderer(content: StatusContent(module: module, mode: mode, s: snapshot, labels: labels,
                                                            color: base, colorize: tinted))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return NSImage() }
        image.isTemplate = !tinted
        return image
    }
}

extension StatusRenderer {
    /// Which overview cell lies under `x` (points from the left edge of the rendered image).
    /// Mirrors the layout of `StatusContent.overview`: 1 pt padding, cells separated by the overview spacing.
    static func overviewCell(at x: CGFloat, snapshot: StatusSnapshot, mode: DisplayMode) -> Module? {
        let spacing = StatusContent.overviewSpacing(mode, separators: snapshot.separators)
        var left: CGFloat = 1 + StatusContent.overviewInset - 1
        for (i, cell) in snapshot.cells.enumerated() {
            let r = ImageRenderer(content: OverviewCellView(cell: cell, mode: mode))
            let width = r.nsImage?.size.width ?? 0
            let lo = i == 0 ? -.infinity : left - spacing / 2
            let hi = i == snapshot.cells.count - 1 ? .infinity : left + width + spacing / 2
            if x >= lo && x < hi { return cell.module }
            left += width + spacing
        }
        return nil
    }
}

struct StatusContent: View {
    let module: Module
    let mode: DisplayMode
    let s: StatusSnapshot
    let labels: Bool
    var color: Color = .black
    var colorize = false

    /// Color for the value of this item (alert tint when colorizing).
    private func tint(_ level: Double?) -> Color {
        let c = colorize ? (Severity.color(level) ?? color) : color
        return s.dimCritical && module != .disk && (level ?? 0) >= 0.9 ? c.opacity(0.25) : c
    }
    private var valueColor: Color { tint(s.level) }

    private let valueFont = Font.system(size: 11.5, weight: .semibold).monospacedDigit()
    private let tinyFont = Font.system(size: 7.5, weight: .heavy)

    var body: some View {
        HStack(spacing: 4) {
            if module == .overview {
                overview
            } else {
                if labels && !(mode == .text && s.text2 == nil) {
                    Text(module.short).font(tinyFont).opacity(0.7).fixedSize()
                }
                content
            }
        }
        .padding(.horizontal, 1)
        .frame(height: 22)
        .foregroundStyle(color)
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .text:
            if let text2 = s.text2 {
                VStack(alignment: .trailing, spacing: -1.5) {
                    Text(s.text)
                    Text(text2)
                }
                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                .frame(minWidth: 44, alignment: .trailing)
            } else {
                HStack(spacing: 2) {
                    if let symbol = s.symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
                    if labels {
                        VStack(alignment: .leading, spacing: -2.5) {
                            Text(module.short).font(tinyFont).opacity(0.7)
                            Text(s.text).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(valueColor)
                        }
                        .frame(minWidth: 27, alignment: .leading)
                    } else {
                        Text(s.text).font(valueFont).frame(minWidth: 27, alignment: .leading)
                    }
                }
            }
        case .graph:
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color.opacity(0.1))
                MenuGraph(values: s.history, maxValue: s.maxHistory, opacity: 1, color: valueColor)
                if let h2 = s.history2 {
                    MenuGraph(values: h2, maxValue: s.maxHistory ?? ((s.history + h2).max() ?? 1), opacity: 0.55, color: color)
                }
            }
            .frame(width: 26, height: 17)
            .clipShape(.rect(cornerRadius: 3, style: .continuous))
            // Always pair the graph with the current value so the item is readable at a glance.
            if let text2 = s.text2 {
                VStack(alignment: .trailing, spacing: -1.5) {
                    Text(s.text)
                    Text(text2)
                }
                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                .frame(minWidth: 44, alignment: .trailing)
            } else if [.cpu, .gpu, .memory].contains(module) {
                Text(s.text).font(valueFont).frame(minWidth: 27, alignment: .leading)
            }
        case .bars:
            HStack(alignment: .bottom, spacing: s.bars.count > 4 ? 1 : 1.5) {
                ForEach(Array(s.bars.enumerated()), id: \.offset) { _, v in
                    ZStack(alignment: .bottom) {
                        Capsule().fill(color.opacity(0.22))
                        Capsule().fill(color).frame(height: max(2, 16 * min(v, 1)))
                    }
                    .frame(width: s.bars.count > 4 ? 2 : 4, height: 16)
                }
            }
            Text(s.text).font(valueFont).frame(minWidth: 27, alignment: .leading)
        case .ring:
            ZStack {
                Circle().stroke(color.opacity(0.22), lineWidth: 2.6)
                Circle().trim(from: 0, to: max(0.01, min(s.value, 1)))
                    .stroke(valueColor, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            Text(s.text).font(valueFont).frame(minWidth: 27, alignment: .leading)
        }
    }

    private var overview: some View {
        let spacing = Self.overviewSpacing(mode, separators: s.separators)
        return HStack(spacing: spacing) {
            ForEach(Array(s.cells.enumerated()), id: \.offset) { i, cell in
                OverviewCellView(cell: cell, mode: mode, color: color, colorize: colorize, dim: s.dimCritical)
                    .background {
                        if s.highlight == cell.module {
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(color.opacity(0.2))
                                .padding(.horizontal, -2.5)
                                .padding(.vertical, -1)
                        }
                    }
                    .overlay(alignment: .leading) {
                        if s.separators && i > 0 {
                            Capsule().fill(color.opacity(0.35))
                                .frame(width: 1, height: 13)
                                .offset(x: -spacing / 2 - 0.5)
                        }
                    }
            }
        }
        .padding(.horizontal, Self.overviewInset - 1)
    }

    /// Spacing between overview cells; also used to map menu bar clicks to cells.
    static func overviewSpacing(_ mode: DisplayMode, separators: Bool = false) -> CGFloat {
        (mode == .text ? 7 : 6) + (separators ? 4 : 0)
    }
    /// Left edge of the first overview cell inside the image (outer 1 pt + inner inset).
    static let overviewInset: CGFloat = 3
}

struct OverviewCellView: View {
    let cell: OverviewCell
    let mode: DisplayMode
    var color: Color = .black
    var colorize = false
    var dim = false

    private let tinyFont = Font.system(size: 7.5, weight: .heavy)
    private func tint(_ level: Double?) -> Color {
        let c = colorize ? (Severity.color(level) ?? color) : color
        return dim && cell.module != .disk && (level ?? 0) >= 0.9 ? c.opacity(0.25) : c
    }

    var body: some View {
                let mode = cell.mode ?? self.mode
                HStack(spacing: 3) {
                    switch mode {
                    case .ring:
                        ZStack {
                            Circle().stroke(color.opacity(0.22), lineWidth: 2.2)
                            Circle().trim(from: 0, to: max(0.01, min(cell.value, 1)))
                                .stroke(tint(cell.level), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 11, height: 11)
                    case .bars:
                        ZStack(alignment: .bottom) {
                            Capsule().fill(color.opacity(0.22))
                            Capsule().fill(tint(cell.level)).frame(height: max(2, 15 * min(cell.value, 1)))
                        }
                        .frame(width: 4, height: 15)
                    case .graph:
                        ZStack {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(color.opacity(0.1))
                            MenuGraph(values: cell.history.isEmpty ? [cell.value, cell.value] : cell.history,
                                      maxValue: cell.maxHistory, opacity: 1, color: tint(cell.level))
                            if let h2 = cell.history2 {
                                MenuGraph(values: h2, maxValue: cell.maxHistory, opacity: 0.55, color: color)
                            }
                        }
                        .frame(width: 18, height: 15)
                        .clipShape(.rect(cornerRadius: 2.5, style: .continuous))
                    case .text:
                        EmptyView()
                    }
                    if let text2 = cell.text2 {
                        // Two lines like the Network item: ↑ upload over ↓ download.
                        if cell.showLabel {
                            Text(cell.label).font(tinyFont).opacity(0.7).fixedSize()
                        }
                        VStack(alignment: .trailing, spacing: -1.5) {
                            Text(cell.text)
                            Text(text2)
                        }
                        .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                        .frame(minWidth: 44, alignment: .trailing)
                    } else if cell.showLabel {
                        VStack(alignment: .leading, spacing: -2.5) {
                            Text(cell.label).font(tinyFont).opacity(0.7)
                            Text(cell.text).font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(tint(cell.level))
                        }
                        .frame(minWidth: 26, alignment: .leading)
                    } else {
                        Text(cell.text).font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(tint(cell.level))
                            .frame(minWidth: 24, alignment: .leading)
                    }
                }
    }
}


/// Tiny filled history graph drawn into the menu bar template image.
struct MenuGraph: View {
    var values: [Double]
    var maxValue: Double?
    var opacity: Double
    var color: Color = .black

    var body: some View {
        let recent = Array(values.suffix(18))
        let top = maxValue ?? max(recent.max() ?? 1, 1)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let step = w / 17
            let start = w - step * CGFloat(max(recent.count - 1, 0))
            let pts = recent.enumerated().map { i, v in
                CGPoint(x: start + CGFloat(i) * step, y: h - 1 - (h - 2) * CGFloat(min(v / top, 1)))
            }
            ZStack {
                Path { p in
                    guard let first = pts.first, let last = pts.last else { return }
                    p.move(to: CGPoint(x: first.x, y: h))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: last.x, y: h))
                    p.closeSubpath()
                }
                .fill(color.opacity(0.45 * opacity))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color.opacity(opacity), style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
            }
        }
    }
}
