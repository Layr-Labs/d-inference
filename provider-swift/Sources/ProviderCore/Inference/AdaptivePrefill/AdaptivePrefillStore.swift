import CryptoKit
import Foundation

public struct AdaptivePrefillStoreKey: Sendable, Hashable {
    public let modelId: String
    public let weightIdentity: String
    public let kvMode: String
    public let hardwareMemoryFingerprint: String
    /// Algorithm/version identity folded into the hashed key so a policy change
    /// yields a fresh key namespace — machines that learned a rung under an
    /// older decision algorithm never collide with the new one.
    public let policyIdentity: String

    public init(
        modelId: String,
        weightIdentity: String,
        kvMode: String,
        hardwareMemoryFingerprint: String,
        policyIdentity: String = AdaptivePrefillPolicy.algorithmIdentity
    ) {
        self.modelId = modelId
        self.weightIdentity = weightIdentity
        self.kvMode = kvMode
        self.hardwareMemoryFingerprint = hardwareMemoryFingerprint
        self.policyIdentity = policyIdentity
    }

    var storageKey: String {
        let raw = [
            modelId,
            weightIdentity,
            kvMode,
            hardwareMemoryFingerprint,
            policyIdentity,
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(raw.utf8)).hexString
    }
}

public final class AdaptivePrefillStore: @unchecked Sendable {
    /// On-disk schema version. Bumped 1→2 with the move from the duration-based
    /// policy to the ms/token hill-climb: a v1 file is ignored wholesale on load
    /// so previously learned 1024/1536 rungs re-seed cleanly instead of blocking
    /// adoption. Mismatched per-entry `policyVersion` is filtered separately by
    /// `AdaptivePrefillPolicy.initialState`.
    static let currentFileVersion = 2

    private struct PersistedFile: Codable {
        var version: Int
        var states: [String: AdaptivePrefillState]
    }

    private let url: URL
    /// Guards the in-memory read + merge of the states map (fast).
    private let lock = NSLock()
    /// Serializes the on-disk write so it can run OUTSIDE `lock`, keeping slow
    /// file I/O off the lock that `load` (and concurrent saves) contend on while
    /// still making each save's read-merge-write atomic on this instance.
    private let ioLock = NSLock()

    public init(url: URL = AdaptivePrefillStore.defaultURL()) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("darkbloom", isDirectory: true)
            .appendingPathComponent("adaptive-prefill.json")
    }

    public func load(key: AdaptivePrefillStoreKey) -> AdaptivePrefillState? {
        lock.lock()
        defer { lock.unlock() }
        return readUnlocked().states[key.storageKey]
    }

    /// Persisted on a rung TRANSITION only (the cold path) — never per request.
    /// The read + merge + encode runs under `lock`; the actual file write runs
    /// outside it (serialized by `ioLock`) so the slow disk write never blocks
    /// `load` or another save's in-memory merge. `ioLock` makes the whole
    /// read-merge-write atomic on this instance, so no save can lose another's
    /// key.
    public func save(_ state: AdaptivePrefillState, key: AdaptivePrefillStoreKey) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        let data = try encodeMergedSnapshot(state, key: key)
        try persist(data)
    }

    private func encodeMergedSnapshot(_ state: AdaptivePrefillState, key: AdaptivePrefillStoreKey) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        var file = readUnlocked()
        file.states[key.storageKey] = state
        return try JSONEncoder().encode(file)
    }

    private func persist(_ data: Data) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private func readUnlocked() -> PersistedFile {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(PersistedFile.self, from: data),
              file.version == Self.currentFileVersion
        else {
            return PersistedFile(version: Self.currentFileVersion, states: [:])
        }
        return file
    }
}
