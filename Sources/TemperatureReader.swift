import Foundation

struct TempSensor: Identifiable, Hashable {
    enum Kind: Int { case soc, ssd, battery, other }
    let id: String
    let name: String
    let value: Double
    let kind: Kind
}

/// Reads Apple Silicon thermal sensors through the (private) IOHIDEventSystem API,
/// resolved at runtime with dlsym so no bridging header is needed.
final class TemperatureReader {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyPropertyFn = @convention(c) (UnsafeMutableRawPointer, CFString) -> UnsafeMutableRawPointer?
    private typealias CopyEventFn = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Double

    private static let eventTypeTemperature: Int64 = 15
    private static let temperatureField = UInt32(15 << 16)

    private var client: UnsafeMutableRawPointer?
    private var copyServices: CopyServicesFn?
    private var copyProperty: CopyPropertyFn?
    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?

    init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            guard let ptr = dlsym(handle, name) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: CreateFn.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self)
        else { return }
        copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self)
        copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self)
        copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEventFn.self)
        getFloat = symbol("IOHIDEventGetFloatValue", as: GetFloatFn.self)

        client = create(kCFAllocatorDefault)
        if let client {
            let matching: [String: Int] = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5]
            _ = setMatching(client, matching as CFDictionary)
        }
    }

    func read() -> [TempSensor] {
        guard let client, let copyServices, let copyProperty, let copyEvent, let getFloat,
              let servicesPtr = copyServices(client) else { return [] }
        let services = Unmanaged<CFArray>.fromOpaque(servicesPtr).takeRetainedValue()

        var values: [String: [Double]] = [:]
        for i in 0..<CFArrayGetCount(services) {
            guard let raw = CFArrayGetValueAtIndex(services, i) else { continue }
            let service = UnsafeMutableRawPointer(mutating: raw)
            guard let namePtr = copyProperty(service, "Product" as CFString) else { continue }
            let nameObj = Unmanaged<AnyObject>.fromOpaque(namePtr).takeRetainedValue()
            guard let name = nameObj as? String else { continue }
            guard let eventPtr = copyEvent(service, Self.eventTypeTemperature, 0, 0) else { continue }
            let value = getFloat(eventPtr, Self.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(eventPtr).release()
            guard value > 1, value < 150 else { continue }
            values[name, default: []].append(value)
        }

        return values.compactMap { name, list -> TempSensor? in
            let kind = Self.kind(for: name)
            if name.lowercased().contains("tcal") { return nil }
            return TempSensor(id: name, name: Self.prettyName(name),
                              value: list.reduce(0, +) / Double(list.count), kind: kind)
        }
        .sorted {
            $0.kind != $1.kind ? $0.kind.rawValue < $1.kind.rawValue
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func kind(for name: String) -> TempSensor.Kind {
        let n = name.lowercased()
        if n.contains("tdie") || n.contains("soc") || n.contains("cpu") { return .soc }
        if n.contains("nand") || n.contains("ssd") { return .ssd }
        if n.contains("battery") || n.contains("gas gauge") { return .battery }
        return .other
    }

    static func prettyName(_ raw: String) -> String {
        let n = raw.lowercased()
        if n.contains("nand") { return raw.replacingOccurrences(of: "NAND", with: "SSD").replacingOccurrences(of: " temp", with: "") }
        if n.contains("gas gauge") { return "Bateria" }
        if n.contains("battery") { return "Bateria" }
        return raw
            .replacingOccurrences(of: "PMU2 tdie", with: "SoC₂ die ")
            .replacingOccurrences(of: "PMU tdie", with: "SoC die ")
            .replacingOccurrences(of: "PMU2 tdev", with: "Płyta₂ ")
            .replacingOccurrences(of: "PMU tdev", with: "Płyta ")
    }
}
