import Foundation
import IOKit
import SwiftUI

/// Wear and health of the internal NVMe SSD from its SMART log (no admin rights needed), plus a small daily log
/// of the data written, kept in Application Support, to show how fast the drive wears.
@MainActor
@Observable
final class SSDHealth {
    static let shared = SSDHealth()

    struct Info: Equatable {
        var model: String?
        var percentUsed: Int          // wear estimate from the drive, may exceed 100
        var availableSpare: Int       // %
        var spareThreshold: Int       // %
        var temperature: Double?      // °C
        var bytesWritten: Double
        var bytesRead: Double
        var powerOnHours: UInt64
        var powerCycles: UInt64
        var unsafeShutdowns: UInt64
        var mediaErrors: UInt64
        var criticalWarning: UInt8
        var lifeLeft: Double { max(0, Double(100 - percentUsed)) / 100 }
    }

    struct Day: Codable, Equatable {
        var day: String
        var written: Double   // bytes, total written so far at that day's last reading
        var used: Int
    }

    private(set) var info: Info?
    private(set) var loaded = false
    private(set) var days: [Day] = []
    @ObservationIgnored private var lastRead: Date?
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var demo = false

    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ssd-log.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode([Day].self, from: data) { days = saved }
    }

    /// Every monitor tick: reads at most once an hour in the background (for the daily log).
    func tick() { if lastRead == nil || Date().timeIntervalSince(lastRead!) > 3600 { refresh() } }

    /// When the Disk panel opens: fresh values if the last reading is older than a minute.
    func refreshIfStale() { if lastRead == nil || Date().timeIntervalSince(lastRead!) > 60 { refresh() } }

    private func refresh() {
        guard !reading, !demo else { return }
        reading = true
        lastRead = Date()
        Task.detached(priority: .utility) {
            let result = Self.read()
            await MainActor.run {
                let s = SSDHealth.shared
                s.reading = false
                guard !s.demo else { return }
                s.loaded = true
                if result != s.info { s.info = result }
                if let result { s.log(result) }
            }
        }
    }

    private func log(_ i: Info) {
        let key = BatteryLog.dayFormat.string(from: Date())
        let entry = Day(day: key, written: i.bytesWritten, used: i.percentUsed)
        if let last = days.indices.last, days[last].day == key {
            guard days[last] != entry else { return }
            days[last] = entry
        } else {
            days.append(entry)
            if days.count > 730 { days.removeFirst(days.count - 730) }
        }
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: Self.url, options: .atomic) }
    }

    /// Bytes written over the last `count` days of the log (nil until two days are known).
    func writtenRecently(days count: Int) -> (bytes: Double, days: Int)? {
        guard let last = days.last,
              let cutoff = Calendar.current.date(byAdding: .day, value: -count, to: Date()) else { return nil }
        let key = BatteryLog.dayFormat.string(from: cutoff)
        guard let first = days.first(where: { $0.day >= key }), first.day != last.day,
              let d0 = BatteryLog.dayFormat.date(from: first.day), let d1 = BatteryLog.dayFormat.date(from: last.day) else { return nil }
        let span = max(1, Calendar.current.dateComponents([.day], from: d0, to: d1).day ?? 1)
        return (max(0, last.written - first.written), span)
    }

    // MARK: - SMART

    /// The first entries of IONVMeSMARTInterface (IOKit/storage/nvme/NVMeSMARTLibExternal.h is not visible to Swift).
    private struct VTable {
        var reserved: UnsafeMutableRawPointer?
        var queryInterface: @convention(c) (UnsafeMutableRawPointer?, REFIID, UnsafeMutablePointer<LPVOID?>?) -> HRESULT
        var addRef: @convention(c) (UnsafeMutableRawPointer?) -> ULONG
        var release: @convention(c) (UnsafeMutableRawPointer?) -> ULONG
        var version: UInt16
        var revision: UInt16
        var smartReadData: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
    }

    private nonisolated static func read() -> Info? {
        var iterator: io_iterator_t = 0
        let match = [kIOPropertyMatchKey: ["NVMe SMART Capable": true]] as CFDictionary
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let userClient = CFUUIDGetConstantUUIDWithBytes(nil, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
        let cfPlugIn = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
        let smartInterface = CFUUIDGetConstantUUIDWithBytes(nil, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
            var score: Int32 = 0
            guard IOCreatePlugInInterfaceForService(service, userClient, cfPlugIn, &plugin, &score) == KERN_SUCCESS,
                  let plugin, let p = plugin.pointee else { continue }
            defer { _ = p.pointee.Release(plugin) }
            var raw: UnsafeMutableRawPointer?
            guard p.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(smartInterface), &raw) == S_OK, let raw else { continue }
            let vt = raw.assumingMemoryBound(to: UnsafeMutablePointer<VTable>.self).pointee.pointee
            defer { _ = vt.release(raw) }
            let buf = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)
            defer { buf.deallocate() }
            buf.initializeMemory(as: UInt8.self, repeating: 0, count: 512)
            guard vt.smartReadData(raw, buf) == kIOReturnSuccess else { continue }
            func u8(_ o: Int) -> UInt8 { buf.load(fromByteOffset: o, as: UInt8.self) }
            func u64(_ o: Int) -> UInt64 { buf.loadUnaligned(fromByteOffset: o, as: UInt64.self) }
            let kelvin = Double(buf.loadUnaligned(fromByteOffset: 1, as: UInt16.self))
            let model = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Model Number" as CFString, kCFAllocatorDefault,
                                                        IOOptionBits(kIORegistryIterateRecursively)) as? String
            // NVMe data units are 1000 × 512 bytes.
            return Info(model: model?.trimmingCharacters(in: .whitespaces), percentUsed: Int(u8(5)), availableSpare: Int(u8(3)),
                        spareThreshold: Int(u8(4)), temperature: kelvin > 200 ? kelvin - 273.15 : nil,
                        bytesWritten: Double(u64(48)) * 512_000, bytesRead: Double(u64(32)) * 512_000,
                        powerOnHours: u64(128), powerCycles: u64(112), unsafeShutdowns: u64(144),
                        mediaErrors: u64(160), criticalWarning: u8(0))
        }
        return nil
    }

    /// README screenshots (`--snapshot <dir> --demo`).
    func applyDemo() {
        demo = true
        loaded = true
        info = Info(model: "APPLE SSD AP0512Z", percentUsed: 2, availableSpare: 100, spareThreshold: 99, temperature: 38,
                    bytesWritten: 18.4e12, bytesRead: 41.2e12, powerOnHours: 1840, powerCycles: 612, unsafeShutdowns: 4,
                    mediaErrors: 0, criticalWarning: 0)
        let cal = Calendar.current
        days = (0..<31).reversed().compactMap { back in
            cal.date(byAdding: .day, value: -back, to: Date()).map { Day(day: BatteryLog.dayFormat.string(from: $0), written: 18.4e12 - Double(back) * 21e9, used: 2) }
        }
    }
}

