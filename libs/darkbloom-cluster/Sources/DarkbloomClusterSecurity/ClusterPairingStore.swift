import CryptoKit
import Darwin
import Foundation
import Security

/// One pairing as this Mac stored it: the other Mac's pinned key, the roster
/// both countersigned, and the link edge both key their link control channel
/// with. Public values only; the edge secret is in the Keychain (or, on a
/// build without it, in its own owner-only file).
public struct ClusterPairingRecord: Codable, Sendable, Equatable {
    public struct Roster: Codable, Sendable, Equatable {
        public let generation: UInt64
        public let members: [ClusterPairingRosterMember]
    }
    public struct Link: Codable, Sendable, Equatable {
        /// The link epoch and edge of the setup's `linkControl` block.
        public let linkEpoch: String
        public let edgeID: String
        /// The pairing's `edge-<pin>.secret` in this store: the edge secret's
        /// file on 0.10.12 and on builds without the Keychain, and the name a
        /// setup's `linkControl` gives the pairing's secret. Kept on every
        /// build, so 0.10.12 still reads `pairings.json` after a rollback.
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
    /// The pairing's link key is in this Mac's Keychain, which is locked until someone logs in after a restart.
    case keychainLocked
    case keychainUnavailable(Int32)
    /// Neither the Keychain nor 0.10.12's file holds the pairing's link key.
    case linkKeyMissing
    /// The pairing was replaced while its link key was read (a new ceremony with the same Mac): read it again.
    case pairingChanged

    public var description: String {
        switch self {
        case .unsafe(let name): return "\(name) is not private to this user (expected an owner-only file); nothing is trusted from it"
        case .unreadable(let name): return "\(name) could not be read"
        case .malformed(let name): return "\(name) is malformed; nothing is trusted from it"
        case .writeFailed(let name): return "\(name) could not be written"
        case .notPaired: return "no pairing with that key"
        case .keychainLocked:
            return "the pairing's link key is in this Mac's Keychain, which stays locked after a restart until someone logs in to this Mac"
        case .keychainUnavailable(let status): return "this Mac's Keychain did not give the pairing's link key (OSStatus \(status))"
        case .linkKeyMissing: return "the pairing's link key is gone: the Macs must pair again"
        case .pairingChanged: return "the pairing changed while its link key was read"
        }
    }
}

/// The pairing store: `cluster-pairing/` in the install's own folder (0700;
/// production's `~/.darkbloom/cluster-pairing`, the provider picks it per
/// install) with `pairings.json`, `gate.json` (the lockout) and `audit.jsonl`,
/// every file 0600 and written atomically. A file that is not private to this
/// user is refused, never repaired: trust rests on these files, so a widened
/// mode fails closed.
///
/// Edge secrets are in `vault` (the provider's: the data-protection Keychain),
/// one item per other Mac. Without a vault, or on a build the Keychain refuses
/// (`notEntitled`: ad-hoc and local builds), each is in its own
/// `edge-<pin>.secret` beside the records, as 0.10.12 keeps it; such a file is
/// moved into the vault the first time a vault build reads it.
public final class ClusterPairingStore: @unchecked Sendable {
    public let directory: URL
    public let vault: (any ClusterEdgeSecretVault)?
    private let lock = NSLock()
    private let clock: @Sendable () -> Double

    public var recordsFile: URL { directory.appendingPathComponent("pairings.json") }
    var gateFile: URL { directory.appendingPathComponent("gate.json") }
    public var auditFile: URL { directory.appendingPathComponent("audit.jsonl") }
    public func secretFile(peerPin: String) -> URL { directory.appendingPathComponent("edge-\(peerPin.prefix(16)).secret") }

    public init(directory: URL, vault: (any ClusterEdgeSecretVault)? = nil,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.directory = directory; self.vault = vault; self.clock = clock
    }

