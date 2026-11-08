import Foundation
import SwiftUI

enum HistoryMetric: String, CaseIterable, Codable {
    case cpu, gpu, mem, temp, diskRead, diskWrite, netIn, netOut, battery, batteryPower
}

enum HistoryRange: Int, CaseIterable, Identifiable {
    case live, hour, day, week, month
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .live: "2 min"
        case .hour: "1 h"
        case .day: "24 h"
        case .week: "7 d"
        case .month: "30 d"
        }
    }
    /// Minutes covered and minutes per chart point.
    var span: Int {
        switch self {
        case .live, .hour: 60
        case .day: 1440
        case .week: 7 * 1440
        case .month: 30 * 1440
        }
    }
    var step: Int {
        switch self {
        case .live, .hour: 1
        case .day: 10
        case .week: 60
        case .month: 240
        }
    }
}

extension HistoryRange {
    /// Clock time of the chart point `pointsBack` slots before the newest one.
    func timeLabel(pointsBack: Int) -> String {
        let date = Date().addingTimeInterval(-Double(pointsBack * step + 1) * 60)
        return span > 1440
            ? date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            : date.formatted(.dateTime.hour().minute())
    }
}

extension HistoryMetric {
    func format(_ value: Double) -> String {
        switch self {
        case .cpu, .gpu, .mem, .battery: Fmt.pct(value)
        case .temp: Fmt.temp(value)
        case .diskRead, .diskWrite, .netIn, .netOut: Fmt.rate(value)
        case .batteryPower: String(format: "%.1f W", value)
        }
    }
}

/// Per-minute averages for the last 24 h plus 10-minute averages for the last 30 days, persisted to Application Support so they survive restarts.
@MainActor
final class HistoryStore {
    static let minutes = 1440
    static let coarseMinutes = 30 * 1440

    private struct Bucket: Codable { var minute: Int; var values: [String: Double] }
    private struct File: Codable { var buckets: [Bucket]; var coarse: [Bucket]? }

