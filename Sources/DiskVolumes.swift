import DiskArbitration
import Foundation

/// A mounted disk a user would recognise as a drive.
struct DiskVolume: Identifiable, Equatable {
    let id: String
    let name: String
    let total: Int64
    let free: Int64
    let isSystem: Bool
    let isInternal: Bool
    var used: Int64 { max(total - free, 0) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var symbol: String { isInternal ? "internaldrive" : "externaldrive" }
}

enum DiskVolumes {
    private static let session = DASessionCreate(kCFAllocatorDefault)
    private static var diskImages: [String: Bool] = [:]

    /// The system disk first, then other local drives; skips network shares, system volumes and mounted images (DMG).
    static func list() -> [DiskVolume] {
        let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let volumes: [DiskVolume] = urls.compactMap { url in
            let path = url.path(percentEncoded: false)
            let isSystem = path == "/"
            guard isSystem || path.hasPrefix("/Volumes/"),
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsLocal == true, v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 0,
                  isSystem || !isDiskImage(url, path: path) else { return nil }
            let important = v.volumeAvailableCapacityForImportantUsage ?? 0
            let free = important > 0 ? important : Int64(v.volumeAvailableCapacity ?? 0)
            return DiskVolume(id: v.volumeUUIDString ?? path, name: v.volumeLocalizedName ?? url.lastPathComponent,
                              total: Int64(total), free: free, isSystem: isSystem, isInternal: v.volumeIsInternal ?? false)
        }
        return volumes.sorted { $0.isSystem != $1.isSystem ? $0.isSystem : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func isDiskImage(_ url: URL, path: String) -> Bool {
        if let known = diskImages[path] { return known }
        var result = false
        if let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
           let info = DADiskCopyDescription(disk) as? [CFString: Any] {
            result = (info[kDADiskDescriptionDeviceModelKey] as? String)?.trimmingCharacters(in: .whitespaces) == "Disk Image"
        }
        diskImages[path] = result
        return result
    }
}

/// What the menu bar and the Overview tile show for the disk (Settings → Dysk).
enum DiskDisplay {
    static let quantityKey = "disk.show", unitKey = "disk.unit", volumeKey = "disk.volume"
    static var showsFree: Bool { UserDefaults.standard.string(forKey: quantityKey) == "free" }
    static var showsAmount: Bool { UserDefaults.standard.string(forKey: unitKey) == "amount" }

    /// Fill of rings and bars: follows the number shown.
    static func fraction(_ v: DiskVolume) -> Double { showsFree ? 1 - v.usedFraction : v.usedFraction }

    static func text(_ v: DiskVolume) -> String {
        if showsAmount { return compact(showsFree ? v.free : v.used) }
        return Fmt.pct(fraction(v))
    }

    /// Short enough for the menu bar: "301 GB", "4,2 GB", "1,2 TB".
    static func compact(_ bytes: Int64) -> String {
        let b = Double(max(bytes, 0))
        func one(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(1))) }
        if b >= 999.5e9 { return one(b / 1e12) + " TB" }
        if b >= 9.95e9 { return "\(Int((b / 1e9).rounded())) GB" }
        if b >= 1e9 { return one(b / 1e9) + " GB" }
        return "\(Int((b / 1e6).rounded())) MB"
    }
}
