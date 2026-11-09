import AppKit
import Charts
import ServiceManagement
import SwiftUI

/// App side of fan control: installs the helper, sends it the curve, stops it around sleep.
@MainActor
@Observable
final class FanControl {
    static let shared = FanControl()

    enum HelperState { case absent, needsApproval, ready }

    /// Debug helper: `--fan-preview` shows the editor on any Mac without touching the fans.
    static let preview = CommandLine.arguments.contains("--fan-preview")
    static func isAvailable(on monitor: SystemMonitor) -> Bool { preview || monitor.hasFans }

    private(set) var helperState = HelperState.absent
    private(set) var errorText: String?
    private(set) var enabled = UserDefaults.standard.bool(forKey: "fan.enabled")
    private(set) var curve: FanCurve

    @ObservationIgnored private let service = SMAppService.daemon(plistName: FanHelperInfo.plistName)
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: "fan.curve"),
           let saved = try? JSONDecoder().decode(FanCurve.self, from: data), let clean = saved.sanitized {
            curve = clean
        } else {
            curve = .standard
        }
    }

    /// Called at app launch: resumes the curve if the user had it on.
    func start() {
        guard !Self.preview else { return }
        refreshState()
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { FanControl.shared.restoreAutoNow() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { FanControl.shared.applyIfEnabled() }
            }
        ]
        applyIfEnabled()
    }

    func refreshState() {
        guard !Self.preview else { return }
        let wasReady = helperState == .ready
        switch service.status {
        case .enabled: helperState = .ready
        case .requiresApproval: helperState = .needsApproval
        default: helperState = .absent
        }
        if helperState == .ready && !wasReady { applyIfEnabled() }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "fan.enabled")
        errorText = nil
        guard !Self.preview else { return }
        if on { applyIfEnabled() } else { restoreAuto() }
    }

    func setCurve(_ new: FanCurve) {
        guard let clean = new.sanitized else { return }
        curve = clean
        if let data = try? JSONEncoder().encode(clean) { UserDefaults.standard.set(data, forKey: "fan.curve") }
        applyIfEnabled()
    }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Removes the privileged helper from the system.
    func removeHelper() {
        guard !Self.preview else { return }
        connection?.invalidate(); connection = nil
        Task { @MainActor in
            try? await service.unregister()
            refreshState()
        }
    }

    /// Registers the helper and takes the user straight to the switch that allows it.
    func installHelper() {
        guard !Self.preview else { return }
        errorText = nil
        do { try service.register() } catch { errorText = error.localizedDescription }
        refreshState()
        if helperState == .needsApproval { openApprovalSettings() }
    }

    private func applyIfEnabled() {
        guard enabled, !Self.preview, helperState == .ready,
              let data = try? JSONEncoder().encode(curve) else { return }
        let proxy = connect().remoteObjectProxyWithErrorHandler { error in
            let text = error.localizedDescription
            Task { @MainActor in FanControl.shared.errorText = text }
        } as? FanHelperProtocol
        proxy?.apply(curve: data) { code in
            Task { @MainActor in FanControl.shared.errorText = code.map(Self.message) }
        }
    }

    private func restoreAuto() {
        (connection?.remoteObjectProxyWithErrorHandler { _ in } as? FanHelperProtocol)?.restoreAuto {}
    }

    /// Blocks until done: the Mac may go to sleep right after.
    private func restoreAutoNow() {
        (connection?.synchronousRemoteObjectProxyWithErrorHandler { _ in } as? FanHelperProtocol)?.restoreAuto {}
    }

    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: FanHelperInfo.label, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        c.interruptionHandler = {
            // The helper died; it returned the fans to automatic on restart. Send the curve again.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                FanControl.shared.applyIfEnabled()
            }
        }
        c.invalidationHandler = {
            Task { @MainActor in FanControl.shared.connection = nil }
        }
        c.resume()
        connection = c
        return c
    }

    private static func message(_ code: String) -> String {
        switch code {
        case FanHelperError.unsupported: String(localized: "Sterowanie wentylatorem nie jest obsługiwane na tym Macu.")
        case FanHelperError.noSensor: String(localized: "Pomocnik nie może odczytać temperatury – wentylator pracuje automatycznie.")
        case FanHelperError.noFans: String(localized: "Nie znaleziono wentylatora, którym można sterować.")
        case FanHelperError.invalidCurve: String(localized: "Nieprawidłowa krzywa.")
        default: String(localized: "System odrzucił zmianę obrotów – wentylator pracuje automatycznie.")
        }
    }
}

