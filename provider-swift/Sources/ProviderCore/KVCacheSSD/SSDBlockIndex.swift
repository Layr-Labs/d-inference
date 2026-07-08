// Copyright © 2026 Eigen Labs.
//
// In-RAM index over one model's on-disk DBK2 block files, plus the
// process-wide disk-budget coordinator.
//
// The index maps truncated 16-byte HMAC tags → (fileBytes, lastAccess).
// It is the ONLY resident state of the SSD tier at steady state
// (~68 B/entry: <1 MB at the 20 GiB default budget). Rebuilt by directory
// scan at startup — the scan IS the recovery protocol, so index and files
// can never disagree after a crash (no sidecar persistence, spec §5.1).
//
// TTL is SLIDING on hit (15-minute max, `SSDPrefixCachePolicy`): a hit
// bumps `lastAccess` AND touches the file's mtime, so recency survives a
// process restart (the scan seeds `lastAccess` from mtime).
//
// Eviction is `unlink` + index removal, oldest-by-last-hit first (LRU),
// coordinated ACROSS models by `SSDDiskBudget` so the 20 GiB budget is
// box-wide.

import Foundation
#if canImport(os)
import os
#endif

// MARK: - Per-model index

final class SSDBlockIndex: @unchecked Sendable {

    struct Entry {
        var fileBytes: Int
        /// Unix seconds of the last hit (or write). Sliding-TTL anchor.
        var lastAccess: Int64
    }

    private let lock = NSLock()
    private var entries: [Data: Entry] = [:]
    private var _totalBytes = 0

    var count: Int {
        lock.withLock { entries.count }
    }

    var totalBytes: Int {
        lock.withLock { _totalBytes }
    }

    func insert(tag16: Data, fileBytes: Int, lastAccess: Int64) {
        lock.withLock {
            if let old = entries[tag16] { _totalBytes -= old.fileBytes }
            entries[tag16] = Entry(fileBytes: fileBytes, lastAccess: lastAccess)
            _totalBytes += fileBytes
        }
    }

    func contains(tag16: Data) -> Bool {
        lock.withLock { entries[tag16] != nil }
    }

    @discardableResult
    func remove(tag16: Data) -> Int {
        lock.withLock {
            guard let old = entries.removeValue(forKey: tag16) else { return 0 }
            _totalBytes -= old.fileBytes
            return old.fileBytes
        }
    }

    /// Longest run `k` such that tags[0..<k] are ALL present (the
    /// prefix-contiguous match rule — block j is only usable when every
    /// earlier block of the chain is present too).
    func longestRun(tags16: [Data]) -> Int {
        lock.withLock {
            var k = 0
            for tag in tags16 {
                guard entries[tag] != nil else { break }
                k += 1
            }
            return k
        }
    }

    /// Byte sizes for a contiguous run (index order = block order).
    /// nil when any tag is missing (raced an eviction — caller re-probes).
    func fileBytes(tags16: ArraySlice<Data>) -> [Int]? {
        lock.withLock {
            var sizes: [Int] = []
            sizes.reserveCapacity(tags16.count)
            for tag in tags16 {
                guard let entry = entries[tag] else { return nil }
                sizes.append(entry.fileBytes)
            }
            return sizes
        }
    }

    /// Sliding-TTL bump for a hit run.
    func touch(tags16: some Sequence<Data>, now: Int64) {
        lock.withLock {
            for tag in tags16 {
                entries[tag]?.lastAccess = now
            }
        }
    }

    /// Tags whose last hit is older than `ttlSeconds` (0 ⇒ none expire).
    func expired(now: Int64, ttlSeconds: Int64) -> [Data] {
        guard ttlSeconds > 0 else { return [] }
        return lock.withLock {
            entries.compactMap { key, entry in
                now - entry.lastAccess >= ttlSeconds ? key : nil
            }
        }
    }

    /// Globally-oldest entry (LRU eviction candidate).
    func oldest() -> (tag16: Data, lastAccess: Int64, fileBytes: Int)? {
        lock.withLock {
            guard let (key, entry) = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })
            else { return nil }
            return (key, entry.lastAccess, entry.fileBytes)
        }
    }

    func removeAll() {
        lock.withLock {
            entries.removeAll()
            _totalBytes = 0
        }
    }
}

// MARK: - Box-wide disk budget

/// What the budget coordinator needs from a registered store: total disk
/// bytes, the age of its oldest entry, and the ability to evict it
/// (unlink + index removal).
protocol SSDEvictableStore: AnyObject, Sendable {
    var diskBytesOnDisk: Int { get }
    /// lastAccess of the store's LRU entry, or nil when empty.
    func oldestEntryAccess() -> Int64?
    /// Evict the store's single oldest entry. Returns bytes freed (0 when
    /// nothing was evicted).
    func evictOldestEntry() -> Int
}

/// Process-wide, BOX-WIDE disk budget (Gaj, 2026-07-07: 20 GiB default
/// across ALL models; `DARKBLOOM_PREFIX_CACHE_DISK_GB` overrides; the
/// default is additionally clamped to free-disk/2 like the legacy
/// resolver). When the limit is hit, the globally-oldest-by-last-hit
/// entry is unlinked, across every registered model store, until the
/// total is back under budget.
///
/// Enforcement runs only on the (serial, utility-QoS) write-behind
/// consumers, so the lock never sits on a request path.
final class SSDDiskBudget: @unchecked Sendable {

    static let shared = SSDDiskBudget()

    private let lock = NSLock()
    private var stores: [ObjectIdentifier: SSDEvictableStore] = [:]
    private var _evictions = 0

    var evictionCount: Int { lock.withLock { _evictions } }

    func register(_ store: SSDEvictableStore) {
        lock.withLock { stores[ObjectIdentifier(store)] = store }
    }

    func deregister(_ store: SSDEvictableStore) {
        lock.withLock { stores.removeValue(forKey: ObjectIdentifier(store)) }
    }

    var totalBytes: Int {
        lock.withLock { stores.values.reduce(0) { $0 + $1.diskBytesOnDisk } }
    }

    /// Evict oldest-by-last-hit (across all stores) until the box-wide
    /// total is at most `budgetBytes`. Returns the number of evictions.
    @discardableResult
    func enforce(budgetBytes: Int) -> Int {
        lock.withLock {
            var evicted = 0
            // Bounded: each pass frees at least one entry or stops.
            while stores.values.reduce(0, { $0 + $1.diskBytesOnDisk }) > budgetBytes {
                var victim: SSDEvictableStore?
                var victimAccess = Int64.max
                for store in stores.values {
                    if let access = store.oldestEntryAccess(), access < victimAccess {
                        victimAccess = access
                        victim = store
                    }
                }
                guard let victim, victim.evictOldestEntry() > 0 else { return evicted }
                evicted += 1
                _evictions += 1
            }
            return evicted
        }
    }
}
