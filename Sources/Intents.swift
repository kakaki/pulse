import AppIntents
import Foundation

/// Shortcuts: read Pulse's current values (e.g. "if the temperature is above 85 °C, …").
enum PulseMetric: String, AppEnum {
    case cpu, memory, temperature, battery, diskFree, gpu, download, upload

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Wartość Pulse"
    static let caseDisplayRepresentations: [PulseMetric: DisplayRepresentation] = [
        .cpu: "Obciążenie CPU (%)",
        .memory: "Użycie pamięci (%)",
        .temperature: "Temperatura SoC (°C)",
        .battery: "Poziom baterii (%)",
        .diskFree: "Wolne miejsce na dysku (GB)",
        .gpu: "Obciążenie GPU (%)",
        .download: "Pobieranie (Mb/s)",
        .upload: "Wysyłanie (Mb/s)",
    ]
}

struct GetPulseValueIntent: AppIntent {
    static let title: LocalizedStringResource = "Pobierz wartość z Pulse"
    static let description = IntentDescription("Zwraca bieżącą wartość jako liczbę: procenty 0–100, temperaturę w °C, wolne miejsce w GB, sieć w Mb/s.")
    static let openAppWhenRun = false

    @Parameter(title: "Wartość", default: .cpu)
    var metric: PulseMetric

    static var parameterSummary: some ParameterSummary {
        Summary("Pobierz \(\.$metric) z Pulse")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let m = SystemMonitor.shared
        let value: Double?
        let text: String
        switch metric {
        case .cpu: value = m.cpu * 100; text = Fmt.pct(m.cpu)
        case .memory: value = m.memFraction * 100; text = Fmt.pct(m.memFraction)
        case .temperature: let t = m.socMax ?? m.socAvg; value = t; text = Fmt.temp(t)
        case .battery: value = m.battery.present ? m.battery.percent * 100 : nil; text = m.battery.present ? Fmt.pct(m.battery.percent) : "—"
        case .diskFree: value = Double(m.diskFree) / 1e9; text = Fmt.file(m.diskFree)
        case .gpu: value = m.gpu.map { $0 * 100 }; text = m.gpu.map(Fmt.pct) ?? "—"
        case .download: value = m.netIn * 8 / 1e6; text = String(format: "%.1f Mb/s", m.netIn * 8 / 1e6)
        case .upload: value = m.netOut * 8 / 1e6; text = String(format: "%.1f Mb/s", m.netOut * 8 / 1e6)
        }
        guard let value else {
            throw PulseIntentError.unavailable
        }
        return .result(value: (value * 10).rounded() / 10, dialog: IntentDialog(stringLiteral: text))
    }
}

struct GetPulseSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Podsumowanie z Pulse"
    static let description = IntentDescription("Zwraca krótki tekst z obciążeniem CPU, pamięcią, temperaturą i baterią.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let m = SystemMonitor.shared
        var parts = ["CPU \(Fmt.pct(m.cpu))", "MEM \(Fmt.pct(m.memFraction))"]
        if let t = m.socMax ?? m.socAvg { parts.append(Fmt.temp(t)) }
        if m.battery.present { parts.append(String(localized: "bateria \(Fmt.pct(m.battery.percent))")) }
        let text = parts.joined(separator: " · ")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct KeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Nie usypiaj Maca"
    static let description = IntentDescription("Nie pozwala Macowi zasnąć przez podany czas. 0 minut wyłącza.")
    static let openAppWhenRun = false

    @Parameter(title: "Minuty", default: 60)
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Nie usypiaj Maca przez \(\.$minutes) min")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if minutes <= 0 { KeepAwake.shared.stop() } else { KeepAwake.shared.start(minutes: minutes) }
        return .result()
    }
}

enum PulseIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable
    var localizedStringResource: LocalizedStringResource { "Ta wartość nie jest dostępna na tym Macu." }
}

struct PulseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetPulseSummaryIntent(), phrases: ["Podsumowanie z \(.applicationName)", "Jak się ma Mac w \(.applicationName)"],
                    shortTitle: "Podsumowanie", systemImageName: "waveform.path.ecg")
        AppShortcut(intent: GetPulseValueIntent(), phrases: ["Pobierz wartość z \(.applicationName)"],
                    shortTitle: "Wartość", systemImageName: "gauge.medium")
    }
}