    /// Which ceremony made a pairing's secret, from its public values: every ceremony derives a new link epoch.
    static func binding(of record: ClusterPairingRecord) -> String {
        "link-epoch \(record.link.linkEpoch) edge \(record.link.edgeID)"
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

    /// The edge secret of a pairing. Only the link control keying calls this; nothing prints it.
    ///
    /// With a vault it is the item of the other Mac's pin that this pairing made (`binding(of:)`). The first read
    /// after an update from 0.10.12 moves that release's file in: the item is stored and read back, and only an item
    /// that reads back equal lets the file be overwritten and removed. Each step may be cut short (a crash, another
    /// process moving the same file) and the next read finishes it. A locked Keychain refuses (`keychainLocked`) and
    /// changes nothing, the file included.
    public func edgeSecret(for record: ClusterPairingRecord) throws -> Data {
        try lock.withLock { try edgeSecretLocked(record) }
    }

    private func edgeSecretLocked(_ record: ClusterPairingRecord) throws -> Data {
        let url = try legacySecretFile(of: record)
        switch try secretHome(peerPin: record.peerPin) {
        case .file:
            guard let legacy = try readLegacySecret(url) else { throw ClusterPairingStoreError.linkKeyMissing }
            return legacy.secret
        case .keychain(_, let item):
            if let item, item.binding == Self.binding(of: record), item.secret.count == 32 {
                removeLeftoverLegacySecret(url)
                return item.secret
            }
            // The move, under the store's lock across processes; what another process did meanwhile is read again.
            return try withSecretsLock {
                guard try loadLocked()?.pairing(peerPin: record.peerPin) == record else {
                    throw ClusterPairingStoreError.pairingChanged
                }
                switch try secretHome(peerPin: record.peerPin) {
                case .file:
                    guard let legacy = try readLegacySecret(url) else { throw ClusterPairingStoreError.linkKeyMissing }
                    return legacy.secret
                case .keychain(let vault, let item):
                    if let item, item.binding == Self.binding(of: record), item.secret.count == 32 { return item.secret }
                    return try moveIntoVault(record, from: url, vault: vault, replacing: item)
                }
            }
        }
    }

    /// Runs `body` holding an advisory lock on `.edge-secrets.lock` in this store, so no two processes move, pair,
    /// unpair or write back a secret at once (always after the store's own lock for this process; never nested). A
    /// holder that doesn't let go within `waitSeconds` (a stopped process) doesn't hold `body` up, nor does a lock
    /// file that can't be opened or a file system without `flock`: `body` then runs on the checks every step makes
    /// on its own (the read-back, the record check, the file's identity).
    private func withSecretsLock<T>(waitSeconds: Double = 10, _ body: () throws -> T) throws -> T {
        let fd = open(directory.appendingPathComponent(".edge-secrets.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, waitSeconds) * 1_000_000_000)
        var held = false
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { held = true; break }
            guard errno == EWOULDBLOCK || errno == EINTR, DispatchTime.now().uptimeNanoseconds < deadline else { break }
            usleep(20_000)
        }
        defer { if held { flock(fd, LOCK_UN) } }
        return try body()
    }

    /// A file still beside the item that holds its key was left by a move cut short, or written back for a rollback
    /// (`writeLegacyFilesForRollback`). Only one last written before this process started is removed: the rollback's
    /// file is written while the release it rolls back still runs (its cluster service drives the rollback), and is
    /// for the release it restores. The next process of a release that keeps keys in the Keychain removes it.
    private func removeLeftoverLegacySecret(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, Self.writtenBeforeThisProcessStarted(info) else { return }
        removeLegacySecret(url, identity: FileIdentity(info))
    }

    /// This process's start (the kernel's), in seconds since 1970; minus infinity when it can't be read, which keeps
    /// every leftover file.
    static let processStart: Double = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -.infinity }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }()

    static func writtenBeforeThisProcessStarted(_ info: stat) -> Bool {
        Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000 < processStart
    }

    /// Where a pairing's edge secret goes next: the vault (with the item there now, any pairing's), or 0.10.12's file
    /// (no vault, or a build the Keychain refuses). A locked or failing Keychain throws before anything changes.
    private enum SecretHome {
        case keychain(any ClusterEdgeSecretVault, ClusterEdgeSecretItem?)
        case file

        var inVault: Bool { if case .keychain = self { return true } else { return false } }
        var item: ClusterEdgeSecretItem? { if case .keychain(_, let item) = self { return item } else { return nil } }
    }

    private func secretHome(peerPin: String) throws -> SecretHome {
        guard let vault else { return .file }
        switch vault.read(peerPin: peerPin) {
        case .found(let item): return .keychain(vault, item)
        case .absent: return .keychain(vault, nil)
        case .failed(.notEntitled): return .file
        case .failed(let failure): throw Self.error(failure)
        }
    }

    static func error(_ failure: ClusterEdgeSecretVaultFailure) -> ClusterPairingStoreError {
        switch failure {
        case .locked: return .keychainLocked
        case .notEntitled: return .keychainUnavailable(errSecMissingEntitlement)
        case .status(let status): return .keychainUnavailable(status)
        }
    }

