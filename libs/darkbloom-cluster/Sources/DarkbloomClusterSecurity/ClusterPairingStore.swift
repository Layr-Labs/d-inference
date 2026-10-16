import CryptoKit
import Darwin
import Foundation

/// One pairing as this Mac stored it: the other Mac's pinned key, the roster
/// both countersigned, and the link edge both key their link control channel
/// with. Public values only; the edge secret is in its own owner-only file.
public struct ClusterPairingRecord: Codable, Sendable, Equatable {
    public struct Roster: Codable, Sendable, Equatable {
        public let generation: UInt64
        public let members: [ClusterPairingRosterMember]
    }
    public struct Link: Codable, Sendable, Equatable {
        /// The link epoch and edge of the setup's `linkControl` block.
        public let linkEpoch: String
        public let edgeID: String
        /// Owner-only file with the edge secret (one hex line).
        public let secretFile: String
        public let localInterface: String
        public let peerInterface: String
    }
    public let peerPin: String
    /// Standard base64 of the other Mac's 65-byte Secure Enclave key.
    public let peerIdentityKey: String
    public let peerName: String
    public let peerPosture: ClusterPairingPeerPosture
    /// This Mac's role in the ceremony.
    public let role: ClusterPairingRole
    /// ISO 8601, UTC.
    public let pairedAt: String
    public let clusterID: String
    public let roster: Roster
    public let rosterSHA256: String
    public let link: Link
    public let transcriptSHA256: String
}

/// Everything this Mac pinned, for one local identity.
public struct ClusterPairingRecords: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_pairings_v1"
    public var schema = ClusterPairingRecords.schemaName
    public var localPin: String
    public var localIdentityKey: String
    public var pairings: [ClusterPairingRecord]

    public init(localPin: String, localIdentityKey: String, pairings: [ClusterPairingRecord]) {
        self.localPin = localPin; self.localIdentityKey = localIdentityKey; self.pairings = pairings
    }

    public func pairing(peerPin: String) -> ClusterPairingRecord? { pairings.first { $0.peerPin == peerPin } }
}

public enum ClusterPairingStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A file or the directory is not an owner-only regular file/directory of this user.
    case unsafe(String)
    case unreadable(String)
    case malformed(String)
    case writeFailed(String)
    case notPaired

    public var description: String {
        switch self {
        case .unsafe(let name): return "\(name) is not private to this user (expected an owner-only file); nothing is trusted from it"
        case .unreadable(let name): return "\(name) could not be read"
        case .malformed(let name): return "\(name) is malformed; nothing is trusted from it"
        case .writeFailed(let name): return "\(name) could not be written"
        case .notPaired: return "no pairing with that key"
        }
    }
}