struct FanSettings: View {
    var body: some View {
        Form {
            if FanControl.shared.helperState != .ready { FanHelperSetupCard() }
            FanControlSection()
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Wentylator"))
        .task {
            // Notices the switch in System Settings as soon as it is flipped.
            while !Task.isCancelled {
                FanControl.shared.refreshState()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// Large, unmissable setup step shown until the privileged helper is allowed to run.
struct FanHelperSetupCard: View {
    private var fan: FanControl { .shared }
    private var waiting: Bool { fan.helperState == .needsApproval }

    var body: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: waiting ? "switch.2" : "fan.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(waiting ? Color.orange : Color.cyan)
                Text(waiting ? String(localized: "Włącz pomocnika Pulse") : String(localized: "Sterowanie wymaga pomocnika Pulse"))
                    .font(.title2.bold())
                Text(waiting
                     ? String(localized: "W Ustawieniach systemowych przejdź do: Ogólne → Rzeczy otwierane po zalogowaniu i rozszerzenia, i włącz przełącznik przy Pulse. macOS poprosi o hasło lub Touch ID. Ta strona sama wykryje zmianę.")
                     : String(localized: "Zmiana obrotów wentylatora wymaga uprawnień systemowych, dlatego Pulse musi dodać małego pomocnika. Trzeba to zrobić tylko raz i można go później usunąć."))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(waiting ? String(localized: "Otwórz Ustawienia systemowe") : String(localized: "Dodaj pomocnika")) {
                    if waiting { fan.openApprovalSettings() } else { fan.installHelper() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

/// Status and shortcut under the fan speeds in the Sensors panel.
struct FanControlShortcut: View {
    var body: some View {
        HStack {
            Text(FanControl.shared.enabled ? String(localized: "Według krzywej") : String(localized: "Automatycznie"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button { AppActions.openSettings(page: .fan) } label: {
                HStack(spacing: 3) {
                    Text("Steruj wentylatorem")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

struct FanControlSection: View {
    @Environment(SystemMonitor.self) private var m
    private var fan: FanControl { .shared }

    var body: some View {
        if FanControl.isAvailable(on: m) {
            Section {
                Toggle("Steruj wentylatorem według krzywej", isOn: Binding(get: { fan.enabled }, set: { fan.setEnabled($0) }))
                    .disabled(fan.helperState != .ready && !FanControl.preview)
                if let error = fan.errorText {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
                FanCurveEditor(current: m.socMax ?? m.socAvg, disabled: !fan.enabled)
                HStack {
                    Button("Przywróć domyślną krzywą") { fan.setCurve(.standard) }
                    Spacer()
                    if !fan.enabled && fan.helperState == .ready {
                        Button("Usuń pomocnika") { fan.removeHelper() }
                    }
                }
            } header: {
                Text("Wentylator")
            } footer: {
                Text(String(localized: "Pomocnik działa z uprawnieniami systemowymi i zmienia obroty tylko, gdy Pulse jest uruchomiony. Po wyjściu z aplikacji, przy usypianiu lub błędzie czujnika wentylator wraca do trybu automatycznego. Od \(Fmt.temp(95)) zawsze pracuje na maksimum."))
            }
        }
    }
}

struct FanCurveEditor: View {
    var current: Double?
    var disabled: Bool

    @State private var draft = FanControl.shared.curve
    @State private var dragged: Int?

    var body: some View {
        Chart {
            ForEach(Array(draft.points.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("°C", p.temp), y: .value("%", p.percent))
                    .foregroundStyle(Color.accentColor)
                PointMark(x: .value("°C", p.temp), y: .value("%", p.percent))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(90)
            }
            if let current {
                RuleMark(x: .value("°C", min(max(current, 30), 100)))
                    .foregroundStyle(.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: 30...100)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: .stride(by: 10)) { mark in
                AxisGridLine()
                AxisValueLabel { if let c = mark.as(Double.self) { Text(verbatim: Fmt.temp(c)) } }
            }
        }
        .chartYAxisLabel("%")
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let anchor = proxy.plotFrame {
                    let plot = geo[anchor]
                    Color.clear.contentShape(.rect)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag($0, proxy, plot) }.onEnded { _ in
                            dragged = nil
                            FanControl.shared.setCurve(draft)
                        })
                }
            }
        }
        .frame(height: 170)
        .opacity(disabled ? 0.55 : 1)
        .onChange(of: FanControl.shared.curve) { _, new in if dragged == nil { draft = new } }
    }

    private func drag(_ value: DragGesture.Value, _ proxy: ChartProxy, _ plot: CGRect) {
        let x = value.location.x - plot.minX, y = value.location.y - plot.minY
        if dragged == nil {
            let start = CGPoint(x: value.startLocation.x - plot.minX, y: value.startLocation.y - plot.minY)
            dragged = draft.points.indices.min { distance(draft.points[$0], proxy, start) < distance(draft.points[$1], proxy, start) }
        }
        guard let i = dragged, let t = proxy.value(atX: x, as: Double.self), let v = proxy.value(atY: y, as: Double.self) else { return }
        let low = i > 0 ? draft.points[i - 1].temp + FanCurve.minGap : FanCurve.tempRange.lowerBound
        let high = i < draft.points.count - 1 ? draft.points[i + 1].temp - FanCurve.minGap : FanCurve.tempRange.upperBound
        let bottom = i > 0 ? draft.points[i - 1].percent : 0
        let top = i < draft.points.count - 1 ? draft.points[i + 1].percent : 100
        draft.points[i] = .init(temp: min(max(t.rounded(), low), high), percent: min(max(v.rounded(), bottom), top))
    }

    private func distance(_ p: FanCurve.Point, _ proxy: ChartProxy, _ location: CGPoint) -> CGFloat {
        guard let x = proxy.position(forX: p.temp), let y = proxy.position(forY: p.percent) else { return .infinity }
        return hypot(x - location.x, y - location.y)
    }
}
