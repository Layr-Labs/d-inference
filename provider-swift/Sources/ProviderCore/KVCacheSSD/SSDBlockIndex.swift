// Copyright © 2026 Eigen Labs.
//
// In-RAM index over one model's on-disk DBK3 block files, plus the
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

    /// Globally-oldest entry (LRU eviction candidate): one linear min-scan in
    /// the same order as `oldestEntries()` (lastAccess, then tag), so the
    /// fast path and the sorted fallback agree on the victim. Box-wide
    /// enforcement calls this once per victim per store — it must not copy
    /// or sort the index.
    func oldest() -> (tag16: Data, lastAccess: Int64, fileBytes: Int)? {
        lock.withLock {
            var best: (key: Data, entry: Entry)?
            for (key, entry) in entries {
                guard let current = best else {
                    best = (key, entry)
                    continue
                }
                if entry.lastAccess < current.entry.lastAccess
                    || (entry.lastAccess == current.entry.lastAccess
                        && key.lexicographicallyPrecedes(current.key))
                {
                    best = (key, entry)
                }
            }
            guard let best else { return nil }
            return (best.key, best.entry.lastAccess, best.entry.fileBytes)
        }
    }

    /// Stable oldest-first snapshot. Eviction walks this bounded list so one
    /// stale or temporarily undeletable index entry cannot pin every newer
    /// victim behind it.
    func oldestEntries() -> [(tag16: Data, lastAccess: Int64, fileBytes: Int)] {
        lock.withLock {
            entries.map { (tag16: $0.key, lastAccess: $0.value.lastAccess, fileBytes: $0.value.fileBytes) }
                .sorted {
                    if $0.lastAccess != $1.lastAccess {
                        return $0.lastAccess < $1.lastAccess
                    }
                    return $0.tag16.lexicographicallyPrecedes($1.tag16)
                }
        }
    }

    func removeAll() {
        lock.withLock {
            entries.removeAll()
            _totalBytes = 0
        }
    }

    func allTags() -> [Data] {
        lock.withLock { Array(entries.keys) }
    }
}

// MARK: - Box-wide disk budget

/// What the budget coordinator needs from a registered store: total disk
/// bytes, an oldest-first snapshot of its entries, and the ability to
/// unlink a planned batch of them (unlink + index removal).
protocol SSDEvictableStore: AnyObject, Sendable {
    var evictionRoot: URL { get }
    var diskBytesOnDisk: Int { get }
    /// Oldest-first snapshot of every entry (lastAccess, then tag). Box-wide
    /// enforcement takes it ONCE per store per pass — never per victim.
    func oldestEntries() -> [(tag16: Data, lastAccess: Int64, fileBytes: Int)]
    /// Unlink `victims` (this store's slice of the global plan, oldest
    /// first) until `targetBytes` are freed or the list is exhausted; stale
    /// entries are dropped, undeletable files skipped. Returns bytes freed
    /// and entries unlinked.
    func evictEntries(_ victims: [Data], freeing targetBytes: Int) -> (freedBytes: Int, evicted: Int)
    /// Drop RAM-index entries whose files were removed by whole-root
    /// maintenance (including unloaded-model accounting).
    func reconcileExternalRemovals()
    /// Bracket whole-root deletion through an active store so it owns the
    /// replacement epoch and can resume advertising after the mutation.
    func performExternalDestructiveChange(_ body: () -> Void) -> Bool
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
        lock.withLock { _ = stores.removeValue(forKey: ObjectIdentifier(store)) }
    }

    func reconcileAll() {
        lock.withLock {
            for store in stores.values { store.reconcileExternalRemovals() }
        }
    }

    /// Returns nil when no active store owns this model root.
    func performActiveDestructiveChange(root: URL, _ body: () -> Void) -> Bool? {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        return lock.withLock {
            guard let store = stores.values.first(where: {
                $0.evictionRoot.standardizedFileURL.resolvingSymlinksInPath().path == key
            }) else { return nil }
            return store.performExternalDestructiveChange(body)
        }
    }

    var totalBytes: Int {
        lock.withLock { stores.values.reduce(0) { $0 + $1.diskBytesOnDisk } }
    }

    /// Evict oldest-by-last-hit (across all stores) until the box-wide
    /// total is at most `budgetBytes`. Returns the number of evictions.
    ///
    /// One sorted snapshot per store per pass, merged globally oldest-first
    /// (lastAccess, then tag — the index's own order) into per-store victim
    /// plans that together cover the excess, each unlinked in the store's
    /// batched bracket. The per-victim form re-scanned every index and read
    /// the epoch record once PER VICTIM under this lock: a budget drop
    /// (free-disk/2 clamp after a large download) forced ~n/2 evictions in
    /// one call, O(victims × entries) with every model's write-behind
    /// consumer — and every ready receipt — waiting behind it.
    @discardableResult
    func enforce(budgetBytes: Int) -> Int {
        lock.withLock {
            var evicted = 0
            var blockedStores: Set<ObjectIdentifier> = []
            let limit = max(0, budgetBytes)
            // Bounded: every pass either shrinks a store (its bytes strictly
            // fall) or permanently excludes one for this call, so the loop
            // ends within entries + stores passes — one in practice, two
            // when a planned victim turned out stale or undeletable.
            while true {
                let total = stores.values.reduce(0) { $0 + $1.diskBytesOnDisk }
                guard total > limit else { return evicted }
                let excess = total - limit

                var cursors: [(store: SSDEvictableStore, entries: [(tag16: Data, lastAccess: Int64, fileBytes: Int)], next: Int)] = []
                for store in stores.values where !blockedStores.contains(ObjectIdentifier(store)) {
                    let entries = store.oldestEntries()
                    if !entries.isEmpty { cursors.append((store, entries, 0)) }
                }
                guard !cursors.isEmpty else { return evicted }

                var plans: [ObjectIdentifier: (store: SSDEvictableStore, victims: [Data], bytes: Int)] = [:]
                var planned = 0
                while planned < excess {
                    var pick: Int?
                    for i in cursors.indices where cursors[i].next < cursors[i].entries.count {
                        guard let current = pick else {
                            pick = i
                            continue
                        }
                        let candidate = cursors[i].entries[cursors[i].next]
                        let best = cursors[current].entries[cursors[current].next]
                        if candidate.lastAccess < best.lastAccess
                            || (candidate.lastAccess == best.lastAccess
                                && candidate.tag16.lexicographicallyPrecedes(best.tag16))
                        {
                            pick = i
                        }
                    }
                    guard let pick else { break }
                    let entry = cursors[pick].entries[cursors[pick].next]
                    cursors[pick].next += 1
                    let key = ObjectIdentifier(cursors[pick].store)
                    var plan = plans[key] ?? (cursors[pick].store, [], 0)
                    plan.victims.append(entry.tag16)
                    plan.bytes += entry.fileBytes
                    plans[key] = plan
                    planned += entry.fileBytes
                }

                for plan in plans.values {
                    let before = plan.store.diskBytesOnDisk
                    let outcome = plan.store.evictEntries(plan.victims, freeing: plan.bytes)
                    evicted += outcome.evicted
                    _evictions += outcome.evicted
                    // Nothing changed (every planned victim undeletable, or
                    // the bracket refused): exclude the store for this call.
                    if plan.store.diskBytesOnDisk >= before {
                        blockedStores.insert(ObjectIdentifier(plan.store))
                    }
                }
            }
        }
    }
}
