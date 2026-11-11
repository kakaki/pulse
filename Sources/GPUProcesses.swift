import Foundation
import IOKit
import SwiftUI

/// GPU time per process, from the `AppUsage` of each GPU user client in the IORegistry (no special rights needed).
/// Sampled only while the Graphics panel is open.
final class GPUProcessSampler {
    struct Entry: Identifiable, Equatable {
        let id: pid_t
        let name: String
        let share: Double   // fraction of GPU time during the last interval (0…1)
    }

    private var previous: [pid_t: UInt64] = [:]
    private var previousTime: Date?

    func sample() -> [Entry] {
        let totals = Self.read()
        let now = Date()
        defer { previous = totals.mapValues(\.time); previousTime = now }
        guard let last = previousTime else { return [] }
        let dt = now.timeIntervalSince(last)
        guard dt > 0 else { return [] }
        return totals.compactMap { pid, value in
            guard let before = previous[pid], value.time > before else { return nil }
            let share = min(Double(value.time - before) / 1e9 / dt, 1)
            guard share >= 0.001 else { return nil }
            // System processes (WindowServer) have no name for us; the GPU registry knows it.
            let known = ProcessSampler.name(for: pid)
            let name = (known.isEmpty || known.hasPrefix("PID ")) && !value.name.isEmpty ? value.name : known
            return Entry(id: pid, name: name, share: share)
        }
        .sorted { $0.share > $1.share }
    }

    /// Accumulated GPU nanoseconds per pid, summed over all of its user clients.
    private static func read() -> [pid_t: (time: UInt64, name: String)] {
        var result: [pid_t: (time: UInt64, name: String)] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(accelerators) }
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let client = IOIteratorNext(children), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = property(client, "IOUserClientCreator") as? String,
                      let usage = property(client, "AppUsage") as? [[String: Any]], !usage.isEmpty else { continue }
                // "pid 406, WindowServer"
                let parts = creator.split(separator: ",", maxSplits: 1)
                guard let pidText = parts.first?.split(separator: " ").last, let pid = pid_t(pidText) else { continue }
                let time = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                result[pid] = ((result[pid]?.time ?? 0) + time, name)
            }
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

struct GPUProcessList: View {
    @Environment(SystemMonitor.self) private var m

    var body: some View {
        let list = Array(m.gpuProcesses.prefix(5))
        Card {
            SectionTitle(text: "Procesy · GPU", trailing: String(localized: "prawy klik: opcje"))
            if list.isEmpty {
                Text(m.gpuProcessesLoaded ? String(localized: "Brak aktywności") : String(localized: "Zbieranie danych…"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            VStack(spacing: 7) {
                ForEach(list) { p in
                    HStack(spacing: 8) {
                        ProcessIcon(pid: p.id).frame(width: 16, height: 16)
                        Text(verbatim: p.name).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Text(verbatim: String(format: "%.1f%%", p.share * 100))
                            .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .processMenu(pid: p.id, name: p.name)
                }
            }
        }
        .onAppear { m.gpuProcessWatchers += 1 }
        .onDisappear { m.gpuProcessWatchers = max(0, m.gpuProcessWatchers - 1) }
    }
}
