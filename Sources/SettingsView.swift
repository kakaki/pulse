import SwiftUI
import ServiceManagement

/// Which page the Settings window shows; set when opened from a module's panel.
@MainActor @Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var page: SettingsView.Page? = .general
}

struct SettingsView: View {
    enum Page: Hashable { case general, alerts, module(Module), fan, about }
    @State private var router = SettingsRouter.shared
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        NavigationSplitView {
            List(selection: $router.page) {
                Section {
                    SidebarRow(title: String(localized: "Ogólne"), symbol: "gearshape.fill", colors: [.gray, Color(white: 0.4)], enabled: nil)
                        .tag(Page.general)
                    SidebarRow(title: String(localized: "Powiadomienia"), symbol: "bell.badge.fill", colors: [.red, .orange], enabled: nil)
                        .tag(Page.alerts)
                }
                Section("Moduły") {
                    ForEach(Module.allCases) { module in
                        ModuleSidebarRow(module: module).tag(Page.module(module))
                    }
                }
                if FanControl.isAvailable(on: monitor) {
                    Section("Sterowanie") {
                        SidebarRow(title: String(localized: "Wentylator"), symbol: "fan.fill", colors: [.cyan, .blue], enabled: FanControl.shared.enabled)
                            .tag(Page.fan)
                    }
                }
                Section {
                    SidebarRow(title: String(localized: "O programie"), symbol: "info.circle.fill", colors: [.blue, .purple], enabled: nil)
                        .tag(Page.about)
                }
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            switch router.page ?? .general {
            case .general: GeneralSettings()
            case .alerts: AlertSettings()
            case .module(let module): ModuleSettings(module: module).id(module)
            case .fan: FanSettings()
            case .about: AboutView()
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let colors: [Color]
    let enabled: Bool?
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: .rect(cornerRadius: 6, style: .continuous))
            Text(title)
            Spacer()
            if let enabled {
                Circle().fill(enabled ? Color.green : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
            }
        }
    }
}

struct ModuleSidebarRow: View {
    let module: Module
    @AppStorage private var enabled: Bool
    init(module: Module) {
        self.module = module
        _enabled = AppStorage(wrappedValue: module.defaultEnabled, module.enabledKey)
    }
    var body: some View {
        SidebarRow(title: module.title, symbol: module.symbol, colors: module.colors, enabled: enabled)
    }
}

struct ModuleSettings: View {
    let module: Module
    @Environment(SystemMonitor.self) private var monitor
    @AppStorage private var enabled: Bool
    @AppStorage private var modeRaw: String
    @AppStorage("showLabels") private var showLabels = true

    init(module: Module) {
        self.module = module
        _enabled = AppStorage(wrappedValue: module.defaultEnabled, module.enabledKey)
        _modeRaw = AppStorage(wrappedValue: module.defaultMode.rawValue, module.modeKey)
    }

