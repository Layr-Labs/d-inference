import Foundation

/// Durable, random generation for one model's reusable SSD cache. The record is
/// descriptor-read/written without following links; binding drift wipes DBK3
/// blocks before a new epoch can be advertised.
final class SSDCacheEpochStore: @unchecked Sendable {
    private final class EpochLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var epochByRoot: [String: String] = [:]

        func publish(root: String, epoch: String?) {
            lock.withLock {
                epochByRoot[root] = epoch
            }
        }

        func current(root: String) -> String? {
            lock.withLock { epochByRoot[root] }
        }
    }

    struct Binding: Codable, Equatable, Sendable {
        let modelId: String
        let modelAggregateHash: String
        let promptContractId: String
        let blockHashVersion: String
        let blockSize: Int
        let layoutEpoch: String
        let keyFingerprint: String
    }

    private struct Record: Codable {
        let schema: String
        let epoch: String
        let binding: Binding
        let nextSequence: UInt64
    }

    private struct ReadResult {
        let exists: Bool
        let record: Record?
    }

    private static let fileName = "cache-epoch.json"
    private static let schema = "darkbloom.cache-epoch.v1"
    private static let invalidatingSchema = "darkbloom.cache-epoch.invalidating.v1"
    private static let maxRecordBytes = 64 * 1024
    private static let epochs = EpochLedger()
    private static let recordLock = NSLock()

    private let lock = NSLock()
    private let root: URL
    private let rootKey: String
    private let binding: Binding
    private var epoch: String?

    init(root: URL, binding: Binding) throws {
        self.root = root
        self.rootKey = Self.canonicalRootKey(root)
        self.binding = binding
        let url = root.appendingPathComponent(Self.fileName)
        let rootKey = self.rootKey
        let selectedEpoch = try Self.recordLock.withLock {
            let existing = try Self.readRecord(at: url)
            if let record = existing.record,
                record.schema == Self.schema,
                record.binding == binding,
                Self.validEpoch(record.epoch)
            {
                Self.epochs.publish(root: rootKey, epoch: record.epoch)
                return record.epoch
            }

            if existing.exists {
                // Persist and publish invalidation before deleting any block.
                // Keeping the previous binding in this intermediate record
                // makes a crash during the wipe retry the destructive rebuild
                // on the next initialization.
                if let record = existing.record {
                    let invalidatingEpoch = Self.newEpoch()
                    try Self.write(
                        record: Record(
                            schema: Self.invalidatingSchema,
                            epoch: invalidatingEpoch,
                            binding: record.binding,
                            nextSequence: 1),
                        to: url)
                    Self.epochs.publish(root: rootKey, epoch: invalidatingEpoch)
                } else {
                    Self.epochs.publish(root: rootKey, epoch: nil)
                }
                try Self.removeAllBlockFiles(under: root)
            } else {
                // A concurrently removed metadata record cannot leave an
                // in-process owner advertising its now-unverifiable epoch.
                Self.epochs.publish(root: rootKey, epoch: nil)
            }

            let fresh = Self.newEpoch()
            try Self.write(
                record: Record(
                    schema: Self.schema,
                    epoch: fresh,
                    binding: binding,
                    nextSequence: 1),
                to: url)
            Self.epochs.publish(root: rootKey, epoch: fresh)
            return fresh
        }
        self.epoch = selectedEpoch
    }

    var current: String? {
        guard let ownedEpoch = lock.withLock({ epoch }),
            Self.epochs.current(root: rootKey) == ownedEpoch
        else { return nil }
        return ownedEpoch
    }

    func takeNextSequence(expectedEpoch: String) -> UInt64? {
        guard let ownedEpoch = lock.withLock({ epoch }),
            ownedEpoch == expectedEpoch,
            current == ownedEpoch
        else { return nil }
        return Self.recordLock.withLock {
            let url = root.appendingPathComponent(Self.fileName)
            guard let existing = try? Self.readRecord(at: url),
                let record = existing.record,
                record.schema == Self.schema,
                record.epoch == ownedEpoch,
                record.binding == binding,
                record.nextSequence > 0,
                record.nextSequence < UInt64.max
            else { return nil }
            do {
                try Self.write(
                    record: Record(
                        schema: record.schema,
                        epoch: record.epoch,
                        binding: record.binding,
                        nextSequence: record.nextSequence + 1),
                    to: url)
                return record.nextSequence
            } catch {
                return nil
            }
        }
    }

    /// Explicit invalidation of every block under this root (binding drift,
    /// whole-root wipe). A persistence failure disables v2 advertisement
    /// instead of exposing an unpersisted generation. Capacity eviction, TTL
    /// expiry, reconciliation, and corrupt-block drops do NOT rotate — they go
    /// through `performOwnedNonRotatingChange`, so the coordinator's holders
    /// for the surviving blocks stay valid.
    @discardableResult
    func rotate() -> String? {
        guard performOwnedDestructiveChange({}) != nil else { return nil }
        return current
    }

    /// Serializes a destructive change that KEEPS the current epoch: the same
    /// ownership verification (in-process ledger, then the durable record
    /// under the process-wide record lock, so constructors and unloaded-root
    /// maintenance cannot interleave with `body`), but no fresh generation, no
    /// record rewrite, and no unpublication — a heartbeat inside `body`
    /// advertises the unchanged epoch.
    ///
    /// The instance lock is deliberately NOT held across `body`: `current` is
    /// read under `SSDPrefixCache.lock` on the engine submit thread, and an
    /// unlink must never stall a lookup. The record lock still is, which keeps
    /// the `lock → recordLock` order of the rotating variant; the failure path
    /// therefore disowns after leaving the record lock.
    func performOwnedNonRotatingChange<T>(_ body: () -> T) -> T? {
        let ownedEpoch: String? = lock.withLock {
            guard let owned = epoch, Self.epochs.current(root: rootKey) == owned else {
                epoch = nil
                return nil
            }
            return owned
        }
        guard let ownedEpoch else { return nil }
        let url = root.appendingPathComponent(Self.fileName)
        var verified = false
        let result: T? = Self.recordLock.withLock {
            guard let existing = try? Self.readRecord(at: url),
                let record = existing.record,
                record.schema == Self.schema,
                record.epoch == ownedEpoch,
                record.binding == binding
            else {
                Self.epochs.publish(root: rootKey, epoch: nil)
                return nil
            }
            verified = true
            return body()
        }
        guard verified else {
            lock.withLock {
                if epoch == ownedEpoch { epoch = nil }
            }
            return nil
        }
        return result
    }

    /// Serializes epoch replacement, destructive I/O, and publication for an
    /// active cache. Constructors and unloaded-root maintenance share the same
    /// record lock, while the in-process ledger is unavailable during `body`.
    func performOwnedDestructiveChange<T>(_ body: () -> T) -> T? {
        lock.withLock {
            guard let ownedEpoch = epoch,
                Self.epochs.current(root: rootKey) == ownedEpoch
            else {
                epoch = nil
                return nil
            }
            let fresh = Self.newEpoch()
            return Self.recordLock.withLock {
                do {
                    let url = root.appendingPathComponent(Self.fileName)
                    guard let existing = try? Self.readRecord(at: url),
                        let record = existing.record,
                        record.schema == Self.schema,
                        record.epoch == ownedEpoch,
                        record.binding == binding
                    else {
                        epoch = nil
                        Self.epochs.publish(root: rootKey, epoch: nil)
                        return nil
                    }
                    try Self.write(
                        record: Record(
                            schema: Self.schema,
                            epoch: fresh,
                            binding: binding,
                            nextSequence: 1),
                        to: url)
                    epoch = fresh
                    Self.epochs.publish(root: rootKey, epoch: nil)
                    let result = body()
                    Self.epochs.publish(root: rootKey, epoch: fresh)
                    return result
                } catch {
                    epoch = nil
                    Self.epochs.publish(root: rootKey, epoch: nil)
                    return nil
                }
            }
        }
    }

    /// Serializes unloaded-root deletion with store initialization. The new
    /// epoch is persisted before unlink and published only after unlink ends.
    static func performUnloadedDestructiveChange(
        root: URL,
        _ body: () -> Void
    ) -> Bool {
        recordLock.withLock {
            let url = root.appendingPathComponent(fileName)
            guard let existing = try? readRecord(at: url) else { return false }
            guard existing.exists else {
                body()
                return true
            }
            guard let record = existing.record,
                record.schema == schema,
                validEpoch(record.epoch)
            else { return false }
            let fresh = newEpoch()
            do {
                try write(
                    record: Record(
                        schema: schema,
                        epoch: fresh,
                        binding: record.binding,
                        nextSequence: 1),
                    to: url)
                epochs.publish(root: canonicalRootKey(root), epoch: nil)
                body()
                epochs.publish(root: canonicalRootKey(root), epoch: fresh)
                return true
            } catch {
                return false
            }
        }
    }

    private static func canonicalRootKey(_ root: URL) -> String {
        root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func readRecord(at url: URL) throws -> ReadResult {
        switch SSDNoFollowIO.regularFileStatus(at: url) {
        case .missing:
            return ReadResult(exists: false, record: nil)
        case .invalid:
            throw SSDBlockStoreError.ioFailure("cache epoch path is not a regular file")
        case .regular:
            let handle = try SSDNoFollowIO.openRegularFileForReading(at: url)
            defer { try? handle.close() }
            guard let data = try handle.readToEnd(), data.count <= maxRecordBytes else {
                throw SSDBlockStoreError.ioFailure("cache epoch record is oversized")
            }
            return ReadResult(
                exists: true,
                record: try? JSONDecoder().decode(Record.self, from: data))
        }
    }

    private static func write(record: Record, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try SSDNoFollowIO.writeMetadataAtomically(
            to: url, data: encoder.encode(record))
    }

    private static func removeAllBlockFiles(under root: URL) throws {
        let fm = FileManager.default
        let directories = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        for directory in directories
        where SSDBlockStore.isLowerHex(directory.lastPathComponent, count: 2) {
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SSDBlockStoreError.ioFailure("unsafe cache fanout during epoch rotation")
            }
            let files = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
            for file in files where file.pathExtension == SSDBlockStore.fileExtension {
                guard SSDBlockStore.removeItemIfSafe(at: file, under: root) else {
                    throw SSDBlockStoreError.ioFailure(
                        "failed to remove stale block during epoch rotation")
                }
            }
        }
    }

    private static func newEpoch() -> String {
        UUID().uuidString.lowercased()
    }

    private static func validEpoch(_ value: String) -> Bool {
        UUID(uuidString: value) != nil && value == value.lowercased()
    }
}
