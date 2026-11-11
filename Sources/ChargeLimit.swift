import SwiftUI

/// App side of the charge limit (MacBooks): the privileged helper stops charging at the limit while Pulse runs.
@MainActor
@Observable
final class ChargeLimit {
    static let shared = ChargeLimit()
    static let enabledKey = "charge.enabled", limitKey = "charge.limit"

    private(set) var enabled = UserDefaults.standard.bool(forKey: enabledKey)
    private(set) var limit: Int = {
        let saved = UserDefaults.standard.integer(forKey: limitKey)
        return ChargeLimitRule.range.contains(saved) ? saved : 80
    }()
    private(set) var errorText: String?

    /// This Mac has a battery and SMC keys that can stop charging (read without root).
    let isSupported: Bool = {
        guard BatterySampler.read().present, let smc = SMC() else { return false }
        return ChargeLimitRule.keys(smc) != nil
    }()

    func setEnabled(_ on: Bool) {
        FanControl.shared.refreshState()
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        errorText = nil
        send(on ? limit : 0)
    }

    func setLimit(_ value: Int) {
        let clamped = min(max(value, ChargeLimitRule.range.lowerBound), ChargeLimitRule.range.upperBound)
        guard clamped != limit else { return }
        limit = clamped
        UserDefaults.standard.set(clamped, forKey: Self.limitKey)
        if enabled { send(clamped) }
    }

    /// (Re)sends the limit: at launch, after wake, after the helper restarted or was just approved.
    func apply() {
        guard enabled else { return }
        send(limit)
    }

    private func send(_ percent: Int) {
        guard isSupported, !FanControl.preview, FanControl.shared.helperState == .ready else { return }
        let proxy = FanControl.shared.connect().remoteObjectProxyWithErrorHandler { error in
            let text = error.localizedDescription
            Task { @MainActor in ChargeLimit.shared.errorText = text }
        } as? FanHelperProtocol
        proxy?.setChargeLimit(percent) { code in
            Task { @MainActor in ChargeLimit.shared.errorText = code.map(Self.message) }
        }
    }

    private static func message(_ code: String) -> String {
        switch code {
        case FanHelperError.unsupported: String(localized: "Ten Mac nie pozwala wstrzymać ładowania.")
        case FanHelperError.noSensor: String(localized: "Pomocnik nie może odczytać poziomu baterii – ładowanie działa normalnie.")
        default: String(localized: "System odrzucił zmianę – ładowanie działa normalnie.")
        }
    }

    /// Short state for the Battery panel.
    func status(_ b: BatteryInfo) -> String? {
        guard enabled, isSupported else { return nil }
        guard FanControl.shared.helperState == .ready else { return String(localized: "Limit \(limit)% · wymaga pomocnika") }
        if b.onAC && !b.isCharging && Int((b.percent * 100).rounded()) >= limit - ChargeLimitRule.hysteresis {
            return String(localized: "Limit \(limit)% · ładowanie wstrzymane")
        }
        return String(localized: "Limit ładowania: \(limit)%")
    }
}

/// Battery settings page.
struct ChargeLimitSection: View {
    private var charge: ChargeLimit { .shared }
    @State private var draft = Double(ChargeLimit.shared.limit)

    var body: some View {
        if charge.isSupported {
            if FanControl.shared.helperState != .ready && charge.enabled {
                FanHelperSetupCard(reason: String(localized: "Wstrzymanie ładowania wymaga uprawnień systemowych, dlatego Pulse musi dodać małego pomocnika (tego samego co do wentylatora). Trzeba to zrobić tylko raz i można go później usunąć."),
                                   symbol: "battery.75percent")
            }
            Section {
                Toggle(isOn: Binding(get: { charge.enabled }, set: { charge.setEnabled($0) })) {
                    Text("Ogranicz ładowanie baterii")
                    Text("Bateria dłużej zachowa pojemność, jeśli nie stoi stale na 100%. Przydatne, gdy MacBook jest prawie zawsze podłączony do zasilacza.")
                }
                LabeledContent {
                    HStack {
                        Slider(value: $draft, in: Double(ChargeLimitRule.range.lowerBound)...Double(ChargeLimitRule.range.upperBound), step: 5) { editing in
                            if !editing { charge.setLimit(Int(draft)) }
                        }
                        Text(verbatim: "\(Int(draft))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                } label: {
                    Text("Ładuj do")
                }
                .disabled(!charge.enabled)
                if let error = charge.errorText {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            } header: {
                Text("Limit ładowania")
            } footer: {
                Text("Po dojściu do limitu Mac pracuje z zasilacza, a bateria się nie ładuje; ładowanie wraca \(ChargeLimitRule.hysteresis) punktów niżej. Limit działa, gdy Pulse jest uruchomiony – po wyjściu z aplikacji Mac ładuje się normalnie. Na czas uśpienia ładowanie zostaje w ostatnim stanie. Przed podróżą wyłącz limit, aby naładować baterię do pełna.")
            }
            .onChange(of: charge.limit) { _, new in draft = Double(new) }
            .task {
                // Notices the helper being approved in System Settings; becoming ready sends the limit.
                while !Task.isCancelled {
                    FanControl.shared.refreshState()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }
}

/// Under the battery cards: the limit's state and a way to change it.
struct ChargeLimitShortcut: View {
    let battery: BatteryInfo
    private var charge: ChargeLimit { .shared }

    var body: some View {
        HStack {
            Image(systemName: charge.enabled ? "battery.75percent" : "battery.100percent")
                .font(.system(size: 11)).foregroundStyle(charge.enabled ? Module.battery.tint : .secondary)
            Text(charge.status(battery) ?? String(localized: "Bez limitu ładowania"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button { AppActions.openSettings(page: .module(.battery)) } label: {
                HStack(spacing: 3) {
                    Text(charge.enabled ? "Zmień limit" : "Ogranicz ładowanie")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }
}
