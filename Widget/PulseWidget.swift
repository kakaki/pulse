import WidgetKit
import SwiftUI

struct Entry: TimelineEntry {
    let date: Date
    let data: WidgetData?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, data: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, data: WidgetData.load() ?? .sample))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app also asks WidgetKit to reload every few minutes while it runs.
        let entry = Entry(date: .now, data: WidgetData.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(300))))
    }
}

extension WidgetData {
    static let sample = WidgetData(date: .now, chip: "Apple M5", cpu: 0.23, mem: 0.64, disk: 0.32, temp: 46, gpu: 0.1,
                                   battery: 0.8, charging: false, netIn: 120_000, netOut: 30_000,
                                   cpuHour: (0..<60).map { 0.2 + 0.15 * sin(Double($0) / 6) },
                                   memHour: Array(repeating: 0.64, count: 60), tempHour: Array(repeating: 46, count: 60))
}

private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
private func temp(_ t: Double?) -> String {
    guard let t else { return "—" }
    let f = UserDefaults(suiteName: "local.pulse.menubar")?.integer(forKey: "tempUnit") == 1
    return "\(Int((f ? t * 9 / 5 + 32 : t).rounded()))°"
}
private func rate(_ r: Double) -> String {
    let units = ["B", "KB", "MB", "GB"]; var v = max(0, r), i = 0
    while v >= 1000 && i < 3 { v /= 1000; i += 1 }
    return (v < 10 && i > 0 ? String(format: "%.1f", v) : String(format: "%.0f", v)) + " " + units[i] + "/s"
}

struct Ring: View {
    let value: Double
    let text: String
    let title: LocalizedStringKey
    let colors: [Color]
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(.primary.opacity(0.1), lineWidth: 6)
                Circle().trim(from: 0, to: max(0.01, min(value, 1)))
                    .stroke(AngularGradient(colors: colors + [colors.last!], center: .center),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(text).font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.7)
            }
            Text(title).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

struct MiniChart: View {
    let values: [Double]
    let maxValue: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let pts = values.enumerated().compactMap { i, v -> CGPoint? in
                guard v >= 0 else { return nil }
                let x = geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1))
                return CGPoint(x: x, y: geo.size.height * (1 - CGFloat(min(v / maxValue, 1))))
            }
            ZStack {
                Path { p in
                    guard let f = pts.first, let l = pts.last else { return }
                    p.move(to: CGPoint(x: f.x, y: geo.size.height)); pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: l.x, y: geo.size.height)); p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f); pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            }
        }
    }
}

struct PulseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    private let cpuC: [Color] = [Color(red: 0.3, green: 0.6, blue: 1), Color(red: 0.4, green: 0.85, blue: 1)]
    private let memC: [Color] = [.purple, .pink]
    private let tempC: [Color] = [.orange, .red]
    private let diskC: [Color] = [.yellow, .orange]

    var body: some View {
        if let d = entry.data {
            content(d)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg").font(.title2)
                Text("Uruchom Pulse, aby zobaczyć dane").font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func content(_ d: WidgetData) -> some View {
        let stale = Date().timeIntervalSince(d.date) > 900
        let rings = Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Ring(value: d.cpu, text: pct(d.cpu), title: "CPU", colors: cpuC)
                Ring(value: d.mem, text: pct(d.mem), title: "Pamięć", colors: memC)
            }
            GridRow {
                Ring(value: (d.temp ?? 0) / 100, text: temp(d.temp), title: "Temp.", colors: tempC)
                Ring(value: d.disk, text: pct(d.disk), title: "Dysk", colors: diskC)
            }
        }
        switch family {
        case .systemSmall:
            rings.opacity(stale ? 0.5 : 1)
        default:
            HStack(spacing: 14) {
                rings.frame(width: 130)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Pulse", systemImage: "waveform.path.ecg").font(.system(size: 12, weight: .bold))
                        Spacer()
                        Text(d.date, style: .time).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("CPU – ostatnia godzina").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                    MiniChart(values: d.cpuHour, maxValue: 1, color: cpuC[1])
                        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 6))
                    HStack(spacing: 10) {
                        Label(rate(d.netIn), systemImage: "arrow.down").foregroundStyle(.cyan)
                        Label(rate(d.netOut), systemImage: "arrow.up").foregroundStyle(.pink)
                        Spacer()
                        if let b = d.battery {
                            Label(pct(b), systemImage: d.charging ? "battery.100percent.bolt" : "battery.75percent")
                        }
                    }
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .labelStyle(.titleAndIcon)
                }
            }
            .opacity(stale ? 0.5 : 1)
        }
    }
}

private func energy(_ wh: Double) -> String {
    wh >= 1000 ? String(format: "%.2f kWh", wh / 1000) : String(format: "%.0f Wh", wh)
}

/// Second widget: energy charged into the battery this month and the hottest computer on the network.
struct PulseExtrasView: View {
    let entry: Entry

    var body: some View {
        if let d = entry.data, d.chargedMonth != nil || d.hotName != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let wh = d.chargedMonth {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("Ładowanie", systemImage: "bolt.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                        Text(energy(wh)).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                            .minimumScaleFactor(0.6).lineLimit(1)
                        Text("w tym miesiącu").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                }
                if d.chargedMonth != nil && d.hotName != nil { Divider() }
                if let name = d.hotName {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("Najcieplejszy", systemImage: "desktopcomputer").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(temp(d.hotTemp)).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                        }
                        if let n = d.computers, n > 1 {
                            Text("Komputerów w sieci: \(n)").font(.system(size: 9.5)).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(Date().timeIntervalSince(d.date) > 900 ? 0.5 : 1)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(.title2)
                Text("Brak baterii i innych komputerów z Pulse w sieci").font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct PulseExtrasWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PulseExtras", provider: Provider()) { entry in
            PulseExtrasView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Pulse – energia i sieć")
        .description("Energia oddana do baterii w tym miesiącu i najcieplejszy komputer w sieci.")
        .supportedFamilies([.systemSmall])
    }
}

struct PulseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PulseWidget", provider: Provider()) { entry in
            PulseWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Pulse")
        .description("CPU, pamięć, temperatura i dysk.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct PulseWidgetBundle: WidgetBundle {
    var body: some Widget {
        PulseWidget()
        PulseExtrasWidget()
    }
}
