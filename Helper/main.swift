import Foundation
import Security

// Privileged helper (launchd daemon): runs the fan curve while Pulse is connected.
// Whatever goes wrong – app quits or crashes, sensors fail, SIGTERM – the fans go back to automatic.

final class FanController {
    private struct Fan { let index: Int; let min: Double; let max: Double; var lastRPM: Double? }

    private let queue: DispatchQueue
    private let smc = SMC()
    private var fans: [Fan] = []
    private var regulator: FanRegulator?
    private var timer: DispatchSourceTimer?
    private var forced = false
    private let cpuKeys = ["TC0F", "TC0D", "TC0E", "TC0P"]
    private let appleSilicon = FanHelperInfo.isAppleSilicon
    private lazy var socSensors = TemperatureReader()
    private static let maxDropPerTick = 150.0

    init(queue: DispatchQueue) { self.queue = queue }

    private func cpuTemperature() -> Double? {
        if appleSilicon { return socSensors.read().filter { $0.kind == .soc }.map(\.value).max() }
        return cpuKeys.compactMap { smc?.number($0) }.filter { $0 > 1 && $0 < 150 }.max()
    }

    /// The per-fan mode key; its spelling differs between Mac generations.
    private func modeKey(_ index: Int) -> String? {
        ["F\(index)Md", "F\(index)md"].first { smc?.read($0) != nil }
    }

    private func isManual(_ index: Int) -> Bool {
        modeKey(index).flatMap { smc?.number($0) } == 1
    }

    /// Apple Silicon: the system thermal manager releases a fan only after the Ftst unlock and a few seconds of retries.
    private func engageAppleSilicon(index: Int) -> Bool {
        guard let smc, let key = modeKey(index) else { return false }
        if isManual(index) { return true }
        if smc.read("Ftst") != nil { _ = smc.write("Ftst", 1) }
        for _ in 0..<16 {
            _ = smc.write(key, 1)
            if isManual(index) { return true }
            usleep(500_000)
        }
        return false
    }

    private func setMode(index: Int, manual: Bool) -> Bool {
        guard let smc else { return false }
        if appleSilicon && manual { return engageAppleSilicon(index: index) }
        if let key = modeKey(index) { return smc.write(key, manual ? 1 : 0) }
        // Older Intel Macs: one bitmask for all fans.
        let mask = UInt16(smc.number("FS! ") ?? 0)
        return smc.write("FS! ", Double(manual ? mask | (1 << index) : mask & ~(1 << index)))
    }

    private func setAutomatic() {
        guard let smc else { return }
        let count = Int(smc.number("FNum") ?? 0)
        for i in 0..<max(count, 0) { _ = setMode(index: i, manual: false) }
        if appleSilicon, smc.read("Ftst") != nil { _ = smc.write("Ftst", 0) }
        forced = false
        for i in fans.indices { fans[i].lastRPM = nil }
    }

    /// Back to automatic and no curve running.
    func stop() {
        timer?.cancel(); timer = nil
        regulator = nil
        setAutomatic()
    }

    func apply(_ curve: FanCurve) -> String? {
        guard let smc else { return FanHelperError.writeFailed }
        guard let clean = curve.sanitized else { return FanHelperError.invalidCurve }
        fans = (0..<max(Int(smc.number("FNum") ?? 0), 0)).compactMap { i in
            guard let lo = smc.number("F\(i)Mn"), let hi = smc.number("F\(i)Mx"), lo > 0, hi > lo else { return nil }
            return Fan(index: i, min: lo, max: hi, lastRPM: nil)
        }
        guard !fans.isEmpty else { return FanHelperError.noFans }
        guard cpuTemperature() != nil else { return FanHelperError.noSensor }
        regulator = FanRegulator(curve: clean)
        guard tick() else { stop(); return FanHelperError.writeFailed }
        if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 3, repeating: 3)
            t.setEventHandler { [weak self] in
                guard let self, !self.tick() else { return }
                self.stop()
            }
            t.resume()
            timer = t
        }
        return nil
    }

    /// One control step; false means the SMC refused a write.
    private func tick() -> Bool {
        guard let smc, regulator != nil else { return true }
        guard let t = cpuTemperature() else {
            // No trustworthy reading: let the system decide until sensors come back.
            if forced { setAutomatic() }
            return true
        }
        let fraction = regulator!.fraction(for: t)
        for i in fans.indices {
            let fan = fans[i]
            var rpm = fan.min + (fan.max - fan.min) * fraction
            if let last = fan.lastRPM {
                rpm = max(rpm, last - Self.maxDropPerTick)   // slow down gently, speed up at once
                // The system may take a fan back on Apple Silicon, so unchanged speeds are still re-checked there.
                if abs(rpm - last) < 25 && (!appleSilicon || isManual(fan.index)) { continue }
            }
            guard setMode(index: fan.index, manual: true), smc.write("F\(fan.index)Tg", rpm) else { return false }
            fans[i].lastRPM = rpm
            forced = true
        }
        return true
    }
}

final class HelperService: NSObject, FanHelperProtocol, NSXPCListenerDelegate {
    private let queue = DispatchQueue(label: "fan.control")
    private lazy var controller = FanController(queue: queue)
    private var active: NSXPCConnection?

    func start() {
        queue.sync { controller.stop() }   // also cleans up after a crash of an earlier run
        queue.asyncAfter(deadline: .now() + 30) { [self] in if active == nil { exit(0) } }
    }

    func shutdown() {
        queue.sync { controller.stop() }
        exit(0)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self else { return }
            self.queue.async {
                guard self.active == nil || self.active === connection else { return }
                self.controller.stop()
                exit(0)
            }
        }
        queue.sync { active = connection }
        connection.resume()
        return true
    }

    func apply(curve: Data, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            guard let decoded = try? JSONDecoder().decode(FanCurve.self, from: curve) else {
                reply(FanHelperError.invalidCurve); return
            }
            reply(controller.apply(decoded))
        }
    }

    func restoreAuto(reply: @escaping () -> Void) {
        queue.async { [self] in controller.stop(); reply() }
    }
}

/// Only Pulse signed by the same developer as this helper may talk to it.
func callerRequirement() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
    return "identifier \"\(FanHelperInfo.appIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
}

guard let requirement = callerRequirement() else { exit(0) }

let service = HelperService()
service.start()

let signals = [SIGTERM, SIGINT, SIGHUP].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler { service.shutdown() }
    source.resume()
    return source
}

let listener = NSXPCListener(machServiceName: FanHelperInfo.label)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = service
listener.resume()
withExtendedLifetime((signals, listener)) { dispatchMain() }
