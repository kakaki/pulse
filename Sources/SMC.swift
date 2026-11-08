import IOKit
import Foundation

/// Minimal read-only AppleSMC client (key info + read bytes) using a raw 80-byte SMCKeyData buffer.
final class SMC {
    private var conn: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var outSize = 80
        let r = input.withUnsafeBytes { inp in
            output.withUnsafeMutableBytes { out in
                IOConnectCallStructMethod(conn, 2, inp.baseAddress, 80, out.baseAddress, &outSize)
            }
        }
        return r == KERN_SUCCESS && output[40] == 0 ? output : nil
    }

    /// Returns (dataType, bytes) for a key.
    func read(_ key: String) -> (String, [UInt8])? {
        var input = [UInt8](repeating: 0, count: 80)
        withUnsafeBytes(of: Self.fourCC(key).littleEndian) { input.replaceSubrange(0..<4, with: $0) }
        input[42] = 9 // kSMCGetKeyInfo
        guard let info = call(input) else { return nil }
        let size = info.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) }
        let type = info.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt32.self) }
        guard size > 0, size <= 32 else { return nil }
        withUnsafeBytes(of: size) { input.replaceSubrange(28..<32, with: $0) }
        input[42] = 5 // kSMCReadKey
        guard let out = call(input) else { return nil }
        let t = String(bytes: withUnsafeBytes(of: type.bigEndian) { Array($0) }, encoding: .ascii) ?? ""
        return (t, Array(out[48..<(48 + Int(size))]))
    }

    func number(_ key: String) -> Double? {
        guard let (type, b) = read(key) else { return nil }
        switch type {
        case "flt ": return b.count >= 4 ? Double(b.withUnsafeBytes { $0.load(as: Float32.self) }) : nil
        case "fpe2": return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4 : nil
        case "sp78": return b.count >= 2 ? Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256 : nil
        case "ui8 ": return b.isEmpty ? nil : Double(b[0])
        case "ui16": return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : nil
        case "ui32": return b.count >= 4 ? Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) : nil
        default: return nil
        }
    }
}

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
