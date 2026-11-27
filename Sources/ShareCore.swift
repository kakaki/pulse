import CryptoKit
@preconcurrency import Dispatch
import Foundation
import Network
import Security

// Clipboard and file sharing between paired computers (`_pulse-share._tcp`).
// Wire format: PulseWin repo, docs/SHARE.md — both apps implement exactly that document.

enum ShareError: Error {
    case closed, timeout, badFrame, decrypt, hash, tooLarge, tooMany, offline, cancelled
    case remote(String)
    case unexpected(String)
}

/// Long-term identity (ECDH P-256) and the list of paired computers.
enum ShareKeys {
    /// Created once and kept in Application Support with owner-only permissions, like PulseWin's per-user file.
    /// Not in the Keychain: a login-keychain item is tied to the exact app binary, so every update would block
    /// the app behind a password prompt.
    /// `persistent` is false when the key could not be saved: pairing is then refused, because a key that
    /// disappears at the next launch would silently break every pairing made with it.
    private static let stored: (key: P256.KeyAgreement.PrivateKey, persistent: Bool) = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
        let url = dir.appendingPathComponent("share-key.bin")
        // Only a regular file of this user is trusted (no link); loose permissions are tightened.
        func load() -> P256.KeyAgreement.PrivateKey?? {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return .some(nil) }   // no file yet
            guard st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else { return nil }   // never use or replace
            guard let data = try? Data(contentsOf: url), let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data) else {
                return .some(nil)   // damaged: replaced below
            }
            if st.st_mode & 0o077 != 0 { chmod(url.path, 0o600) }
            return key
        }
        switch load() {
        case .some(.some(let key)): return (key, true)
        case .none: return (P256.KeyAgreement.PrivateKey(), false)
        case .some(.none): break
        }
        let key = P256.KeyAgreement.PrivateKey()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("share-key.\(UUID().uuidString).tmp")
        defer { unlink(tmp.path) }
        guard FileManager.default.createFile(atPath: tmp.path, contents: key.rawRepresentation, attributes: [.posixPermissions: 0o600]) else {
            return (key, false)
        }
        // A damaged file is replaced; otherwise link() never overwrites, so of two instances starting
        // together the first one wins and the other uses its key.
        var existing = stat()
        if lstat(url.path, &existing) == 0 { unlink(url.path) }
        if link(tmp.path, url.path) != 0, case .some(.some(let winner)) = load() { return (winner, true) }
        guard (try? Data(contentsOf: url)) == key.rawRepresentation else { return (key, false) }
        return (key, true)
    }()

    static var identity: P256.KeyAgreement.PrivateKey { stored.key }
    static var isPersistent: Bool { stored.persistent }

    static var publicKey: Data { identity.publicKey.x963Representation }

    /// TXT `pk`: first 8 bytes of SHA-256 of the public key, hex.
    static func fingerprint(_ key: Data) -> String { hex(Data(SHA256.hash(data: key)).prefix(8)) }

    static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }

    static func sharedSecret(peerKey: Data) throws -> SharedSecret {
        try identity.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peerKey))
    }

    /// Session keys: HKDF-SHA256(Z, salt nC‖nS, "pulse-share-v1 c2s" / "… s2c").
    static func sessionKeys(peerKey: Data, nC: Data, nS: Data) throws -> (c2s: SymmetricKey, s2c: SymmetricKey) {
        let z = try sharedSecret(peerKey: peerKey)
        func key(_ info: String) -> SymmetricKey {
            z.hkdfDerivedSymmetricKey(using: SHA256.self, salt: nC + nS, sharedInfo: Data(info.utf8), outputByteCount: 32)
        }
        return (key("pulse-share-v1 c2s"), key("pulse-share-v1 s2c"))
    }

    static func commitment(pkS: Data, pkC: Data, nS: Data) -> Data { Data(SHA256.hash(data: pkS + pkC + nS)) }

    /// Six digits both screens show while pairing.
    static func pairingCode(pkC: Data, pkS: Data, nC: Data, nS: Data) -> String {
        let h = Data(SHA256.hash(data: Data("pulse-pair-v1".utf8) + pkC + pkS + nC + nS))
        let v = (UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3])) % 1_000_000
        let s = String(format: "%06d", v)
        return "\(s.prefix(3)) \(s.suffix(3))"
    }

    /// SystemRandomNumberGenerator is the system CSPRNG on Apple platforms and cannot fail.
    static func random(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }
}

