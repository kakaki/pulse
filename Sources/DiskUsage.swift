import AppKit
import Observation
import SwiftUI

/// "What takes up the disk": sizes of the usual big folders, computed on demand in the background.
@MainActor
@Observable
final class DiskUsage {
    static let shared = DiskUsage()

    struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
        let symbol: String
        let url: URL
        var size: Int64?
        var denied = false
    }

    private(set) var entries: [Entry] = []
    private(set) var scanning = false
    private(set) var lastScan: Date?

    private static func folders() -> [Entry] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var list: [Entry] = [
            .init(id: "apps", name: String(localized: "Aplikacje"), symbol: "app.badge", url: URL(fileURLWithPath: "/Applications")),
            .init(id: "downloads", name: String(localized: "Pobrane"), symbol: "arrow.down.circle", url: home.appending(path: "Downloads")),
            .init(id: "documents", name: String(localized: "Dokumenty"), symbol: "doc", url: home.appending(path: "Documents")),
            .init(id: "desktop", name: String(localized: "Biurko"), symbol: "menubar.dock.rectangle", url: home.appending(path: "Desktop")),
            .init(id: "movies", name: String(localized: "Filmy"), symbol: "film", url: home.appending(path: "Movies")),
            .init(id: "music", name: String(localized: "Muzyka"), symbol: "music.note", url: home.appending(path: "Music")),
            .init(id: "pictures", name: String(localized: "Obrazy"), symbol: "photo", url: home.appending(path: "Pictures")),
            .init(id: "caches", name: String(localized: "Pamięć podręczna"), symbol: "archivebox", url: home.appending(path: "Library/Caches")),
            .init(id: "trash", name: String(localized: "Kosz"), symbol: "trash", url: home.appending(path: ".Trash")),
        ]
        let dev = home.appending(path: "Library/Developer")
        if FileManager.default.fileExists(atPath: dev.path) {
            list.insert(.init(id: "developer", name: String(localized: "Dane deweloperskie (Xcode)"), symbol: "hammer", url: dev), at: 8)
        }
        return list
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        if entries.isEmpty { entries = Self.folders() }
        let targets = Self.folders()
        Task {
            await withTaskGroup(of: (String, Int64?, Bool).self) { group in
                for e in targets {
                    let id = e.id, url = e.url
                    group.addTask { let r = await Self.size(of: url); return (id, r.0, r.1) }
                }
                for await (id, size, denied) in group {
                    if let i = entries.firstIndex(where: { $0.id == id }) {
                        entries[i].size = size
                        entries[i].denied = denied
                    }
                }
            }
            entries.sort { ($0.size ?? -1) > ($1.size ?? -1) }
            lastScan = Date()
            scanning = false
        }
    }

    /// Allocated size of everything below `url`; `denied` when macOS blocks reading the folder itself.
    private nonisolated static func size(of url: URL) async -> (Int64?, Bool) {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else { return (nil, false) }
            do { _ = try fm.contentsOfDirectory(atPath: url.path) } catch { return (nil, true) }
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
            guard let en = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
            else { return (nil, true) }
            var total: Int64 = 0
            while let file = en.nextObject() as? URL {
                guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
            return (total, false)
        }.value
    }
}

struct DiskUsageCard: View {
    @Environment(SystemMonitor.self) private var m
    private let usage = DiskUsage.shared

    var body: some View {
        Card {
            HStack {
                SectionTitle(text: "Co zajmuje miejsce",
                             trailing: usage.lastScan.map { $0.formatted(date: .omitted, time: .shortened) })
                Button {
                    usage.scan()
                } label: {
                    if usage.scanning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(usage.lastScan == nil ? String(localized: "Analizuj") : String(localized: "Odśwież"))
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(usage.scanning)
            }
            if usage.entries.isEmpty {
                Text("Policzę rozmiar najważniejszych folderów. macOS może zapytać o dostęp do Biurka, Dokumentów i Pobranych.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let used = max(m.diskTotal - m.diskFree, 1)
                VStack(spacing: 8) {
                    ForEach(usage.entries) { e in
                        row(e, used: used)
                    }
                    if !usage.scanning {
                        let known = usage.entries.compactMap(\.size).reduce(0, +)
                        let other = used - known
                        if other > 0 {
                            HStack(spacing: 8) {
                                Image(systemName: "gearshape.2").frame(width: 16).foregroundStyle(.secondary)
                                Text("System i pozostałe").font(.system(size: 12))
                                Spacer()
                                Text(Fmt.file(other)).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ e: DiskUsage.Entry, used: Int64) -> some View {
        HStack(spacing: 8) {
            Image(systemName: e.symbol).frame(width: 16).foregroundStyle(Module.disk.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.name).font(.system(size: 12)).lineLimit(1)
                if let size = e.size {
                    LinearMeter(value: Double(size) / Double(used), colors: Module.disk.colors, height: 3)
                }
            }
            Spacer(minLength: 6)
            Group {
                if let size = e.size {
                    Text(Fmt.file(size))
                } else if e.denied {
                    Text("brak dostępu").foregroundStyle(.secondary)
                        .help("macOS nie pozwala odczytać tego folderu. Dostęp nadasz w Ustawieniach systemowych → Prywatność → Pełny dostęp do dysku.")
                } else if usage.scanning {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            .frame(width: 78, alignment: .trailing)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([e.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Pokaż w Finderze")
        }
    }
}