/// The pairing store: `~/.darkbloom/cluster-pairing/` (0700) with
/// `pairings.json`, one `edge-<pin>.secret` per peer, `gate.json` (the
/// lockout) and `audit.jsonl`, every file 0600 and written atomically. A file
/// that is not private to this user is refused, never repaired: trust rests
/// on these files, so a widened mode fails closed.
public final class ClusterPairingStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private let clock: @Sendable () -> Double

    public var recordsFile: URL { directory.appendingPathComponent("pairings.json") }
    var gateFile: URL { directory.appendingPathComponent("gate.json") }
    public var auditFile: URL { directory.appendingPathComponent("audit.jsonl") }
    public func secretFile(peerPin: String) -> URL { directory.appendingPathComponent("edge-\(peerPin.prefix(16)).secret") }

    public init(directory: URL, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.directory = directory; self.clock = clock
    }

    /// `<home>/.darkbloom/cluster-pairing`.
    public static func `default`(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClusterPairingStore {
        ClusterPairingStore(directory: home.appendingPathComponent(".darkbloom/cluster-pairing", isDirectory: true))
    }

    // MARK: - Reading

    /// Nil when nothing was ever paired here.
    public func load() throws -> ClusterPairingRecords? {
        try lock.withLock { try loadLocked() }
    }

    private func loadLocked() throws -> ClusterPairingRecords? {
        guard try requireDirectory(create: false) else { return nil }
        guard let data = try readPrivate(recordsFile, maximum: 1 << 20) else { return nil }
        guard let records = try? JSONDecoder().decode(ClusterPairingRecords.self, from: data),
              records.schema == ClusterPairingRecords.schemaName, ClusterPairingPin.isPin(records.localPin),
              let key = Data(base64Encoded: records.localIdentityKey), ClusterPairingPin.of(identityKey: key) == records.localPin,
              records.pairings.allSatisfy(Self.valid), Set(records.pairings.map(\.peerPin)).count == records.pairings.count else {
            throw ClusterPairingStoreError.malformed("pairings.json")
        }
        return records
    }

    static func valid(_ record: ClusterPairingRecord) -> Bool {
        guard ClusterPairingPin.isPin(record.peerPin), let key = Data(base64Encoded: record.peerIdentityKey),
              ClusterPairingPin.isIdentityKey(key), ClusterPairingPin.of(identityKey: key) == record.peerPin,
              ClusterPairingLabel.isValid(record.clusterID), record.roster.generation > 0,
              record.roster.members.contains(where: { $0.pin == record.peerPin && $0.sePublicKey == record.peerIdentityKey }),
              UUID(uuidString: record.link.linkEpoch) != nil, UUID(uuidString: record.link.edgeID) != nil,
              record.link.secretFile.hasPrefix("/") else { return false }
        return true
    }

    /// The edge secret of a pairing, read from its owner-only file. Only the
    /// link control keying calls this; nothing prints it.
    public func edgeSecret(for record: ClusterPairingRecord) throws -> Data {
        let url = URL(fileURLWithPath: record.link.secretFile)
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              let data = try readPrivate(url, maximum: 256),
              let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = Self.hexDecode(line), secret.count == 32 else {
            throw ClusterPairingStoreError.malformed(url.lastPathComponent)
        }
        return secret
    }

    // MARK: - Writing

    /// What `commit` replaced, so `rollback` can put it back.
    public struct Commit: Sendable {
        let peerPin: String
        let previousRecords: ClusterPairingRecords?
        let previousSecret: Data?
    }

    /// Stores a finished ceremony: the edge secret first, then the records
    /// (atomic rename each). A failure at any point restores what was there.
    /// A record set made under another local identity is replaced whole: its
    /// pins name keys this Mac no longer signs with.
    @discardableResult
    public func commit(_ outcome: ClusterPairingOutcome, edgeID: UUID) throws -> Commit {
        try lock.withLock {
            _ = try requireDirectory(create: true)
            let previous = try loadLocked()
            let secretURL = secretFile(peerPin: outcome.peer.pin)
            let previousSecret = try readPrivate(secretURL, maximum: 256)
            let record = ClusterPairingRecord(peerPin: outcome.peer.pin, peerIdentityKey: outcome.peer.identityKey.base64EncodedString(),
                peerName: outcome.peer.name, peerPosture: outcome.peer.posture, role: outcome.role,
                pairedAt: Self.timestamp(clock()), clusterID: outcome.clusterID,
                roster: .init(generation: outcome.generation, members: outcome.rosterMembers), rosterSHA256: outcome.rosterSHA256,
                link: .init(linkEpoch: outcome.linkEpoch.uuidString.lowercased(), edgeID: edgeID.uuidString.lowercased(),
                    secretFile: secretURL.path, localInterface: outcome.localInterface, peerInterface: outcome.peer.interface),
                transcriptSHA256: Self.hex(outcome.transcriptSHA256))
            var records = previous ?? ClusterPairingRecords(localPin: outcome.localPin,
                localIdentityKey: outcome.localIdentityKey.base64EncodedString(), pairings: [])
            if records.localPin != outcome.localPin {
                auditLocked("identity_changed", ["previous_pin": String(records.localPin.prefix(16)), "pin": String(outcome.localPin.prefix(16))])
                records = ClusterPairingRecords(localPin: outcome.localPin, localIdentityKey: outcome.localIdentityKey.base64EncodedString(),
                    pairings: [])
            }
            records.pairings.removeAll { $0.peerPin == record.peerPin }
            records.pairings.append(record)
            records.pairings.sort { $0.peerPin < $1.peerPin }
            let token = Commit(peerPin: record.peerPin, previousRecords: previous, previousSecret: previousSecret)
            do {
                try writePrivate(Data((Self.hex(outcome.edgeSecret) + "\n").utf8), to: secretURL)
                try writePrivate(try Self.encode(records), to: recordsFile)
            } catch {
                restoreLocked(token)
                auditLocked("persist_failed", ["peer_pin": String(record.peerPin.prefix(16))])
                throw ClusterPairingStoreError.writeFailed("pairings.json")
            }
            auditLocked("pair_stored", ["peer_pin": String(record.peerPin.prefix(16)), "cluster": record.clusterID,
                                        "generation": String(record.roster.generation), "roster_sha256": String(record.rosterSHA256.prefix(16))])
            return token
        }
    }

    /// Puts back what `commit` replaced (the other Mac did not finish).
    public func rollback(_ token: Commit) {
        lock.withLock {
            restoreLocked(token)
            auditLocked("rollback", ["peer_pin": String(token.peerPin.prefix(16))])
        }
    }

    private func restoreLocked(_ token: Commit) {
        let secretURL = secretFile(peerPin: token.peerPin)
        if let previous = token.previousSecret { try? writePrivate(previous, to: secretURL) } else { unlink(secretURL.path) }
        if let previous = token.previousRecords, let data = try? Self.encode(previous) { try? writePrivate(data, to: recordsFile) }
        else { unlink(recordsFile.path) }
    }

    /// Unpairs: removes the record (the trust anchor) first, then the edge secret.
    @discardableResult
    public func forget(peerPin: String) throws -> ClusterPairingRecord {
        try lock.withLock {
            guard var records = try loadLocked(), let record = records.pairing(peerPin: peerPin) else {
                throw ClusterPairingStoreError.notPaired
            }
            records.pairings.removeAll { $0.peerPin == peerPin }
            if records.pairings.isEmpty { unlink(recordsFile.path) } else { try writePrivate(try Self.encode(records), to: recordsFile) }
            unlink(record.link.secretFile)
            auditLocked("unpaired", ["peer_pin": String(peerPin.prefix(16))])
            return record
        }
    }

    // MARK: - Gate (attempts and lockout, persisted so a restart does not reset them)

    struct GateState: Codable, Equatable {
        var failures: [Double] = []
        var lockedUntil: Double?
    }

    /// Throws `lockedOut` while a lockout runs.
    public func checkGate() throws {
        try lock.withLock {
            let state = (try? readGateLocked()) ?? GateState()
            if let until = state.lockedUntil, until > clock() {
                throw ClusterPairingError.lockedOut(untilEpochSeconds: until)
            }
        }
    }

    /// Counts a failed ceremony; returns the lockout's end when this one started it.
    @discardableResult
    public func recordFailure(_ error: ClusterPairingError) -> Double? {
        lock.withLock {
            let now = clock()
            var state = (try? readGateLocked()) ?? GateState()
            if let until = state.lockedUntil, until <= now { state.lockedUntil = nil }
            state.failures = state.failures.filter { now - $0 < ClusterPairingPolicy.lockoutSeconds } + [now]
            var started: Double?
            if state.failures.count >= ClusterPairingPolicy.maximumFailedAttempts {
                state.lockedUntil = now + ClusterPairingPolicy.lockoutSeconds
                state.failures = []
                started = state.lockedUntil
            }
            _ = try? requireDirectory(create: true)
            if let data = try? JSONEncoder().encode(state) { try? writePrivate(data, to: gateFile) }
            auditLocked("attempt_failed", ["reason": String(describing: error).prefix(120).description,
                                           "failures_in_window": String(state.failures.count)])
            if let started { auditLocked("lockout", ["until": Self.timestamp(started)]) }
            return started
        }
    }

    /// A completed ceremony clears the failure count.
    public func recordSuccess() {
        lock.withLock {
            if FileManager.default.fileExists(atPath: gateFile.path) { unlink(gateFile.path) }
        }
    }

    private func readGateLocked() throws -> GateState {
        guard try requireDirectory(create: false), let data = try readPrivate(gateFile, maximum: 64 * 1024) else { return GateState() }
        guard let state = try? JSONDecoder().decode(GateState.self, from: data) else { throw ClusterPairingStoreError.malformed("gate.json") }
        return state
    }

    // MARK: - Audit

    /// Appends one line to `audit.jsonl`: time, event, details. Never a key,
    /// a secret, a code or an address; pins are public and shortened. An audit
    /// failure never breaks a pairing step.
    public func audit(_ event: String, _ detail: [String: String] = [:]) {
        lock.withLock { auditLocked(event, detail) }
    }

    private func auditLocked(_ event: String, _ detail: [String: String]) {
        guard (try? requireDirectory(create: true)) == true else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        struct Line: Encodable { let ts: String; let event: String; let detail: [String: String] }
        guard var data = try? encoder.encode(Line(ts: Self.timestamp(clock()), event: event, detail: detail)) else { return }
        data.append(0x0A)
        let fd = open(auditFile.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    // MARK: - Files

    /// Whether the directory exists; creates it (0700) when asked. Refuses a
    /// symbolic link, another owner, or a mode open to group or others.
    private func requireDirectory(create: Bool) throws -> Bool {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw ClusterPairingStoreError.unreadable("the pairing directory") }
            guard create else { return false }
            try? FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST, lstat(directory.path, &info) == 0 else {
                throw ClusterPairingStoreError.writeFailed("the pairing directory")
            }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw ClusterPairingStoreError.unsafe("the pairing directory")
        }
        return true
    }

    /// Nil when the file does not exist.
    private func readPrivate(_ url: URL, maximum: Int) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw ClusterPairingStoreError.unsafe(url.lastPathComponent) }
            throw ClusterPairingStoreError.unreadable(url.lastPathComponent)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ClusterPairingStoreError.unreadable(url.lastPathComponent) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw ClusterPairingStoreError.unsafe(url.lastPathComponent)
        }
        guard info.st_size <= off_t(maximum) else { throw ClusterPairingStoreError.malformed(url.lastPathComponent) }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count == Int(info.st_size) else { throw ClusterPairingStoreError.unreadable(url.lastPathComponent) }
        return data
    }

    /// Temporary file (0600, exclusive, no symlink) in the same directory, fsync, rename.
    private func writePrivate(_ data: Data, to url: URL) throws {
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ClusterPairingStoreError.writeFailed(url.lastPathComponent) }
        var ok = fchmod(fd, 0o600) == 0
        if ok {
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            ok = written == data.count && fsync(fd) == 0
        }
        close(fd)
        guard ok, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw ClusterPairingStoreError.writeFailed(url.lastPathComponent)
        }
    }

    static func encode(_ records: ClusterPairingRecords) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(records)
    }

    static func timestamp(_ epochSeconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: epochSeconds))
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func hexDecode(_ text: String) -> Data? {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var result = Data(capacity: digits.count / 2)
        var index = 0
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            default: return nil
            }
        }
        while index < digits.count {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
            result.append(high << 4 | low)
            index += 2
        }
        return result
    }
}

extension ClusterPairingParticipant {
    /// A participant whose roster generation and cluster label come from
    /// this Mac's earlier pairing with the same peer, if any: re-pairing keeps
    /// the label and raises the generation. `clusterID` overrides the label.
    public static func storeBacked(identity: any ClusterPairingIdentity, name: String, interface: String,
                                   attestation: @escaping @Sendable (Data) throws -> Data, store: ClusterPairingStore,
                                   clusterID: String? = nil) -> ClusterPairingParticipant {
        ClusterPairingParticipant(identity: identity, name: name, interface: interface, attestation: attestation,
            knownGeneration: { peerPin in ((try? store.load())?.pairing(peerPin: peerPin)?.roster.generation) ?? 0 },
            clusterLabel: { localPin, peerPin in
                clusterID ?? ((try? store.load())?.pairing(peerPin: peerPin)?.clusterID)
                    ?? ClusterPairingLabel.derived(pins: [localPin, peerPin])
            })
    }
}