    /// 0.10.12's file of a pairing: the record's `secretFile`, which must lie in this store.
    private func legacySecretFile(of record: ClusterPairingRecord) throws -> URL {
        let url = URL(fileURLWithPath: record.link.secretFile)
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else {
            throw ClusterPairingStoreError.malformed(url.lastPathComponent)
        }
        return url
    }

    /// The move of 0.10.12's file into the vault (no item of this pairing there yet; `stale` is an earlier pairing's).
    private func moveIntoVault(_ record: ClusterPairingRecord, from url: URL, vault: any ClusterEdgeSecretVault,
                               replacing stale: ClusterEdgeSecretItem?) throws -> Data {
        let binding = Self.binding(of: record)
        let legacy: LegacySecret
        do {
            guard let read = try readLegacySecret(url) else { throw ClusterPairingStoreError.linkKeyMissing }
            legacy = read
        } catch let error as ClusterPairingStoreError where error == .linkKeyMissing || error == .malformed(url.lastPathComponent) {
            // A process of a release without this lock may have just moved the file (or be overwriting it): then its
            // item answers.
            if case .found(let item) = vault.read(peerPin: record.peerPin), item.binding == binding, item.secret.count == 32 {
                return item.secret
            }
            throw error
        }
        try store(ClusterEdgeSecretItem(secret: legacy.secret, binding: binding), peerPin: record.peerPin, in: vault,
                  previous: stale, overwrite: false)
        removeLegacySecret(url, identity: legacy.identity)
        auditLocked("link_key_moved_to_keychain", ["peer_pin": String(record.peerPin.prefix(16))])
        return legacy.secret
    }

    /// Stores `item` for `peerPin` (adding it, or replacing `previous`) and reads it back: only an item that reads
    /// back equal counts as stored. A move (`overwrite` false) never overwrites an item another process added in
    /// the meantime: the read-back then decides; a new pairing (`overwrite`) does.
    private func store(_ item: ClusterEdgeSecretItem, peerPin: String, in vault: any ClusterEdgeSecretVault,
                       previous: ClusterEdgeSecretItem?, overwrite: Bool) throws {
        var write = previous == nil ? vault.add(peerPin: peerPin, item) : vault.replace(peerPin: peerPin, item)
        if write == .absent { write = vault.add(peerPin: peerPin, item) }
        if write == .exists, overwrite { write = vault.replace(peerPin: peerPin, item) }
        switch write {
        case .done, .exists: break
        case .absent: throw ClusterPairingStoreError.keychainUnavailable(errSecItemNotFound)
        case .failed(let failure): throw Self.error(failure)
        }
        switch vault.read(peerPin: peerPin) {
        case .found(let stored) where stored == item: return
        case .found: throw ClusterPairingStoreError.writeFailed("the Keychain item")
        case .absent: throw ClusterPairingStoreError.keychainUnavailable(errSecItemNotFound)
        case .failed(let failure): throw Self.error(failure)
        }
    }

    /// Where a pairing's link key is now, without reading it.
    public enum LinkKeyLocation: Equatable, Sendable {
        /// The Keychain item of this pairing, as the Keychain protects it; `legacyFileLeft` when 0.10.12's file is still
        /// beside it (removed by the next process that reads the key).
        case keychain(ClusterEdgeSecretItemProtection, legacyFileLeft: Bool)
        /// 0.10.12's file (not moved yet, or a build that keeps files).
        case file
        case missing
        case keychainLocked
        case keychainUnavailable(Int32)
    }

    public func linkKeyLocation(for record: ClusterPairingRecord) -> LinkKeyLocation {
        lock.withLock {
            guard let url = try? legacySecretFile(of: record) else { return .missing }
            var info = stat()
            let file: LinkKeyLocation = lstat(url.path, &info) == 0 ? .file : .missing
            guard let vault else { return file }
            switch vault.protection(peerPin: record.peerPin) {
            case .success(let protection?) where protection.binding == Self.binding(of: record):
                return .keychain(protection, legacyFileLeft: file == .file)
            case .success, .failure(.notEntitled): return file
            case .failure(.locked): return .keychainLocked
            case .failure(.status(let status)): return .keychainUnavailable(status)
            }
        }
    }

