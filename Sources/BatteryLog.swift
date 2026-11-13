import Foundation
import SwiftUI

/// One entry per day: energy charged into the battery and its health, kept for two years in Application Support.
/// Charged energy comes from the rise of the battery's charge (mAh × V), so charging while asleep counts too.
@MainActor
@Observable
final class BatteryLog {
    static let shared = BatteryLog()

    struct Day: Codable, Equatable, Identifiable {
        var day: String              // yyyy-MM-dd, local time
        var chargedWh: Double = 0
        var health: Double?
        var maxCapacity: Int?        // mAh
        var cycles: Int?
        var id: String { day }
        var date: Date? { BatteryLog.dayFormat.date(from: day) }
    }

    private(set) var days: [Day] = []
    @ObservationIgnored private var lastCharge: Int?
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var demo = false

    static let keptDays = 730
    nonisolated static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("battery-log.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode([Day].self, from: data) {
            days = saved
        }
    }

    /// Called whenever Pulse reads the battery (every few seconds and on plugging in or out).
    func record(_ b: BatteryInfo) {
        guard b.present, !demo else { return }
        let key = Self.dayFormat.string(from: Date())
        var i = days.lastIndex { $0.day == key }
        if i == nil {
            days.append(Day(day: key))
            if days.count > Self.keptDays { days.removeFirst(days.count - Self.keptDays) }
            i = days.count - 1
        }
        guard let i else { return }
        var entry = days[i]
        if let charge = b.currentCharge {
            // Only a rise while charging counts: holding at the charge limit and small jumps of the reading add nothing.
            if b.isCharging, let last = lastCharge, charge > last, let v = b.voltage, v > 0 {
                let added = Double(charge - last) * v / 1000
                if added < 200 { entry.chargedWh += added }
            }
            lastCharge = charge
        }
        if let h = b.health { entry.health = h }
        if let c = b.maxCapacity { entry.maxCapacity = c }
        if let c = b.cycleCount { entry.cycles = c }
        if entry != days[i] { days[i] = entry }
        if Date().timeIntervalSince(lastSave) > 300 { save() }
    }

    func save() {
        guard !demo else { return }
        lastSave = Date()
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// Energy charged in the calendar month `monthsBack` months ago (0 = this month).
    func charged(monthsBack: Int) -> Double {
        let cal = Calendar.current
        guard let month = cal.date(byAdding: .month, value: -monthsBack, to: Date()) else { return 0 }
        return days.reduce(0) { sum, d in
            guard let date = d.date, cal.isDate(date, equalTo: month, toGranularity: .month) else { return sum }
            return sum + d.chargedWh
        }
    }

    /// The last `count` days, oldest first; days without data are 0.
    func recentCharged(_ count: Int) -> [(day: Date, wh: Double)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let byDay = Dictionary(days.map { ($0.day, $0.chargedWh) }, uniquingKeysWith: +)
        return (0..<count).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (d, byDay[Self.dayFormat.string(from: d)] ?? 0)
        }
    }

    /// README screenshots (`--snapshot <dir> --demo`).
    func applyDemo() {
        demo = true
        let cal = Calendar.current
        var list: [Day] = []
        for back in (0..<75).reversed() {
            guard let d = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let wh = back % 7 == 3 ? 0 : 18 + Double((back * 37) % 29)
            list.append(Day(day: Self.dayFormat.string(from: d), chargedWh: wh, health: 0.995 - Double(75 - back) * 0.0002,
                            maxCapacity: 5645, cycles: 62 + (75 - back) / 3))
        }
        days = list
    }
}

/// Wh below 1 kWh, kWh above.
private func energy(_ wh: Double) -> String {
    wh >= 1000 ? String(format: "%.2f kWh", wh / 1000) : String(format: "%.0f Wh", wh)
}

/// Battery panel: energy charged per month and the battery's health over time.
struct BatteryLogCard: View {
    private let log = BatteryLog.shared

    var body: some View {
        let recent = log.recentCharged(30)
        let top = max(recent.map(\.wh).max() ?? 0, 1)
        Card {
            SectionTitle(text: "Ładowanie", trailing: String(localized: "poprzedni miesiąc: \(energy(log.charged(monthsBack: 1)))"))
            HStack(alignment: .firstTextBaseline) {
                BigValue(value: energy(log.charged(monthsBack: 0)))
                Text("w tym miesiącu").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(recent, id: \.day) { d in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(d.wh > 0 ? AnyShapeStyle(Module.battery.tint) : AnyShapeStyle(.primary.opacity(0.08)))
                        .frame(height: max(2, 34 * d.wh / top))
                        .frame(maxWidth: .infinity)
                        .help(Text(verbatim: "\(d.day.formatted(.dateTime.day().month(.abbreviated))): \(energy(d.wh))"))
                }
            }
            .frame(height: 34, alignment: .bottom)
            Text("Energia oddana do baterii w ostatnich 30 dniach, bez prądu zasilającego samego Maca.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            health
        }
    }

    @ViewBuilder private var health: some View {
        let known = log.days.filter { $0.health != nil }
        if let first = known.first, let last = known.last, first.day != last.day,
           let h0 = first.health, let h1 = last.health, let since = first.date {
            Divider().padding(.vertical, 2)
            VStack(spacing: 7) {
                InfoRow(title: String(localized: "Kondycja od \(since.formatted(.dateTime.day().month(.abbreviated).year()))"),
                        value: "\(Fmt.pct(h0)) → \(Fmt.pct(h1))")
                if let c0 = first.cycles, let c1 = last.cycles {
                    InfoRow(title: String(localized: "Cykle w tym czasie"), value: "+\(max(c1 - c0, 0))")
                }
            }
        }
    }
}