    private var isLastEnabled: Bool {
        enabled && Module.allCases.filter { m in
            UserDefaults.standard.object(forKey: m.enabledKey) as? Bool ?? m.defaultEnabled
        }.count <= 1
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: module.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(LinearGradient(colors: module.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: .rect(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.title).font(.title3.bold())
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Toggle("Pokaż w pasku menu", isOn: $enabled)
                    .disabled(isLastEnabled)
            } footer: {
                if isLastEnabled {
                    Text("Co najmniej jeden moduł musi być widoczny w pasku menu.")
                }
            }

            if module == .disk { DiskDisplaySection() }
            if let item = OverviewItem.allCases.first(where: { $0.module == module }) { OverviewModuleSection(item: item) }
            if module == .overview {
                OverviewItemsSection(defaultMode: DisplayMode(rawValue: modeRaw) ?? .text)
            }
            Section(module == .overview ? String(localized: "Domyślny styl wartości") : String(localized: "Wygląd w pasku menu")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: module == .overview ? 380 : 104), spacing: 10)], spacing: 10) {
                    ForEach(module.modes) { mode in
                        ModePreview(module: module, mode: mode, labels: showLabels, selected: modeRaw == mode.rawValue) {
                            modeRaw = mode.rawValue
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if module == .sensors {
                TemperatureUnitSection()
                if FanControl.isAvailable(on: monitor) {
                    Section {
                        Button("Steruj wentylatorem…") { SettingsRouter.shared.page = .fan }
                    }
                }
            }
            if module == .battery { EnergySavingSection() }
            if module == .macs { RemoteSharingSection() }
            ForEach(Alerts.Kind.kinds(for: module)) { AlertRow(kind: $0) }
        }
        .formStyle(.grouped)
        .navigationTitle(module.title)
    }

    private var description: String {
        switch module {
        case .overview: String(localized: "Wszystkie moduły w jednym miejscu; wybierz, co pokazywać w pasku.")
        case .cpu: String(localized: "Obciążenie, rdzenie, średnie obciążenie i procesy.")
        case .gpu: String(localized: "Wykorzystanie układu graficznego.")
        case .memory: String(localized: "Pamięć aplikacji, związana, skompresowana i swap.")
        case .disk: String(localized: "Wolne miejsce oraz prędkość odczytu i zapisu.")
        case .network: String(localized: "Prędkość pobierania i wysyłania, adres IP.")
        case .sensors: String(localized: "Temperatury SoC, SSD i baterii.")
        case .battery: String(localized: "Poziom naładowania, kondycja, cykle i moc.")
        case .macs: String(localized: "Obciążenie, temperatury i wentylatory pozostałych Maców w sieci lokalnej.")
        }
    }
}

struct TemperatureUnitSection: View {
    @AppStorage("tempUnit") private var tempUnit = 0
    var body: some View {
        Section {
            Picker("Jednostka temperatury", selection: $tempUnit) {
                Text("°C").tag(0)
                Text("°F").tag(1)
            }
            .pickerStyle(.segmented)
        }
    }
}

struct EnergySavingSection: View {
    @Environment(SystemMonitor.self) private var monitor
    @AppStorage("interval") private var interval = 2.0
    @AppStorage("powerSaver") private var powerSaver = true
    var body: some View {
        Section {
            Toggle(isOn: $powerSaver) {
                Text("Oszczędzaj energię na baterii")
                Text("Na baterii i w trybie niskiego zużycia energii Pulse odświeża dane rzadziej (co \(Int(max(interval * 2.5, 5))) s zamiast co \(Int(interval)) s).")
            }
            .onChange(of: powerSaver) { monitor.updateSaving() }
            LabeledContent("Stan", value: monitor.isSaving ? String(localized: "Oszczędzanie aktywne · co \(Int(monitor.effectiveInterval)) s") : String(localized: "Pełna częstotliwość"))
        } header: {
            Text("Energia")
        }
    }
}

struct DiskDisplaySection: View {
    @Environment(SystemMonitor.self) private var monitor
    @AppStorage(DiskDisplay.quantityKey) private var quantity = "used"
    @AppStorage(DiskDisplay.unitKey) private var unit = "percent"
    @AppStorage(DiskDisplay.volumeKey) private var volume = ""

