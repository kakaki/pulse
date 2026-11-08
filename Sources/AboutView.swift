import SwiftUI

enum ProjectLinks {
    static let home = URL(string: "https://github.com/kakaki/pulse")!
    static let releases = URL(string: "https://github.com/kakaki/pulse/releases")!
    static let issues = URL(string: "https://github.com/kakaki/pulse/issues")!
    static let sparkle = URL(string: "https://sparkle-project.org")!
}

/// Settings → O programie.
struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Wersja \(short) (\(build))")
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            VStack(spacing: 4) {
                Text("Pulse").font(.system(size: 26, weight: .bold))
                Text(version).foregroundStyle(.secondary).monospacedDigit().textSelection(.enabled)
            }
            Text("Lekki monitor systemu w pasku menu macOS.")
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Link(destination: ProjectLinks.home) { Label("Strona projektu", systemImage: "globe") }
                Link(destination: ProjectLinks.releases) { Label("Co nowego", systemImage: "sparkles") }
                Link(destination: ProjectLinks.issues) { Label("Zgłoś problem", systemImage: "exclamationmark.bubble") }
            }
            .pulseGlassButton()
            .controlSize(.large)
            if Updater.shared.isConfigured {
                Button("Sprawdź aktualizacje…") { Updater.shared.checkForUpdates() }
                    .disabled(!Updater.shared.canCheck)
            }
            Spacer()
            VStack(spacing: 3) {
                Text("© 2026 Krzysztof Pliszka")
                HStack(spacing: 4) {
                    Text("Aktualizacje:")
                    Link("Sparkle", destination: ProjectLinks.sparkle)
                    Text("(licencja MIT)")
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("O programie")
    }
}