/// Disk panel: SSD wear and SMART values.
struct SSDHealthCard: View {
    private let ssd = SSDHealth.shared

    var body: some View {
        Group {
            if let i = ssd.info {
                Card {
                    SectionTitle(text: "Żywotność SSD", trailing: i.model)
                    HStack(alignment: .firstTextBaseline) {
                        BigValue(value: Fmt.pct(i.lifeLeft))
                        Text("pozostało").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        if i.criticalWarning != 0 || i.mediaErrors > 0 || i.availableSpare < i.spareThreshold {
                            Label("Ostrzeżenie SMART", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                        }
                    }
                    let c: Color = i.lifeLeft > 0.3 ? .green : (i.lifeLeft > 0.1 ? .orange : .red)
                    LinearMeter(value: i.lifeLeft, colors: [c.opacity(0.7), c], height: 6)
                    VStack(spacing: 7) {
                        InfoRow(title: "Zapisano", value: Fmt.file(Int64(i.bytesWritten)))
                        if let recent = ssd.writtenRecently(days: 30) {
                            InfoRow(title: String(localized: "Średnio dziennie (\(recent.days) dni)"),
                                    value: Fmt.file(Int64(recent.bytes / Double(recent.days))))
                        }
                        InfoRow(title: "Odczytano", value: Fmt.file(Int64(i.bytesRead)))
                        if let t = i.temperature { InfoRow(title: "Temperatura", value: Fmt.temp(t)) }
                        InfoRow(title: "Rezerwa bloków", value: "\(i.availableSpare)%")
                        InfoRow(title: "Godziny pracy", value: "\(i.powerOnHours)")
                        InfoRow(title: "Włączenia", value: "\(i.powerCycles)")
                        InfoRow(title: "Nagłe wyłączenia", value: "\(i.unsafeShutdowns)")
                        if i.mediaErrors > 0 { InfoRow(title: "Błędy nośnika", value: "\(i.mediaErrors)") }
                    }
                    Text("Zużycie podaje sam dysk na podstawie liczby zapisów. Dyski Apple wytrzymują zwykle setki TB zapisu.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { ssd.refreshIfStale() }
    }
}