    var body: some View {
        Section {
            Picker("Pokazuj", selection: $quantity) {
                Text("Zajęte miejsce").tag("used")
                Text("Wolne miejsce").tag("free")
            }
            .pickerStyle(.segmented)
            Picker("Format", selection: $unit) {
                Text("Procenty").tag("percent")
                Text("GB / TB").tag("amount")
            }
            .pickerStyle(.segmented)
            if monitor.volumes.count > 1 || !volume.isEmpty {
                Picker("Dysk", selection: $volume) {
                    Text("Dysk systemowy").tag("")
                    ForEach(monitor.volumes.filter { !$0.isSystem }) { v in
                        Text(verbatim: v.name).tag(v.id)
                    }
                    if !volume.isEmpty, !monitor.volumes.contains(where: { $0.id == volume }) {
                        Text("Niepodłączony dysk").tag(volume)
                    }
                }
            }
        } header: {
            Text("Wartość w pasku menu i na kafelku")
        } footer: {
            Text("Dotyczy też Przeglądu. Gdy wybrany dysk jest odłączony, Pulse pokazuje dysk systemowy.")
        }
    }
}

struct ModePreview: View {
    let module: Module
    let mode: DisplayMode
    let labels: Bool
    let selected: Bool
    let action: () -> Void
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                StatusContent(module: module, mode: mode, s: .make(module, monitor), labels: labels, color: .primary)
                    .fixedSize()
                    .frame(height: 24)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.primary.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
                Text(mode.title).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .primary.opacity(0.1), lineWidth: selected ? 2 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct GeneralSettings: View {
    @Environment(SystemMonitor.self) private var monitor
    @AppStorage("showLabels") private var showLabels = true
    @AppStorage("colorize") private var colorize = true
    @AppStorage("interval") private var interval = 2.0
    @AppStorage("accent") private var accent = Accent.auto.rawValue
    @AppStorage("pulseAlerts") private var pulseAlerts = true
    @AppStorage("hide.fullscreen") private var hideFullscreen = false
    @AppStorage("hide.mirroring") private var hideMirroring = false
    @AppStorage("autoCompact") private var autoCompact = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Pasek menu") {
                Toggle("Pokazuj etykiety (CPU, MEM, …)", isOn: $showLabels)
                Toggle(isOn: $colorize) {
                    Text("Koloruj wartości przy wysokim obciążeniu")
                    Text("Pomarańczowy od ok. 70%, czerwony od 90% (CPU, GPU, dysk), temperatura od ok. 82°C / 90°C, ciśnienie pamięci, niski poziom baterii.")
                }
                Toggle(isOn: $pulseAlerts) {
                    Text("Pulsuj wartościami krytycznymi")
                    Text("Wartość powyżej progu krytycznego (np. CPU ≥ 90%, temperatura ≥ ok. 90°C, krytyczne ciśnienie pamięci) miga w pasku menu.")
                }
                Toggle(isOn: $autoCompact) {
                    Text("Zmniejszaj, gdy brakuje miejsca")
                    Text("Gdy macOS chowa Pulse za wycięciem ekranu lub długim menu aplikacji, Pulse ukrywa etykiety i przechodzi na najwęższy styl.")
                }
                Text("Kliknij ikonę z wciśniętym ⌘ i przeciągnij, aby zmienić kolejność elementów w pasku menu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $hideFullscreen) {
                    Text("Ukrywaj, gdy aplikacja jest na pełnym ekranie")
                    Text("Pulse nie pojawi się w wysuwanym pasku menu podczas filmów, gier czy prezentacji Keynote.")
                }
                Toggle(isOn: $hideMirroring) {
                    Text("Ukrywaj, gdy ekran jest dublowany")
                    Text("Np. przy podłączeniu projektora lub telewizora w trybie dublowania (AirPlay).")
                }
            } header: {
                Text("Ukrywanie")
            }
            Section("Wygląd") {
                LabeledContent("Kolor akcentu") {
                    HStack(spacing: 8) {
                        ForEach(Accent.allCases) { a in
                            Button { accent = a.rawValue } label: {
                                Circle()
                                    .fill(a.colors.map { AnyShapeStyle(LinearGradient(colors: $0, startPoint: .topLeading, endPoint: .bottomTrailing)) }
                                          ?? AnyShapeStyle(AngularGradient(colors: [.blue, .purple, .pink, .orange, .yellow, .green, .blue], center: .center)))
                                    .frame(width: 18, height: 18)
                                    .overlay {
                                        Circle().strokeBorder(.primary.opacity(accent == a.rawValue ? 0.9 : 0), lineWidth: 2).padding(-3)
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(a.title)
                        }
                    }
                }
                Text("Ikony w okienkach i kafelki Przeglądu. „Kolory modułów” zostawia każdemu modułowi własny kolor.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Dane") {
                Picker("Częstotliwość odświeżania", selection: $interval) {
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("3 s").tag(3.0)
                    Text("5 s").tag(5.0)
                }
                LabeledContent("Historia") {
                    HStack {
                        Text("do 30 dni").foregroundStyle(.secondary)
                        Button("Eksportuj CSV…") { exportHistory() }
                    }
                }
            }
            Section {
                Toggle("Uruchamiaj przy logowaniu", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
            } footer: {
                if let loginError { Text(loginError).foregroundStyle(.red) }
            }
            UpdateSettingsSection()
            Section("Ten Mac") {
                LabeledContent("Procesor", value: monitor.chipName)
                LabeledContent("Rdzenie", value: "\(monitor.coreCount)")
                LabeledContent("Pamięć", value: Fmt.memory(monitor.memTotal))
                LabeledContent("Czas pracy", value: Fmt.duration(monitor.uptime))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Ogólne")
    }
}

/// Overview values: drag to reorder; per value: on/off, own style, label, tile in the dropdown.
@MainActor
private func exportHistory() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    let day = Date().formatted(.iso8601.year().month().day())
    panel.nameFieldStringValue = String(localized: "Pulse-historia-\(day).csv")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? SystemMonitor.shared.history.csv().write(to: url, atomically: true, encoding: .utf8)
}

struct OverviewItemsSection: View {
    let defaultMode: DisplayMode
    @Environment(SystemMonitor.self) private var monitor
    @State private var items = OverviewItem.ordered
    @State private var dragged: OverviewItem?
    @State private var rowFrames: [OverviewItem: CGRect] = [:]
    @AppStorage("overview.separators") private var separators = false
    @AppStorage("showLabels") private var showLabels = true

    var body: some View {
        Section {
            // Live preview of the menu bar item.
            StatusContent(module: .overview, mode: defaultMode, s: .make(.overview, monitor), labels: showLabels, color: .primary)
                .fixedSize()
                .frame(height: 24)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
                .id(items.map(\.rawValue).joined())
            ForEach(items) { item in
                OverviewItemRow(item: item, defaultMode: defaultMode, isDragging: dragged == item) { y in
                    dragged = item
                    reorder(item, pointerY: y)
                } onDragEnd: {
                    dragged = nil
                    OverviewItem.setOrder(items)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames[item] = $0 }
            }
            Toggle("Separatory między wartościami", isOn: $separators)
        } header: {
            Text("Wartości w pasku menu")
        } footer: {
            Text("Przeciągnij za ≡, aby zmienić kolejność – ta sama kolejność obowiązuje w kafelkach okienka. To, co pokazuje każda wartość, ustawisz na stronie jej modułu.")
        }
    }

    /// Moves the dragged row to the row under the pointer; the frames follow, so it can't flip back and forth.
    private func reorder(_ item: OverviewItem, pointerY y: CGFloat) {
        guard let target = items.first(where: { $0 != item && rowFrames[$0].map { $0.minY...$0.maxY ~= y } == true }),
              let from = items.firstIndex(of: item), let to = items.firstIndex(of: target) else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        OverviewItem.setOrder(items)   // saved at every step, in case the gesture gets cancelled
    }
}

/// Order only: what each value shows is decided on its module's page.
struct OverviewItemRow: View {
    let item: OverviewItem
    let defaultMode: DisplayMode
    let isDragging: Bool
    let onDrag: (CGFloat) -> Void
    let onDragEnd: () -> Void
    @AppStorage private var on: Bool
    @AppStorage private var style: String

    init(item: OverviewItem, defaultMode: DisplayMode, isDragging: Bool, onDrag: @escaping (CGFloat) -> Void, onDragEnd: @escaping () -> Void) {
        self.item = item
        self.defaultMode = defaultMode
        self.isDragging = isDragging
        self.onDrag = onDrag
        self.onDragEnd = onDragEnd
        _on = AppStorage(wrappedValue: item.defaultOn, item.key)
        _style = AppStorage(wrappedValue: "", item.styleKey)
    }

    private var status: String {
        guard on else { return String(localized: "Ukryta") }
        return (DisplayMode(rawValue: style) ?? defaultMode).title
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .pointerStyle(isDragging ? .grabActive : .grabIdle)
                .help("Przeciągnij, aby zmienić kolejność")
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { onDrag($0.location.y) }
                        .onEnded { _ in onDragEnd() }
                )
            Image(systemName: item.module.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(LinearGradient(colors: item.module.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: .rect(cornerRadius: 5, style: .continuous))
            Text(verbatim: item.title)
            Spacer()
            Text(verbatim: status).foregroundStyle(.secondary)
            Button {
                SettingsRouter.shared.page = .module(item.module)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .help("Ustawienia modułu")
        }
        .opacity(on ? 1 : 0.6)
        .scaleEffect(isDragging ? 1.02 : 1)
    }
}

/// On a module's page: what this module shows in Overview.
struct OverviewModuleSection: View {
    let item: OverviewItem
    @AppStorage private var on: Bool
    @AppStorage private var style: String
    @AppStorage private var label: Bool
    @AppStorage private var tile: Bool
    @AppStorage("overview.net.split") private var netSplit = true

    init(item: OverviewItem) {
        self.item = item
        _on = AppStorage(wrappedValue: item.defaultOn, item.key)
        _style = AppStorage(wrappedValue: "", item.styleKey)
        _label = AppStorage(wrappedValue: true, item.labelKey)
        _tile = AppStorage(wrappedValue: true, item.tileKey)
    }

    var body: some View {
        Section("W Przeglądzie") {
            Toggle("Pokazuj w pasku menu", isOn: $on)
            if on {
                Picker("Styl", selection: $style) {
                    Text("Domyślny (\(Module.overview.currentMode.title.lowercased()))").tag("")
                    Divider()
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Pokaż etykietę (\(item.title))", isOn: $label)
                if item == .net {
                    Toggle("Wysyłanie i pobieranie (dwie linie)", isOn: $netSplit)
                }
            }
            Toggle("Kafelek w okienku Przeglądu", isOn: $tile)
            if item == .macs { RemoteValuePickers() }
        }
    }
}