struct SharePeer: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var key: Data
    var platform: String?
    var autoAccept = false
    /// Takes this Mac's clipboard without asking each time.
    var allowClip = false
    var pairedAt = Date()

    init(id: String, name: String, key: Data, platform: String?, autoAccept: Bool = false, allowClip: Bool = false) {
        self.id = id; self.name = name; self.key = key; self.platform = platform
        self.autoAccept = autoAccept; self.allowClip = allowClip
    }

    // Peers saved by older versions have no `allowClip`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        key = try c.decode(Data.self, forKey: .key)
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        autoAccept = try c.decodeIfPresent(Bool.self, forKey: .autoAccept) ?? false
        allowClip = try c.decodeIfPresent(Bool.self, forKey: .allowClip) ?? false
        pairedAt = try c.decodeIfPresent(Date.self, forKey: .pairedAt) ?? Date()
    }
}

/// One TCP connection speaking the framed protocol; plain JSON while pairing, AES-GCM once keys are set.
final class ShareConnection: @unchecked Sendable {
    static let maxFrame = 1_048_576 + 16 + 1
    static let chunk = 512 * 1024

    let connection: NWConnection
    private let queue = DispatchQueue(label: "local.pulse.share.connection")
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    // Watching for the other side closing while this side waits for its user (see `watchForClose`).
    private let lock = NSLock()
    private var buffered = Data()
    private var peerClosed = false
    private var peeking = false
    private var peekWaiters: [() -> Void] = []

    init(_ connection: NWConnection) { self.connection = connection }

    convenience init(endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        self.init(NWConnection(to: endpoint, using: params))
    }

