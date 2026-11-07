import SwiftUI

enum DisplayMode: String, CaseIterable, Identifiable {
    case text, graph, bars, ring
    var id: Self { self }
    var title: String {
        switch self {
        case .text: String(localized: "Tekst")
        case .graph: String(localized: "Wykres")
        case .bars: String(localized: "Słupki")
        case .ring: String(localized: "Pierścień")
        }
    }
}

enum Module: String, CaseIterable, Identifiable {
    case overview, cpu, gpu, memory, disk, network, sensors, battery
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: String(localized: "Przegląd")
        case .cpu: String(localized: "Procesor")
        case .gpu: String(localized: "Grafika")
        case .memory: String(localized: "Pamięć")
        case .disk: String(localized: "Dysk")
        case .network: String(localized: "Sieć")
        case .sensors: String(localized: "Czujniki")
        case .battery: String(localized: "Bateria")
        }
    }

    var short: String {
        switch self {
        case .overview: "PULSE"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "MEM"
        case .disk: "SSD"
        case .network: "NET"
        case .sensors: "TEMP"
        case .battery: "BAT"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .cpu: "cpu"
        case .gpu: "cube.transparent"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "arrow.up.arrow.down"
        case .sensors: "thermometer.medium"
        case .battery: "battery.75percent"
        }
    }

    var colors: [Color] {
        switch self {
        case .overview: [.indigo, .purple]
        case .cpu: [Color(red: 0.25, green: 0.78, blue: 1.0), Color(red: 0.2, green: 0.45, blue: 1.0)]
        case .gpu: [Color(red: 0.3, green: 0.95, blue: 0.75), Color(red: 0.1, green: 0.7, blue: 0.55)]
        case .memory: [Color(red: 0.85, green: 0.45, blue: 1.0), Color(red: 0.55, green: 0.3, blue: 1.0)]
        case .disk: [Color(red: 1.0, green: 0.78, blue: 0.3), Color(red: 1.0, green: 0.5, blue: 0.2)]
        case .network: [Color(red: 0.4, green: 0.85, blue: 1.0), Color(red: 1.0, green: 0.45, blue: 0.55)]
        case .sensors: [Color(red: 0.35, green: 0.9, blue: 0.5), Color(red: 1.0, green: 0.85, blue: 0.3), Color(red: 1.0, green: 0.35, blue: 0.3)]
        case .battery: [Color(red: 0.45, green: 0.95, blue: 0.45), Color(red: 0.2, green: 0.75, blue: 0.35)]
        }
    }

    var tint: Color { colors.last ?? .accentColor }

    var modes: [DisplayMode] {
        switch self {
        case .overview: [.text, .ring, .bars, .graph]
        case .sensors: [.text, .graph, .ring]
        case .network: [.text, .graph]
        case .battery: [.text, .ring]
        case .cpu, .gpu, .memory, .disk: [.text, .graph, .bars, .ring]
        }
    }

    var defaultEnabled: Bool { [.cpu, .memory, .sensors, .network].contains(self) }
    var defaultMode: DisplayMode { self == .cpu ? .graph : .text }

    var enabledKey: String { "\(rawValue).enabled" }
    var modeKey: String { "\(rawValue).mode" }
}

/// Optional accent for dropdown icons and overview tiles ("auto" keeps each module's own colors).
enum Accent: String, CaseIterable, Identifiable {
    case auto, purple, blue, teal, green, orange, pink, graphite
    var id: Self { self }
    var title: String {
        switch self {
        case .auto: String(localized: "Kolory modułów"); case .purple: String(localized: "Fioletowy"); case .blue: String(localized: "Niebieski"); case .teal: String(localized: "Morski")
        case .green: String(localized: "Zielony"); case .orange: String(localized: "Pomarańczowy"); case .pink: String(localized: "Różowy"); case .graphite: String(localized: "Grafitowy")
        }
    }
    var colors: [Color]? {
        switch self {
        case .auto: nil
        case .purple: [Color(red: 0.75, green: 0.45, blue: 1.0), Color(red: 0.5, green: 0.3, blue: 0.95)]
        case .blue: [Color(red: 0.35, green: 0.7, blue: 1.0), Color(red: 0.15, green: 0.42, blue: 1.0)]
        case .teal: [Color(red: 0.35, green: 0.92, blue: 0.85), Color(red: 0.1, green: 0.62, blue: 0.7)]
        case .green: [Color(red: 0.5, green: 0.95, blue: 0.5), Color(red: 0.2, green: 0.72, blue: 0.4)]
        case .orange: [Color(red: 1.0, green: 0.78, blue: 0.35), Color(red: 1.0, green: 0.48, blue: 0.2)]
        case .pink: [Color(red: 1.0, green: 0.55, blue: 0.75), Color(red: 0.95, green: 0.3, blue: 0.55)]
        case .graphite: [Color(white: 0.72), Color(white: 0.45)]
        }
    }
    static var current: Accent { Accent(rawValue: UserDefaults.standard.string(forKey: "accent") ?? "") ?? .auto }
}

extension Module {
    /// Colors for dropdown icons and tiles, honoring the accent setting.
    var accentColors: [Color] { Accent.current.colors ?? colors }
    var accentTint: Color { accentColors.last ?? tint }
}

enum Fmt {
    static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func file(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func rate(_ r: Double, compact: Bool = false) -> String {
        let units: [String] = ["B", "KB", "MB", "GB"]
        var value = max(0, r), i = 0
        while value >= 1000 && i < units.count - 1 { value /= 1000; i += 1 }
        let number = value < 10 && i > 0 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return compact ? "\(number) \(units[i])" : "\(number) \(units[i])/s"
    }

    static var fahrenheit: Bool { UserDefaults.standard.integer(forKey: "tempUnit") == 1 }

    static func temp(_ t: Double?) -> String {
        guard let t else { return "—" }
        let v = fahrenheit ? t * 9 / 5 + 32 : t
        return "\(Int(v.rounded()))°"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) d \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        return "\(m) min"
    }

    static func minutes(_ m: Int) -> String { m >= 60 ? "\(m / 60):\(String(format: "%02d", m % 60)) h" : "\(m) min" }
}

enum Heat {
    static func color(_ t: Double) -> Color {
        switch t {
        case ..<50: Color(red: 0.35, green: 0.88, blue: 0.5)
        case ..<70: Color(red: 1.0, green: 0.82, blue: 0.3)
        case ..<85: Color(red: 1.0, green: 0.55, blue: 0.25)
        default: Color(red: 1.0, green: 0.32, blue: 0.3)
        }
    }

    static func label(_ t: Double) -> String {
        switch t {
        case ..<50: String(localized: "Chłodno")
        case ..<70: String(localized: "W normie")
        case ..<85: String(localized: "Ciepło")
        default: String(localized: "Gorąco")
        }
    }

    static func load(_ v: Double) -> Color {
        switch v {
        case ..<0.5: Color(red: 0.35, green: 0.88, blue: 0.5)
        case ..<0.8: Color(red: 1.0, green: 0.75, blue: 0.3)
        default: Color(red: 1.0, green: 0.35, blue: 0.3)
        }
    }
}
