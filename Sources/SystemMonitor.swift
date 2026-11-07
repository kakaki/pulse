import SwiftUI
import AppKit
import Darwin
import IOKit
import IOKit.ps
import Observation
import WidgetKit

enum MemoryPressure: Equatable {
    case normal, warning, critical
}

@MainActor
@Observable
final class SystemMonitor {
    static let historyLength = 60
    static let shared = SystemMonitor()

    // MARK: CPU
    private(set) var cpu: Double = 0
    private(set) var cpuUser: Double = 0
    private(set) var cpuSystem: Double = 0
    private(set) var cores: [Double] = []
    private(set) var cpuHistory: [Double] = []
    private(set) var loadAverage: [Double] = [0, 0, 0]

    // MARK: Memory
    let memTotal = ProcessInfo.processInfo.physicalMemory
    private(set) var memUsed: UInt64 = 0
    private(set) var memApp: UInt64 = 0
    private(set) var memWired: UInt64 = 0
    private(set) var memCompressed: UInt64 = 0
    private(set) var memCached: UInt64 = 0
    private(set) var swapUsed: UInt64 = 0
    private(set) var memPressure: MemoryPressure = .normal
    private(set) var memHistory: [Double] = []
    var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }

    // MARK: Disk
    private(set) var diskName = "Macintosh HD"
    private(set) var diskTotal: Int64 = 0
    private(set) var diskFree: Int64 = 0
    private(set) var readRate: Double = 0
    private(set) var writeRate: Double = 0
    private(set) var readHistory: [Double] = []
    private(set) var writeHistory: [Double] = []
    var diskFraction: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) : 0 }

    // MARK: Temperatures
    private(set) var sensors: [TempSensor] = []
    private(set) var socAvg: Double?
    private(set) var socMax: Double?
    private(set) var ssdTemp: Double?
    private(set) var batteryTemp: Double?
    private(set) var tempHistory: [Double] = []

    // MARK: GPU
    private(set) var gpu: Double?
    private(set) var gpuHistory: [Double] = []

    // MARK: Network
    private(set) var netIn: Double = 0
    private(set) var netOut: Double = 0
    private(set) var netInHistory: [Double] = []
    private(set) var netOutHistory: [Double] = []
    private(set) var netInterface: String?
    private(set) var netAddress: String?
    private(set) var netSessionIn: UInt64 = 0
    private(set) var netSessionOut: UInt64 = 0

    // MARK: Fans & power (SMC)
    private(set) var fans: [FanInfo] = []
    private(set) var hasFans = false
    private(set) var systemPower: Double?
    /// macOS thermal pressure; above nominal the system throttles performance.
    private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    // MARK: Battery
    private(set) var battery = BatteryInfo()
    private(set) var batteryHistory: [Double] = []

    // MARK: Power saving
    /// True while Pulse refreshes less often (on battery or in Low Power Mode).
    private(set) var isSaving = false
    var effectiveInterval: Double {
        let base = max(0.5, UserDefaults.standard.double(forKey: "interval"))
        return isSaving ? max(base * 2.5, 5) : base
    }
    @ObservationIgnored private var powerSource: CFRunLoopSource?

    // MARK: Processes
    private(set) var processes: [ProcessStat] = []
    var topByCPU: [ProcessStat] { Array(processes.sorted { $0.cpu > $1.cpu }.prefix(5)) }
    var topByMemory: [ProcessStat] { Array(processes.sorted { $0.memory > $1.memory }.prefix(5)) }
    /// Number of open dropdowns that need the (costlier) per-process sample.
    @ObservationIgnored var processWatchers = 0 {
        didSet { if processWatchers > 0 && oldValue == 0 { processes = processSampler.sample() } }
    }

    /// Called after every refresh (used to redraw the menu bar items).
    @ObservationIgnored var onUpdate: (() -> Void)?

    // MARK: System
    let chipName: String
    let coreCount = ProcessInfo.processInfo.activeProcessorCount
    private(set) var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    @ObservationIgnored private var prevTicks: [[UInt32]] = []
    @ObservationIgnored private var prevIO: (read: UInt64, write: UInt64, time: Date)?
    @ObservationIgnored private let tempReader = TemperatureReader()
    @ObservationIgnored private var prevNet: (rx: UInt32, tx: UInt32, time: Date)?
    @ObservationIgnored private let processSampler = ProcessSampler()
    @ObservationIgnored private let smcSampler = SMCSampler()
    @ObservationIgnored let history = HistoryStore()
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var loop: Task<Void, Never>?

    private init() {
        UserDefaults.standard.register(defaults: [
            "interval": 2.0, "tempUnit": 0, "showLabels": true, "colorize": true, "powerSaver": true,
        ])
        chipName = Sysctl.string("machdep.cpu.brand_string") ?? "Mac"
        battery = BatterySampler.read()
        updateSaving()
        refresh()
        // React to plugging/unplugging immediately instead of on the next battery poll.
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { SystemMonitor.shared.powerSourceChanged() }
        }, nil)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode); powerSource = source }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SystemMonitor.shared.updateSaving() }
        }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: .seconds(self.effectiveInterval))
            }
        }
    }

    private func powerSourceChanged() {
        battery = BatterySampler.read()
        updateSaving()
        onUpdate?()
    }

    func updateSaving() {
        let enabled = UserDefaults.standard.bool(forKey: "powerSaver")
        let onBattery = battery.present && !battery.onAC
        let saving = enabled && (onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled)
        if saving != isSaving { isSaving = saving }
    }

    func refresh() {
        sampleCPU()
        sampleMemory()
        if tick % 5 == 0 { sampleDiskCapacity() }
        sampleDiskIO()
        sampleTemperatures()
        sampleGPU()
        sampleNetwork()
        if tick % 5 == 0 { battery = BatterySampler.read(); updateSaving() }
        if battery.present { push(&batteryHistory, battery.percent) }
        if processWatchers > 0 { processes = processSampler.sample() }
        hasFans = smcSampler.fanCount > 0
        if hasFans { fans = smcSampler.fans() }
        systemPower = smcSampler.systemPower()
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal != thermalState { thermalState = thermal }
        uptime = ProcessInfo.processInfo.systemUptime
        recordHistory()
        if tick % 30 == 0 { publishWidget() }
        tick += 1
        onUpdate?()
    }

    /// Writes the widget snapshot (~every minute) and asks WidgetKit to refresh (~every 5 minutes).
    @ObservationIgnored private var lastWidgetReload = Date.distantPast
    private func publishWidget() {
        let enc: ([Double]) -> [Double] = { $0.map { $0.isFinite ? $0 : -1 } }
        var cpuHour = enc(history.series(.cpu, range: .hour))
        if !cpuHour.contains(where: { $0 >= 0 }) { cpuHour = cpuHistory }
        WidgetData(date: Date(), chip: chipName, cpu: cpu, mem: memFraction, disk: diskFraction, temp: socMax ?? socAvg,
                   gpu: gpu, battery: battery.present ? battery.percent : nil, charging: battery.isCharging,
                   netIn: netIn, netOut: netOut, cpuHour: cpuHour,
                   memHour: enc(history.series(.mem, range: .hour)), tempHour: enc(history.series(.temp, range: .hour)))
            .save()
        if Date().timeIntervalSince(lastWidgetReload) > 290 {
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func recordHistory() {
        history.add(.cpu, cpu)
        history.add(.gpu, gpu)
        history.add(.mem, memFraction)
        history.add(.temp, socMax ?? socAvg)
        history.add(.diskRead, readRate)
        history.add(.diskWrite, writeRate)
        history.add(.netIn, netIn)
        history.add(.netOut, netOut)
        if battery.present {
            history.add(.battery, battery.percent)
            history.add(.batteryPower, battery.watts)
        }
    }

    private func push(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > Self.historyLength { array.removeFirst(array.count - Self.historyLength) }
    }

    // MARK: - CPU

    private func sampleCPU() {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var ticks: [[UInt32]] = []
        for i in 0..<Int(count) {
            let base = i * Int(CPU_STATE_MAX)
            ticks.append([CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE]
                .map { UInt32(bitPattern: info[base + Int($0)]) })
        }

        if prevTicks.count == ticks.count {
            var totalUser = 0.0, totalSystem = 0.0, total = 0.0
            var perCore: [Double] = []
            for (a, b) in zip(prevTicks, ticks) {
                let user = Double(b[0] &- a[0]) + Double(b[3] &- a[3])
                let system = Double(b[1] &- a[1])
                let idle = Double(b[2] &- a[2])
                let sum = user + system + idle
                perCore.append(sum > 0 ? (user + system) / sum : 0)
                totalUser += user; totalSystem += system; total += sum
            }
            cores = perCore
            cpuUser = total > 0 ? totalUser / total : 0
            cpuSystem = total > 0 ? totalSystem / total : 0
            cpu = min(1, cpuUser + cpuSystem)
            push(&cpuHistory, cpu)
        }
        prevTicks = ticks

        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { loadAverage = load }
    }

    // MARK: - Memory

    private func sampleMemory() {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        memApp = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        memWired = UInt64(stats.wire_count) * page
        memCompressed = UInt64(stats.compressor_page_count) * page
        memCached = (UInt64(stats.external_page_count) + purgeable) * page
        memUsed = min(memTotal, memApp + memWired + memCompressed)
        push(&memHistory, memFraction)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { swapUsed = swap.xsu_used }

        switch Sysctl.int32("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 4: memPressure = .critical
        case 2: memPressure = .warning
        default: memPressure = .normal
        }
    }

    // MARK: - Disk

    private func sampleDiskCapacity() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
        if let name = values.volumeLocalizedName { diskName = name }
    }

    private func sampleDiskIO() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0, write: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }

        let now = Date()
        if let prev = prevIO {
            let dt = now.timeIntervalSince(prev.time)
            if dt > 0 {
                readRate = read >= prev.read ? Double(read - prev.read) / dt : 0
                writeRate = write >= prev.write ? Double(write - prev.write) / dt : 0
                push(&readHistory, readRate)
                push(&writeHistory, writeRate)
            }
        }
        prevIO = (read, write, now)
    }

    // MARK: - GPU

    private func sampleGPU() {
        gpu = GPUSampler.utilization()
        if let gpu { push(&gpuHistory, gpu) }
    }

    // MARK: - Network

    private func sampleNetwork() {
        let c = NetworkSampler.counters()
        netInterface = c.primary
        netAddress = c.address
        let now = Date()
        if let prev = prevNet {
            let dt = now.timeIntervalSince(prev.time)
            let dIn = UInt64(c.rx &- prev.rx), dOut = UInt64(c.tx &- prev.tx)
            if dt > 0 {
                netIn = Double(dIn) / dt
                netOut = Double(dOut) / dt
                netSessionIn += dIn
                netSessionOut += dOut
                push(&netInHistory, netIn)
                push(&netOutHistory, netOut)
            }
        }
        prevNet = (c.rx, c.tx, now)
    }

    // MARK: - Temperatures

    private func sampleTemperatures() {
        let all = tempReader.read()
        sensors = all
        let soc = all.filter { $0.kind == .soc }.map(\.value)
        socAvg = soc.isEmpty ? nil : soc.reduce(0, +) / Double(soc.count)
        socMax = soc.max()
        ssdTemp = all.filter { $0.kind == .ssd }.map(\.value).max()
        batteryTemp = all.filter { $0.kind == .battery }.map(\.value).max()
        if let t = socMax ?? socAvg { push(&tempHistory, t) }
    }
}

enum Sysctl {
    static func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

extension ProcessInfo.ThermalState {
    var title: String {
        switch self {
        case .nominal: String(localized: "Normalny")
        case .fair: String(localized: "Podwyższony")
        case .serious: String(localized: "Poważny")
        case .critical: String(localized: "Krytyczny")
        @unknown default: String(localized: "Nieznany")
        }
    }
    var detail: String {
        switch self {
        case .nominal: String(localized: "Pełna wydajność.")
        case .fair: String(localized: "Mac się nagrzewa – wydajność jeszcze bez zmian.")
        case .serious: String(localized: "macOS ogranicza wydajność, żeby schłodzić układ.")
        case .critical: String(localized: "Silne ograniczenie wydajności – Mac jest bardzo gorący.")
        @unknown default: ""
        }
    }
    var color: Color {
        switch self {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        default: .red
        }
    }
}
