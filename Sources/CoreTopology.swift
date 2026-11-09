import Foundation
import IOKit

/// Cores of one kind (efficiency, performance…); `indices` point into `SystemMonitor.cores`.
struct CoreGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let indices: [Int]
}

enum CoreTopology {
    /// Core kinds from the device tree, fastest first. Empty on Intel, where all cores are alike.
    static func groups() -> [CoreGroup] {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard root != 0 else { return [] }
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(root, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        func data(_ entry: io_object_t, _ key: String) -> Data? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
        }
        var byKind: [String: [Int]] = [:]
        while case let cpu = IOIteratorNext(iterator), cpu != 0 {
            defer { IOObjectRelease(cpu) }
            guard let type = data(cpu, "cluster-type"), let first = type.first,
                  let id = IORegistryEntryCreateCFProperty(cpu, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber else { continue }
            byKind[String(UnicodeScalar(first)), default: []].append(id.intValue)
        }
        guard byKind.count > 1 else { return [] }
        let order = ["S": 0, "P": 1, "M": 2, "E": 3]
        let sorted = byKind.sorted { (order[$0.key] ?? 2, $0.key) < (order[$1.key] ?? 2, $1.key) }
        // The system names each tier itself, so tiers of future chips are labelled without code changes.
        let levels = (0..<Int(Sysctl.int32("hw.nperflevels") ?? 0)).map {
            (name: Sysctl.string("hw.perflevel\($0).name"), count: Sysctl.int32("hw.perflevel\($0).logicalcpu"))
        }
        return sorted.enumerated().map { position, entry in
            var label = name(kind: entry.key)
            if levels.count == sorted.count, levels[position].count == Int32(entry.value.count), let tier = levels[position].name {
                label = name(tier: tier)
            }
            return CoreGroup(id: entry.key, name: label, indices: entry.value.sorted())
        }
    }

    private static func name(kind: String) -> String {
        switch kind {
        case "E": String(localized: "Rdzenie efektywne")
        case "S": String(localized: "Superrdzenia")
        default: String(localized: "Rdzenie wydajne")
        }
    }

    private static func name(tier: String) -> String {
        switch tier {
        case "Efficiency": String(localized: "Rdzenie efektywne")
        case "Performance": String(localized: "Rdzenie wydajne")
        case "Super": String(localized: "Superrdzenia")
        default: tier
        }
    }

    /// Two-tier chips whose fast cores are called "Super"; with more tiers the sensor family cannot be told apart.
    static var fastestAreSuper: Bool { Sysctl.int32("hw.nperflevels") == 2 && Sysctl.string("hw.perflevel0.name") == "Super" }
}