    func start(timeout: TimeInterval = 8) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready: if once.take() { cont.resume() }
                case .failed(let e), .waiting(let e):
                    if once.take() { connection.cancel(); cont.resume(throwing: e) }
                case .cancelled: if once.take() { cont.resume(throwing: ShareError.closed) }
                default: break
                }
            }
            connection.start(queue: queue)
            schedule(timeout) { [connection] in
                if once.take() { connection.cancel(); cont.resume(throwing: ShareError.timeout) }
            }
        }
    }

    /// A timeout that is cancelled as soon as the operation ends, so finished reads leave nothing queued.
    @discardableResult
    private func schedule(_ seconds: TimeInterval, _ fire: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: fire)
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    /// While this side waits for its user and the other side has nothing to send, notices the other side
    /// going away (or this connection being closed) and calls `onClose`. Bytes that arrive meanwhile are
    /// kept and read first, in order.
    func watchForClose(_ onClose: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !peeking, !peerClosed else { lock.unlock(); return }
        peeking = true
        lock.unlock()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            lock.lock()
            if let data { buffered.append(data) }
            if isComplete || error != nil { peerClosed = true }
            peeking = false
            let waiters = peekWaiters
            peekWaiters = []
            lock.unlock()
            waiters.forEach { $0() }
            if (data?.isEmpty ?? true) && (isComplete || error != nil) { onClose() }
        }
    }

    /// Waits for a pending `watchForClose` read, so the next read cannot overtake its bytes.
    private func settlePeek(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            lock.lock()
            guard peeking else { lock.unlock(); cont.resume(); return }
            let timer = schedule(timeout) { [connection] in
                if once.take() { connection.cancel(); cont.resume(throwing: ShareError.timeout) }
            }
            peekWaiters.append { timer.cancel(); if once.take() { cont.resume() } }
            lock.unlock()
        }
    }

    func close() { connection.cancel() }

    func setKeys(send: SymmetricKey, receive: SymmetricKey) {
        sendKey = send; receiveKey = receive; sendCounter = 0; receiveCounter = 0
    }

    // MARK: Raw frames

    private func receive(exactly n: Int, timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        try await settlePeek(timeout: timeout)
        let (head, closed) = lock.withLock { () -> (Data, Bool) in
            let head = Data(buffered.prefix(n))
            buffered = Data(buffered.dropFirst(head.count))
            return (head, peerClosed)
        }
        if head.count == n { return head }
        if closed { throw ShareError.closed }
        let rest = try await receiveRaw(n - head.count, timeout: max(deadline.timeIntervalSinceNow, 0.5))
        return head + rest
    }

    private func receiveRaw(_ n: Int, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = Once()
            let timer = schedule(timeout) { [connection] in
                if once.take() { connection.cancel(); cont.resume(throwing: ShareError.timeout) }
            }
            connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
                timer.cancel()
                guard once.take() else { return }
                if let error { cont.resume(throwing: error); return }
                guard let data, data.count == n else { cont.resume(throwing: isComplete ? ShareError.closed : ShareError.badFrame); return }
                cont.resume(returning: data)
            }
        }
    }

    /// One deadline for the whole frame (length and body).
    func readFrame(timeout: TimeInterval, limit: Int = ShareConnection.maxFrame) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        let head = try await receive(exactly: 4, timeout: timeout)
        let length = Int(head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard length > 0, length <= limit else { close(); throw ShareError.badFrame }
        return try await receive(exactly: length, timeout: max(deadline.timeIntervalSinceNow, 0.5))
    }

    /// A peer that stops reading cannot hold a send forever.
    func writeFrame(_ body: Data, timeout: TimeInterval = 30) async throws {
        guard body.count <= Self.maxFrame else { throw ShareError.tooLarge }
        var length = UInt32(body.count).bigEndian
        let frame = Data(bytes: &length, count: 4) + body
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            let timer = schedule(timeout) { [connection] in
                if once.take() { connection.cancel(); cont.resume(throwing: ShareError.timeout) }
            }
            connection.send(content: frame, completion: .contentProcessed { error in
                timer.cancel()
                guard once.take() else { return }
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    // MARK: Plain JSON (pairing phase and the session handshake)

    func sendPlain(_ object: [String: Any]) async throws {
        try await writeFrame(try JSONSerialization.data(withJSONObject: object))
    }

    func readPlain(timeout: TimeInterval = 10) async throws -> [String: Any] {
        // Handshake frames are small; a big one before authentication is refused.
        let body = try await readFrame(timeout: timeout, limit: 64 * 1024)
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw ShareError.badFrame }
        if let error = object["error"] as? String { throw ShareError.remote(error) }
        return object
    }

    // MARK: Encrypted frames

    private static func nonce(_ counter: UInt64) -> AES.GCM.Nonce {
        var be = counter.bigEndian
        return try! AES.GCM.Nonce(data: Data(count: 4) + Data(bytes: &be, count: 8))
    }

    func send(type: UInt8, _ body: Data = Data()) async throws {
        guard let key = sendKey else { throw ShareError.unexpected("no key") }
        let box = try AES.GCM.seal(Data([type]) + body, using: key, nonce: Self.nonce(sendCounter))
        sendCounter += 1
        try await writeFrame(box.ciphertext + box.tag)
    }

    func read(timeout: TimeInterval = 10) async throws -> (type: UInt8, body: Data) {
        guard let key = receiveKey else { throw ShareError.unexpected("no key") }
        let frame = try await readFrame(timeout: timeout)
        guard frame.count >= 17 else { close(); throw ShareError.badFrame }
        let payload: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: Self.nonce(receiveCounter), ciphertext: frame.dropLast(16), tag: frame.suffix(16))
            payload = try AES.GCM.open(box, using: key)
        } catch { close(); throw ShareError.decrypt }
        receiveCounter += 1
        guard let type = payload.first else { throw ShareError.badFrame }
        return (type, Data(payload.dropFirst()))
    }

    func sendJSON(_ object: [String: Any]) async throws {
        try await send(type: 0x01, try JSONSerialization.data(withJSONObject: object))
    }

    func readJSON(timeout: TimeInterval = 10) async throws -> [String: Any] {
        let (type, body) = try await read(timeout: timeout)
        guard type == 0x01, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw ShareError.badFrame }
        if let error = object["error"] as? String { throw ShareError.remote(error) }
        return object
    }

    /// Data chunks followed by the end frame with the SHA-256 of the whole stream.
    func sendStream(_ data: Data, progress: ((Int) -> Void)? = nil) async throws {
        var hasher = SHA256()
        var offset = 0
        while offset < data.count {
            let piece = data.subdata(in: offset..<min(offset + Self.chunk, data.count))
            hasher.update(data: piece)
            try await send(type: 0x02, piece)
            offset += piece.count
            progress?(piece.count)
        }
        try await sendEnd(hasher)
    }

    func sendFile(_ url: URL, progress: ((Int) -> Void)? = nil, cancelled: () -> Bool) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if cancelled() { throw ShareError.closed }
            guard let piece = try handle.read(upToCount: Self.chunk), !piece.isEmpty else { break }
            hasher.update(data: piece)
            try await send(type: 0x02, piece)
            progress?(piece.count)
        }
        try await sendEnd(hasher)
    }

    private func sendEnd(_ hasher: SHA256) async throws {
        let digest = ShareKeys.hex(hasher.finalize())
        try await send(type: 0x03, try JSONSerialization.data(withJSONObject: ["sha256": digest]))
    }

    /// Reads chunks until the end frame; `sink` gets each chunk. Checks the size limit and the hash.
    func receiveStream(limit: Int, sink: (Data) throws -> Void) async throws -> Int {
        var hasher = SHA256()
        var total = 0
        while true {
            let (type, body) = try await read()
            switch type {
            case 0x02:
                // An empty chunk makes no progress; refusing it keeps a sender from holding the slot open.
                guard !body.isEmpty, body.count <= 1_048_576 else { close(); throw ShareError.badFrame }
                total += body.count
                guard total <= limit else { close(); throw ShareError.tooLarge }
                hasher.update(data: body)
                try sink(body)
            case 0x03:
                if !body.isEmpty {
                    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                          let expected = object["sha256"] as? String, Self.isDigest(expected) else { close(); throw ShareError.badFrame }
                    guard expected == ShareKeys.hex(hasher.finalize()) else { close(); throw ShareError.hash }
                }
                return total
            case 0x01:
                if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let error = object["error"] as? String {
                    throw ShareError.remote(error)
                }
                throw ShareError.badFrame
            default:
                throw ShareError.badFrame
            }
        }
    }
}

