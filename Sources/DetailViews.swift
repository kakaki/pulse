import SwiftUI

struct ModuleDetail: View {
    let module: Module
    var body: some View {
        switch module {
        case .overview, .cpu: CPUDetail()
        case .gpu: GPUDetail()
        case .memory: MemoryDetail()
        case .disk: DiskDetail()
        case .network: NetworkDetail()
        case .sensors: SensorsDetail()
        case .battery: BatteryDetail()
        }
    }
}

struct InfoRow: View {
    let title: Text
    let value: String
    var copyable = false
    init(title: LocalizedStringKey, value: String, copyable: Bool = false) { self.title = Text(title); self.value = value; self.copyable = copyable }
    @_disfavoredOverload init<S: StringProtocol>(title: S, value: String) { self.title = Text(verbatim: String(title)); self.value = value }
    var body: some View {
        HStack {
            title.foregroundStyle(.secondary)
            Spacer()
            if copyable {
                CopyableValue(value: value)
            } else {
                Text(value).monospacedDigit().fontWeight(.medium)
            }
        }
        .font(.system(size: 12))
    }
}

// MARK: - CPU

struct CPUDetail: View {
    @Environment(SystemMonitor.self) private var m
    private let colors = Module.cpu.colors

    var body: some View {
        VStack(spacing: 10) {
            Card {
                SectionTitle(text: "Użycie procesora", trailing: String(localized: "\(m.coreCount) rdzeni"))
                HStack {
                    BigValue(value: Fmt.pct(m.cpu))
                    Spacer()
                    Pill(text: m.cpu < 0.5 ? String(localized: "Spokojnie") : (m.cpu < 0.8 ? String(localized: "Pracuje") : String(localized: "Pełne obciążenie")),
                         color: Heat.load(m.cpu))
                }
                HistoryChart(metric: .cpu, live: m.cpuHistory, maxValue: 1, color: colors[1], height: 62)
                VStack(spacing: 5) {
                    LegendItem(color: colors[1], title: "Użytkownik", value: Fmt.pct(m.cpuUser))
                    LegendItem(color: colors[0], title: "System", value: Fmt.pct(m.cpuSystem))
                    LegendItem(color: .gray.opacity(0.5), title: "Bezczynny", value: Fmt.pct(max(0, 1 - m.cpu)))
                }
            }
            Card {
                SectionTitle(text: "Rdzenie")
                if m.coreGroups.isEmpty {
                    CoreBars(values: m.cores, colors: colors)
                } else {
                    ForEach(m.coreGroups) { group in
                        let loads = group.indices.filter { $0 < m.cores.count }.map { m.cores[$0] }
                        VStack(spacing: 5) {
                            LegendItem(color: group.id == "E" ? colors[0] : colors[1], title: group.name,
                                       value: Fmt.pct(loads.isEmpty ? 0 : loads.reduce(0, +) / Double(loads.count)))
                            CoreBars(values: loads, colors: group.id == "E" ? [colors[0], colors[0].opacity(0.7)] : colors)
                        }
                    }
                }
                HStack(spacing: 8) {
                    MiniStat(title: "Obc. 1 min", value: String(format: "%.2f", m.loadAverage[0]))
                    MiniStat(title: "5 min", value: String(format: "%.2f", m.loadAverage[1]))
                    MiniStat(title: "15 min", value: String(format: "%.2f", m.loadAverage[2]))
                }
            }
            ProcessList(metric: .cpu)
        }
    }
}

// MARK: - GPU

struct GPUDetail: View {
    @Environment(SystemMonitor.self) private var m

