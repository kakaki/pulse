import AppKit
import CryptoKit
import Foundation
import ImageIO
import Network
import os

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
    nonisolated static let askClipKey = "share.askClip"
    private static let peersKey = "share.peers"
    private static let lastPeerKey = "share.lastPeer"

    nonisolated static var isOn: Bool { UserDefaults.standard.bool(forKey: onKey) }
    nonisolated static var sharesClipboard: Bool { UserDefaults.standard.object(forKey: clipKey) as? Bool ?? true }
    nonisolated static var acceptsFiles: Bool { UserDefaults.standard.object(forKey: filesKey) as? Bool ?? true }
    nonisolated static var notifiesTaken: Bool { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }
    nonisolated static var pastesAtOnce: Bool { UserDefaults.standard.bool(forKey: pasteKey) }
    nonisolated static var hotkeyOn: Bool { UserDefaults.standard.object(forKey: hotkeyKey) as? Bool ?? true }
    /// Ask on this Mac before another computer takes its clipboard (on unless turned off).
    nonisolated static var asksClip: Bool { UserDefaults.standard.object(forKey: askClipKey) as? Bool ?? true }

    /// Install ids are UUIDs; anything else is refused before it can reach a prompt or a table.
    nonisolated static func validID(_ s: String) -> Bool {
        (1...64).contains(s.utf8.count) && s.utf8.allSatisfy { $0 == 0x2D || (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
    }

    struct Nearby: Identifiable {
        let id: String
        var name: String
        var endpoint: NWEndpoint
        var fingerprint: String?
        /// A paired id advertising a different key: reinstalled, or someone else using that id.
        var keyChanged = false
    }

    /// A transfer in progress, shown on the computer's card.
    struct Transfer: Identifiable {
        let id = UUID()
        let peerID: String
        let incoming: Bool
        var done: Int64 = 0
        var total: Int64
        var cancelled = false
        /// Closed by Cancel, so a stalled read or write ends at once.
        var conn: ShareConnection?
        var fraction: Double { total > 0 ? min(Double(done) / Double(total), 1) : 0 }
    }

    private(set) var paired: [SharePeer] = []
    private(set) var nearby: [String: Nearby] = [:]
    private(set) var transfers: [Transfer] = []
    private(set) var listenerError: String?
    /// Computer ids whose pairing was cancelled recently (30 s of `busy`).
    @ObservationIgnored private var cancelledPairings: [String: Date] = [:]
    @ObservationIgnored private var lastCancelledPairing: Date?
    @ObservationIgnored private var pairingBusy = false
    @ObservationIgnored private var receiving = false
    @ObservationIgnored private var clipPromptOpen = false
    /// Every advertisement per id, before choosing the one whose key matches.
    @ObservationIgnored private var advertised: [String: [Nearby]] = [:]

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
            nearby = [:]; advertised = [:]
            // Nothing keeps going once the option is off: open sessions and open questions end here.
            ShareRegistry.shared.close()
            SharePrompt.dismissAll()
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
                guard ShareRegistry.shared.admit(conn, incoming: true) else { connection.cancel(); return }
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
            var found: [String: [Nearby]] = [:]
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint,
                      case .bonjour(let txt) = result.metadata, let id = txt["id"], id != ownID, ShareCenter.validID(id),
                      txt["v"] == nil || txt["v"] == "1" else { continue }
                found[id, default: []].append(Nearby(id: id, name: name, endpoint: result.endpoint, fingerprint: txt["pk"]?.lowercased()))
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { ShareCenter.shared.advertised = found; ShareCenter.shared.refreshNearby() } }
        }
        b.start(queue: queue)
        browser = b
    }

    // MARK: - Paired computers

    func peer(_ id: String) -> SharePeer? { paired.first { $0.id == id } }
    /// Online means advertising the key this Mac paired with; a different key is never used.
    func isOnline(_ id: String) -> Bool { nearby[id].map { !$0.keyChanged } ?? false }

    /// For a paired id prefers the advertisement whose `pk` matches the stored key.
    private func refreshNearby() {
        var result: [String: Nearby] = [:]
        for (id, list) in advertised {
            guard var pick = list.first else { continue }
            if let peer = peer(id) {
                let fp = ShareKeys.fingerprint(peer.key)
                if let match = list.first(where: { $0.fingerprint == fp }) ?? list.first(where: { $0.fingerprint == nil }) {
                    pick = match
                } else {
                    pick.keyChanged = true
                }
            }
            result[id] = pick
        }
        nearby = result
    }
    var onlinePeers: [SharePeer] {
        let last = UserDefaults.standard.string(forKey: Self.lastPeerKey)
        return paired.filter { isOnline($0.id) }.sorted { a, b in
            if a.id == last { return true }
            if b.id == last { return false }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func store(_ peer: SharePeer) {
        // A new key for a known id: sessions opened with the old one end here.
        if let old = self.peer(peer.id), old.key != peer.key { ShareRegistry.shared.close(peer: peer.id) }
        paired.removeAll { $0.id == peer.id }
        paired.append(peer)
        save()
        refreshNearby()
    }

    func remove(_ id: String) {
        paired.removeAll { $0.id == id }
        save()
        refreshNearby()
        // A session opened before the removal must not finish after it.
        ShareRegistry.shared.close(peer: id)
    }

    func setAllowClip(_ id: String, _ on: Bool) {
        guard let i = paired.firstIndex(where: { $0.id == id }) else { return }
        paired[i].allowClip = on
        save()
    }

    /// Whether a session with this key may still act: option on and the computer still paired with that key.
    fileprivate func stillTrusted(_ id: String, key: Data) -> Bool {
        Self.isOn && peer(id)?.key == key
    }

    func setAutoAccept(_ id: String, _ on: Bool) {
        guard let i = paired.firstIndex(where: { $0.id == id }) else { return }
        paired[i].autoAccept = on
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(paired) { UserDefaults.standard.set(data, forKey: Self.peersKey) }
    }

    /// One pairing at a time, 30 s per id after a cancel, and 10 s for anyone after any cancel,
    /// so changing the id does not reopen the question again and again.
    fileprivate func pairingAllowed(_ id: String) -> Bool {
        let now = Date()
        cancelledPairings = cancelledPairings.filter { now.timeIntervalSince($0.value) < 30 }
        if pairingBusy { return false }
        if cancelledPairings[id] != nil { return false }
        if let t = lastCancelledPairing, now.timeIntervalSince(t) < 10 { return false }
        pairingBusy = true
        return true
    }

    fileprivate func pairingEnded(_ id: String, cancelled: Bool) {
        pairingBusy = false
        if cancelled {
            cancelledPairings[id] = Date()
            lastCancelledPairing = Date()
        }
    }

    fileprivate func beginClipPrompt() -> Bool {
        if clipPromptOpen { return false }
        clipPromptOpen = true
        return true
    }
    fileprivate func endClipPrompt() { clipPromptOpen = false }

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
        if let i = transfers.firstIndex(where: { $0.id == id }) {
            transfers[i].cancelled = true
            transfers[i].conn?.close()
        }
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
    fileprivate func clipInfo(for peer: SharePeer) -> [String: Any] {
        guard Self.sharesClipboard else { return ["kind": "off", "size": 0, "age": NSNull(), "ask": false] }
        let pb = NSPasteboard.general
        let age: Any = lastChange.map { Int(Date().timeIntervalSince($0)) } ?? NSNull()
        let ask = asks(peer)
        if pb.types?.contains(.fileURL) == true { return ["kind": "empty", "size": 0, "age": age, "ask": ask] }
        if let text = pb.string(forType: .string) { return ["kind": "text", "size": Self.lf(text).utf8.count, "age": age, "ask": ask] }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) { return ["kind": "image", "size": data.count, "age": age, "ask": ask] }
        return ["kind": "empty", "size": 0, "age": age, "ask": ask]
    }

    /// Whether this computer has to ask before taking the clipboard.
    fileprivate func asks(_ peer: SharePeer) -> Bool {
        Self.asksClip && !(self.peer(peer.id)?.allowClip ?? false)
    }

    fileprivate func clipContent() -> ClipContent {
        guard Self.sharesClipboard else { return ClipContent(kind: "off") }
        let pb = NSPasteboard.general
        if pb.types?.contains(.fileURL) == true { return ClipContent(kind: "empty") }
        if let text = pb.string(forType: .string) {
            return ClipContent(kind: "text", data: Data(Self.lf(text).utf8), mime: "text/plain;charset=utf-8")
        }
        // Raw image data only: decoding and PNG conversion happen off the main actor, after size checks.
        if let png = pb.data(forType: .png) { return ClipContent(kind: "image", data: png, mime: "image/png") }
        if let tiff = pb.data(forType: .tiff) { return ClipContent(kind: "image", data: tiff, mime: "image/tiff") }
        return ClipContent(kind: "empty")
    }

    /// Size from the image header, PNG made from other formats; nil (too large) before any decoding
    /// of an image bigger than the limits.
    nonisolated static func preparedImage(_ clip: ClipContent) -> ClipContent? {
        guard clip.data.count <= 200_000_000,
              let source = CGImageSourceCreateWithData(clip.data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 65_535, h <= 65_535, w * h <= 150_000_000 else { return nil }
        var result = clip
        result.width = w; result.height = h
        if clip.mime != "image/png" {
            guard let png = NSBitmapImageRep(data: clip.data)?.representation(using: .png, properties: [:]) else { return nil }
            result.data = png; result.mime = "image/png"
        }
        return result
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
        // The result gets a fresh banner: an update of a notification that is already shown stays silent.
        func notify(_ title: String, _ body: String) {
            Alerts.shared.withdraw("share.wait")
            Alerts.shared.withdraw("share.clip")
            Alerts.shared.send(title: title, body: body, id: "share.clip")
        }
        Task {
            // When the other side asks its user first, say so instead of looking frozen.
            let waiting = Task {
                try await Task.sleep(for: .seconds(1.5))
                Alerts.shared.send(title: peer.name, body: String(localized: "Czekam na zgodę na \(peer.name)…"), id: "share.wait")
            }
            defer { waiting.cancel(); Alerts.shared.withdraw("share.wait") }
            do {
                let clip = try await ShareClient.clipGet(peer)
                waiting.cancel()
                let body: String
                switch clip.kind {
                case "text":
                    // Checked before the clipboard is touched, so a bad answer leaves it as it was.
                    guard let text = String(data: clip.data, encoding: .utf8) else { throw ShareError.badFrame }
                    let pb = NSPasteboard.general
                    pb.clearContents(); pb.setString(text, forType: .string)
                    body = String(localized: "tekst, \(text.count) zn.")
                case "image":
                    guard let size = ShareClient.pngSize(clip.data) else { throw ShareError.badFrame }
                    let png = clip.data
                    // TIFF for apps that do not read PNG, made off the main actor and only for sane sizes.
                    let tiff: Data? = size.width * size.height <= 40_000_000
                        ? await Task.detached { NSBitmapImageRep(data: png)?.tiffRepresentation }.value : nil
                    guard Self.isOn else { return }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setData(png, forType: .png)
                    if let tiff { pb.setData(tiff, forType: .tiff) }
                    body = String(localized: "obraz \(size.width)×\(size.height)")
                case "off":
                    notify(peer.name, String(localized: "Ten komputer nie udostępnia swojego schowka."))
                    return
                default:
                    notify(peer.name, String(localized: "Schowek na tym komputerze jest pusty albo zawiera coś, czego nie da się przesłać."))
                    return
                }
                lastChangeCount = NSPasteboard.general.changeCount
                notify(String(localized: "Schowek z \(peer.name)"), body)
                if Self.pastesAtOnce { ShareMenus.pasteNow() }
            } catch {
                waiting.cancel()
                shareLog.info("clip-get from \(peer.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                notify(peer.name, ShareClient.describe(error, clipboard: true))
            }
        }
    }

    // MARK: - Sending files

    func send(_ urls: [URL], to peer: SharePeer) {
        Task.detached {
            do {
                try await ShareClient.sendFiles(urls, to: peer)
            } catch ShareError.cancelled {
                // Cancelled here with ✕: nothing to say.
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

/// `log stream --predicate 'subsystem == "local.pulse.share"'` shows what the share server did (no content).
let shareLog = Logger(subsystem: "local.pulse.share", category: "share")

enum ShareServer {
    static func handle(_ conn: ShareConnection) async {
        let remote = "\(conn.connection.endpoint)"
        shareLog.info("connection from \(remote, privacy: .public)")
        defer { conn.close(); ShareRegistry.shared.remove(conn); shareLog.info("closed \(remote, privacy: .public)") }
        do {
            try await conn.start()
            // The first message comes at once; a silent connection does not keep a slot.
            let hello = try await conn.readPlain(timeout: 5)
            guard hello["hello"] as? String == "pulse-share", let id = hello["id"] as? String, ShareCenter.validID(id) else {
                try await conn.sendPlain(["error": "bad-request"]); return
            }
            guard ShareJSON.int(hello["v"]) == 1 else { try await conn.sendPlain(["error": "unsupported"]); return }
            guard await MainActor.run(body: { ShareCenter.isOn }) else { try await conn.sendPlain(["error": "off"]); return }
            switch hello["mode"] as? String {
            case "pair": try await pair(conn, hello: hello, id: id)
            case "session": try await session(conn, hello: hello, id: id)
            default: try await conn.sendPlain(["error": "bad-request"])
            }
        } catch {
            // A dropped or refused connection needs no message on this side.
            shareLog.info("ended with \(String(describing: error), privacy: .public)")
        }
    }

    private static func pair(_ conn: ShareConnection, hello: [String: Any], id: String) async throws {
        guard let keyB64 = hello["key"] as? String, let pkC = Data(base64Encoded: keyB64), pkC.count == 65,
              (try? P256.KeyAgreement.PublicKey(x963Representation: pkC)) != nil else {
            try await conn.sendPlain(["error": "bad-request"]); return
        }
        // A key that is not saved would be gone after a restart, and the pairing with it.
        guard ShareKeys.isPersistent else { try await conn.sendPlain(["error": "busy"]); return }
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
        // The client sends nothing until this side answers, so a close now means it gave up.
        conn.watchForClose { Task { @MainActor in prompt.dismiss() } }
        let mine = await prompt.result()
        try await conn.sendPlain(["confirmed": mine])
        guard mine else { return }
        let theirs = try await conn.readPlain(timeout: 130)
        guard ShareJSON.bool(theirs["confirmed"]) == true else { return }
        let peer = SharePeer(id: id, name: name, key: pkC, platform: hello["platform"] as? String)
        // The option may have been turned off while the question was open.
        let stored = await MainActor.run { () -> Bool in
            guard ShareCenter.isOn else { return false }
            ShareCenter.shared.store(peer)
            Alerts.shared.send(title: String(localized: "Sparowano"), body: String(localized: "\(name) może teraz pobierać Twój schowek i wysyłać Ci pliki."), id: "share.pair")
            return true
        }
        confirmed = stored
    }

    private static func session(_ conn: ShareConnection, hello: [String: Any], id: String) async throws {
        guard let peer = await MainActor.run(body: { ShareCenter.shared.peer(id) }) else {
            try await conn.sendPlain(["error": "not-paired"]); return
        }
        guard let nC = (hello["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }), nC.count == 32 else {
            try await conn.sendPlain(["error": "bad-request"]); return
        }
        ShareRegistry.shared.bind(conn, to: id)
        let nS = ShareKeys.random(32)
        try await conn.sendPlain(["nonce": nS.base64EncodedString()])
        let keys = try ShareKeys.sessionKeys(peerKey: peer.key, nC: nC, nS: nS)
        conn.setKeys(send: keys.s2c, receive: keys.c2s)
        let request = try await conn.readJSON()
        shareLog.info("\(peer.name, privacy: .public): \(request["op"] as? String ?? "?", privacy: .public)")
        // Removed or turned off while this connection waited for its request.
        guard await MainActor.run(body: { ShareCenter.shared.stillTrusted(id, key: peer.key) }) else {
            try await conn.sendJSON(["error": "not-paired"]); return
        }
        switch request["op"] as? String {
        case "hello":
            let name = await MainActor.run { RemoteMacs.sharedName }
            let ask = await MainActor.run { ShareCenter.shared.asks(peer) }
            try await conn.sendJSON(["name": name, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                                     "platform": "macos", "clip": ShareCenter.sharesClipboard, "files": ShareCenter.acceptsFiles,
                                     "ask": ask])
        case "clip-info":
            let info = await MainActor.run { ShareCenter.shared.clipInfo(for: peer) }
            try await conn.sendJSON(info)
        case "clip-get":
            // `wait` is optional, but when present it must be a JSON boolean.
            if request["wait"] != nil, ShareJSON.bool(request["wait"]) == nil { try await conn.sendJSON(["error": "bad-request"]); return }
            try await clipGet(conn, peer: peer, waits: ShareJSON.bool(request["wait"]) == true)
        case "files-offer":
            try await ShareReceiver.receive(conn, offer: request, from: peer)
        default:
            try await conn.sendJSON(["error": "unsupported"])
        }
    }

    /// `waits`: the client sent `"wait": true` and gives the user here up to 130 s. An older client would
    /// time out after 10 s, so it gets a plain "off" (reason "ask") and no question pops up.
    private static func clipGet(_ conn: ShareConnection, peer: SharePeer, waits: Bool) async throws {
        guard ShareCenter.sharesClipboard else { try await conn.sendJSON(["kind": "off", "size": 0]); return }
        var remember = false
        if await MainActor.run(body: { ShareCenter.shared.asks(peer) }) {
            guard waits else { try await conn.sendJSON(["kind": "off", "size": 0, "reason": "ask"]); return }
            guard await MainActor.run(body: { ShareCenter.shared.beginClipPrompt() }) else {
                try await conn.sendJSON(["error": "busy"]); return
            }
            defer { Task { @MainActor in ShareCenter.shared.endClipPrompt() } }
            let prompt = await SharePrompt.show(
                title: String(localized: "\(peer.name) chce pobrać Twój schowek"),
                message: String(localized: "To, co teraz jest w schowku tego Maca, trafi na \(peer.name). Bez Twojej zgody nic nie zostanie wysłane."),
                code: nil, symbol: "doc.on.clipboard", ok: String(localized: "Pozwól"), cancel: String(localized: "Odmów"),
                checkbox: String(localized: "Zawsze pozwalaj temu komputerowi"), timeout: 120)
            // The client waits silently for the answer; if it goes away, so does the question.
            conn.watchForClose { Task { @MainActor in prompt.dismiss() } }
            guard await prompt.result() else {
                let timedOut = await prompt.timedOut
                shareLog.info("clip-get refused: \(timedOut ? "timeout" : "declined", privacy: .public)")
                try await conn.sendJSON(["error": timedOut ? "timeout" : "declined"]); return
            }
            remember = await prompt.checked
        }
        // One decision on the main actor: still trusted with this key, "always allow" saved for this key,
        // and the clipboard read only now, after consent.
        let rememberNow = remember
        let current = await MainActor.run { () -> ShareCenter.ClipContent? in
            let center = ShareCenter.shared
            guard center.stillTrusted(peer.id, key: peer.key), ShareCenter.sharesClipboard else { return nil }
            if rememberNow { center.setAllowClip(peer.id, true) }
            return center.clipContent()
        }
        guard var clip = current else { try await conn.sendJSON(["error": "declined"]); return }
        if clip.kind == "image" {
            guard let image = ShareCenter.preparedImage(clip) else {
                try await conn.sendJSON(["kind": "empty", "reason": "too-large", "size": clip.data.count]); return
            }
            clip = image
        }
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
        shareLog.info("clip-get sent \(clip.kind, privacy: .public), \(clip.data.count) bytes")
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
    static let maxFileSize: Int64 = 1 << 50

    /// The offer as SHARE.md allows it, or nil: whole non-negative sizes whose sum fits and equals `total`,
    /// no path twice, and no path that is a file in one entry and a folder in another (both compared
    /// without case, like the Mac disk).
    static func parse(_ offer: [String: Any]) -> (items: [Item], total: Int64)? {
        guard let list = offer["files"] as? [[String: Any]], !list.isEmpty, list.count <= 10_000,
              let declared = ShareJSON.int(offer["total"]) else { return nil }
        var items: [Item] = []
        var files = Set<String>(), folders = Set<String>()
        var total: Int64 = 0
        for entry in list {
            guard let path = entry["path"] as? String, let parts = SharePaths.components(path),
                  let size = ShareJSON.int(entry["size"]), size >= 0, size <= maxFileSize else { return nil }
            let lower = parts.map { $0.lowercased() }
            guard files.insert(lower.joined(separator: "/")).inserted else { return nil }
            for i in 1..<lower.count { folders.insert(lower[..<i].joined(separator: "/")) }
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard !overflow else { return nil }
            total = sum
            items.append(Item(parts: parts, size: size))
        }
        guard files.isDisjoint(with: folders), declared == total else { return nil }
        return (items, total)
    }

    static func receive(_ conn: ShareConnection, offer: [String: Any], from peer: SharePeer) async throws {
        guard ShareCenter.acceptsFiles else { try await conn.sendJSON(["accept": false, "reason": "off"]); return }
        guard let parsed = parse(offer) else { try await conn.sendJSON(["error": "bad-request"]); return }
        let (items, total) = parsed
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let free = (try? downloads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if let free, free - 100_000_000 < total { try await conn.sendJSON(["accept": false, "reason": "space"]); return }
        guard await MainActor.run(body: { ShareCenter.shared.beginReceiving() }) else {
            try await conn.sendJSON(["accept": false, "reason": "busy"]); return
        }
        defer { Task { @MainActor in ShareCenter.shared.endReceiving() } }

        // "Always accept" as it is now, not as it was when the connection opened.
        let autoAccept = await MainActor.run { ShareCenter.shared.peer(peer.id)?.autoAccept ?? false }
        if !autoAccept {
            let what = items.count == 1 ? items[0].parts.joined(separator: "/")
                : String(localized: "Pliki: \(items.count)")
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            let prompt = await SharePrompt.show(
                title: String(localized: "\(peer.name) chce wysłać pliki"),
                message: String(localized: "\(what) (\(size)). Pliki trafią do folderu Pobrane."),
                code: nil, ok: String(localized: "Przyjmij"), cancel: String(localized: "Odrzuć"), timeout: 115)
            // The sender waits silently for the answer; if it gives up, the question goes too.
            conn.watchForClose { Task { @MainActor in prompt.dismiss() } }
            guard await prompt.result() else {
                let timedOut = await prompt.timedOut
                try await conn.sendJSON(["accept": false, "reason": timedOut ? "timeout" : "declined"]); return
            }
        }
        guard await MainActor.run(body: { ShareCenter.shared.stillTrusted(peer.id, key: peer.key) }), ShareCenter.acceptsFiles else {
            try await conn.sendJSON(["accept": false, "reason": "off"]); return
        }
        guard let root = ShareDir.open(downloads) else { try await conn.sendJSON(["accept": false, "reason": "space"]); return }
        try await conn.sendJSON(["accept": true])

        var transfer = ShareCenter.Transfer(peerID: peer.id, incoming: true, total: total)
        transfer.conn = conn
        await MainActor.run { [transfer] in ShareCenter.shared.addTransfer(transfer) }
        defer { Task { @MainActor [transfer] in ShareCenter.shared.finishTransfer(transfer.id) } }

        // Every top-level item goes straight into Downloads; a taken name gets " (2)". Folders are opened
        // one level at a time without following links, so nothing can be written outside Downloads.
        var tops: [String: String] = [:]
        var folders: [String: ShareDir] = ["": root]
        var created: [URL] = []
        var partial: (dir: ShareDir, name: String)?
        do {
            for (index, item) in items.enumerated() {
                let header = try await conn.readJSON()
                guard ShareJSON.int(header["file"]) == Int64(index) else { throw ShareError.badFrame }
                let top = item.parts[0]
                var dir = root
                var key = ""
                var names = [String]()
                if item.parts.count > 1 {
                    let topName: String
                    if let t = tops[top] { topName = t } else {
                        topName = root.free(top)
                        tops[top] = topName
                        created.append(downloads.appendingPathComponent(topName))
                    }
                    names = [topName] + item.parts.dropFirst().dropLast()
                }
                for name in names {
                    let next = key.isEmpty ? name : key + "/" + name
                    if let open = folders[next] { dir = open } else {
                        dir = try dir.folder(name)
                        folders[next] = dir
                    }
                    key = next
                }
                let fileName = item.parts.last!
                let tmp = "\(fileName).\(ShareKeys.hex(ShareKeys.random(4))).pulse-part"
                let handle = try dir.createExclusive(tmp)
                partial = (dir, tmp)
                var pending = 0
                let written: Int
                do {
                    written = try await conn.receiveStream(limit: Int(item.size)) { chunk in
                        try handle.write(contentsOf: chunk)
                        pending += chunk.count
                        // Progress in steps, not per chunk: tiny chunks must not flood the main actor.
                        if pending >= 1_048_576 {
                            let n = pending; pending = 0
                            Task { @MainActor in ShareCenter.shared.progress(transfer.id, n) }
                        }
                    }
                    try handle.close()
                } catch { try? handle.close(); throw error }
                if pending > 0 { let n = pending; Task { @MainActor in ShareCenter.shared.progress(transfer.id, n) } }
                guard written == Int(item.size) else { throw ShareError.badFrame }
                let final = try dir.publish(tmp, as: fileName)
                partial = nil
                if item.parts.count == 1 { created.append(downloads.appendingPathComponent(final)) }
            }
            try await conn.sendJSON(["ok": true])
            shareLog.info("received \(items.count) files, \(total) bytes")
        } catch {
            if let partial { partial.dir.remove(partial.name) }
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

    static func describe(_ error: Error, clipboard: Bool = false) -> String {
        switch error {
        case ShareError.remote("declined") where clipboard: String(localized: "Na tamtym komputerze odmówiono pobrania schowka.")
        case ShareError.remote("timeout") where clipboard: String(localized: "Na tamtym komputerze nikt nie odpowiedział na prośbę o schowek.")
        case ShareError.tooMany: String(localized: "Najwyżej 10 000 plików naraz.")
        case ShareError.unexpected("key"): String(localized: "Nie udało się zapisać klucza tego Maca w folderze Application Support, więc parowanie nie jest możliwe.")
        case ShareError.remote("off"): String(localized: "Na tamtym komputerze opcja „Schowek i pliki” jest wyłączona.")
        case ShareError.remote("not-paired"): String(localized: "Tamten komputer nie zna już tego Maca. Sparuj je ponownie.")
        case ShareError.remote("busy"): String(localized: "Tamten komputer jest zajęty. Spróbuj za chwilę.")
        case ShareError.remote("declined"): String(localized: "Odrzucono.")
        case ShareError.remote("space"): String(localized: "Na tamtym komputerze brakuje miejsca.")
        case ShareError.remote("timeout"): String(localized: "Nikt nie odpowiedział na tamtym komputerze.")
        case ShareError.tooLarge: String(localized: "Za dużo danych.")
        case ShareError.hash, ShareError.decrypt: String(localized: "Dane nie przeszły kontroli. Spróbuj ponownie.")
        case ShareError.offline: String(localized: "Ten komputer nie jest teraz w sieci.")
        case ShareError.timeout: String(localized: "Tamten komputer nie odpowiada.")
        case ShareError.remote("bad-request"), ShareError.remote("unsupported"), ShareError.remote("mismatch"):
            String(localized: "Tamten komputer nie przyjął żądania. Zaktualizuj Pulse lub PulseWin na obu komputerach.")
        default: String(localized: "Połączenie się nie udało.")
        }
    }

    /// Connects and runs the session handshake; the connection is ready for one encrypted request.
    static func session(_ peer: SharePeer) async throws -> ShareConnection {
        guard let endpoint = await MainActor.run(body: { ShareCenter.shared.nearby[peer.id]?.endpoint }) else { throw ShareError.offline }
        let conn = ShareConnection(endpoint: endpoint)
        _ = ShareRegistry.shared.admit(conn, incoming: false)
        ShareRegistry.shared.bind(conn, to: peer.id)
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
        } catch { conn.close(); ShareRegistry.shared.remove(conn); throw error }
    }

    /// Closes the session and forgets it.
    static func done(_ conn: ShareConnection) { conn.close(); ShareRegistry.shared.remove(conn) }

    /// Width and height of a PNG, read from its header without decoding it; nil for anything else
    /// or for images too large to put on the clipboard safely.
    static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w.multipliedReportingOverflow(by: h).partialValue <= 150_000_000, w <= 65_535, h <= 65_535 else { return nil }
        return (w, h)
    }

    static func clipInfo(_ peer: SharePeer) async throws -> [String: Any] {
        let conn = try await session(peer)
        defer { done(conn) }
        try await conn.sendJSON(["op": "clip-info"])
        return try await conn.readJSON(timeout: 3)
    }

    static func clipGet(_ peer: SharePeer) async throws -> Clip {
        let conn = try await session(peer)
        defer { done(conn) }
        try await conn.sendJSON(["op": "clip-get", "wait": true])
        // The other side may ask its user first (up to 120 s).
        let header = try await conn.readJSON(timeout: 130)
        let kind = header["kind"] as? String ?? "empty"
        guard kind == "text" || kind == "image" else { return Clip(kind: kind) }
        guard let size = ShareJSON.int(header["size"]), size >= 0, size <= Int64(ShareCenter.clipLimit),
              (header["mime"] as? String ?? "").lowercased().hasPrefix(kind == "text" ? "text/plain" : "image/png") else { throw ShareError.badFrame }
        var data = Data()
        // Exactly the announced size: less or more is a broken answer and the clipboard stays as it was.
        _ = try await conn.receiveStream(limit: Int(size)) { data.append($0) }
        guard data.count == Int(size) else { throw ShareError.badFrame }
        return Clip(kind: kind, data: data, width: header["width"] as? Int ?? 0, height: header["height"] as? Int ?? 0)
    }

    /// Files and folders → relative paths ("/" separators); folders keep their tree, links are skipped.
    static func collect(_ urls: [URL]) throws -> [(url: URL, path: String, size: Int64)] {
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
                    if result.count > 10_000 { throw ShareError.tooMany }
                }
            } else if values?.isRegularFile == true {
                result.append((url, url.lastPathComponent, Int64(values?.fileSize ?? 0)))
            }
        }
        guard result.count <= 10_000 else { throw ShareError.tooMany }
        return result
    }

    static func sendFiles(_ urls: [URL], to peer: SharePeer) async throws {
        let files = try collect(urls)
        guard !files.isEmpty else { return }
        let total = files.reduce(0) { $0 + $1.size }
        let conn = try await session(peer)
        defer { done(conn) }
        // Shown (with Cancel) from the offer on, also while the other side decides.
        var transfer = ShareCenter.Transfer(peerID: peer.id, incoming: false, total: total)
        transfer.conn = conn
        await MainActor.run { [transfer] in ShareCenter.shared.addTransfer(transfer) }
        defer { Task { @MainActor [transfer] in ShareCenter.shared.finishTransfer(transfer.id) } }
        do {
            try await conn.sendJSON(["op": "files-offer", "total": total,
                                     "files": files.map { ["path": $0.path, "size": $0.size] }])
            let answer = try await conn.readJSON(timeout: 130)
            guard ShareJSON.bool(answer["accept"]) == true else { throw ShareError.remote(answer["reason"] as? String ?? "declined") }
            for (index, file) in files.enumerated() {
                try await conn.sendJSON(["file": index])
                // The size announced in the offer is what the receiver checks.
                try await conn.sendFile(file.url, progress: { n in
                    Task { @MainActor in ShareCenter.shared.progress(transfer.id, n) }
                }, cancelled: { DispatchQueue.main.sync { MainActor.assumeIsolated { ShareCenter.shared.isCancelled(transfer.id) } } })
            }
            let result = try await conn.readJSON(timeout: 30)
            guard ShareJSON.bool(result["ok"]) == true else { throw ShareError.remote(result["reason"] as? String ?? "error") }
        } catch {
            // ✕ closes the connection on purpose: that is not a failure to report.
            if await MainActor.run(body: { [id = transfer.id] in ShareCenter.shared.isCancelled(id) }) { throw ShareError.cancelled }
            shareLog.info("send to \(peer.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        await MainActor.run {
            Alerts.shared.send(title: String(localized: "Wysłano"),
                               body: String(localized: "\(files.count == 1 ? files[0].path : String(localized: "Pliki: \(files.count)")) → \(peer.name)"),
                               id: "share.files")
        }
    }

    /// Pairing as the client. Returns the other computer's name.
    static func pair(_ nearby: ShareCenter.Nearby) async throws -> String {
        guard ShareKeys.isPersistent else { throw ShareError.unexpected("key") }
        let conn = ShareConnection(endpoint: nearby.endpoint)
        _ = ShareRegistry.shared.admit(conn, incoming: false)
        defer { done(conn) }
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
        // The computer answering must be the one chosen: same id, and the key it advertises.
        guard id == nearby.id, nearby.fingerprint == nil || nearby.fingerprint == ShareKeys.fingerprint(pkS) else {
            throw ShareError.badFrame
        }
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
        // The server answers first; a "no" there, or the connection dropping, closes this prompt too.
        let theirsTask = Task { try await conn.readPlain(timeout: 130) }
        let watcher = Task {
            let theirs = try? await theirsTask.value
            if ShareJSON.bool(theirs?["confirmed"]) != true { await prompt.dismiss() }
        }
        let mine = await prompt.result()
        // Cancel here ends it at once: the server's question closes when the connection does.
        guard mine else { watcher.cancel(); conn.close(); throw ShareError.remote("declined") }
        let theirs = try await theirsTask.value
        watcher.cancel()
        let serverOK = ShareJSON.bool(theirs["confirmed"]) == true
        try await conn.sendPlain(["confirmed": mine && serverOK])
        guard serverOK else { throw ShareError.remote("declined") }
        guard mine else { throw ShareError.remote("declined") }
        guard ShareCenter.validID(id) else { throw ShareError.badFrame }
        let peer = SharePeer(id: id, name: name, key: pkS, platform: server["platform"] as? String)
        let stored = await MainActor.run { () -> Bool in
            guard ShareCenter.isOn else { return false }
            ShareCenter.shared.store(peer)
            return true
        }
        guard stored else { throw ShareError.closed }
        return name
    }
}

extension RemoteMacs {
    /// The install id, readable off the main actor.
    nonisolated static var installIDValue: String {
        UserDefaults.standard.string(forKey: "remote.id") ?? ""
    }
}