    /// The rollback path to 0.10.12, which reads edge secrets only from files: when the updater restores such a
    /// release, each pairing's secret is written back from the vault into its `edge-<pin>.secret`, in that release's
    /// format (one hex line, owner-only). The items stay: a process of this release started before the write leaves
    /// the file alone, the next update moves it in again, and a pairing the older release makes meanwhile wins by its
    /// binding. `rewrite` writes a pairing's file again when one is there (a new file, newer than every process
    /// running then); without it such a file is kept. A pairing whose item belongs to another pairing is left as it
    /// is. Never throws; one line per pairing for the updater's log, without key material.
    public func writeLegacyFilesForRollback(rewrite: Bool = false) -> [String] {
        lock.withLock {
            guard let vault, (try? requireDirectory(create: false)) == true else { return [] }
            // A rollback waits at most two seconds for another process's secret change.
            return (try? withSecretsLock(waitSeconds: 2) { (try? loadLocked())?.pairings.map { record in
                let name = "the pairing with \(record.peerPin.prefix(16))"
                guard let url = try? legacySecretFile(of: record) else { return "\(name): its record names no file in this store" }
                var info = stat()
                if !rewrite, lstat(url.path, &info) == 0 { return "\(name): \(url.lastPathComponent) is there already" }
                switch vault.read(peerPin: record.peerPin) {
                case .found(let item) where item.binding == Self.binding(of: record) && item.secret.count == 32:
                    do {
                        try writePrivate(Data((Self.hex(item.secret) + "\n").utf8), to: url)
                    } catch {
                        return "\(name): \(url.lastPathComponent) could not be written"
                    }
                    auditLocked("link_key_written_for_rollback", ["peer_pin": String(record.peerPin.prefix(16))])
                    return "\(name): its link key was written back to \(url.lastPathComponent)"
                case .found: return "\(name): the Keychain holds another pairing's key"
                case .absent: return "\(name): its link key is not in the Keychain"
                case .failed(.locked): return "\(name): the Keychain is locked until someone logs in to this Mac"
                case .failed(.notEntitled): return "\(name): this build keeps no link key in the Keychain"
                case .failed(.status(let status)): return "\(name): the Keychain did not answer (OSStatus \(status))"
                }
            } ?? [] }) ?? []
        }
    }

    // MARK: - Writing

    /// What `commit` replaced, so `rollback` can put it back.
    public struct Commit: Sendable {
        let peerPin: String
        let previousRecords: ClusterPairingRecords?
        let previousSecret: Data?
        /// The secret went into the vault, where `previousItem` was before.
        let inVault: Bool
        let previousItem: ClusterEdgeSecretItem?
    }

    /// Stores a finished ceremony: the edge secret first (the vault's item, or
    /// 0.10.12's file), then the records (atomic rename), then, with a vault,
    /// the peer's 0.10.12 file is removed. A failure at any point restores what
    /// was there. A record set made under another local identity is replaced
    /// whole: its pins name keys this Mac no longer signs with.
    @discardableResult
    public func commit(_ outcome: ClusterPairingOutcome, edgeID: UUID) throws -> Commit {
        try lock.withLock {
            _ = try requireDirectory(create: true)
            return try withSecretsLock { try commitLocked(outcome, edgeID: edgeID) }
        }
    }

    private func commitLocked(_ outcome: ClusterPairingOutcome, edgeID: UUID) throws -> Commit {
        let previous = try loadLocked()
        let secretURL = secretFile(peerPin: outcome.peer.pin)
        let previousSecret = try readPrivate(secretURL, maximum: 256)
        let home = try secretHome(peerPin: outcome.peer.pin)
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
        let token = Commit(peerPin: record.peerPin, previousRecords: previous, previousSecret: previousSecret,
                           inVault: home.inVault, previousItem: home.item)
        do {
            switch home {
            case .keychain(let vault, let item):
                try store(ClusterEdgeSecretItem(secret: outcome.edgeSecret, binding: Self.binding(of: record)),
                          peerPin: record.peerPin, in: vault, previous: item, overwrite: true)
            case .file:
                try writePrivate(Data((Self.hex(outcome.edgeSecret) + "\n").utf8), to: secretURL)
            }
            try writePrivate(try Self.encode(records), to: recordsFile)
            if token.inVault { removeLegacySecret(secretURL) }
        } catch {
            restoreLocked(token)
            auditLocked("persist_failed", ["peer_pin": String(record.peerPin.prefix(16))])
            switch error as? ClusterPairingStoreError {
            case .keychainLocked?, .keychainUnavailable?: throw error
            default: throw ClusterPairingStoreError.writeFailed("pairings.json")
            }
        }
        auditLocked("pair_stored", ["peer_pin": String(record.peerPin.prefix(16)), "cluster": record.clusterID,
                                    "generation": String(record.roster.generation), "roster_sha256": String(record.rosterSHA256.prefix(16))])
        return token
    }