    private func stage(_ title: LocalizedStringKey, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.pct(value)).monospacedDigit().fontWeight(.medium)
            }
            .font(.system(size: 12))
            LinearMeter(value: value, colors: Module.gpu.colors, height: 5)
        }
    }

    var body: some View {
        let s = m.gpuStats
        VStack(spacing: 10) {
            Card {
                SectionTitle(text: "Użycie grafiki", trailing: m.chipName)
                if let gpu = m.gpu {
                    HStack {
                        BigValue(value: Fmt.pct(gpu))
                        Spacer()
                        RingGauge(value: gpu, colors: Module.gpu.colors, lineWidth: 6).frame(width: 40, height: 40)
                    }
                    HistoryChart(metric: .gpu, live: m.gpuHistory, maxValue: 1, color: Module.gpu.tint, height: 70)
                } else {
                    Text("Statystyki GPU są niedostępne na tym Macu.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if s?.renderer != nil || s?.tiler != nil {
                Card {
                    SectionTitle(text: "Etapy pracy")
                    VStack(spacing: 9) {
                        if let v = s?.renderer { stage("Renderer", v) }
                        if let v = s?.tiler { stage("Tiler", v) }
                    }
                    Text("Tiler przygotowuje geometrię sceny, a renderer rysuje piksele.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let s, s.memoryInUse != nil || s.memoryAllocated != nil || s.cores != nil || s.recoveries != nil {
                Card {
                    SectionTitle(text: "Szczegóły")
                    VStack(spacing: 7) {
                        if let v = s.memoryInUse { InfoRow(title: "Pamięć GPU w użyciu", value: Fmt.memory(v)) }
                        if let v = s.memoryAllocated { InfoRow(title: "Pamięć GPU przydzielona", value: Fmt.memory(v)) }
                        if let v = s.cores { InfoRow(title: "Rdzenie GPU", value: "\(v)") }
                        if let v = s.recoveries { InfoRow(title: "Restarty GPU", value: "\(v)") }
                    }
                }
            }
        }
    }
}

// MARK: - Memory

struct MemoryDetail: View {
    @Environment(SystemMonitor.self) private var m
    private let appColor = Color(red: 0.75, green: 0.4, blue: 1.0)
    private let wiredColor = Color(red: 1.0, green: 0.6, blue: 0.3)
    private let compColor = Color(red: 1.0, green: 0.4, blue: 0.6)
    private let cacheColor = Color(red: 0.45, green: 0.6, blue: 1.0)

    private var pressure: (String, Color) {
        switch m.memPressure {
        case .normal: (String(localized: "Ciśnienie: niskie"), Heat.load(0))
        case .warning: (String(localized: "Ciśnienie: średnie"), Heat.load(0.6))
        case .critical: (String(localized: "Ciśnienie: wysokie"), Heat.load(1))
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Card {
                SectionTitle(text: "Pamięć użyta", trailing: String(localized: "z \(Fmt.memory(m.memTotal))"))
                HStack {
                    BigValue(value: Fmt.memory(m.memUsed))
                    Spacer()
                    Pill(text: pressure.0, color: pressure.1)
                }
                let total = Double(max(m.memTotal, 1))
                SegmentBar(segments: [
                    .init(id: "app", value: Double(m.memApp) / total, color: appColor),
                    .init(id: "wired", value: Double(m.memWired) / total, color: wiredColor),
                    .init(id: "comp", value: Double(m.memCompressed) / total, color: compColor),
                ])
                Grid(horizontalSpacing: 16, verticalSpacing: 5) {
                    GridRow {
                        LegendItem(color: appColor, title: "Aplikacje", value: Fmt.memory(m.memApp))
                        LegendItem(color: wiredColor, title: "Związana", value: Fmt.memory(m.memWired))
                    }
                    GridRow {
                        LegendItem(color: compColor, title: "Skompres.", value: Fmt.memory(m.memCompressed))
                        LegendItem(color: cacheColor, title: "Podręczna", value: Fmt.memory(m.memCached))
                    }
                }
            }
            Card {
                SectionTitle(text: "Historia", trailing: Fmt.pct(m.memFraction))
                HistoryChart(metric: .mem, live: m.memHistory, maxValue: 1, color: appColor, height: 48)
                HStack(spacing: 8) {
                    MiniStat(title: "Wolna", value: Fmt.memory(m.memTotal - m.memUsed), color: Heat.load(0), symbol: "circle.fill")
                    MiniStat(title: "Swap", value: Fmt.memory(m.swapUsed), color: compColor, symbol: "arrow.left.arrow.right")
                }
            }
            MemoryPurgeCard()
            ProcessList(metric: .memory)
        }
    }
}

// MARK: - Disk

struct DiskDetail: View {
    @Environment(SystemMonitor.self) private var m
    private let readColor = Color(red: 0.3, green: 0.7, blue: 1.0)
    private let writeColor = Color(red: 1.0, green: 0.55, blue: 0.25)

    var body: some View {
        VStack(spacing: 10) {
            Card {
                SectionTitle(text: m.diskName, trailing: Fmt.file(m.diskTotal))
                HStack(alignment: .firstTextBaseline) {
                    BigValue(value: Fmt.file(m.diskFree), unit: "wolne")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        DiskActivityDots(rates: m.volumes.first { $0.isSystem }.flatMap { m.volumeRates[$0.id] })
                        Text(String(localized: "\(Fmt.pct(m.diskFraction)) zajęte")).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                LinearMeter(value: m.diskFraction, colors: Module.disk.colors, height: 10)
            }
            let others = m.volumes.filter { !$0.isSystem }
            if !others.isEmpty {
                Card {
                    SectionTitle(text: "Inne dyski")
                    VStack(spacing: 9) {
                        ForEach(others) { v in
                            HStack(spacing: 8) {
                                Image(systemName: v.symbol).frame(width: 16).foregroundStyle(Module.disk.tint)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(verbatim: v.name).font(.system(size: 12)).lineLimit(1)
                                        DiskActivityDots(rates: m.volumeRates[v.id])
                                        Spacer()
                                        Text(String(localized: "\(Fmt.file(v.free)) wolne z \(Fmt.file(v.total))"))
                                            .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    LinearMeter(value: v.usedFraction, colors: Module.disk.colors, height: 4)
                                }
                            }
                        }
                    }
                }
            }
            Card {
                SectionTitle(text: "Aktywność", trailing: m.volumes.count > 1 ? String(localized: "wszystkie dyski") : nil)
                HStack(spacing: 8) {
                    MiniStat(title: "Odczyt", value: Fmt.rate(m.readRate), color: readColor, symbol: "arrow.down")
                    MiniStat(title: "Zapis", value: Fmt.rate(m.writeRate), color: writeColor, symbol: "arrow.up")
                }
                HistoryChart(metric: .diskRead, live: m.readHistory, color: readColor,
                             metric2: .diskWrite, live2: m.writeHistory, color2: writeColor, height: 56, mirrored: true)
                PeakRow(down: m.peakRead, up: m.peakWrite, downColor: readColor, upColor: writeColor)
            }
            ProcessList(metric: .disk)
            DiskUsageCard()
        }
    }
}

// MARK: - Network

struct NetworkDetail: View {
    @Environment(SystemMonitor.self) private var m
    private let x = NetworkExtras.shared
    private let inColor = Color(red: 0.35, green: 0.8, blue: 1.0)
    private let outColor = Color(red: 1.0, green: 0.45, blue: 0.6)

    var body: some View {
        VStack(spacing: 10) {
            Card {
                SectionTitle(text: "Przepustowość", trailing: m.netInterface)
                HStack(spacing: 8) {
                    MiniStat(title: "Pobieranie", value: Fmt.rate(m.netIn), color: inColor, symbol: "arrow.down")
                    MiniStat(title: "Wysyłanie", value: Fmt.rate(m.netOut), color: outColor, symbol: "arrow.up")
                }
                HistoryChart(metric: .netIn, live: m.netInHistory, color: inColor,
                             metric2: .netOut, live2: m.netOutHistory, color2: outColor, height: 64, mirrored: true)
                PeakRow(down: m.peakIn, up: m.peakOut, downColor: inColor, upColor: outColor)
            }
            Card {
                SectionTitle(text: "Aplikacje", trailing: "↓ / ↑")
                if x.apps.isEmpty {
                    Text(x.watchers > 0 ? String(localized: "Mierzę ruch aplikacji…") : String(localized: "Brak ruchu"))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                let top = max(x.apps.first?.total ?? 1, 1)
                VStack(spacing: 7) {
                    ForEach(x.apps) { app in
                        HStack(spacing: 8) {
                            ProcessIcon(pid: app.id).frame(width: 16, height: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.system(size: 12)).lineLimit(1)
                                LinearMeter(value: app.total / top, colors: [inColor, outColor], height: 3)
                            }
                            Spacer(minLength: 6)
                            VStack(alignment: .trailing, spacing: 0) {
                                Text("↓ " + Fmt.rate(app.inRate)).foregroundStyle(inColor)
                                Text("↑ " + Fmt.rate(app.outRate)).foregroundStyle(outColor)
                            }
                            .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                            .frame(width: 84, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                        .processMenu(pid: app.id, name: app.name)
                    }
                }
            }
            Card {
                SectionTitle(text: "Opóźnienie", trailing: "1.1.1.1")
                HStack(alignment: .firstTextBaseline) {
                    BigValue(value: x.ping.map { String(Int($0.rounded())) } ?? "—", unit: "ms")
                    Spacer()
                    if let p = x.ping {
                        Pill(text: p < 30 ? String(localized: "Świetnie") : p < 80 ? String(localized: "Dobrze") : p < 150 ? String(localized: "Przeciętnie") : String(localized: "Wolno"),
                             color: p < 30 ? .green : p < 80 ? .mint : p < 150 ? .orange : .red)
                    } else {
                        Pill(text: "Mierzę…")
                    }
                }
                if x.pingHistory.count > 1 {
                    Sparkline(values: x.pingHistory, color: .mint, length: 40, format: { "\(Int($0.rounded())) ms" }).frame(height: 34)
                }
            }
            if let w = x.wifi {
                Card {
                    SectionTitle(text: "Wi‑Fi", trailing: w.band)
                    HStack(spacing: 10) {
                        Image(systemName: "wifi", variableValue: Double(w.bars) / 4)
                            .font(.system(size: 20, weight: .semibold)).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.ssid ?? String(localized: "Sieć Wi‑Fi")).font(.system(size: 13, weight: .semibold))
                            Text("Sygnał: \(w.quality)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if w.ssid == nil {
                            Button("Pokaż nazwę") { x.requestSSIDAccess() }
                                .pulseGlassButton().controlSize(.small)
                                .help("macOS udostępnia nazwę sieci Wi‑Fi tylko aplikacjom z dostępem do lokalizacji.")
                        }
                    }
                    VStack(spacing: 7) {
                        InfoRow(title: "Siła sygnału (RSSI)", value: "\(w.rssi) dBm")
                        InfoRow(title: "Szum", value: "\(w.noise) dBm")
                        InfoRow(title: "Szybkość łącza", value: "\(Int(w.txRate)) Mb/s")
                        if let c = w.channel { InfoRow(title: "Kanał", value: "\(c)") }
                    }
                }
            }
            Card {
                SectionTitle(text: "Połączenie")
                VStack(spacing: 7) {
                    InfoRow(title: "Adres publiczny", value: x.publicIP ?? "—", copyable: x.publicIP != nil)
                    InfoRow(title: "Adres lokalny", value: m.netAddress ?? String(localized: "Brak połączenia"), copyable: m.netAddress != nil)
                    InfoRow(title: "Interfejs", value: m.netInterface ?? "—", copyable: m.netInterface != nil)
                    Divider().opacity(0.5)
                    InfoRow(title: "Pobrano (sesja)", value: Fmt.file(Int64(m.netSessionIn)))
                    InfoRow(title: "Wysłano (sesja)", value: Fmt.file(Int64(m.netSessionOut)))
                }
            }
        }
        .onAppear { x.watchers += 1 }
        .onDisappear { x.watchers -= 1 }
    }
}

// MARK: - Sensors

struct SensorsDetail: View {
    @AppStorage("sensors.detailed") private var showAllSensors = false
    @Environment(SystemMonitor.self) private var m
    @AppStorage("tempUnit") private var tempUnit = 0
    @State private var expanded: String?

    private var gpuTemperature: Double? {
        (m.sensorGroups.first { $0.id == "gpu" } ?? m.sensors.first { $0.name == "GPU" })?.value
    }

    private func gauge(_ title: String, _ value: String, fraction: Double, color: Color) -> some View {
        RingGauge(value: fraction, colors: [color.opacity(0.7), color], lineWidth: 6)
            .frame(width: 76, height: 76)
            .overlay {
                VStack(spacing: 0) {
                    Text(verbatim: title).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                    Text(verbatim: value).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity)
    }

    /// A row that shows its own history chart when clicked; rows without a key are plain.
    @ViewBuilder
    private func expandable<Row: View>(key: String?, maxValue: Double?, color: Color, format: @escaping (Double) -> String,
                                       @ViewBuilder row: () -> Row) -> some View {
        VStack(spacing: 6) {
            row()
                .contentShape(.rect)
                .onTapGesture { if let key { expanded = expanded == key ? nil : key } }
            if let key, expanded == key {
                HistoryChart(live: m.itemHistory[key] ?? [], maxValue: maxValue, color: color, height: 48, key: key, format: format)
                    .padding(.bottom, 4)
            }
        }
    }

    private func chevron(_ key: String?) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(key != nil && expanded == key ? 90 : 0))
            .opacity(key == nil ? 0 : 1)
    }

    var body: some View {
        let _ = tempUnit
        VStack(spacing: 10) {
            if m.socMax != nil || m.socAvg != nil || !m.sensors.isEmpty {
                Card {
                    HStack {
                        let cpu = m.socMax ?? m.socAvg
                        gauge("CPU", Fmt.temp(cpu), fraction: (cpu ?? 0) / 105, color: Heat.color(cpu ?? 0))
                        if let gpu = gpuTemperature { gauge("GPU", Fmt.temp(gpu), fraction: gpu / 105, color: Heat.color(gpu)) }
                        if m.hasFans, !m.fans.isEmpty {
                            let level = m.fans.map(\.fraction).reduce(0, +) / Double(m.fans.count)
                            gauge(String(localized: "Wentylator"), Fmt.pct(level), fraction: level, color: .cyan)
                        }
                    }
                }
            }
            Card {
                SectionTitle(text: "Temperatura SoC", trailing: String(localized: "maks."))
                if let avg = m.socAvg {
                    HStack {
                        BigValue(value: Fmt.temp(m.socMax ?? avg))
                        Spacer()
                        Pill(text: Heat.label(m.socMax ?? avg), color: Heat.color(m.socMax ?? avg))
                    }
                    HistoryChart(metric: .temp, live: m.tempHistory, maxValue: 110, color: Heat.color(m.socMax ?? avg), height: 52)
                    HStack(spacing: 8) {
                        MiniStat(title: "Średnio", value: Fmt.temp(avg), color: Heat.color(avg), symbol: "flame.fill")
                        if m.ssdTemp != nil {
                            MiniStat(title: "SSD", value: Fmt.temp(m.ssdTemp), color: Heat.color(m.ssdTemp ?? 0), symbol: "internaldrive")
                        }
                        if m.batteryTemp != nil {
                            MiniStat(title: "Bateria", value: Fmt.temp(m.batteryTemp), color: Heat.color(m.batteryTemp ?? 0), symbol: "battery.75percent")
                        }
                    }
                } else {
                    Text("Nie udało się odczytać czujników temperatury.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Card {
                SectionTitle(text: "Chłodzenie i zasilanie")
                HStack(spacing: 10) {
                    Image(systemName: m.thermalState == .nominal ? "checkmark.seal.fill" : "flame.fill")
                        .foregroundStyle(m.thermalState.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Stan termiczny").font(.system(size: 12))
                        Text(m.thermalState.detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Pill(text: m.thermalState.title, color: m.thermalState.color)
                }
                if m.hasFans {
                    ForEach(m.fans) { fan in
                        expandable(key: "fan.\(fan.id)", maxValue: fan.max > 0 ? fan.max : nil, color: .cyan,
                                   format: { String(localized: "\(Int($0)) obr/min") }) {
                        HStack(spacing: 10) {
                            Image(systemName: "fan.fill").foregroundStyle(.cyan)
                            Text(m.fans.count > 1 ? String(localized: "Wentylator \(fan.id + 1)") : String(localized: "Wentylator")).font(.system(size: 12))
                            Spacer()
                            LinearMeter(value: fan.fraction, colors: [.cyan.opacity(0.7), .blue], height: 5).frame(width: 70)
                            Text("\(Int(fan.rpm)) obr/min").font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                                .frame(width: 92, alignment: .trailing)
                            chevron("fan.\(fan.id)")
                        }
                        }
                    }
                    if FanControl.isAvailable(on: m) { FanControlShortcut() }
                } else {
                    InfoRow(title: "Wentylator", value: String(localized: "Brak – chłodzenie pasywne"))
                }
                if let w = m.systemPower {
                    InfoRow(title: "Pobór mocy systemu", value: String(format: "%.1f W", w))
                }
            }
            if !m.sensors.isEmpty {
                Card {
                    let detailed = showAllSensors || m.sensorGroups.isEmpty
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if detailed {
                            SectionTitle(text: "Wszystkie czujniki", trailing: "\(m.sensors.count)")
                        } else {
                            SectionTitle(text: "Podzespoły")
                        }
                        if !m.sensorGroups.isEmpty {
                            Button(detailed ? String(localized: "Mniej") : String(localized: "Wszystkie")) { showAllSensors.toggle() }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    ScrollView {
                        VStack(spacing: 7) {
                            ForEach(detailed ? m.sensors : m.sensorGroups) { s in
                                let key: String? = detailed && !m.sensorGroups.isEmpty ? nil : "sensor.\(s.id)"
                                expandable(key: key, maxValue: 110, color: Heat.color(s.value), format: { Fmt.temp($0) }) {
                                HStack(spacing: 10) {
                                    Text(s.name).font(.system(size: 11.5)).lineLimit(1)
                                    Spacer()
                                    LinearMeter(value: s.value / 110, colors: [Heat.color(s.value).opacity(0.7), Heat.color(s.value)], height: 5)
                                        .frame(width: 70)
                                    Text(Fmt.temp(s.value))
                                        .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                                        .frame(width: 34, alignment: .trailing)
                                    chevron(key)
                                }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: expanded == nil ? 190 : 300)
                    .scrollIndicators(.never)
                }
            }
        }
    }
}

// MARK: - Battery

struct BatteryDetail: View {
    @Environment(SystemMonitor.self) private var m

    var body: some View {
        let b = m.battery
        VStack(spacing: 10) {
            if b.present {
                Card {
                    SectionTitle(text: "Bateria", trailing: state(b))
                    HStack(spacing: 16) {
                        ZStack {
                            RingGauge(value: b.percent, colors: Module.battery.colors, lineWidth: 8)
                            Image(systemName: b.isCharging ? "bolt.fill" : (b.onAC ? "powerplug.fill" : "battery.100percent"))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Module.battery.tint)
                        }
                        .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 2) {
                            BigValue(value: Fmt.pct(b.percent))
                            if let min = b.minutesRemaining {
                                Text(b.isCharging ? String(localized: "Do pełna: \(Fmt.minutes(min))") : String(localized: "Pozostało: \(Fmt.minutes(min))"))
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            } else if b.fullyCharged {
                                Text("Naładowana").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            if let w = b.watts, abs(w) >= 0.1 {
                                Text(w > 0 ? String(localized: "Ładowanie \(watts(w))") : String(localized: "Pobór \(watts(-w))"))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(w > 0 ? Module.battery.tint : .orange)
                            }
                        }
                        Spacer()
                    }
                    HStack(spacing: 6) {
                        if let aw = b.adapterWatts, b.onAC { Pill(text: "Zasilacz \(aw) W", color: .secondary) }
                        if m.isSaving { Pill(text: "Oszczędzanie energii", color: .green) }
                    }
                }
                Card {
                    SectionTitle(text: "Poziom naładowania")
                    HistoryChart(metric: .battery, live: m.batteryHistory, maxValue: 1, color: Module.battery.tint, height: 52)
                }
                healthCard(b)
            } else {
                Card {
                    SectionTitle(text: "Bateria")
                    Label("Ten Mac jest zasilany z sieci.", systemImage: "powerplug.fill")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func healthCard(_ b: BatteryInfo) -> some View {
        let health = b.health ?? 0
        let healthColor: Color = health >= 0.8 ? Module.battery.tint : (health >= 0.7 ? .orange : .red)
        return Card {
            SectionTitle(text: "Kondycja", trailing: b.health == nil ? nil : (health >= 0.8 ? String(localized: "Normalna") : String(localized: "Zalecany serwis")))
            HStack(alignment: .firstTextBaseline) {
                BigValue(value: b.health.map(Fmt.pct) ?? "—")
                Text("pojemności fabrycznej").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            LinearMeter(value: health, colors: [healthColor.opacity(0.7), healthColor], height: 6)
            VStack(spacing: 7) {
                if let max = b.maxCapacity, let design = b.designCapacity {
                    InfoRow(title: "Pojemność maks.", value: "\(max) / \(design) mAh")
                }
                if let cur = b.currentCharge { InfoRow(title: "Obecny ładunek", value: "\(cur) mAh") }
                if let cycles = b.cycleCount {
                    InfoRow(title: "Cykle ładowania", value: b.designCycles.map { String(localized: "\(cycles) z \($0)") } ?? "\(cycles)")
                    if let design = b.designCycles, design > 0 {
                        LinearMeter(value: Double(cycles) / Double(design), colors: [.blue.opacity(0.6), .blue], height: 4)
                    }
                }
                InfoRow(title: "Temperatura", value: Fmt.temp(b.temperature))
                if let v = b.voltage { InfoRow(title: "Napięcie", value: String(format: "%.2f V", v)) }
            }
        }
    }

    private func state(_ b: BatteryInfo) -> String {
        if b.isCharging { return String(localized: "Ładowanie") }
        if b.onAC { return b.fullyCharged ? String(localized: "Naładowana") : String(localized: "Zasilacz") }
        return String(localized: "Na baterii")
    }

    private func watts(_ w: Double) -> String { String(format: "%.1f W", w) }
}

// MARK: - Processes

struct ProcessList: View {
    enum Metric { case cpu, memory, disk }
    let metric: Metric
    @Environment(SystemMonitor.self) private var m

    var body: some View {
        let list = metric == .cpu ? m.topByCPU : (metric == .memory ? m.topByMemory : m.topByDisk)
        Card {
            SectionTitle(text: metric == .cpu ? String(localized: "Procesy · CPU") : (metric == .memory ? String(localized: "Procesy · pamięć") : String(localized: "Procesy · dysk")), trailing: String(localized: "prawy klik: opcje"))
            if list.isEmpty {
                Text(metric == .disk ? String(localized: "Brak aktywności") : String(localized: "Zbieranie danych…"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            VStack(spacing: 7) {
                ForEach(list) { p in
                    HStack(spacing: 8) {
                        ProcessIcon(pid: p.id).frame(width: 16, height: 16)
                        Text(p.name).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Text(value(p))
                            .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .processMenu(pid: p.id, name: p.name)
                }
            }
        }
        .onAppear { m.processWatchers += 1 }
        .onDisappear { m.processWatchers = max(0, m.processWatchers - 1) }
    }

    private func value(_ p: ProcessStat) -> String {
        switch metric {
        case .cpu: String(format: "%.1f%%", p.cpu * 100)
        case .memory: Fmt.memory(p.memory)
        case .disk: "↓ \(Fmt.rate(p.diskRead)) ↑ \(Fmt.rate(p.diskWrite))"
        }
    }
}

/// Highest speeds seen since Pulse started.
struct PeakRow: View {
    let down: Double
    let up: Double
    let downColor: Color
    let upColor: Color
    var body: some View {
        HStack(spacing: 10) {
            Text("Szczyt").foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: "↓ " + Fmt.rate(down)).foregroundStyle(downColor)
            Text(verbatim: "↑ " + Fmt.rate(up)).foregroundStyle(upColor)
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
    }
}

/// Two small lights: lit while a volume is being read from or written to.
struct DiskActivityDots: View {
    let rates: DiskRates?
    private func dot(_ on: Bool, _ color: Color) -> some View {
        Circle().fill(on ? color : Color.secondary.opacity(0.25)).frame(width: 6, height: 6)
    }
    var body: some View {
        HStack(spacing: 3) {
            dot((rates?.read ?? 0) > 1024, Color(red: 0.35, green: 0.8, blue: 1.0))
            dot((rates?.write ?? 0) > 1024, Color(red: 1.0, green: 0.45, blue: 0.6))
        }
    }
}

struct ProcessIcon: View {
    let pid: pid_t
    var body: some View {
        if let icon = ProcessSampler.icon(for: pid) {
            Image(nsImage: icon).resizable().interpolation(.high)
        } else {
            Image(systemName: "gearshape.fill")
                .resizable().scaledToFit().padding(2)
                .foregroundStyle(.secondary)
        }
    }
}
