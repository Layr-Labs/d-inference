/// PrefixCacheIndex — the on-disk index over SSD prefix-cache files
/// (design §7, phase P2). JSON-backed per `[Q3]`: the index is a few MB
/// at most, so we load it into RAM at startup, mutate in memory, and
/// write it back atomically. No SQLite dependency.
///
/// Maps `(modelHash, prefixDigest)` → the `.darkbloom-kv` file holding
/// that prefix's encrypted KV, plus token count and LRU metadata. The
/// core operation is `findLongestCheckpoint`: given an incoming
/// prompt's tokens, compute its checkpoint digests (PrefixDigest) and
/// return the entry for the LONGEST checkpoint present for that model —
/// the exact-checkpoint match (design §4.4).
///
/// MB-1: entries are partitioned by `modelHash`, so a lookup for model
/// B cannot return model A's entry.
///
/// Timestamps are passed in by the caller (`now: Int64`, unix seconds)
/// rather than read from the clock, keeping the type deterministic and
/// testable. `final class`, owned by the PrefixCacheManager actor in
/// P3; mutations mark the index dirty and a `save()` persists.

import Foundation
import os

private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "prefix-cache-index")

// MARK: - Entry

public struct PrefixIndexEntry: Codable, Sendable, Equatable {
    public let modelHash: String
    /// Hex of the prefix digest (PrefixDigest.checkpoints).
    public let digestHex: String
    /// Number of prompt tokens this prefix covers (the checkpoint length).
    public let tokenCount: Int
    /// Path to the `.darkbloom-kv` file, relative to the cache root.
    public let relativePath: String
    /// Encrypted file size in bytes (for disk-budget accounting).
    public let fileBytes: Int
    public var createdAt: Int64
    public var lastHitAt: Int64
    public var hitCount: Int

    public init(
        modelHash: String, digestHex: String, tokenCount: Int,
        relativePath: String, fileBytes: Int,
        createdAt: Int64, lastHitAt: Int64, hitCount: Int = 0
    ) {
        self.modelHash = modelHash
        self.digestHex = digestHex
        self.tokenCount = tokenCount
        self.relativePath = relativePath
        self.fileBytes = fileBytes
        self.createdAt = createdAt
        self.lastHitAt = lastHitAt
        self.hitCount = hitCount
    }
}

// MARK: - Errors

public enum PrefixCacheIndexError: Error, CustomStringConvertible, Sendable {
    case loadFailed(String)
    case saveFailed(String)

    public var description: String {
        switch self {
        case .loadFailed(let m): return "index load failed: \(m)"
        case .saveFailed(let m): return "index save failed: \(m)"
        }
    }
}

// MARK: - Index

public final class PrefixCacheIndex {

    /// On-disk JSON shape. `version` lets the format evolve.
    private struct Persisted: Codable {
        var version: Int
        var entries: [PrefixIndexEntry]
    }

    private static let formatVersion = 1

    private let fileURL: URL
    /// modelHash → (digestHex → entry).
    private var byModel: [String: [String: PrefixIndexEntry]] = [:]
    private var dirty = false

