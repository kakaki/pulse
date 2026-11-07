import Foundation
import Sparkle
import SwiftUI

/// Sparkle auto-updates. Starts only when the build has a feed URL (release.conf → UPDATE_URL → SUFeedURL).
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    private(set) var canCheck = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    var isConfigured: Bool { controller != nil }
    var feedURL: String? { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String }
    var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    private init() {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.isEmpty == false
            && !CommandLine.arguments.contains("--snapshot")
        controller = configured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        if let updater = controller?.updater {
            canCheck = updater.canCheckForUpdates
            observation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] u, _ in
                let value = u.canCheckForUpdates
                Task { @MainActor in self?.canCheck = value }
            }
        }
    }

    func checkForUpdates() {
        AppActions.closePopovers()
        NSApp.activate()
        controller?.checkForUpdates(nil)
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
