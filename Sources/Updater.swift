import Foundation
import Sparkle
import SwiftUI

/// Sparkle auto-updates. Starts only when the build has a feed URL (release.conf → UPDATE_URL → SUFeedURL).
/// Another Mac can ask for an update (`installRemotely()`): the same signed feed, but installed without any window,
/// because nobody may be sitting at that Mac.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    private let updater: SPUUpdater?
    private let driver: QuietUserDriver?
    private(set) var canCheck = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// State of an update started by another Mac, reported back to it.
    enum RemoteState: String, Codable { case checking, installing, upToDate, failed }
    private(set) var remoteState: RemoteState?
    @ObservationIgnored private var remoteStarted = Date.distantPast

    var isConfigured: Bool { updater != nil }
    var feedURL: String? { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String }
    var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { updater?.lastUpdateCheckDate }

    private init() {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.isEmpty == false
            && !CommandLine.arguments.contains("--snapshot")
        guard configured else { updater = nil; driver = nil; return }
        let driver = QuietUserDriver(standard: SPUStandardUserDriver(hostBundle: .main, delegate: nil))
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        self.driver = driver
        do { try updater.start() } catch { NSLog("Pulse: updater did not start: \(error)") }
        self.updater = updater
        canCheck = updater.canCheckForUpdates
        observation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] u, _ in
            let value = u.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    func checkForUpdates() {
        AppActions.closePopovers()
        NSApp.activate()
        updater?.checkForUpdates()
    }

    /// Asked by another Mac. Returns false when updates are not set up or one was asked for in the last minute.
    func installRemotely() -> Bool {
        guard let updater, let driver else { return false }
        if remoteState == .checking || remoteState == .installing, Date().timeIntervalSince(remoteStarted) < 120 { return true }
        guard Date().timeIntervalSince(remoteStarted) > 20 else { return true }
        remoteStarted = Date()
        remoteState = .checking
        driver.quiet = true
        // An update alert may already wait for a click here (scheduled check): answer it instead of starting a new check.
        if driver.acceptPending() { return true }
        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        } else {
            // A session without a pending choice (e.g. a download in progress): let it finish.
            remoteState = .installing
        }
        return true
    }

    fileprivate func remoteFinished(_ state: RemoteState) { remoteState = state }

    /// What the last remote request came to; forgotten after 5 minutes.
    var recentRemoteState: RemoteState? {
        Date().timeIntervalSince(remoteStarted) < 300 ? remoteState : nil
    }

    fileprivate func remoteInstalling() { remoteState = .installing }
}

/// Sparkle's standard windows, except while an update asked for by another Mac runs: then every question gets
/// "install" and nothing is shown. Sparkle still checks the EdDSA signature and the code signature of the download.
private final class QuietUserDriver: NSObject, SPUUserDriver {
    let standard: SPUStandardUserDriver
    var quiet = false
    /// The answer an update alert waits for, so a remote request can give it.
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?

    init(standard: SPUStandardUserDriver) { self.standard = standard }

    /// Ends a remote request once; later callbacks of the same cycle (dismiss) no longer count.
    private func finish(_ state: Updater.RemoteState) {
        guard quiet else { return }
        quiet = false
        Task { @MainActor in Updater.shared.remoteFinished(state) }
    }

    func acceptPending() -> Bool {
        guard let choice = pendingChoice else { return false }
        pendingChoice = nil
        standard.dismissUpdateInstallation()
        Task { @MainActor in Updater.shared.remoteInstalling() }
        choice(.install)
        return true
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        if !quiet { standard.showUserInitiatedUpdateCheck(cancellation: cancellation) }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if quiet {
            Task { @MainActor in Updater.shared.remoteInstalling() }
            reply(.install)
            return
        }
        var answered = false
        let once: (SPUUserUpdateChoice) -> Void = { [weak self] choice in
            guard !answered else { return }
            answered = true
            self?.pendingChoice = nil
            reply(choice)
        }
        pendingChoice = once
        standard.showUpdateFound(with: appcastItem, state: state, reply: once)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if !quiet { standard.showUpdateReleaseNotes(with: downloadData) }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        if !quiet { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if quiet { finish(.upToDate); acknowledgement() } else { standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement) }
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if quiet { finish(.failed); acknowledgement() } else { standard.showUpdaterError(error, acknowledgement: acknowledgement) }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        if !quiet { standard.showDownloadInitiated(cancellation: cancellation) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        if !quiet { standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        if !quiet { standard.showDownloadDidReceiveData(ofLength: length) }
    }

    func showDownloadDidStartExtractingUpdate() {
        if !quiet { standard.showDownloadDidStartExtractingUpdate() }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        if !quiet { standard.showExtractionReceivedProgress(progress) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if quiet { reply(.install) } else { standard.showReady(toInstallAndRelaunch: reply) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        if !quiet { standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication) }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func showUpdateInFocus() {
        if !quiet { standard.showUpdateInFocus() }
    }

    func dismissUpdateInstallation() {
        pendingChoice = nil
        standard.dismissUpdateInstallation()
        // The cycle ended without installing (cancelled, skipped): a remote request is over.
        finish(.failed)
    }
}

struct UpdateSettingsSection: View {
    private let updater = Updater.shared
    @State private var auto = Updater.shared.automaticallyChecks

    var body: some View {
        Section {
            LabeledContent("Wersja", value: updater.version)
            if updater.isConfigured {
                Toggle("Sprawdzaj aktualizacje automatycznie", isOn: $auto)
                    .onChange(of: auto) { _, on in updater.automaticallyChecks = on }
                LabeledContent("Ostatnie sprawdzenie") {
                    HStack {
                        Text(updater.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                            .foregroundStyle(.secondary)
                        Button("Sprawdź teraz") { updater.checkForUpdates() }
                            .disabled(!updater.canCheck)
                    }
                }
            } else {
                Text("Aktualizacje nie są skonfigurowane w tej kompilacji.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Aktualizacje")
        }
    }
}
