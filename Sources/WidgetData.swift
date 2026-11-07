import Foundation

/// Snapshot the app writes for the desktop widget (compiled into both the app and the widget extension).
struct WidgetData: Codable {
    var date: Date
    var chip: String
    var cpu: Double
    var mem: Double
    var disk: Double
    var temp: Double?
    var gpu: Double?
    var battery: Double?
    var charging: Bool
    var netIn: Double
    var netOut: Double
    /// Last hour, per-minute averages (NaN encoded as -1).
    var cpuHour: [Double]
    var memHour: [Double]
    var tempHour: [Double]

    /// Real home directory (inside the widget sandbox NSHomeDirectory() points at the container).
    static var url: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Pulse/widget.json")
    }

    static func load() -> WidgetData? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetData.self, from: data)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}
