import Foundation
import SwiftUI

/// Running Docker containers with their CPU and memory, read from the Docker Engine API over its unix socket
/// (Docker Desktop, OrbStack, Colima, Rancher Desktop). Polled only while someone looks: the CPU panel,
/// or another Mac asking for this Mac's details.
@MainActor
@Observable
final class DockerContainers {
    static let shared = DockerContainers()

    struct Container: Identifiable, Equatable, Codable {
        let id: String
        let name: String
        let image: String
        let cpu: Double        // fraction of one core (1.0 = 100%)
        let memory: UInt64     // bytes, without page cache
        let memoryLimit: UInt64
    }

    private(set) var containers: [Container] = []
    /// A Docker socket answered at least once.
    private(set) var available = false
    private(set) var loaded = false

    @ObservationIgnored var watchers = 0 {
        didSet { if watchers > 0 && oldValue == 0 { refresh() } }
    }
    @ObservationIgnored private var running = false
    @ObservationIgnored private var previous: [String: (total: UInt64, system: UInt64)] = [:]

    /// Docker installed on this Mac at all (a socket file exists); cheap enough to call while drawing.
    static var installed: Bool { socketPath != nil }

    func tick() {
        if watchers > 0 { refresh() }
    }

    func refresh() {
        guard !running, let path = Self.socketPath else {
            if Self.socketPath == nil, available || !containers.isEmpty { available = false; containers = []; loaded = true }
            return
        }
        running = true
        let before = previous
        Task.detached(priority: .utility) {
            let result = Self.read(socket: path, previous: before)
            await MainActor.run {
                let shared = DockerContainers.shared
                shared.running = false
                shared.loaded = true
                if let result {
                    shared.available = true
                    shared.previous = result.counters
                    if result.list != shared.containers { shared.containers = result.list }
                } else if shared.available || !shared.containers.isEmpty {
                    shared.available = false
                    shared.containers = []
                }
            }
        }
    }

    // MARK: - Engine API

