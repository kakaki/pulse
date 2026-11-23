import AppKit
import CryptoKit
import Foundation
import Network

/// Clipboard pull and file transfer between paired computers (Pulse and PulseWin). Off until turned on in Settings.
@MainActor
@Observable
final class ShareCenter {
    static let shared = ShareCenter()
    nonisolated static let serviceType = "_pulse-share._tcp"
    nonisolated static let clipLimit = 50 * 1_000_000

    nonisolated static let onKey = "share.on"
    nonisolated static let clipKey = "share.clip"
    nonisolated static let filesKey = "share.files"
    nonisolated static let notifyKey = "share.notifyTaken"
    nonisolated static let pasteKey = "share.paste"
    nonisolated static let hotkeyKey = "share.hotkey"
    private static let peersKey = "share.peers"
    private static let lastPeerKey = "share.lastPeer"

    nonisolated static var isOn: Bool { UserDefaults.standard.bool(forKey: onKey) }
    nonisolated static var sharesClipboard: Bool { UserDefaults.standard.object(forKey: clipKey) as? Bool ?? true }
    nonisolated static var acceptsFiles: Bool { UserDefaults.standard.object(forKey: filesKey) as? Bool ?? true }
    nonisolated static var notifiesTaken: Bool { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }
    nonisolated static var pastesAtOnce: Bool { UserDefaults.standard.bool(forKey: pasteKey) }
    nonisolated static var hotkeyOn: Bool { UserDefaults.standard.object(forKey: hotkeyKey) as? Bool ?? true }

    struct Nearby: Identifiable {
        let id: String
        var name: String
        var endpoint: NWEndpoint
        var fingerprint: String?
    }

    /// A transfer in progress, shown on the computer's card.
    struct Transfer: Identifiable {
        let id = UUID()
        let peerID: String
        let incoming: Bool
        var done: Int64 = 0
        var total: Int64
        var cancelled = false
        var fraction: Double { total > 0 ? min(Double(done) / Double(total), 1) : 0 }
    }