extension ShareConnection {
    /// 64 lowercase hex digits.
    static func isDigest(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// Resumes a continuation exactly once across callbacks and timeouts.
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Receiver-side path rules from SHARE.md.
enum SharePaths {
    private static let reserved = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })

    /// Relative path → safe components, or nil when it must be refused.
    static func components(_ path: String) -> [String]? {
        if path.hasPrefix("/") || path.contains("\\") || path.contains("\0") { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // SHARE.md: at most 4096 characters and 256 parts.
        guard !parts.isEmpty, parts.count <= 256, path.count <= 4096 else { return nil }
        var result: [String] = []
        for raw in parts {
            guard !raw.isEmpty, raw != ".", raw != ".." else { return nil }
            var part = raw.replacingOccurrences(of: ":", with: "_")
            while let last = part.last, last == "." || last == " " { part.removeLast() }
            guard !part.isEmpty else { return nil }
            let stem = part.split(separator: ".", maxSplits: 1).first.map(String.init)?.uppercased() ?? ""
            if reserved.contains(stem) { part = "_" + part }
            // Room for the temp suffix (".1a2b3c4d.pulse-part") within the 255-byte name limit;
            // trimming must not leave a trailing dot or space behind.
            while part.utf8.count > 200 { part.removeLast() }
            while let last = part.last, last == "." || last == " " { part.removeLast() }
            guard !part.isEmpty else { return nil }
            result.append(part)
        }
        return result
    }
}

/// Open connections, so turning the option off or removing a computer ends what is in flight,
/// and a cap on incoming connections that have not authenticated yet.
final class ShareRegistry: @unchecked Sendable {
    static let shared = ShareRegistry()
    /// Incoming connections that have not authenticated yet, and all incoming ones: unpaired
    /// connections alone cannot use up the room a paired computer needs.
    static let maxUnauthenticated = 16
    static let maxIncoming = 48