    nonisolated static var socketPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            candidates.append(String(host.dropFirst(7)))
        }
        candidates += ["\(home)/.docker/run/docker.sock", "/var/run/docker.sock", "\(home)/.orbstack/run/docker.sock",
                       "\(home)/.colima/default/docker.sock", "\(home)/.colima/docker.sock", "\(home)/.rd/docker.sock"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private nonisolated static func read(socket: String, previous: [String: (total: UInt64, system: UInt64)])
        -> (list: [Container], counters: [String: (total: UInt64, system: UInt64)])? {
        guard let data = request(socket: socket, path: "/containers/json"),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var list: [Container] = []
        var counters: [String: (total: UInt64, system: UInt64)] = [:]
        for item in items.prefix(40) {
            guard let id = item["Id"] as? String else { continue }
            let name = ((item["Names"] as? [String])?.first ?? String(id.prefix(12))).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let image = item["Image"] as? String ?? ""
            var cpu = 0.0, memory: UInt64 = 0, limit: UInt64 = 0
            if let raw = request(socket: socket, path: "/containers/\(id)/stats?stream=false&one-shot=true"),
               let stats = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                let cpuStats = stats["cpu_stats"] as? [String: Any] ?? [:]
                let total = ((cpuStats["cpu_usage"] as? [String: Any])?["total_usage"] as? NSNumber)?.uint64Value ?? 0
                let system = (cpuStats["system_cpu_usage"] as? NSNumber)?.uint64Value ?? 0
                let cores = Double((cpuStats["online_cpus"] as? NSNumber)?.intValue ?? 1)
                if let before = previous[id], total >= before.total, system > before.system {
                    cpu = Double(total - before.total) / Double(system - before.system) * max(cores, 1)
                }
                counters[id] = (total, system)
                let mem = stats["memory_stats"] as? [String: Any] ?? [:]
                let usage = (mem["usage"] as? NSNumber)?.uint64Value ?? 0
                let details = mem["stats"] as? [String: Any] ?? [:]
                let cache = ((details["inactive_file"] ?? details["total_inactive_file"] ?? details["cache"]) as? NSNumber)?.uint64Value ?? 0
                memory = usage > cache ? usage - cache : usage
                limit = (mem["limit"] as? NSNumber)?.uint64Value ?? 0
            }
            list.append(Container(id: id, name: name, image: image, cpu: cpu, memory: memory, memoryLimit: limit))
        }
        return (list.sorted { $0.cpu == $1.cpu ? $0.name < $1.name : $0.cpu > $1.cpu }, counters)
    }

    /// Minimal HTTP/1.0 GET over a unix socket; returns the body of a 200 response.
    nonisolated static func request(socket path: String, path resource: String, timeout: Int = 3) -> Data? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        let request = Array("GET \(resource) HTTP/1.0\r\nHost: docker\r\n\r\n".utf8)
        guard write(fd, request, request.count) == request.count else { return nil }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while response.count < 8_000_000 {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            response.append(contentsOf: chunk[0..<n])
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        guard head.hasPrefix("HTTP/1.") && head.split(separator: " ").dropFirst().first == "200" else { return nil }
        let body = response[split.upperBound...]
        return head.lowercased().contains("transfer-encoding: chunked") ? dechunk(Data(body)) : Data(body)
    }

    private nonisolated static func dechunk(_ data: Data) -> Data {
        var out = Data(), rest = data[...]
        while let line = rest.range(of: Data("\r\n".utf8)) {
            let sizeText = String(decoding: rest[..<line.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = line.upperBound
            guard rest.distance(from: start, to: rest.endIndex) >= size else { break }
            let end = rest.index(start, offsetBy: size)
            out.append(rest[start..<end])
            rest = rest[end...].dropFirst(2)
        }
        return out
    }

    /// README screenshots (`--snapshot <dir> --demo`).
    func applyDemo() {
        let mb: UInt64 = 1 << 20
        containers = [
            Container(id: "demo1", name: "gitlab-runner", image: "gitlab/gitlab-runner:latest", cpu: 0.64, memory: 412 * mb, memoryLimit: 8192 * mb),
            Container(id: "demo2", name: "postgres", image: "postgres:17", cpu: 0.03, memory: 96 * mb, memoryLimit: 8192 * mb),
            Container(id: "demo3", name: "redis", image: "redis:7-alpine", cpu: 0.01, memory: 9 * mb, memoryLimit: 8192 * mb),
        ]
        available = true
        loaded = true
    }
}

// MARK: - Panel

/// Containers card; draws nothing on Macs without Docker.
struct DockerContainersCard: View {
    private let docker = DockerContainers.shared
    var containers: [DockerContainers.Container]?   // another Mac's list instead of this Mac's

    var body: some View {
        let list = containers ?? docker.containers
        Group {
            if containers != nil || DockerContainers.installed || !docker.containers.isEmpty {
                Card {
                    SectionTitle(text: "Kontenery Dockera", trailing: list.isEmpty ? nil : String(localized: "CPU · pamięć"))
                    if list.isEmpty {
                        Text(containers == nil && !docker.available && docker.loaded
                             ? String(localized: "Docker nie działa.")
                             : (containers == nil && !docker.loaded ? String(localized: "Zbieranie danych…") : String(localized: "Brak uruchomionych kontenerów.")))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 7) {
                        ForEach(list) { row($0) }
                    }
                }
            }
        }
        .onAppear { if containers == nil { docker.watchers += 1 } }
        .onDisappear { if containers == nil { docker.watchers = max(0, docker.watchers - 1) } }
    }

    private func row(_ c: DockerContainers.Container) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill").font(.system(size: 11)).foregroundStyle(.blue).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: c.name).font(.system(size: 12)).lineLimit(1)
                Text(verbatim: c.image).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(verbatim: String(format: "%.1f%%", c.cpu * 100) + " · " + Fmt.memory(c.memory))
                .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help(Text(verbatim: c.image))
    }
}