    private var buckets: [Bucket] = []
    /// 10-minute averages (minute = start of the slot), kept for 30 days.
    private var coarse: [Bucket] = []
    private var coarseSlot = HistoryStore.minuteNow() / 10
    private var coarseSums: [String: (sum: Double, count: Int)] = [:]
    private var currentMinute = HistoryStore.minuteNow()
    private var sums: [HistoryMetric: (sum: Double, count: Int)] = [:]
    private var lastSave = Date()

    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.url), let file = try? JSONDecoder().decode(File.self, from: data) {
            let oldest = Self.minuteNow() - Self.minutes
            buckets = file.buckets.filter { $0.minute > oldest }
            let oldestCoarse = Self.minuteNow() - Self.coarseMinutes
            coarse = (file.coarse ?? []).filter { $0.minute > oldestCoarse }
        }
    }

    private static func minuteNow() -> Int { Int(Date().timeIntervalSince1970 / 60) }

    func add(_ metric: HistoryMetric, _ value: Double?) {
        guard let value, value.isFinite else { return }
        let now = Self.minuteNow()
        if now != currentMinute { flush(); currentMinute = now }
        let s = sums[metric] ?? (0, 0)
        sums[metric] = (s.sum + value, s.count + 1)
    }

    private func flush() {
        guard !sums.isEmpty else { return }
        var values: [String: Double] = [:]
        for (k, v) in sums where v.count > 0 { values[k.rawValue] = v.sum / Double(v.count) }
        buckets.append(Bucket(minute: currentMinute, values: values))
        addCoarse(minute: currentMinute, values: values)
        let oldest = Self.minuteNow() - Self.minutes
        if let first = buckets.first, first.minute <= oldest { buckets.removeAll { $0.minute <= oldest } }
        sums = [:]
        if Date().timeIntervalSince(lastSave) > 300 { save() }
    }

    private func addCoarse(minute: Int, values: [String: Double]) {
        if minute / 10 != coarseSlot { flushCoarse(); coarseSlot = minute / 10 }
        for (k, v) in values {
            let s = coarseSums[k] ?? (0, 0)
            coarseSums[k] = (s.sum + v, s.count + 1)
        }
    }

    private func flushCoarse() {
        guard !coarseSums.isEmpty else { return }
        var values: [String: Double] = [:]
        for (k, v) in coarseSums where v.count > 0 { values[k] = v.sum / Double(v.count) }
        coarse.append(Bucket(minute: coarseSlot * 10, values: values))
        coarseSums = [:]
        let oldest = Self.minuteNow() - Self.coarseMinutes
        if let first = coarse.first, first.minute <= oldest { coarse.removeAll { $0.minute <= oldest } }
    }

    /// On quit: also keep the unfinished 10-minute slot.
    func saveFinal() {
        flush()
        flushCoarse()
        save()
    }

    func save() {
        lastSave = Date()
        guard let data = try? JSONEncoder().encode(File(buckets: buckets, coarse: coarse)) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// Fixed-length series (oldest first) for the range; missing slots are NaN.
    /// The last 24 h come from per-minute data, older points from the 10-minute averages.
    func series(_ metric: HistoryMetric, range: HistoryRange) -> [Double] {
        let span = range.span, step = range.step
        let now = Self.minuteNow()
        var slots = [(sum: Double, count: Int)](repeating: (0, 0), count: span / step)
        func add(_ b: Bucket, weight: Int) {
            let age = now - b.minute           // 1 = previous minute
            guard age >= 1, age <= span, let v = b.values[metric.rawValue] else { return }
            let idx = slots.count - 1 - (age - 1) / step
            slots[idx].sum += v * Double(weight); slots[idx].count += weight
        }
        for b in buckets { add(b, weight: 1) }
        if span > Self.minutes {
            for b in coarse where now - b.minute > Self.minutes { add(b, weight: 10) }
        }
        return slots.map { $0.count > 0 ? $0.sum / Double($0.count) : .nan }
    }

    /// CSV (semicolon-separated, decimal comma – opens directly in Polish Excel / Numbers):
    /// 10-minute rows for the last 30 days, then per-minute rows for the last 24 h.
    func csv() -> String {
        flush()
        let columns: [(HistoryMetric, String, Double)] = [
            (.cpu, String(localized: "CPU %"), 100), (.gpu, String(localized: "GPU %"), 100), (.mem, String(localized: "Pamięć %"), 100), (.temp, String(localized: "Temperatura °C"), 1),
            (.diskRead, String(localized: "Dysk odczyt B/s"), 1), (.diskWrite, String(localized: "Dysk zapis B/s"), 1),
            (.netIn, String(localized: "Sieć pobieranie B/s"), 1), (.netOut, String(localized: "Sieć wysyłanie B/s"), 1),
            (.battery, String(localized: "Bateria %"), 100), (.batteryPower, String(localized: "Moc baterii W"), 1),
        ]
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let number = NumberFormatter()
        number.locale = Locale(identifier: "pl_PL")
        number.maximumFractionDigits = 2
        number.usesGroupingSeparator = false

        let firstMinute = buckets.first?.minute ?? Self.minuteNow()
        // Merge duplicate 10-minute slots (e.g. a partial slot saved on quit).
        var merged: [Int: [String: (Double, Int)]] = [:]
        for b in coarse where b.minute < firstMinute {
            for (k, v) in b.values {
                let s = merged[b.minute, default: [:]][k] ?? (0, 0)
                merged[b.minute, default: [:]][k] = (s.0 + v, s.1 + 1)
            }
        }
        var rows: [(Int, Int, [String: Double])] = merged.keys.sorted().map { m in
            (m, 10, merged[m]!.mapValues { $0.0 / Double($0.1) })
        }
        rows += buckets.map { ($0.minute, 1, $0.values) }

        var out = "\u{FEFF}" + ([String(localized: "Czas"), String(localized: "Rozdzielczość (min)")] + columns.map(\.1)).joined(separator: ";") + "\n"
        for (minute, res, values) in rows {
            let date = Date(timeIntervalSince1970: TimeInterval(minute * 60))
            let cells = columns.map { c in
                values[c.0.rawValue].flatMap { number.string(from: NSNumber(value: $0 * c.2)) } ?? ""
            }
            out += ([fmt.string(from: date), "\(res)"] + cells).joined(separator: ";") + "\n"
        }
        return out
    }
}

/// Chart with a 2 min / 1 h / 24 h / 7 d / 30 d switch; the range choice is shared by all dropdowns.
struct HistoryChart: View {
    @Environment(SystemMonitor.self) private var m
    @AppStorage("historyRange") private var rangeRaw = 0
    var metric: HistoryMetric
    var live: [Double]
    var maxValue: Double? = nil
    var color: Color
    var metric2: HistoryMetric? = nil
    var live2: [Double]? = nil
    var color2: Color = .orange
    var height: CGFloat = 60

    private var range: HistoryRange { HistoryRange(rawValue: rangeRaw) ?? .live }

    var body: some View {
        VStack(spacing: 6) {
            let values = range == .live ? live : m.history.series(metric, range: range)
            let second: [Double]? = metric2.map { range == .live ? (live2 ?? []) : m.history.series($0, range: range) }
            Sparkline(values: values, maxValue: maxValue, color: color, secondary: second, secondaryColor: color2,
                      length: range == .live ? SystemMonitor.historyLength : values.count,
                      format: metric.format, timeLabel: range == .live ? nil : { range.timeLabel(pointsBack: $0) })
                .frame(height: height)
                .overlay {
                    if range != .live, !values.contains(where: { $0.isFinite }) {
                        Text("Zbieram dane – pierwsze punkty pojawią się po minucie")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            HStack(spacing: 2) {
                ForEach(HistoryRange.allCases) { r in
                    Button { rangeRaw = r.rawValue } label: {
                        Text(r.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(r == range ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(r == range ? AnyShapeStyle(.primary.opacity(0.12)) : AnyShapeStyle(.clear),
                                        in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(.primary.opacity(0.05), in: .capsule)
        }
    }
}