    private let lock = NSLock()
    private var open: [ObjectIdentifier: (conn: ShareConnection, peer: String?, incoming: Bool)] = [:]

    /// False when too many incoming connections are already open.
    func admit(_ conn: ShareConnection, incoming: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if incoming {
            let all = open.values.filter(\.incoming)
            if all.count >= Self.maxIncoming || all.filter({ $0.peer == nil }).count >= Self.maxUnauthenticated { return false }
        }
        open[ObjectIdentifier(conn)] = (conn, nil, incoming)
        return true
    }

    func bind(_ conn: ShareConnection, to peer: String) {
        lock.lock(); defer { lock.unlock() }
        open[ObjectIdentifier(conn)]?.peer = peer
    }

    func remove(_ conn: ShareConnection) {
        lock.lock(); defer { lock.unlock() }
        open[ObjectIdentifier(conn)] = nil
    }

    /// Closes the connections of one computer, or all of them.
    func close(peer: String? = nil) {
        lock.lock()
        let victims = open.values.filter { peer == nil || $0.peer == peer }.map(\.conn)
        lock.unlock()
        victims.forEach { $0.close() }
    }
}

/// Strict reading of JSON values: NSNumber bridging would otherwise turn true into 1, 1 into true, 1.9 into 1.
enum ShareJSON {
    static func int(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return nil }
        return n.int64Value
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
}

/// A folder opened without following links. Files are created, published and removed relative to it,
/// so renaming a folder or putting a link in its place cannot redirect a write elsewhere.
final class ShareDir: @unchecked Sendable {
    let fd: Int32
    private init(fd: Int32) { self.fd = fd }
    deinit { Darwin.close(fd) }

    /// Downloads itself may be a link the user made; everything below it is opened without following links.
    static func open(_ url: URL) -> ShareDir? {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        return fd >= 0 ? ShareDir(fd: fd) : nil
    }

    /// A subfolder, created when missing; a link or a file in its place is refused.
    func folder(_ name: String) throws -> ShareDir {
        if mkdirat(fd, name, 0o755) != 0, errno != EEXIST { throw ShareError.unexpected("mkdir") }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw ShareError.badFrame }
        return ShareDir(fd: child)
    }

    func exists(_ name: String) -> Bool {
        var st = stat()
        return fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0
    }

    /// `name`, `name (2).ext`, `name (3).ext`… — the first one free here.
    func free(_ name: String) -> String {
        if !exists(name) { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for i in 2...9999 {
            let candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            if !exists(candidate) { return candidate }
        }
        return UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// A new file that did not exist before (never an existing file or a link).
    func createExclusive(_ name: String) throws -> FileHandle {
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { throw ShareError.unexpected("create") }
        return FileHandle(fileDescriptor: file, closeOnDealloc: true)
    }

    /// Renames the finished temp file to a free name; never replaces anything. Returns the name used.
    func publish(_ tmp: String, as name: String) throws -> String {
        for _ in 0..<20 {
            let target = free(name)
            if renameatx_np(fd, tmp, fd, target, UInt32(RENAME_EXCL)) == 0 { return target }
            guard errno == EEXIST else { break }
        }
        throw ShareError.unexpected("rename")
    }

    func remove(_ name: String) { unlinkat(fd, name, 0) }
}
