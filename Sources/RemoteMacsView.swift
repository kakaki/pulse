import SwiftUI

// MARK: - Panel

struct RemoteMacsDetail: View {
    private let remote = RemoteMacs.shared
    @AppStorage(RemoteMacs.shareKey) private var share = false
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 10) {
            if remote.peers.isEmpty {
                Card {
                    SectionTitle(text: "Inne komputery")
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Szukam innych komputerów z Pulse w tej sieci…")
                            .font(.system(size: 12, weight: .medium))
                        Text("Na każdym Macu zainstaluj Pulse 1.11 lub nowszy, a na Windowsie PulseWin, i włącz w ustawieniach udostępnianie odczytów.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if let error = remote.browserError {
                            Text(error).font(.system(size: 10.5)).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
            }
            ForEach(remote.peers) { peer in
                RemoteMacCard(peer: peer, expanded: expanded.contains(peer.id)) {
                    withAnimation(.snappy(duration: 0.25)) {
                        if expanded.contains(peer.id) { expanded.remove(peer.id) } else { expanded.insert(peer.id) }
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: share ? "dot.radiowaves.left.and.right" : "eye.slash")
                    .foregroundStyle(share ? Color.green : Color.secondary)
                Text(share ? "Ten Mac też udostępnia swoje odczyty." : "Ten Mac nie udostępnia swoich odczytów.")
                    .foregroundStyle(.secondary)
                Spacer()
                if !share { Button("Udostępniaj") { share = true }.controlSize(.small) }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 4)
        }
        .onAppear { remote.panelWatchers += 1 }
        .onDisappear { remote.panelWatchers = max(0, remote.panelWatchers - 1) }
    }
}

struct RemoteMacCard: View {
    let peer: RemoteMacs.Peer
    let expanded: Bool
    let toggle: () -> Void
    private var r: RemoteReport { peer.report }
    private let cpuColors = Module.cpu.colors

    var body: some View {
        Card {
            Button(action: toggle) {
                VStack(spacing: 10) {
                    header
                    gauges
                    Sparkline(values: r.cpuHistory, maxValue: 1, color: cpuColors[1], format: Fmt.pct)
                        .frame(height: 34)
                    if !r.fans.isEmpty { fans }
                    if let containers = r.containers, !containers.isEmpty { dockerSummary(containers) }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if showsUpdate { updateRow }
            if expanded { details }
        }
        .opacity(peer.isStale ? 0.55 : 1)
    }

    /// Chip only when the Mac's name already says what it is ("Mac mini (Office)"), otherwise model · chip.
    private var subtitle: String {
        let chip = RemoteMacs.shortChip(r.chip)
        let base = r.model.components(separatedBy: " (").first ?? r.model
        return r.name.localizedCaseInsensitiveContains(base) ? chip : "\(r.model) · \(chip)"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: RemoteMacs.symbol(for: r))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(LinearGradient(colors: Module.macs.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: .rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: r.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(verbatim: subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if peer.isStale {
                Pill(text: "Brak odpowiedzi", color: .secondary)
            } else if let state = ProcessInfo.ThermalState(rawValue: r.thermal), state != .nominal {
                Pill(text: "🔥 \(state.title)", color: state.color)
            } else {
                Pill(text: r.cpu < 0.5 ? String(localized: "Spokojnie") : (r.cpu < 0.8 ? String(localized: "Pracuje") : String(localized: "Pełne obciążenie")),
                     color: Heat.load(r.cpu))
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
    }

    private var gauges: some View {
        HStack(spacing: 6) {
            gauge(value: r.cpu, text: Fmt.pct(r.cpu), title: "CPU", colors: Module.cpu.colors)
            if let gpu = r.gpu { gauge(value: gpu, text: Fmt.pct(gpu), title: "GPU", colors: Module.gpu.colors) }
            gauge(value: r.mem, text: Fmt.pct(r.mem), title: String(localized: "Pamięć"),
                  colors: r.memPressure > 0 ? [.orange, .red] : Module.memory.colors)
            if let t = r.temp {
                gauge(value: t / 105, text: Fmt.temp(t), title: String(localized: "Temp."), colors: [Heat.color(t).opacity(0.7), Heat.color(t)])
            }
        }
    }

    private func gauge(value: Double, text: String, title: String, colors: [Color]) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RingGauge(value: value, colors: colors, lineWidth: 4.5)
                Text(verbatim: text)
                    .font(.system(size: text.count > 4 ? 9 : 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
            }
            .frame(width: 44, height: 44)
            Text(verbatim: title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var fans: some View {
        VStack(spacing: 6) {
            ForEach(Array(r.fans.enumerated()), id: \.offset) { i, fan in
                let fraction = fan.max > fan.min ? min(max((fan.rpm - fan.min) / (fan.max - fan.min), 0), 1) : 0
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: "fan.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(r.fans.count > 1 ? String(localized: "Wentylator \(i + 1)") : String(localized: "Wentylator"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(fan.rpm)) obr/min").fontWeight(.semibold).monospacedDigit()
                    }
                    .font(.system(size: 11.5))
                    LinearMeter(value: fraction, colors: [.cyan, fraction > 0.7 ? .orange : .blue], height: 5)
                }
            }
        }
    }

    /// Always visible: how much the containers of that Mac take together, and the busiest one.
    private func dockerSummary(_ containers: [DockerContainers.Container]) -> some View {
        let cpu = containers.reduce(0) { $0 + $1.cpu }
        let memory = containers.reduce(UInt64(0)) { $0 + $1.memory }
        let top = containers.max { $0.cpu < $1.cpu }
        return HStack(spacing: 6) {
            Image(systemName: "shippingbox.fill").font(.system(size: 10)).foregroundStyle(.blue)
            Text("Docker: \(containers.count)").foregroundStyle(.secondary).fixedSize()
            if let top, top.cpu >= 0.05 {
                Text(verbatim: "· " + top.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text(verbatim: String(format: "%.0f%%", cpu * 100) + " CPU · " + Fmt.memory(memory))
                .fontWeight(.semibold).monospacedDigit().lineLimit(1).fixedSize()
        }
        .font(.system(size: 11.5))
    }

    @ViewBuilder private var details: some View {
        VStack(spacing: 6) {
            if let processes = r.processes, !processes.isEmpty {
                SectionTitle(text: "Procesy · CPU")
                ForEach(Array(processes.enumerated()), id: \.offset) { _, p in
                    HStack {
                        Text(verbatim: p.name).lineLimit(1)
                        Spacer()
                        Text(verbatim: String(format: "%.1f%%", p.cpu * 100)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11.5))
                }
            } else if !peer.isStale {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Pobieram listę procesów…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let containers = r.containers, !containers.isEmpty {
                SectionTitle(text: "Kontenery Dockera").padding(.top, 4)
                ForEach(containers) { c in
                    HStack {
                        Image(systemName: "shippingbox.fill").font(.system(size: 10)).foregroundStyle(.blue)
                        Text(verbatim: c.name).lineLimit(1)
                        Spacer()
                        Text(verbatim: String(format: "%.1f%%", c.cpu * 100) + " · " + Fmt.memory(c.memory))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11.5))
                }
            }
            Divider().padding(.vertical, 2)
            InfoRow(title: "Pobieranie / wysyłanie", value: "↓ \(Fmt.rate(r.netIn)) · ↑ \(Fmt.rate(r.netOut))")
            if let power = r.power { InfoRow(title: "Pobór mocy", value: String(format: "%.1f W", power)) }
            InfoRow(title: "Pamięć RAM", value: Fmt.memory(r.memTotal))
            InfoRow(title: "Czas pracy", value: Fmt.duration(r.uptime))
            if !r.version.isEmpty {
                HStack {
                    InfoRow(title: r.isWindows ? "Wersja PulseWin" : "Wersja Pulse", value: r.version)
                    if !showsUpdate && !peer.isStale && !r.isWindows {
                        Button("Sprawdź aktualizację") { RemoteMacs.shared.requestUpdate(peer) }
                            .controlSize(.mini)
                            .help(Text("Ten Mac sprawdzi i zainstaluje najnowszą wersję Pulse bez pytania."))
                    }
                }
            }
        }
        .transition(.opacity)
    }

    // MARK: Update

    private var request: RemoteMacs.UpdateRequest? { RemoteMacs.shared.updateRequests[peer.id] }

    private var showsUpdate: Bool {
        // PulseWin has its own versions and never updates remotely.
        !peer.isStale && !r.isWindows && (RemoteMacs.isOlder(r.version) || request != nil || r.update != nil)
    }

    private var updateRow: some View {
        let (text, busy, action, color) = updateStatus
        return HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 11)).foregroundStyle(color)
            }
            Text(verbatim: text).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action {
                Button(action) { RemoteMacs.shared.requestUpdate(peer) }.controlSize(.small)
            }
        }
        .font(.system(size: 11.5))
    }

    /// Text, spinner, button title (nil: no button), icon colour.
    private var updateStatus: (String, Bool, LocalizedStringKey?, Color) {
        switch request {
        case .sending:
            return (String(localized: "Wysyłam prośbę…"), true, nil, .accentColor)
        case .refused:
            return (String(localized: "Ten Mac nie pozwala na zdalną aktualizację (Ustawienia → Inne komputery)."), false, nil, .orange)
        case .unavailable:
            return (String(localized: "Ta kopia Pulse nie ma aktualizatora."), false, nil, .orange)
        case .tooOld:
            return (String(localized: "Pulse na tym Macu jest starszy niż 1.13 – zaktualizuj go raz ręcznie."), false, nil, .orange)
        case .unreachable:
            return (String(localized: "Brak odpowiedzi."), false, "Ponów", .orange)
        case .started, nil:
            switch r.update.flatMap(Updater.RemoteState.init) {
            case .checking: return (String(localized: "Sprawdzam aktualizacje…"), true, nil, .accentColor)
            case .installing: return (String(localized: "Instaluję – Pulse uruchomi się ponownie…"), true, nil, .accentColor)
            case .upToDate: return (String(localized: "Pulse \(r.version) jest najnowszą wersją."), false, nil, .green)
            case .failed: return (String(localized: "Aktualizacja się nie udała."), false, "Ponów", .orange)
            case nil:
                if request == .started { return (String(localized: "Aktualizacja uruchomiona…"), true, nil, .accentColor) }
                return (String(localized: "Pulse \(r.version) · dostępna wersja \(RemoteMacs.ownVersion)"), false, "Aktualizuj", .accentColor)
            }
        }
    }
}

// MARK: - Settings

/// Which value of which Mac the menu bar item and the Overview tile show.
struct RemoteValuePickers: View {
    @AppStorage(RemoteMacs.metricKey) private var metric = RemoteMacs.Metric.temp.rawValue
    @AppStorage(RemoteMacs.targetKey) private var target = ""
    @AppStorage(RemoteMacs.targetNameKey) private var targetName = ""
    private let remote = RemoteMacs.shared

    var body: some View {
        Picker("Pokazuj", selection: $metric) {
            ForEach(RemoteMacs.Metric.allCases) { Text(verbatim: $0.title).tag($0.rawValue) }
        }
        Picker("Komputer", selection: $target) {
            Text("Najwyższa wartość ze wszystkich").tag("")
            Divider()
            ForEach(remote.peers) { Text(verbatim: $0.report.name).tag($0.id) }
            if !target.isEmpty && !remote.peers.contains(where: { $0.id == target }) {
                Text("\(targetName) (niedostępny)").tag(target)
            }
        }
        .onChange(of: target) { _, id in
            targetName = remote.peers.first { $0.id == id }?.report.name ?? ""
        }
    }
}

struct RemoteSharingSection: View {
    @AppStorage(RemoteMacs.shareKey) private var share = false
    @AppStorage(RemoteMacs.nameKey) private var customName = ""
    @AppStorage(RemoteMacs.allowUpdateKey) private var allowUpdate = false
    private let remote = RemoteMacs.shared

    var body: some View {
        Section {
            Toggle(isOn: $share) {
                Text("Udostępniaj odczyty tego Maca w sieci lokalnej")
                Text("Inne komputery z Pulse lub PulseWin w tej samej sieci zobaczą obciążenie, temperatury, wentylatory i najbardziej obciążające procesy tego Maca. Nic nie wychodzi poza sieć lokalną.")
            }
            Toggle(isOn: $allowUpdate) {
                Text("Pozwól innym komputerom zaktualizować Pulse")
                Text("Inny komputer z Pulse może poprosić o instalację najnowszej wersji Pulse na tym Macu. Instalowana jest tylko oficjalna, podpisana aktualizacja – nic więcej nie da się zdalnie zmienić ani uruchomić.")
            }
            .disabled(!share)
            TextField(text: $customName, prompt: Text(verbatim: RemoteMacs.computerName)) {
                Text("Nazwa w sieci")
                Text("Pod tą nazwą inne komputery zobaczą ten Mac. Puste pole: nazwa komputera z Ustawień systemowych.")
            }
            if let error = remote.listenerError {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
        } header: {
            Text("Udostępnianie")
        } footer: {
            Text("Włącz udostępnianie na każdym komputerze, który chcesz widzieć. Przy pierwszym uruchomieniu macOS zapyta o dostęp do sieci lokalnej: wybierz Zezwól. Panel „Inne komputery” pokaże każdy komputer z Pulse w tej samej sieci.")
        }
    }
}