    /// Puts back what `commit` replaced (the other Mac did not finish).
    public func rollback(_ token: Commit) {
        lock.withLock {
            _ = try? withSecretsLock { restoreLocked(token) }
            auditLocked("rollback", ["peer_pin": String(token.peerPin.prefix(16))])
        }
    }

    private func restoreLocked(_ token: Commit) {
        if token.inVault, let vault {
            if let previous = token.previousItem {
                if vault.replace(peerPin: token.peerPin, previous) == .absent { _ = vault.add(peerPin: token.peerPin, previous) }
            } else {
                _ = vault.delete(peerPin: token.peerPin)
            }
        }
        let secretURL = secretFile(peerPin: token.peerPin)
        if let previous = token.previousSecret { try? writePrivate(previous, to: secretURL) } else { unlink(secretURL.path) }
        if let previous = token.previousRecords, let data = try? Self.encode(previous) { try? writePrivate(data, to: recordsFile) }
        else { unlink(recordsFile.path) }
    }

    /// Unpairs: removes the record (the trust anchor) first, then the edge
    /// secret (the vault's item and any 0.10.12 file); with no pairing left,
    /// every item of the vault (none is used). A locked Keychain, which could
    /// not delete the item, refuses before anything changes.
    @discardableResult
    public func forget(peerPin: String) throws -> ClusterPairingRecord {
        try lock.withLock {
            guard try requireDirectory(create: false) else { throw ClusterPairingStoreError.notPaired }
            return try withSecretsLock {
                guard var records = try loadLocked(), let record = records.pairing(peerPin: peerPin) else {
                    throw ClusterPairingStoreError.notPaired
                }
                if let vault, case .failed(.locked) = vault.read(peerPin: peerPin) { throw ClusterPairingStoreError.keychainLocked }
                records.pairings.removeAll { $0.peerPin == peerPin }
                if records.pairings.isEmpty { unlink(recordsFile.path) } else { try writePrivate(try Self.encode(records), to: recordsFile) }
                removeLegacySecret(secretFile(peerPin: peerPin))
                if let vault {
                    switch records.pairings.isEmpty ? vault.deleteAll() : vault.delete(peerPin: peerPin) {
                    case .done, .exists, .absent, .failed(.notEntitled): break
                    case .failed: auditLocked("link_key_not_deleted", ["peer_pin": String(peerPin.prefix(16))])
                    }
                }
                auditLocked("unpaired", ["peer_pin": String(peerPin.prefix(16))])
                return record
            }
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

    /// Which file was read (device and inode), so only that file is removed.
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }

    private struct LegacySecret {
        let secret: Data
        let identity: FileIdentity
    }

    /// 0.10.12's file: one hex line of the 32 secret bytes in an owner-only regular file. Nil when there is none.
    private func readLegacySecret(_ url: URL) throws -> LegacySecret? {
        guard let (data, info) = try readPrivateFile(url, maximum: 256) else { return nil }
        guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = Self.hexDecode(line), secret.count == 32 else {
            throw ClusterPairingStoreError.malformed(url.lastPathComponent)
        }
        return LegacySecret(secret: secret, identity: FileIdentity(info))
    }

    /// Overwrites 0.10.12's file where it lies (never through a link), flushes it, then removes it; with `identity`,
    /// only while it is still the file that was read (one put there since is left to the next read). A file that is
    /// not this user's regular file is left alone. The overwrite is best effort: APFS snapshots and clones keep their
    /// own copies. Returns whether no file is left.
    @discardableResult
    private func removeLegacySecret(_ url: URL, identity: FileIdentity? = nil) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), identity.map({ $0 == FileIdentity(info) }) ?? true else {
            return false
        }
        let fd = open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            var opened = stat()
            if fstat(fd, &opened) == 0, FileIdentity(opened) == FileIdentity(info) {
                let zeros = [UInt8](repeating: 0, count: Int(min(max(opened.st_size, 0), 4096)))
                _ = zeros.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
                _ = fsync(fd)
            }
            close(fd)
        }
        var now = stat()
        guard lstat(url.path, &now) == 0 else { return errno == ENOENT }
        guard FileIdentity(now) == FileIdentity(info) else { return false }
        return unlink(url.path) == 0 || errno == ENOENT
    }

    /// Nil when the file does not exist.
    private func readPrivate(_ url: URL, maximum: Int) throws -> Data? {
        try readPrivateFile(url, maximum: maximum)?.data
    }

    private func readPrivateFile(_ url: URL, maximum: Int) throws -> (data: Data, info: stat)? {
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
        return (data, info)
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
