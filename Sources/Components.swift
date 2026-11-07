import SwiftUI
import Charts

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.045), in: .rect(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
            }
    }
}

struct SectionTitle: View {
    let text: Text
    var trailing: String? = nil
    init(text: LocalizedStringKey, trailing: String? = nil) { self.text = Text(text); self.trailing = trailing }
    @_disfavoredOverload init<S: StringProtocol>(text: S, trailing: String? = nil) { self.text = Text(verbatim: String(text)); self.trailing = trailing }
    var body: some View {
        HStack {
            text
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }
}

struct BigValue: View {
    let value: String
    var unit: LocalizedStringKey? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}

struct Pill: View {
    let text: Text
    var color: Color = .secondary
    init(text: LocalizedStringKey, color: Color = .secondary) { self.text = Text(text); self.color = color }
    @_disfavoredOverload init<S: StringProtocol>(text: S, color: Color = .secondary) { self.text = Text(verbatim: String(text)); self.color = color }
    var body: some View {
        text
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(color.opacity(0.14), in: .capsule)
    }
}

struct RingGauge: View {
    var value: Double
    var colors: [Color]
    var lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.005, min(value, 1)))
                .stroke(
                    AngularGradient(colors: colors + [colors.last ?? .blue], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: (colors.last ?? .blue).opacity(0.4), radius: 4)
        }
        .animation(.smooth(duration: 0.6), value: value)
    }
}

struct LinearMeter: View {
    var value: Double
    var colors: [Color]
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.5), value: value)
    }
}

struct SegmentBar: View {
    struct Segment: Identifiable { let id: String; let value: Double; let color: Color }
    var segments: [Segment]
    var height: CGFloat = 10
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments) { s in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(s.color.gradient)
                        .frame(width: max(0, geo.size.width * s.value - 2))
                }
                Spacer(minLength: 0)
            }
            .background(.primary.opacity(0.08), in: .rect(cornerRadius: 4))
            .clipShape(.rect(cornerRadius: height / 2.5, style: .continuous))
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.5), value: segments.map(\.value))
    }
}

struct LegendItem: View {
    let color: Color
    let title: Text
    let value: String
    init(color: Color, title: LocalizedStringKey, value: String) { self.color = color; self.title = Text(title); self.value = value }
    @_disfavoredOverload init<S: StringProtocol>(color: Color, title: S, value: String) { self.color = color; self.title = Text(verbatim: String(title)); self.value = value }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color.gradient).frame(width: 7, height: 7)
            title.foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.system(size: 11.5))
    }
}

struct Sparkline: View {
    var values: [Double]
    var maxValue: Double? = nil
    var color: Color
    var secondary: [Double]? = nil
    var secondaryColor: Color = .orange
    var length: Int = SystemMonitor.historyLength

    private struct Point: Identifiable { let id: String; let series: String; let x: Int; let y: Double }

    private var points: [Point] {
        let n = length
        var result = values.enumerated().filter { $0.element.isFinite }
            .map { Point(id: "a\($0.offset)", series: "a", x: n - values.count + $0.offset, y: $0.element) }
        if let secondary {
            result += secondary.enumerated().filter { $0.element.isFinite }
                .map { Point(id: "b\($0.offset)", series: "b", x: n - secondary.count + $0.offset, y: $0.element) }
        }
        return result
    }

    private var top: Double {
        if let maxValue { return maxValue }
        return max((values + (secondary ?? [])).filter(\.isFinite).max() ?? 1, 1) * 1.15
    }

    var body: some View {
        Chart(points) { p in
            let c = p.series == "a" ? color : secondaryColor
            AreaMark(x: .value("t", p.x), yStart: .value("0", 0), yEnd: .value("v", p.y), series: .value("s", p.series))
                .foregroundStyle(LinearGradient(colors: [c.opacity(0.32), c.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", p.x), y: .value("v", p.y), series: .value("s", p.series))
                .foregroundStyle(c)
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
        .chartXScale(domain: 0...max(length - 1, 1))
        .chartYScale(domain: 0...top)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(.primary.opacity(0.12))
            }
        }
        .chartLegend(.hidden)
        .animation(.smooth(duration: 0.4), value: values)
    }
}

struct CoreBars: View {
    var values: [Double]
    var colors: [Color]
    var height: CGFloat = 34
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.primary.opacity(0.07))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LinearGradient(colors: colors.reversed(), startPoint: .top, endPoint: .bottom))
                        .frame(height: max(3, height * min(v, 1)))
                }
                .frame(height: height)
                .clipShape(.rect(cornerRadius: 3, style: .continuous))
            }
        }
        .animation(.smooth(duration: 0.5), value: values)
    }
}

struct MiniStat: View {
    let title: Text
    let value: String
    var color: Color = .primary
    var symbol: String? = nil
    init(title: LocalizedStringKey, value: String, color: Color = .primary, symbol: String? = nil) {
        self.title = Text(title); self.value = value; self.color = color; self.symbol = symbol
    }
    @_disfavoredOverload init<S: StringProtocol>(title: S, value: String, color: Color = .primary, symbol: String? = nil) {
        self.title = Text(verbatim: String(title)); self.value = value; self.color = color; self.symbol = symbol
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(color) }
                title.font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.primary.opacity(0.04), in: .rect(cornerRadius: 12, style: .continuous))
    }
}
