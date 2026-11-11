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
                    SectionTitle(text: "Inne Maki")
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Szukam innych Maców z Pulse w tej sieci…")
                            .font(.system(size: 12, weight: .medium))
                        Text("Na każdym z nich zainstaluj Pulse 1.11 lub nowszy i włącz Ustawienia → Inne Maki → „Udostępniaj odczyty tego Maca”.")
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
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
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
            Image(systemName: RemoteMacs.symbol(for: r.model))
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
            Divider().padding(.vertical, 2)
            InfoRow(title: "Pobieranie / wysyłanie", value: "↓ \(Fmt.rate(r.netIn)) · ↑ \(Fmt.rate(r.netOut))")
            if let power = r.power { InfoRow(title: "Pobór mocy", value: String(format: "%.1f W", power)) }
            InfoRow(title: "Pamięć RAM", value: Fmt.memory(r.memTotal))
            InfoRow(title: "Czas pracy", value: Fmt.duration(r.uptime))
            if !r.version.isEmpty { InfoRow(title: "Wersja Pulse", value: r.version) }
        }
        .transition(.opacity)
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
        Picker("Mac", selection: $target) {
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
    private let remote = RemoteMacs.shared

    var body: some View {
        Section {
            Toggle(isOn: $share) {
                Text("Udostępniaj odczyty tego Maca w sieci lokalnej")
                Text("Inne Maki z Pulse w tej samej sieci zobaczą obciążenie, temperatury, wentylatory i najbardziej obciążające procesy tego Maca. Nic nie wychodzi poza sieć lokalną i niczego nie da się zdalnie zmienić.")
            }
            TextField(text: $customName, prompt: Text(verbatim: RemoteMacs.computerName)) {
                Text("Nazwa w sieci")
                Text("Pod tą nazwą inne Maki zobaczą ten Mac. Puste pole: nazwa komputera z Ustawień systemowych.")
            }
            if let error = remote.listenerError {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
        } header: {
            Text("Udostępnianie")
        } footer: {
            Text("Włącz udostępnianie na każdym Macu, który chcesz widzieć. Przy pierwszym uruchomieniu macOS zapyta o dostęp do sieci lokalnej: wybierz Zezwól. Panel „Inne Maki” pokaże każdy Mac z Pulse w tej samej sieci.")
        }
    }
}
