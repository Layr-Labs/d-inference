/// PrefixCacheRAM — the in-process, decrypted RAM tier of the SSD KV cache
/// (design doc §4.1). Holds recently-used prefix KV snapshots as live
/// `[any KVCache]` (one per layer, extracted to single-row form via
/// `BatchedCache.extractBatched(row)`) so a repeat request whose prompt prefix
/// matches a cached checkpoint hits RAM (~ms) instead of decrypting from SSD or
/// cold-prefilling. A plain `final class` (NOT `Sendable` — stores MLXArrays);
/// owned and serialized by the `PrefixCacheManager` actor.
///
/// - MB-1 (model binding): entries are keyed by `(modelHash, prefixDigest)`, so
///   a lookup for model B can't return model A's entry. The SSD tier adds the
///   metadata equality check (§8.1.1).
/// - Snapshot integrity: `get` returns a `copy()` of each cache (caller may
///   mutate freely); `put` takes ownership (caller must not mutate after).
///   Guarded by `getReturnsIndependentCopy`.
/// - Eviction: LRU by a monotonic use-counter (deterministic, no wall-clock),
///   bounded by both an entry count and a byte budget.

import Foundation
import MLX
import MLXLMCommon
import os

private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "prefix-cache-ram")

// MARK: - Key

/// Composite cache key. `modelHash` is the locally-computed weight
/// hash (never the coordinator's); `digest` is the SHA-256 of the
/// token-ID prefix at the checkpoint boundary.
public struct PrefixCacheKey: Hashable, Sendable {
    public let modelHash: String
    public let digest: Data

    public init(modelHash: String, digest: Data) {
        self.modelHash = modelHash
        self.digest = digest
    }
}

// MARK: - Hit

/// Result of a successful lookup. `caches` are independent copies the
/// caller owns; `tokenCount` is how many prompt tokens this snapshot
/// covers (the consumer skips prefill on `tokens[0..<tokenCount]`).
public struct PrefixCacheHit {
    public let caches: [any KVCache]
    public let tokenCount: Int
}

// MARK: - Stats

public struct PrefixCacheRAMStats: Sendable, Equatable {
    public var entries: Int = 0
    public var bytes: Int = 0
    public var hits: Int = 0
    public var misses: Int = 0
    public var evictions: Int = 0
    public var inserts: Int = 0
    /// Entries refused because their own size exceeded the byte budget.
    public var rejects: Int = 0
}

// MARK: - PrefixCacheRAM

public final class PrefixCacheRAM {

    // MARK: Entry

    private final class Entry {
        let key: PrefixCacheKey
        let caches: [any KVCache]
        let tokenCount: Int
        let bytes: Int
        var lastUsedTick: UInt64

        init(
            key: PrefixCacheKey, caches: [any KVCache], tokenCount: Int,
            bytes: Int, tick: UInt64
        ) {
            self.key = key
            self.caches = caches
            self.tokenCount = tokenCount
            self.bytes = bytes
            self.lastUsedTick = tick
        }
    }

    // MARK: Config

    /// Maximum number of cached prefixes. `0` disables the count bound.
    public let maxEntries: Int
    /// Maximum total decrypted bytes held. `0` disables the byte bound.
    public let maxBytes: Int

    // MARK: State

    private var entries: [PrefixCacheKey: Entry] = [:]
    private var tick: UInt64 = 0
    private var currentBytes: Int = 0
    private var stats = PrefixCacheRAMStats()

