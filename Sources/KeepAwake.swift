import Foundation
import IOKit.pwr_mgt
import SwiftUI

/// "Nie usypiaj": keeps the Mac (and optionally the display) awake for a while, like `caffeinate`.
/// Holds a power assertion; it is released when the time runs out, when turned off or when Pulse quits.
@MainActor
@Observable
final class KeepAwake {
    static let shared = KeepAwake()
    static let displayKey = "keepAwake.display"

    private(set) var isOn = false
    /// nil while on = until turned off.
    private(set) var until: Date?

    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var timer: Timer?

    var keepsDisplay: Bool { UserDefaults.standard.object(forKey: Self.displayKey) as? Bool ?? true }

    /// minutes == nil: until turned off.
    func start(minutes: Int?) {
        release()
        let type = (keepsDisplay ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "Pulse: Nie usypiaj" as CFString, &id) == kIOReturnSuccess else { return }
        assertion = id
        isOn = true
        until = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        if let until {
            timer = Timer.scheduledTimer(withTimeInterval: until.timeIntervalSinceNow, repeats: false) { _ in
                MainActor.assumeIsolated { KeepAwake.shared.stop() }
            }
        }
    }

    func stop() {
        release()
        isOn = false
        until = nil
    }

    /// Applies a changed "keep the display on" setting to a running session.
    func restartIfOn() {
        guard isOn else { return }
        let minutes = until.map { max(1, Int(($0.timeIntervalSinceNow / 60).rounded(.up))) }
        start(minutes: minutes)
    }

    private func release() {
        timer?.invalidate(); timer = nil
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }

    var statusText: String {
        guard isOn else { return "" }
        if let until { return String(localized: "Nie usypia do \(until.formatted(date: .omitted, time: .shortened))") }
        return String(localized: "Nie usypia")
    }
}

/// Cup button in the panel footer.
struct KeepAwakeMenu: View {
    private let awake = KeepAwake.shared
    @AppStorage(KeepAwake.displayKey) private var display = true

    var body: some View {
        Menu {
            if awake.isOn {
                Button("Wyłącz", systemImage: "moon.zzz") { awake.stop() }
                Divider()
            }
            Section("Nie usypiaj Maca") {
                Button("30 minut") { awake.start(minutes: 30) }
                Button("1 godzinę") { awake.start(minutes: 60) }
                Button("3 godziny") { awake.start(minutes: 180) }
                Button("Do wyłączenia") { awake.start(minutes: nil) }
            }
            Divider()
            Toggle("Nie wygaszaj ekranu", isOn: $display)
                .onChange(of: display) { awake.restartIfOn() }
        } label: {
            Image(systemName: awake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                .foregroundStyle(awake.isOn ? Color.orange : Color.primary)
                .frame(width: 16, height: 16)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(awake.isOn ? awake.statusText : String(localized: "Nie usypiaj Maca"))
    }
}
