import Foundation

// Shared between the app and the privileged fan helper.

enum FanHelperInfo {
    static let label = "local.pulse.menubar.fanhelper"
    static let plistName = label + ".plist"
    static let appIdentifier = "local.pulse.menubar"

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}

/// Error codes the helper replies with; the app turns them into messages.
enum FanHelperError {
    static let unsupported = "unsupported", noFans = "noFans", invalidCurve = "invalidCurve", writeFailed = "writeFailed"
}

@objc protocol FanHelperProtocol {
    func apply(curve: Data, reply: @escaping (String?) -> Void)
    func restoreAuto(reply: @escaping () -> Void)
}

/// Temperature (°C) → fan speed (0–100 % of the SMC's min…max range).
struct FanCurve: Codable, Equatable {
    struct Point: Codable, Equatable {
        var temp: Double
        var percent: Double
    }

    var points: [Point]

    static let tempRange = 40.0...95.0
    static let minGap = 3.0
    static let standard = FanCurve(points: [
        .init(temp: 50, percent: 0), .init(temp: 65, percent: 15), .init(temp: 75, percent: 40),
        .init(temp: 85, percent: 80), .init(temp: 92, percent: 100)
    ])

    /// Checked copy (temperatures increase, speed never falls as it gets hotter), or nil if unusable.
    var sanitized: FanCurve? {
        guard (2...8).contains(points.count), points.allSatisfy({ $0.temp.isFinite && $0.percent.isFinite }) else { return nil }
        var result: [Point] = []
        for p in points.sorted(by: { $0.temp < $1.temp }) {
            let temp = min(max(p.temp, Self.tempRange.lowerBound), Self.tempRange.upperBound)
            if let last = result.last, temp - last.temp < 1 { return nil }
            let percent = max(min(max(p.percent, 0), 100), result.last?.percent ?? 0)
            result.append(.init(temp: temp, percent: percent))
        }
        return FanCurve(points: result)
    }

    func percent(at t: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 100 }
        if t <= first.temp { return first.percent }
        if t >= last.temp { return last.percent }
        for (a, b) in zip(points, points.dropFirst()) where t <= b.temp {
            return a.percent + (b.percent - a.percent) * (t - a.temp) / (b.temp - a.temp)
        }
        return last.percent
    }
}

/// Curve plus safety rules: full speed when too hot, and hysteresis so small dips do not change the speed.
struct FanRegulator {
    static let hotLimit = 95.0, hotRelease = 90.0, hysteresis = 3.0

    var curve: FanCurve
    private var held: Double?
    private var hot = false

    init(curve: FanCurve) { self.curve = curve }

    /// Fan speed as 0…1 of the min…max range.
    mutating func fraction(for t: Double) -> Double {
        if t >= Self.hotLimit { hot = true } else if t < Self.hotRelease { hot = false }
        if let h = held {
            if t > h { held = t } else if t < h - Self.hysteresis { held = t + Self.hysteresis }
        } else {
            held = t
        }
        if hot { return 1 }
        return curve.percent(at: held ?? t) / 100
    }
}
