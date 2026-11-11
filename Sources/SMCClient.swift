import Foundation
import IOKit

/// Minimal AppleSMC client (key info, read, and – as root – write) using a raw 80-byte SMCKeyData buffer.
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

    /// Every key the SMC knows, in index order.
    func allKeys() -> [String] {
        guard let (_, b) = read("#KEY"), b.count >= 4 else { return [] }
        let count = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        return (0..<min(count, 20_000)).compactMap { index in
            var input = [UInt8](repeating: 0, count: 80)
            input[42] = 8 // kSMCGetKeyFromIndex
            withUnsafeBytes(of: UInt32(index).littleEndian) { input.replaceSubrange(44..<48, with: $0) }
            guard let out = call(input) else { return nil }
            return String(bytes: out[0..<4].reversed(), encoding: .ascii)
        }
    }

    /// Writes a number in the key's own SMC format. Needs root.
    func write(_ key: String, _ value: Double) -> Bool {
        var input = [UInt8](repeating: 0, count: 80)
        withUnsafeBytes(of: Self.fourCC(key).littleEndian) { input.replaceSubrange(0..<4, with: $0) }
        input[42] = 9 // kSMCGetKeyInfo
        guard let info = call(input) else { return false }
        let size = info.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) }
        let type = info.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt32.self) }
        let name = String(bytes: withUnsafeBytes(of: type.bigEndian) { Array($0) }, encoding: .ascii) ?? ""
        guard let bytes = Self.encode(value, type: name), bytes.count == Int(size) else { return false }
        withUnsafeBytes(of: size) { input.replaceSubrange(28..<32, with: $0) }
        input.replaceSubrange(48..<(48 + bytes.count), with: bytes)
        input[42] = 6 // kSMCWriteKey
        return call(input) != nil
    }

    /// Writes raw bytes (must match the key's size). Needs root.
    func write(_ key: String, bytes: [UInt8]) -> Bool {
        var input = [UInt8](repeating: 0, count: 80)
        withUnsafeBytes(of: Self.fourCC(key).littleEndian) { input.replaceSubrange(0..<4, with: $0) }
        input[42] = 9 // kSMCGetKeyInfo
        guard let info = call(input) else { return false }
        let size = info.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) }
        guard bytes.count == Int(size) else { return false }
        withUnsafeBytes(of: size) { input.replaceSubrange(28..<32, with: $0) }
        input.replaceSubrange(48..<(48 + bytes.count), with: bytes)
        input[42] = 6 // kSMCWriteKey
        return call(input) != nil
    }

    static func encode(_ value: Double, type: String) -> [UInt8]? {
        switch type {
        case "flt ": return withUnsafeBytes(of: Float32(value)) { Array($0) }
        case "fpe2":
            let raw = UInt16(max(0, min(value, 16383)) * 4)
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case "ui8 ": return [UInt8(max(0, min(value, 255)))]
        case "ui16":
            let raw = UInt16(max(0, min(value, 65535)))
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        default: return nil
        }
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
