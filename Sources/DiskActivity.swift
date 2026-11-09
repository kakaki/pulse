import Darwin
import Foundation
import IOKit

struct DiskRates: Equatable {
    var read: Double = 0
    var write: Double = 0
}

/// Read/write speed of each mounted volume, taken from the physical drive that holds it.
final class DiskActivitySampler {
    private var previous: [String: (read: UInt64, write: UInt64, time: Date)] = [:]

    func sample(_ volumes: [DiskVolume]) -> [String: DiskRates] {
        var rates: [String: DiskRates] = [:]
        let now = Date()
        for volume in volumes {
            guard let counters = Self.counters(path: volume.path) else { continue }
            if let prev = previous[volume.id] {
                let dt = now.timeIntervalSince(prev.time)
                if dt > 0 {
                    rates[volume.id] = DiskRates(read: counters.read >= prev.read ? Double(counters.read - prev.read) / dt : 0,
                                                 write: counters.write >= prev.write ? Double(counters.write - prev.write) / dt : 0)
                }
            }
            previous[volume.id] = (counters.read, counters.write, now)
        }
        return rates
    }

    private static func counters(path: String) -> (read: UInt64, write: UInt64)? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let device = withUnsafePointer(to: &info.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let bsd = (device as NSString).lastPathComponent
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { return nil }
        // APFS volumes sit several layers above the drive that does the actual I/O.
        while IOObjectConformsTo(entry, "IOBlockStorageDriver") == 0 {
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard status == KERN_SUCCESS else { return nil }
            entry = parent
        }
        defer { IOObjectRelease(entry) }
        guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { return nil }
        return ((stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0, (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0)
    }
}
