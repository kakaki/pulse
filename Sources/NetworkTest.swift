import Foundation
import SwiftUI

/// On request: 20 pings to the router and to 1.1.1.1, to tell a weak Wi‑Fi / home network from a slow internet connection.
@MainActor
@Observable
final class NetworkTest {
    static let shared = NetworkTest()

    struct Result: Equatable {
        var host: String
        var sent = 0
        var received = 0
        var avg: Double?       // ms
        var jitter: Double?    // ms (standard deviation)
        var loss: Double { sent > 0 ? Double(sent - received) / Double(sent) : 1 }
    }

    private(set) var running = false
    private(set) var router: Result?
    private(set) var internet: Result?
    private(set) var finished: Date?

    func run() {
        guard !running else { return }
        running = true
        router = nil; internet = nil
        Task.detached(priority: .utility) {
            let gateway = Self.gateway()
            async let r = gateway.map { Self.ping($0) }
            async let i = Self.ping("1.1.1.1")
            let (routerResult, internetResult) = await (r, i)
            await MainActor.run {
                let test = NetworkTest.shared
                test.router = routerResult
                test.internet = internetResult
                test.finished = Date()
                test.running = false
            }
        }
    }

    /// Plain-language reading of the two results.
    var verdict: (text: String, color: Color)? {
        guard let internet else { return nil }
        if let router, router.received == 0 {
            return (String(localized: "Brak odpowiedzi routera – sprawdź Wi‑Fi lub kabel."), .red)
        }
        if let router, router.loss >= 0.1 || (router.avg ?? 0) > 50 {
            return (String(localized: "Problem w sieci domowej: router odpowiada wolno lub gubi pakiety (często słabe Wi‑Fi)."), .orange)
        }
        if internet.received == 0 {
            return (String(localized: "Router działa, ale internet nie odpowiada – problem u operatora lub z modemem."), .red)
        }
        if internet.loss >= 0.05 || (internet.avg ?? 0) > 100 {
            return (String(localized: "Sieć domowa działa dobrze, ale internet jest wolny lub gubi pakiety – to po stronie operatora."), .orange)
        }
        return (String(localized: "Wszystko działa dobrze."), .green)
    }

    // MARK: - Helpers

    private nonisolated static func gateway() -> String? {
        guard let out = run("/sbin/route", ["-n", "get", "default"]) else { return nil }
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "gateway", !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }

    private nonisolated static func ping(_ host: String) -> Result {
        var result = Result(host: host)
        guard let out = run("/sbin/ping", ["-c", "20", "-i", "0.2", "-t", "8", "-q", host]) else { return result }
        for line in out.split(separator: "\n") {
            if line.contains("packets transmitted") {
                let numbers = line.split(separator: " ").compactMap { Int($0) }
                if numbers.count >= 2 { result.sent = numbers[0]; result.received = numbers[1] }
            } else if line.contains("min/avg/max"), let eq = line.split(separator: "=").last {
                let values = eq.replacingOccurrences(of: "ms", with: "").split(separator: "/")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if values.count >= 4 { result.avg = values[1]; result.jitter = values[3] }
            }
        }
        return result
    }

    private nonisolated static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Inside the Latency card of the Network panel.
struct NetworkTestSection: View {
    private let test = NetworkTest.shared

    var body: some View {
        VStack(spacing: 7) {
            Divider().padding(.vertical, 2)
            HStack {
                Text("Test połączenia").font(.system(size: 12, weight: .semibold))
                Spacer()
                if test.running {
                    ProgressView().controlSize(.small)
                    Text("ok. 5 s").font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else {
                    Button(test.finished == nil ? String(localized: "Sprawdź") : String(localized: "Sprawdź ponownie")) { test.run() }
                        .pulseGlassButton().controlSize(.small)
                        .help("Wysyła 20 pakietów ping do routera i do 1.1.1.1 (Cloudflare).")
                }
            }
            if let router = test.router { row(String(localized: "Router"), router) }
            if let internet = test.internet { row(String(localized: "Internet (1.1.1.1)"), internet) }
            if let v = test.verdict {
                Label(v.text, systemImage: v.color == .green ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(v.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ title: String, _ r: NetworkTest.Result) -> some View {
        HStack {
            Text(verbatim: title).foregroundStyle(.secondary)
            Spacer()
            if r.received == 0 {
                Text("brak odpowiedzi").foregroundStyle(.red)
            } else {
                Text(verbatim: "\(r.avg.map { String(format: "%.0f ms", $0) } ?? "—") · ± \(r.jitter.map { String(format: "%.0f ms", $0) } ?? "—")")
                    .monospacedDigit()
                Text(String(localized: "utrata \(Fmt.pct(r.loss))"))
                    .foregroundStyle(r.loss == 0 ? Color.secondary : (r.loss < 0.05 ? .orange : .red))
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11.5, weight: .medium))
    }
}
