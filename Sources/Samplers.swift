import AppKit
import Darwin
import IOKit
import IOKit.ps

// MARK: - GPU

/// Undocumented IOAccelerator statistics: every field but `device` may be missing on other Macs or systems.
struct GPUStats: Equatable {
    var device: Double
    var renderer: Double?
    var tiler: Double?
    var memoryInUse: UInt64?
    var memoryAllocated: UInt64?
    var recoveries: Int?
    var cores: Int?
}

enum GPUSampler {
    static func stats() -> GPUStats? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let device = fraction(stats["Device Utilization %"]) else { continue }
            let cores = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
            return GPUStats(device: device,
                            renderer: fraction(stats["Renderer Utilization %"]),
                            tiler: fraction(stats["Tiler Utilization %"]),
                            memoryInUse: (stats["In use system memory"] as? NSNumber)?.uint64Value,
                            memoryAllocated: (stats["Alloc system memory"] as? NSNumber)?.uint64Value,
                            recoveries: (stats["recoveryCount"] as? NSNumber)?.intValue,
                            cores: cores?.intValue)
        }
        return nil
    }

    private static func fraction(_ value: Any?) -> Double? {
        (value as? NSNumber).map { min(1, max(0, $0.doubleValue / 100)) }
    }
}

// MARK: - Network

struct NetworkCounters {
    var received: UInt64 = 0
    var sent: UInt64 = 0
}

enum NetworkSampler {
    /// Byte counters (32-bit, wrapping) summed over physical / cellular interfaces.
    static func counters() -> (rx: UInt32, tx: UInt32, primary: String?, address: String?) {
        var rx: UInt32 = 0, tx: UInt32 = 0
        var primary: String?, address: String?
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0, nil, nil) }
        defer { freeifaddrs(ifap) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip"),
                  let addr = ifa.pointee.ifa_addr else { continue }
            let flags = Int32(ifa.pointee.ifa_flags)
            let family = addr.pointee.sa_family

            if family == UInt8(AF_LINK), let data = ifa.pointee.ifa_data {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                rx &+= stats.ifi_ibytes
                tx &+= stats.ifi_obytes
            } else if family == UInt8(AF_INET), flags & IFF_UP != 0, flags & IFF_RUNNING != 0, address == nil {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: host)
                    primary = name
                }
            }
        }
        return (rx, tx, primary, address)
    }
}

// MARK: - Battery

struct BatteryInfo: Equatable {
    var present = false
    var percent: Double = 0
    var isCharging = false
    var onAC = false
    var minutesRemaining: Int?
    var cycleCount: Int?
    var health: Double?
    var temperature: Double?
    /// Battery power in watts: positive while charging, negative while discharging.
    var watts: Double?
    var fullyCharged = false
    var designCapacity: Int?      // mAh
    var maxCapacity: Int?         // mAh, current full-charge capacity
    var currentCharge: Int?       // mAh
    var designCycles: Int?
    var voltage: Double?          // V
    var adapterWatts: Int?
    var adapterName: String?
}

enum BatterySampler {
    static func read() -> BatteryInfo {
        var info = BatteryInfo()
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                      (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                info.present = true
                let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
                let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
                info.percent = max > 0 ? Double(current) / Double(max) : 0
                info.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
                info.onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                let minutes = info.isCharging ? desc[kIOPSTimeToFullChargeKey] as? Int : desc[kIOPSTimeToEmptyKey] as? Int
                if let minutes, minutes > 0 { info.minutesRemaining = minutes }
            }
        }
        guard info.present else { return info }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return info }
        defer { IOObjectRelease(service) }
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        func int(_ key: String) -> Int? { (prop(key) as? NSNumber)?.intValue }
        info.cycleCount = int("CycleCount")
        info.designCycles = int("DesignCycleCount9C")
        info.designCapacity = int("DesignCapacity")
        info.maxCapacity = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity")
        info.currentCharge = int("AppleRawCurrentCapacity")
        info.fullyCharged = (prop("FullyCharged") as? Bool) ?? false
        if let raw = info.maxCapacity, let design = info.designCapacity, design > 0 {
            info.health = min(1, Double(raw) / Double(design))
        }
        if let t = (prop("Temperature") as? NSNumber)?.doubleValue { info.temperature = t / 100 }
        if let mv = (prop("Voltage") as? NSNumber)?.doubleValue {
            info.voltage = mv / 1000
            if let ma = (prop("InstantAmperage") as? NSNumber)?.int64Value ?? (prop("Amperage") as? NSNumber)?.int64Value {
                info.watts = mv * Double(ma) / 1_000_000
            }
        }
        if info.onAC, let adapter = prop("AdapterDetails") as? [String: Any] {
            info.adapterWatts = (adapter["Watts"] as? NSNumber)?.intValue
            info.adapterName = adapter["Name"] as? String
        }
        return info
    }
}

// MARK: - Processes

struct ProcessStat: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let cpu: Double      // fraction of one core (1.0 = 100%)
    let memory: UInt64   // physical footprint in bytes
    var diskRead: Double = 0    // bytes per second
    var diskWrite: Double = 0
}

final class ProcessSampler {
    private var previous: [pid_t: UInt64] = [:]
    private var previousTime: Date?
    private var previousIO: [pid_t: (read: UInt64, write: UInt64)] = [:]
    private let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    func sample() -> [ProcessStat] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        let now = Date()
        let dt = previousTime.map { now.timeIntervalSince($0) } ?? 0
        var current: [pid_t: UInt64] = [:]
        var currentIO: [pid_t: (read: UInt64, write: UInt64)] = [:]
        var result: [ProcessStat] = []
        result.reserveCapacity(Int(count))

        for pid in pids.prefix(Int(count)) where pid > 0 {
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0 else { continue }
            let cpuTime = usage.ri_user_time + usage.ri_system_time
            current[pid] = cpuTime
            var cpu = 0.0
            if dt > 0, let prev = previous[pid], cpuTime >= prev {
                cpu = Double(cpuTime - prev) * timebase / 1e9 / dt
            }
            currentIO[pid] = (usage.ri_diskio_bytesread, usage.ri_diskio_byteswritten)
            var diskRead = 0.0, diskWrite = 0.0
            if dt > 0, let prev = previousIO[pid] {
                if usage.ri_diskio_bytesread >= prev.read { diskRead = Double(usage.ri_diskio_bytesread - prev.read) / dt }
                if usage.ri_diskio_byteswritten >= prev.write { diskWrite = Double(usage.ri_diskio_byteswritten - prev.write) / dt }
            }
            result.append(ProcessStat(id: pid, name: Self.name(for: pid), cpu: cpu, memory: usage.ri_phys_footprint,
                                      diskRead: diskRead, diskWrite: diskWrite))
        }
        previous = current
        previousIO = currentIO
        previousTime = now
        return result
    }

    private var nameCache: [pid_t: String] = [:]

    private static var cache: [pid_t: String] = [:]
    static func name(for pid: pid_t) -> String {
        if let cached = cache[pid] { return cached }
        var name: String
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName {
            name = n
        } else {
            var buffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buffer, UInt32(buffer.count))
            name = String(cString: buffer)
            if name.isEmpty { name = "PID \(pid)" }
        }
        cache[pid] = name
        return name
    }

    private static var icons: [pid_t: NSImage?] = [:]

    /// Looked up once per process: asking LaunchServices on every panel redraw is expensive.
    static func icon(for pid: pid_t) -> NSImage? {
        if let known = icons[pid] { return known }
        if icons.count > 400 { icons.removeAll() }
        let image = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = image
        return image
    }
}