    public init(maxEntries: Int = 64, maxBytes: Int = 8 * 1024 * 1024 * 1024) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }

    // MARK: - Lookup

    /// Look up a prefix. On hit, returns independent copies of the
    /// cached caches (caller may freely mutate them) and bumps the
    /// entry's recency. On miss, returns nil.
    public func get(_ key: PrefixCacheKey) -> PrefixCacheHit? {
        guard let entry = entries[key] else {
            stats.misses += 1
            return nil
        }
        tick &+= 1
        entry.lastUsedTick = tick
        stats.hits += 1
        let copies = entry.caches.map { $0.copy() }
        return PrefixCacheHit(caches: copies, tokenCount: entry.tokenCount)
    }

    /// Convenience overload keyed by raw fields.
    public func get(modelHash: String, digest: Data) -> PrefixCacheHit? {
        get(PrefixCacheKey(modelHash: modelHash, digest: digest))
    }

    // MARK: - Insert

    /// Insert (or replace) a prefix snapshot. Takes ownership of
    /// `caches` — the caller must not mutate them after this call. The
    /// stored byte size is measured from the caches' physical buffers.
    /// Evicts LRU entries if either budget is exceeded.
    ///
    /// Returns `true` if the entry was stored, `false` if it was refused
    /// because its own size exceeds `maxBytes` (storing it would only
    /// trigger immediate self-eviction — a silent no-op — so we reject
    /// up front and count it).
    @discardableResult
    public func put(_ key: PrefixCacheKey, caches: [any KVCache], tokenCount: Int) -> Bool {
        let bytes = Self.byteSize(of: caches)

        if maxBytes > 0 && bytes > maxBytes {
            stats.rejects += 1
            logger.warning("prefix entry (\(bytes) bytes) exceeds byte budget (\(self.maxBytes)); refusing")
            return false
        }

        // Replace any existing entry for this key (drop its bytes first).
        if let old = entries[key] {
            currentBytes -= old.bytes
        }

        tick &+= 1
        let entry = Entry(
            key: key, caches: caches, tokenCount: tokenCount,
            bytes: bytes, tick: tick
        )
        entries[key] = entry
        currentBytes += bytes
        stats.inserts += 1

        evictToBudget()
        return true
    }

    /// Convenience overload keyed by raw fields.
    @discardableResult
    public func put(modelHash: String, digest: Data, caches: [any KVCache], tokenCount: Int) -> Bool {
        put(PrefixCacheKey(modelHash: modelHash, digest: digest), caches: caches, tokenCount: tokenCount)
    }

    // MARK: - Clear

    /// Drop every entry for a given model (e.g. on model unload, before
    /// flushing to SSD). Returns the number of entries removed.
    @discardableResult
    public func clear(modelHash: String) -> Int {
        let toRemove = entries.keys.filter { $0.modelHash == modelHash }
        for k in toRemove { removeEntry(k) }
        return toRemove.count
    }

    /// Drop all entries.
    public func clearAll() {
        entries.removeAll()
        currentBytes = 0
    }

    /// Snapshot every entry for a model as `(key, caches, tokenCount)`
    /// without removing them — used by the P4 flush path to serialize
    /// the RAM tier to SSD. Returns copies so the flush can encrypt
    /// without racing a concurrent mutation.
    public func entriesForFlush(modelHash: String) -> [(key: PrefixCacheKey, caches: [any KVCache], tokenCount: Int)] {
        entries.values
            .filter { $0.key.modelHash == modelHash }
            .map { ($0.key, $0.caches.map { c in c.copy() }, $0.tokenCount) }
    }

    /// Snapshot one entry for persistence. Used by second-use promotion; do
    /// not call `entriesForFlush(...).first(where:)` there, because that copies
    /// every checkpoint for the model before discarding all but one.
    public func entryForFlush(modelHash: String, digest: Data) -> (key: PrefixCacheKey, caches: [any KVCache], tokenCount: Int)? {
        let key = PrefixCacheKey(modelHash: modelHash, digest: digest)
        guard let entry = entries[key] else { return nil }
        return (entry.key, entry.caches.map { $0.copy() }, entry.tokenCount)
    }

    // MARK: - Introspection

    public func contains(_ key: PrefixCacheKey) -> Bool { entries[key] != nil }
    public var count: Int { entries.count }
    public var byteSize: Int { currentBytes }
    public func snapshotStats() -> PrefixCacheRAMStats {
        var s = stats
        s.entries = entries.count
        s.bytes = currentBytes
        return s
    }

    // MARK: - Eviction

    private func evictToBudget() {
        // Evict least-recently-used until BOTH bounds are satisfied.
        while overBudget(), let victim = lruKey() {
            removeEntry(victim)
            stats.evictions += 1
            logger.debug("evicted prefix cache entry; entries=\(self.entries.count) bytes=\(self.currentBytes)")
        }
    }

    private func overBudget() -> Bool {
        if maxEntries > 0 && entries.count > maxEntries { return true }
        if maxBytes > 0 && currentBytes > maxBytes { return true }
        return false
    }

    private func lruKey() -> PrefixCacheKey? {
        // Small N (tens of entries); linear scan for the min tick is fine.
        entries.min(by: { $0.value.lastUsedTick < $1.value.lastUsedTick })?.key
    }

    private func removeEntry(_ key: PrefixCacheKey) {
        if let e = entries.removeValue(forKey: key) {
            currentBytes -= e.bytes
        }
    }

    // MARK: - Byte accounting

    /// Resident-RAM estimate. Uses `innerState()` (the cache's
    /// physically-allocated buffers) rather than `state` (the trimmed
    /// logical view): caches like KVCacheSimple/RotatingKVCache
    /// over-allocate in `step`-sized chunks, so `state` would undercount
    /// the memory actually held. Bounding `maxBytes` on physical bytes
    /// keeps the budget honest.
    static func byteSize(of caches: [any KVCache]) -> Int {
        caches.reduce(0) { acc, cache in
            acc + cache.innerState().reduce(0) { $0 + $1.nbytes }
        }
    }
}