    /// Load the index from `fileURL` if it exists; otherwise start empty.
    /// A corrupt index file is treated as empty (and logged) — the SSD
    /// files are self-describing and the index can be rebuilt from them.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let persisted = try JSONDecoder().decode(Persisted.self, from: data)
            for e in persisted.entries {
                byModel[e.modelHash, default: [:]][e.digestHex] = e
            }
            logger.info("loaded prefix cache index: \(persisted.entries.count) entries")
        } catch {
            logger.warning("prefix cache index unreadable, starting empty: \(String(describing: error))")
            byModel = [:]
        }
    }

    // MARK: - Lookup

    /// Exact-checkpoint match: return the entry for the LONGEST
    /// checkpoint of `tokens` that is present for `modelHash`, or nil.
    /// Does NOT mutate hit metadata — call `touch` after a confirmed,
    /// successful load.
    public func findLongestCheckpoint(
        modelHash: String,
        tokens: [Int],
        boundaries: [Int] = PrefixDigest.defaultCheckpoints,
        scope: String = ""
    ) -> PrefixIndexEntry? {
        guard let modelEntries = byModel[modelHash], !modelEntries.isEmpty else { return nil }
        // Scoped digests: a different scope yields different boundary digests,
        // so a scope-A lookup can never match a scope-B index entry.
        let checkpoints = PrefixDigest.checkpoints(tokens: tokens, boundaries: boundaries, scope: scope)
        // Longest first.
        for cp in checkpoints.reversed() {
            if let entry = modelEntries[cp.digest.dbkvHexString] {
                return entry
            }
        }
        return nil
    }

    /// Direct lookup by digest hex (no token hashing).
    public func entry(modelHash: String, digestHex: String) -> PrefixIndexEntry? {
        byModel[modelHash]?[digestHex]
    }

    // MARK: - Mutation

    /// Insert or replace an entry.
    public func record(_ entry: PrefixIndexEntry) {
        byModel[entry.modelHash, default: [:]][entry.digestHex] = entry
        dirty = true
    }

    /// Bump hit metadata after a confirmed successful load.
    public func touch(modelHash: String, digestHex: String, now: Int64) {
        guard var e = byModel[modelHash]?[digestHex] else { return }
        e.lastHitAt = now
        e.hitCount += 1
        byModel[modelHash]![digestHex] = e
        dirty = true
    }

    /// Remove a single entry. Returns the removed entry (e.g. so the
    /// caller can delete its file), or nil if absent.
    @discardableResult
    public func remove(modelHash: String, digestHex: String) -> PrefixIndexEntry? {
        guard let e = byModel[modelHash]?.removeValue(forKey: digestHex) else { return nil }
        if byModel[modelHash]?.isEmpty == true { byModel.removeValue(forKey: modelHash) }
        dirty = true
        return e
    }

    /// Remove all entries for a model. Returns them (for file cleanup).
    @discardableResult
    public func removeModel(_ modelHash: String) -> [PrefixIndexEntry] {
        guard let removed = byModel.removeValue(forKey: modelHash) else { return [] }
        dirty = true
        return Array(removed.values)
    }

    // MARK: - Introspection

    public func entries(modelHash: String) -> [PrefixIndexEntry] {
        Array(byModel[modelHash]?.values ?? [:].values)
    }

    public func allEntries() -> [PrefixIndexEntry] {
        byModel.values.flatMap { $0.values }
    }

    public var count: Int { byModel.values.reduce(0) { $0 + $1.count } }
    public func bytes(modelHash: String) -> Int {
        byModel[modelHash]?.values.reduce(0) { $0 + $1.fileBytes } ?? 0
    }

    /// Entries for a model ordered least-recently-hit first — the
    /// eviction order for the P6 disk-budget sweep. `digestHex` is a
    /// deterministic secondary key so entries with equal `lastHitAt`
    /// sort stably (dictionary iteration order is otherwise undefined).
    public func entriesLRUFirst(modelHash: String) -> [PrefixIndexEntry] {
        entries(modelHash: modelHash).sorted {
            ($0.lastHitAt, $0.digestHex) < ($1.lastHitAt, $1.digestHex)
        }
    }

    /// TB-016 sub-feature C: Benefit-per-byte score for eviction
    /// prioritization. Higher score = more valuable = evict LAST.
    /// Lowest-score entries are evicted first.
    ///
    /// Benefit = (hitCount + 1) × tokenCount × prefillCostPerToken
    /// Recency = halfLifeSeconds / (halfLifeSeconds + age)
    /// Score = (benefit / bytes) × recency
    ///
    /// GUARD: fileBytes can be 0 (defensive).
    public static func benefitScore(
        _ e: PrefixIndexEntry,
        now: Int64,
        prefillCostPerToken: Double,
        halfLifeSeconds: Double
    ) -> Double {
        let bytes = Double(max(1, e.fileBytes))
        let benefit = Double(e.hitCount + 1) * Double(max(0, e.tokenCount))
            * max(0.0, prefillCostPerToken)
        let age = Double(max(0, now - e.lastHitAt))
        let recency = halfLifeSeconds / (halfLifeSeconds + age)
        return (benefit / bytes) * recency
    }

    /// Entries ordered by score ascending (LOWEST score = evict first).
    /// Deterministic tie-break: when scores are equal, evict older entry
    /// first (smaller lastHitAt), then by digestHex.
    public func entriesByScoreAscending(
        modelHash: String,
        now: Int64,
        prefillCostPerToken: Double,
        halfLifeSeconds: Double
    ) -> [PrefixIndexEntry] {
        entries(modelHash: modelHash)
            .map { ($0, Self.benefitScore($0, now: now, prefillCostPerToken: prefillCostPerToken, halfLifeSeconds: halfLifeSeconds)) }
            .sorted { lhs, rhs in
                let (l, ls) = lhs
                let (r, rs) = rhs
                // LOWEST score first; tie-break by (lastHitAt, digestHex).
                return (ls, l.lastHitAt, l.digestHex) < (rs, r.lastHitAt, r.digestHex)
            }
            .map { $0.0 }
    }

    public var isDirty: Bool { dirty }

    // MARK: - Persistence

    /// Atomically write the index to disk if dirty. No-op when clean.
    public func save() throws {
        guard dirty else { return }
        let persisted = Persisted(version: Self.formatVersion, entries: allEntries())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(persisted)
        } catch {
            throw PrefixCacheIndexError.saveFailed("encode: \(error)")
        }

        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Foundation's `.atomic` already writes to an auxiliary file and
        // renames into place, which is crash-safe. Using it directly (vs
        // a manual tmp-<uuid> + replaceItemAt) avoids leaking a UUID-named
        // sibling if the process dies between write and replace — the
        // earlier scheme had no sweep for those orphans.
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw PrefixCacheIndexError.saveFailed(String(describing: error))
        }
        dirty = false
    }

    /// Replace the entire index with a freshly-scanned set (used to
    /// rebuild from the filesystem when the JSON is missing/corrupt).
    public func rebuild(from entries: [PrefixIndexEntry]) {
        byModel = [:]
        for e in entries {
            byModel[e.modelHash, default: [:]][e.digestHex] = e
        }
        dirty = true
    }
}
