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
        return byKind.sorted { (order[$0.key] ?? 2, $0.key) < (order[$1.key] ?? 2, $1.key) }
            .map { CoreGroup(id: $0.key, name: name(kind: $0.key, kinds: byKind.count), indices: $0.value.sorted()) }
    }

    private static func name(kind: String, kinds: Int) -> String {
        switch kind {
        case "E": String(localized: "Rdzenie efektywne")
        case "S": String(localized: "Superrdzenia")
        // Some chips report their "Super" cores with the performance cluster type.
        case "P" where kinds == 2 && fastestAreSuper: String(localized: "Superrdzenia")
        default: String(localized: "Rdzenie wydajne")
        }
    }

    /// Newest chips call their fastest cores "Super".
    static var fastestAreSuper: Bool { Sysctl.string("hw.perflevel0.name") == "Super" }
}