    private(set) var paired: [SharePeer] = []
    private(set) var nearby: [String: Nearby] = [:]
    private(set) var transfers: [Transfer] = []
    private(set) var listenerError: String?
    /// Computer ids whose pairing was cancelled recently (30 s of `busy`).
    @ObservationIgnored private var cancelledPairings: [String: Date] = [:]
    @ObservationIgnored private var pairingBusy = false
    @ObservationIgnored private var receiving = false

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var clipTimer: Timer?
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var lastChange: Date?
    @ObservationIgnored private let queue = DispatchQueue(label: "local.pulse.share")

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.peersKey),
           let list = try? JSONDecoder().decode([SharePeer].self, from: data) { paired = list }
    }

    // MARK: - On / off

    /// Starts or stops advertising, browsing and the shortcut to match Settings.
    func apply() {
        if Self.isOn {
            if listener == nil { startListener() }
            if browser == nil { startBrowser() }
            if clipTimer == nil {
                clipTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    MainActor.assumeIsolated { ShareCenter.shared.trackClipboard() }
                }
            }
        } else {
            listener?.cancel(); listener = nil
            browser?.cancel(); browser = nil
            clipTimer?.invalidate(); clipTimer = nil
            nearby = [:]
        }
        ShareHotkey.shared.update(Self.isOn && Self.hotkeyOn)
    }

    private func trackClipboard() {
        let count = NSPasteboard.general.changeCount
        if count != lastChangeCount { lastChangeCount = count; lastChange = Date() }
    }

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            let l = try NWListener(using: params)
            var txt = NWTXTRecord()
            txt["id"] = RemoteMacs.installID
            txt["v"] = "1"
            txt["pk"] = ShareKeys.fingerprint(ShareKeys.publicKey)
            l.service = NWListener.Service(name: RemoteMacs.sharedName, type: Self.serviceType, domain: nil, txtRecord: txt)
            l.newConnectionHandler = { connection in
                let conn = ShareConnection(connection)
                Task.detached { await ShareServer.handle(conn) }
            }
            l.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let c = ShareCenter.shared
                            c.listenerError = RemoteMacs.isLocalNetworkDenial(error)
                                ? String(localized: "macOS nie pozwala Pulse korzystać z sieci lokalnej. Włącz Pulse w Ustawieniach systemowych → Prywatność i ochrona → Sieć lokalna.")
                                : error.localizedDescription
                            c.listener?.cancel(); c.listener = nil
                        }
                    }
                }
            }
            l.start(queue: queue)
            listener = l
            listenerError = nil
        } catch {
            listenerError = error.localizedDescription
        }
    }

    private func startBrowser() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        let ownID = RemoteMacs.installID
        b.browseResultsChangedHandler = { results, _ in
            var found: [String: Nearby] = [:]
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint,
                      case .bonjour(let txt) = result.metadata, let id = txt["id"], id != ownID else { continue }
                found[id] = Nearby(id: id, name: name, endpoint: result.endpoint, fingerprint: txt["pk"])
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { ShareCenter.shared.nearby = found } }
        }
        b.start(queue: queue)
        browser = b
    }

    // MARK: - Paired computers

    func peer(_ id: String) -> SharePeer? { paired.first { $0.id == id } }
    func isOnline(_ id: String) -> Bool { nearby[id] != nil }
    var onlinePeers: [SharePeer] {
        let last = UserDefaults.standard.string(forKey: Self.lastPeerKey)
        return paired.filter { isOnline($0.id) }.sorted { a, b in
            if a.id == last { return true }
            if b.id == last { return false }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func store(_ peer: SharePeer) {
        paired.removeAll { $0.id == peer.id }
        paired.append(peer)
        save()
    }

    func remove(_ id: String) {
        paired.removeAll { $0.id == id }
        save()
    }

    func setAutoAccept(_ id: String, _ on: Bool) {
        guard let i = paired.firstIndex(where: { $0.id == id }) else { return }
        paired[i].autoAccept = on
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(paired) { UserDefaults.standard.set(data, forKey: Self.peersKey) }
    }

    fileprivate func pairingAllowed(_ id: String) -> Bool {
        if pairingBusy { return false }
        if let t = cancelledPairings[id], Date().timeIntervalSince(t) < 30 { return false }
        pairingBusy = true
        return true
    }

    fileprivate func pairingEnded(_ id: String, cancelled: Bool) {
        pairingBusy = false
        if cancelled { cancelledPairings[id] = Date() }
    }

    fileprivate func beginReceiving() -> Bool {
        if receiving { return false }
        receiving = true
        return true
    }
    fileprivate func endReceiving() { receiving = false }

    // MARK: - Transfers

    fileprivate func addTransfer(_ t: Transfer) { transfers.append(t) }
    fileprivate func progress(_ id: UUID, _ bytes: Int) {
        if let i = transfers.firstIndex(where: { $0.id == id }) { transfers[i].done += Int64(bytes) }
    }
    fileprivate func finishTransfer(_ id: UUID) { transfers.removeAll { $0.id == id } }
    func cancelTransfer(_ id: UUID) {
        if let i = transfers.firstIndex(where: { $0.id == id }) { transfers[i].cancelled = true }
    }
    fileprivate func isCancelled(_ id: UUID) -> Bool { transfers.first { $0.id == id }?.cancelled ?? true }

    // MARK: - This Mac's clipboard (server side)

    struct ClipContent {
        var kind: String
        var data = Data()
        var mime: String?
        var width = 0, height = 0
    }

    /// What `clip-info` reports: no conversion, sizes are approximate for images.
    fileprivate func clipInfo() -> [String: Any] {
        guard Self.sharesClipboard else { return ["kind": "off", "size": 0, "age": NSNull()] }
        let pb = NSPasteboard.general
        let age: Any = lastChange.map { Int(Date().timeIntervalSince($0)) } ?? NSNull()
        if pb.types?.contains(.fileURL) == true { return ["kind": "empty", "size": 0, "age": age] }
        if let text = pb.string(forType: .string) { return ["kind": "text", "size": Self.lf(text).utf8.count, "age": age] }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) { return ["kind": "image", "size": data.count, "age": age] }
        return ["kind": "empty", "size": 0, "age": age]
    }

    fileprivate func clipContent() -> ClipContent {
        guard Self.sharesClipboard else { return ClipContent(kind: "off") }
        let pb = NSPasteboard.general
        if pb.types?.contains(.fileURL) == true { return ClipContent(kind: "empty") }
        if let text = pb.string(forType: .string) {
            return ClipContent(kind: "text", data: Data(Self.lf(text).utf8), mime: "text/plain;charset=utf-8")
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: data),
           let png = pb.data(forType: .png) ?? rep.representation(using: .png, properties: [:]) {
            return ClipContent(kind: "image", data: png, mime: "image/png", width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return ClipContent(kind: "empty")
    }

    nonisolated static func lf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Taking the clipboard from another computer

    /// The shortcut: one computer → fetch at once; more → a menu at the pointer.
    func takeClipboard() {
        let online = onlinePeers
        if online.isEmpty {
            Alerts.shared.send(title: String(localized: "Schowek"),
                               body: paired.isEmpty ? String(localized: "Najpierw sparuj inny komputer w Ustawieniach → Inne komputery.")
                                                    : String(localized: "Żaden sparowany komputer nie jest teraz w sieci."),
                               id: "share.none")
            return
        }
        if online.count == 1 { fetchClipboard(from: online[0]); return }
        Task {
            let infos = await withTaskGroup(of: (String, [String: Any]?).self) { group in
                for peer in online {
                    group.addTask { (peer.id, try? await ShareClient.clipInfo(peer)) }
                }
                var result: [String: [String: Any]] = [:]
                for await (id, info) in group { if let info { result[id] = info } }
                return result
            }
            DispatchQueue.main.async { ShareMenus.chooser(peers: online, infos: infos).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
        }
    }

    func fetchClipboard(from peer: SharePeer) {
        UserDefaults.standard.set(peer.id, forKey: Self.lastPeerKey)
        Task {
            do {
                let clip = try await ShareClient.clipGet(peer)
                let pb = NSPasteboard.general
                let body: String
                switch clip.kind {
                case "text":
                    let text = String(decoding: clip.data, as: UTF8.self)
                    pb.clearContents(); pb.setString(text, forType: .string)
                    body = String(localized: "tekst, \(text.count) zn.")
                case "image":
                    pb.clearContents()
                    pb.setData(clip.data, forType: .png)
                    if let tiff = NSImage(data: clip.data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
                    body = String(localized: "obraz \(clip.width)×\(clip.height)")
                case "off":
                    Alerts.shared.send(title: peer.name, body: String(localized: "Ten komputer nie udostępnia swojego schowka."), id: "share.clip")
                    return
                default:
                    Alerts.shared.send(title: peer.name, body: String(localized: "Schowek na tym komputerze jest pusty albo zawiera coś, czego nie da się przesłać."), id: "share.clip")
                    return
                }
                lastChangeCount = pb.changeCount
                Alerts.shared.send(title: String(localized: "Schowek z \(peer.name)"), body: body, id: "share.clip")
                if Self.pastesAtOnce { ShareMenus.pasteNow() }
            } catch {
                Alerts.shared.send(title: peer.name, body: ShareClient.describe(error), id: "share.clip")
            }
        }
    }

    // MARK: - Sending files

    func send(_ urls: [URL], to peer: SharePeer) {
        Task.detached {
            do {
                try await ShareClient.sendFiles(urls, to: peer)
            } catch {
                await MainActor.run { Alerts.shared.send(title: peer.name, body: ShareClient.describe(error), id: "share.files") }
            }
        }
    }

    // MARK: - Pairing (client side)

    func pair(with nearby: Nearby) {
        Task.detached {
            do {
                let name = try await ShareClient.pair(nearby)
                await MainActor.run { Alerts.shared.send(title: String(localized: "Sparowano"), body: String(localized: "Możesz pobierać schowek z \(name) i wysyłać tam pliki."), id: "share.pair") }
            } catch ShareError.remote("declined") {
                // The other side said no: nothing to add.
            } catch {
                await MainActor.run { Alerts.shared.send(title: nearby.name, body: ShareClient.describe(error), id: "share.pair") }
            }
        }
    }

    func applyDemo() {
        let ids = RemoteMacs.shared.peers.map(\.id)
        paired = ids.prefix(2).enumerated().map { i, id in
            SharePeer(id: id, name: RemoteMacs.shared.peers[i].report.name, key: Data(), platform: "macos", autoAccept: i == 1)
        }
        for p in paired { nearby[p.id] = Nearby(id: p.id, name: p.name, endpoint: .hostPort(host: "127.0.0.1", port: 9), fingerprint: nil) }
        if let first = paired.first { transfers = [Transfer(peerID: first.id, incoming: false, done: 420_000_000, total: 1_200_000_000)] }
    }
}

// MARK: - Server

enum ShareServer {
    static func handle(_ conn: ShareConnection) async {
        defer { conn.close() }
        do {
            try await conn.start()
            let hello = try await conn.readPlain()
            guard hello["hello"] as? String == "pulse-share", let id = hello["id"] as? String else { return }
            guard await MainActor.run(body: { ShareCenter.isOn }) else { try await conn.sendPlain(["error": "off"]); return }
            switch hello["mode"] as? String {
            case "pair": try await pair(conn, hello: hello, id: id)
            case "session": try await session(conn, hello: hello, id: id)
            default: try await conn.sendPlain(["error": "bad-request"])
            }
        } catch {
            // A dropped or refused connection needs no message on this side.
        }
    }

    private static func pair(_ conn: ShareConnection, hello: [String: Any], id: String) async throws {
        guard let keyB64 = hello["key"] as? String, let pkC = Data(base64Encoded: keyB64), pkC.count == 65,
              (try? P256.KeyAgreement.PublicKey(x963Representation: pkC)) != nil else {
            try await conn.sendPlain(["error": "bad-request"]); return
        }
        let name = String((hello["name"] as? String ?? "?").prefix(63))
        guard await MainActor.run(body: { ShareCenter.shared.pairingAllowed(id) }) else {
            try await conn.sendPlain(["error": "busy"]); return
        }
        var confirmed = false
        defer { let ok = confirmed; Task { @MainActor in ShareCenter.shared.pairingEnded(id, cancelled: !ok) } }
        let pkS = ShareKeys.publicKey
        let nS = ShareKeys.random(32)
        let myName = await MainActor.run { RemoteMacs.sharedName }
        try await conn.sendPlain(["id": RemoteMacs.installIDValue, "name": myName, "platform": "macos",
                                  "key": pkS.base64EncodedString(),
                                  "commit": ShareKeys.commitment(pkS: pkS, pkC: pkC, nS: nS).base64EncodedString()])
        let msg = try await conn.readPlain()
        guard let nC = (msg["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }), nC.count == 32 else { return }
        try await conn.sendPlain(["nonce": nS.base64EncodedString()])
        let code = ShareKeys.pairingCode(pkC: pkC, pkS: pkS, nC: nC, nS: nS)
        let prompt = await SharePrompt.show(
            title: String(localized: "Parowanie z \(name)"),
            message: String(localized: "Sprawdź, czy na obu komputerach widać ten sam kod. Po sparowaniu \(name) może pobierać Twój schowek (jeśli na to pozwalasz) i wysyłać Ci pliki."),
            code: code, ok: String(localized: "Paruj"), cancel: String(localized: "Anuluj"), timeout: 120)
        let mine = await prompt.result()
        try await conn.sendPlain(["confirmed": mine])
        guard mine else { return }
        let theirs = try await conn.readPlain(timeout: 130)
        guard theirs["confirmed"] as? Bool == true else { return }
        let peer = SharePeer(id: id, name: name, key: pkC, platform: hello["platform"] as? String)
        await MainActor.run {
            ShareCenter.shared.store(peer)
            Alerts.shared.send(title: String(localized: "Sparowano"), body: String(localized: "\(name) może teraz pobierać Twój schowek i wysyłać Ci pliki."), id: "share.pair")
        }
        confirmed = true
    }

    private static func session(_ conn: ShareConnection, hello: [String: Any], id: String) async throws {
        guard let peer = await MainActor.run(body: { ShareCenter.shared.peer(id) }) else {
            try await conn.sendPlain(["error": "not-paired"]); return
        }
        guard let nC = (hello["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }), nC.count == 32 else {
            try await conn.sendPlain(["error": "bad-request"]); return
        }
        let nS = ShareKeys.random(32)
        try await conn.sendPlain(["nonce": nS.base64EncodedString()])
        let keys = try ShareKeys.sessionKeys(peerKey: peer.key, nC: nC, nS: nS)
        conn.setKeys(send: keys.s2c, receive: keys.c2s)
        let request = try await conn.readJSON()
        switch request["op"] as? String {
        case "hello":
            let name = await MainActor.run { RemoteMacs.sharedName }
            try await conn.sendJSON(["name": name, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                                     "platform": "macos", "clip": ShareCenter.sharesClipboard, "files": ShareCenter.acceptsFiles])
        case "clip-info":
            let info = await MainActor.run { ShareCenter.shared.clipInfo() }
            try await conn.sendJSON(info)
        case "clip-get":
            try await clipGet(conn, peer: peer)
        case "files-offer":
            try await ShareReceiver.receive(conn, offer: request, from: peer)
        default:
            try await conn.sendJSON(["error": "unsupported"])
        }
    }

    private static func clipGet(_ conn: ShareConnection, peer: SharePeer) async throws {
        let clip = await MainActor.run { ShareCenter.shared.clipContent() }
        guard clip.kind == "text" || clip.kind == "image" else {
            try await conn.sendJSON(["kind": clip.kind, "size": 0]); return
        }
        guard clip.data.count <= ShareCenter.clipLimit else {
            try await conn.sendJSON(["kind": "empty", "reason": "too-large", "size": clip.data.count]); return
        }
        var header: [String: Any] = ["kind": clip.kind, "size": clip.data.count, "mime": clip.mime ?? ""]
        if clip.kind == "image" { header["width"] = clip.width; header["height"] = clip.height }
        try await conn.sendJSON(header)
        try await conn.sendStream(clip.data)
        if await MainActor.run(body: { ShareCenter.notifiesTaken }) {
            await MainActor.run {
                Alerts.shared.send(title: String(localized: "Schowek"), body: String(localized: "\(peer.name) pobrał schowek z tego Maca."), id: "share.taken")
            }
        }
    }
}

// MARK: - Receiving files

enum ShareReceiver {
    struct Item { let parts: [String]; let size: Int64 }

    static func receive(_ conn: ShareConnection, offer: [String: Any], from peer: SharePeer) async throws {
        guard ShareCenter.acceptsFiles else { try await conn.sendJSON(["accept": false, "reason": "off"]); return }
        guard let list = offer["files"] as? [[String: Any]], !list.isEmpty, list.count <= 10_000 else {
            try await conn.sendJSON(["error": "bad-request"]); return
        }
        var items: [Item] = []
        for entry in list {
            guard let path = entry["path"] as? String, let parts = SharePaths.components(path),
                  let size = (entry["size"] as? NSNumber)?.int64Value, size >= 0 else {
                try await conn.sendJSON(["error": "bad-request"]); return
            }
            items.append(Item(parts: parts, size: size))
        }
        let total = items.reduce(0) { $0 + $1.size }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let free = (try? downloads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if let free, free < total + 100_000_000 { try await conn.sendJSON(["accept": false, "reason": "space"]); return }
        guard await MainActor.run(body: { ShareCenter.shared.beginReceiving() }) else {
            try await conn.sendJSON(["accept": false, "reason": "busy"]); return
        }
        defer { Task { @MainActor in ShareCenter.shared.endReceiving() } }

        if !peer.autoAccept {
            let what = items.count == 1 ? items[0].parts.joined(separator: "/")
                : String(localized: "Pliki: \(items.count)")
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            let prompt = await SharePrompt.show(
                title: String(localized: "\(peer.name) chce wysłać pliki"),
                message: String(localized: "\(what) (\(size)). Pliki trafią do folderu Pobrane."),
                code: nil, ok: String(localized: "Przyjmij"), cancel: String(localized: "Odrzuć"), timeout: 115)
            guard await prompt.result() else {
                let timedOut = await prompt.timedOut
                try await conn.sendJSON(["accept": false, "reason": timedOut ? "timeout" : "declined"]); return
            }
        }
        try await conn.sendJSON(["accept": true])

        let transfer = ShareCenter.Transfer(peerID: peer.id, incoming: true, total: total)
        await MainActor.run { ShareCenter.shared.addTransfer(transfer) }
        defer { Task { @MainActor in ShareCenter.shared.finishTransfer(transfer.id) } }

        // Every top-level item goes straight into Downloads; a taken name gets " (2)".
        var tops: [String: String] = [:]
        var created: [URL] = []
        var partials: [URL] = []
        do {
            for (index, item) in items.enumerated() {
                let header = try await conn.readJSON()
                guard header["file"] as? Int == index else { throw ShareError.badFrame }
                let top = item.parts[0]
                let topName: String
                if let t = tops[top] { topName = t } else {
                    topName = SharePaths.free(top, in: downloads)
                    tops[top] = topName
                    created.append(downloads.appendingPathComponent(topName))
                }
                var target = downloads.appendingPathComponent(topName)
                for p in item.parts.dropFirst() { target.appendPathComponent(p) }
                // Never outside Downloads, whatever the names resolve to.
                guard target.standardizedFileURL.path.hasPrefix(downloads.standardizedFileURL.path + "/") else { throw ShareError.badFrame }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let part = target.appendingPathExtension("pulse-part")
                FileManager.default.createFile(atPath: part.path, contents: nil)
                partials.append(part)
                let handle = try FileHandle(forWritingTo: part)
                let written: Int
                do {
                    written = try await conn.receiveStream(limit: Int(item.size)) { chunk in
                        try handle.write(contentsOf: chunk)
                        Task { @MainActor in ShareCenter.shared.progress(transfer.id, chunk.count) }
                    }
                    try handle.close()
                } catch { try? handle.close(); throw error }
                guard written == Int(item.size) else { throw ShareError.badFrame }
                let final = item.parts.count == 1 ? target
                    : target.deletingLastPathComponent().appendingPathComponent(SharePaths.free(target.lastPathComponent, in: target.deletingLastPathComponent()))
                try FileManager.default.moveItem(at: part, to: final)
                partials.removeLast()
            }
            try await conn.sendJSON(["ok": true])
        } catch {
            for p in partials { try? FileManager.default.removeItem(at: p) }
            try? await conn.sendJSON(["ok": false, "reason": "error"])
            await MainActor.run {
                Alerts.shared.send(title: peer.name, body: String(localized: "Przesyłanie plików przerwane."), id: "share.files")
            }
            throw error
        }
        let first = created.first
        let what = items.count == 1 ? items[0].parts.last ?? "" : String(localized: "Pliki: \(items.count)")
        await MainActor.run {
            Alerts.shared.send(title: String(localized: "Zapisano w Pobranych"),
                               body: String(localized: "Od \(peer.name): \(what)"),
                               id: "share.files", file: first)
        }
    }
}

// MARK: - Client

enum ShareClient {
    struct Clip { var kind: String; var data = Data(); var width = 0; var height = 0 }

    static func describe(_ error: Error) -> String {
        switch error {
        case ShareError.remote("off"): String(localized: "Na tamtym komputerze opcja „Schowek i pliki” jest wyłączona.")
        case ShareError.remote("not-paired"): String(localized: "Tamten komputer nie zna już tego Maca. Sparuj je ponownie.")
        case ShareError.remote("busy"): String(localized: "Tamten komputer jest zajęty. Spróbuj za chwilę.")
        case ShareError.remote("declined"): String(localized: "Odrzucono.")
        case ShareError.remote("space"): String(localized: "Na tamtym komputerze brakuje miejsca.")
        case ShareError.remote("timeout"): String(localized: "Nikt nie odpowiedział na tamtym komputerze.")
        case ShareError.tooLarge: String(localized: "Za dużo danych.")
        case ShareError.hash, ShareError.decrypt: String(localized: "Dane nie przeszły kontroli. Spróbuj ponownie.")
        case ShareError.offline: String(localized: "Ten komputer nie jest teraz w sieci.")
        default: String(localized: "Połączenie się nie udało.")
        }
    }

    /// Connects and runs the session handshake; the connection is ready for one encrypted request.
    static func session(_ peer: SharePeer) async throws -> ShareConnection {
        guard let endpoint = await MainActor.run(body: { ShareCenter.shared.nearby[peer.id]?.endpoint }) else { throw ShareError.offline }
        let conn = ShareConnection(endpoint: endpoint)
        do {
            try await conn.start()
            let nC = ShareKeys.random(32)
            try await conn.sendPlain(["hello": "pulse-share", "v": 1, "mode": "session", "id": RemoteMacs.installIDValue,
                                      "nonce": nC.base64EncodedString()])
            let reply = try await conn.readPlain()
            guard let nS = (reply["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }), nS.count == 32 else { throw ShareError.badFrame }
            let keys = try ShareKeys.sessionKeys(peerKey: peer.key, nC: nC, nS: nS)
            conn.setKeys(send: keys.c2s, receive: keys.s2c)
            return conn
        } catch { conn.close(); throw error }
    }

    static func clipInfo(_ peer: SharePeer) async throws -> [String: Any] {
        let conn = try await session(peer)
        defer { conn.close() }
        try await conn.sendJSON(["op": "clip-info"])
        return try await conn.readJSON(timeout: 3)
    }

    static func clipGet(_ peer: SharePeer) async throws -> Clip {
        let conn = try await session(peer)
        defer { conn.close() }
        try await conn.sendJSON(["op": "clip-get"])
        let header = try await conn.readJSON()
        let kind = header["kind"] as? String ?? "empty"
        guard kind == "text" || kind == "image" else { return Clip(kind: kind) }
        var data = Data()
        _ = try await conn.receiveStream(limit: ShareCenter.clipLimit) { data.append($0) }
        return Clip(kind: kind, data: data, width: header["width"] as? Int ?? 0, height: header["height"] as? Int ?? 0)
    }

    /// Files and folders → relative paths ("/" separators); folders keep their tree, links are skipped.
    static func collect(_ urls: [URL]) -> [(url: URL, path: String, size: Int64)] {
        var result: [(URL, String, Int64)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                let base = url.deletingLastPathComponent().path
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
                while let item = walker?.nextObject() as? URL {
                    let v = try? item.resourceValues(forKeys: Set(keys))
                    guard v?.isRegularFile == true, v?.isSymbolicLink != true else { continue }
                    let rel = String(item.path.dropFirst(base.count + 1))
                    result.append((item, rel, Int64(v?.fileSize ?? 0)))
                }
            } else if values?.isRegularFile == true {
                result.append((url, url.lastPathComponent, Int64(values?.fileSize ?? 0)))
            }
        }
        return Array(result.prefix(10_000))
    }

    static func sendFiles(_ urls: [URL], to peer: SharePeer) async throws {
        let files = collect(urls)
        guard !files.isEmpty else { return }
        let total = files.reduce(0) { $0 + $1.size }
        let conn = try await session(peer)
        defer { conn.close() }
        try await conn.sendJSON(["op": "files-offer", "total": total,
                                 "files": files.map { ["path": $0.path, "size": $0.size] }])
        let answer = try await conn.readJSON(timeout: 130)
        guard answer["accept"] as? Bool == true else { throw ShareError.remote(answer["reason"] as? String ?? "declined") }
        let transfer = ShareCenter.Transfer(peerID: peer.id, incoming: false, total: total)
        await MainActor.run { ShareCenter.shared.addTransfer(transfer) }
        defer { Task { @MainActor in ShareCenter.shared.finishTransfer(transfer.id) } }
        for (index, file) in files.enumerated() {
            try await conn.sendJSON(["file": index])
            // The size announced in the offer is what the receiver checks.
            try await conn.sendFile(file.url, progress: { n in
                Task { @MainActor in ShareCenter.shared.progress(transfer.id, n) }
            }, cancelled: { DispatchQueue.main.sync { MainActor.assumeIsolated { ShareCenter.shared.isCancelled(transfer.id) } } })
        }
        let result = try await conn.readJSON(timeout: 30)
        guard result["ok"] as? Bool == true else { throw ShareError.remote(result["reason"] as? String ?? "error") }
        await MainActor.run {
            Alerts.shared.send(title: String(localized: "Wysłano"),
                               body: String(localized: "\(files.count == 1 ? files[0].path : String(localized: "Pliki: \(files.count)")) → \(peer.name)"),
                               id: "share.files")
        }
    }

    /// Pairing as the client. Returns the other computer's name.
    static func pair(_ nearby: ShareCenter.Nearby) async throws -> String {
        let conn = ShareConnection(endpoint: nearby.endpoint)
        defer { conn.close() }
        try await conn.start()
        let pkC = ShareKeys.publicKey
        let myName = await MainActor.run { RemoteMacs.sharedName }
        try await conn.sendPlain(["hello": "pulse-share", "v": 1, "mode": "pair", "id": RemoteMacs.installIDValue,
                                  "name": myName, "platform": "macos", "key": pkC.base64EncodedString()])
        let server = try await conn.readPlain()
        guard let pkS = (server["key"] as? String).flatMap({ Data(base64Encoded: $0) }), pkS.count == 65,
              (try? P256.KeyAgreement.PublicKey(x963Representation: pkS)) != nil,
              let commit = (server["commit"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let id = server["id"] as? String else { throw ShareError.badFrame }
        let name = String((server["name"] as? String ?? nearby.name).prefix(63))
        let nC = ShareKeys.random(32)
        try await conn.sendPlain(["nonce": nC.base64EncodedString()])
        let reply = try await conn.readPlain()
        guard let nS = (reply["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }), nS.count == 32,
              ShareKeys.commitment(pkS: pkS, pkC: pkC, nS: nS) == commit else { throw ShareError.badFrame }
        let code = ShareKeys.pairingCode(pkC: pkC, pkS: pkS, nC: nC, nS: nS)
        let prompt = await SharePrompt.show(
            title: String(localized: "Parowanie z \(name)"),
            message: String(localized: "Sprawdź, czy na obu komputerach widać ten sam kod, i potwierdź na obu."),
            code: code, ok: String(localized: "Paruj"), cancel: String(localized: "Anuluj"), timeout: 120)
        // The server answers first; a "no" there closes this prompt too.
        let theirsTask = Task { try await conn.readPlain(timeout: 130) }
        let watcher = Task {
            if let theirs = try? await theirsTask.value, theirs["confirmed"] as? Bool != true { await prompt.dismiss() }
        }
        let mine = await prompt.result()
        let theirs = try await theirsTask.value
        watcher.cancel()
        let serverOK = theirs["confirmed"] as? Bool == true
        try await conn.sendPlain(["confirmed": mine && serverOK])
        guard serverOK else { throw ShareError.remote("declined") }
        guard mine else { throw ShareError.remote("declined") }
        let peer = SharePeer(id: id, name: name, key: pkS, platform: server["platform"] as? String)
        await MainActor.run { ShareCenter.shared.store(peer) }
        return name
    }
}

extension RemoteMacs {
    /// The install id, readable off the main actor.
    nonisolated static var installIDValue: String {
        UserDefaults.standard.string(forKey: "remote.id") ?? ""
    }
}
