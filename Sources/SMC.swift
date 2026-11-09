import IOKit
import Foundation

struct FanInfo: Identifiable, Equatable {
    let id: Int
    var rpm: Double
    var min: Double
    var max: Double
    var fraction: Double { max > min ? Swift.min(Swift.max((rpm - min) / (max - min), 0), 1) : 0 }
}

/// Fans and total system power from the SMC. MacBook Air has no fan: `fanCount` is then 0.
@MainActor
final class SMCSampler {
    private let smc = SMC()
    private(set) lazy var fanCount: Int = Int(smc?.number("FNum") ?? 0)

    func fans() -> [FanInfo] {
        guard let smc, fanCount > 0 else { return [] }
        return (0..<fanCount).compactMap { i in
            guard let rpm = smc.number("F\(i)Ac") else { return nil }
            return FanInfo(id: i, rpm: rpm, min: smc.number("F\(i)Mn") ?? 0, max: smc.number("F\(i)Mx") ?? 0)
        }
    }

    /// Temperature keys of Intel Macs, which do not publish thermal sensors through IOHIDEventSystem.
    private static let intelTemperatureKeys: [(key: String, name: () -> String, kind: TempSensor.Kind)] = [
        ("TC0F", { "CPU" }, .soc), ("TC0D", { "CPU" }, .soc), ("TC0E", { "CPU" }, .soc), ("TC0P", { "CPU" }, .soc),
        ("TG0D", { "GPU" }, .other), ("TG0P", { "GPU" }, .other),
        ("TH0a", { "SSD" }, .ssd), ("TH0b", { "SSD" }, .ssd), ("TH0P", { "SSD" }, .ssd),
        ("TM0P", { String(localized: "Pamięć") }, .other),
        ("TPCD", { String(localized: "Płyta") }, .other),
        ("TA0P", { String(localized: "Otoczenie") }, .other),
        ("TB0T", { String(localized: "Bateria") }, .battery)
    ]

    /// One reading per sensor name: the first key that exists, in the list's order of preference.
    func intelTemperatures() -> [TempSensor] {
        guard let smc else { return [] }
        var seen = Set<String>()
        var sensors: [TempSensor] = []
        for entry in Self.intelTemperatureKeys {
            let name = entry.name()
            guard !seen.contains(name), let value = smc.number(entry.key), value > 1, value < 150 else { continue }
            seen.insert(name)
            sensors.append(TempSensor(id: entry.key, name: name, value: value, kind: entry.kind))
        }
        return sensors.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    /// Whole-system power draw in watts (PSTR), if the SMC exposes it.
    func systemPower() -> Double? { smc?.number("PSTR") }
}
