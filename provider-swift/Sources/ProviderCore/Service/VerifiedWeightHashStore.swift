import Foundation
import ProviderCoreFoundation

/// Aggregate weight hashes from earlier complete SHA-256 reads (a full startup
/// registration hash, or a managed load's verification against the catalog
/// manifest), each bound to the identity of every file it covered, so a
/// restart can register a verified hash without reading the weights again.
///
/// A record is reused only while every file `WeightHasher.computeHash` covers
/// keeps its device, inode, size, and modification and status-change times;
/// a write, replacement, or added or removed file forces a full hash. Only
/// models whose managed load SHA-256-verifies every file against the catalog
/// manifest before serving consult it (`ModelInfo.weightsVerifiedByManagedLoad`),
/// so a stale or edited record can misstate the registration claim but cannot
/// put unverified bytes into service.
///
/// The file lives beside `daemon-state.json` in the provider's data directory
/// (`DARKBLOOM_VERIFIED_WEIGHTS_FILE` overrides it). Reads and writes are best
/// effort: any failure falls back to hashing.
public enum VerifiedWeightHashStore {
    public static let currentSchema = 1

    /// `stat(2)` identity of one hashed file, after resolving symlinks.
    public struct FileIdentity: Codable, Equatable, Sendable {
        public let path: String
        public let device: UInt64
        public let inode: UInt64
        public let size: Int64
        public let modifiedSeconds: Int64
        public let modifiedNanoseconds: Int64
        public let changedSeconds: Int64
        public let changedNanoseconds: Int64
    }

    struct Record: Codable, Equatable {
        let aggregateSHA256: String
        let files: [FileIdentity]
    }

    struct State: Codable {
        var schema: Int
        var records: [String: Record]
    }

    private static let lock = NSLock()

    public static func path() -> URL {
        if let override = ProcessInfo.processInfo.environment["DARKBLOOM_VERIFIED_WEIGHTS_FILE"],
            !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return BuildEnvironment.current.installDirectory()
            .appendingPathComponent("verified-weights.json")
    }

    /// Identities of the files `WeightHasher.computeHash(snapshotDir:)` hashes,
    /// in its order; nil when the snapshot has none or one cannot be stat'ed.
    public static func fileIdentities(snapshotDir: URL) -> [FileIdentity]? {
        let (_, paths) = ModelScanner.collectWeightFiles(in: snapshotDir)
        guard !paths.isEmpty else { return nil }
        var identities: [FileIdentity] = []
        identities.reserveCapacity(paths.count)
        for url in paths.sorted(by: { $0.path < $1.path }) {
            var value = stat()
            guard stat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
            identities.append(FileIdentity(
                path: url.path,
                device: UInt64(bitPattern: Int64(value.st_dev)), inode: UInt64(value.st_ino),
                size: Int64(value.st_size),
                modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                changedSeconds: Int64(value.st_ctimespec.tv_sec),
                changedNanoseconds: Int64(value.st_ctimespec.tv_nsec)))
        }
        return identities
    }

    /// The recorded aggregate when every current file identity matches it.
    public static func verifiedHash(
        modelID: String, identities: [FileIdentity]?, at url: URL = path()
    ) -> String? {
        guard let identities else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let record = read(url).records[modelID], record.files == identities else { return nil }
        return record.aggregateSHA256
    }

    /// Records `aggregateSHA256` for files whose identities were captured
    /// before the verification that produced it began.
    public static func record(
        modelID: String, aggregateSHA256: String, identities: [FileIdentity],
        at url: URL = path()
    ) {
        guard !identities.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var state = read(url)
        state.records[modelID] = Record(aggregateSHA256: aggregateSHA256, files: identities)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Best effort: the next start hashes the weights instead.
        }
    }

    private static func read(_ url: URL) -> State {
        guard let data = try? Data(contentsOf: url),
            let state = try? JSONDecoder().decode(State.self, from: data),
            state.schema == currentSchema
        else { return State(schema: currentSchema, records: [:]) }
        return state
    }
}

extension ModelInfo {
    /// The managed GLM load SHA-256-verifies every manifest file against the
    /// catalog-pinned manifest before the model serves, in both coordinator
    /// and standalone mode.
    public var weightsVerifiedByManagedLoad: Bool {
        GLM5NextPromptPolicy.applies(modelType: modelType)
    }
}
