// Copyright © 2026 Eigen Labs.
//
// In-RAM index over one model's on-disk DBK3 block files, plus the
// process-wide disk-budget coordinator.
//
// The index maps truncated 16-byte HMAC tags → (fileBytes, lastAccess).
// It retains metadata, not prefix payloads, between requests. Rebuilt by directory
// scan at startup — the scan IS the recovery protocol, so index and files
// can never disagree after a crash (no sidecar persistence, spec §5.1).
//
// TTL is SLIDING on hit (30-minute max, `SSDPrefixCachePolicy`): a hit
// bumps `lastAccess` AND touches the file's mtime, so recency survives a
// process restart (the scan seeds `lastAccess` from mtime). A complete
// checkpoint's touch needs a reader holding the file alone and an mtime at
// least `ttlSeconds / 30` old, so that mtime can trail `lastAccess`. Whole-root
// TTL expiry of a loaded store's file checks `lastAccess` first and persists it.
//
// Eviction is `unlink` + index removal, oldest-by-last-hit first (LRU),
// coordinated across models by `SSDDiskBudget` under one box-wide budget.
// Eviction never rotates the model's cache epoch: the coordinator learns of
// a removed file through an ordinary lookup miss, and every other file it
// recorded for this provider stays valid evidence.

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
        /// A delta's parent entry; empty until the scan resolves it.
        var parent: Data?
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

    func usageSnapshot() -> (entries: Int, bytes: Int) {
        lock.withLock { (entries.count, _totalBytes) }
    }

    func insert(tag16: Data, fileBytes: Int, lastAccess: Int64, parent: Data? = nil) {
        lock.withLock {
            if let old = entries[tag16] { _totalBytes -= old.fileBytes }
            entries[tag16] = Entry(fileBytes: fileBytes, lastAccess: lastAccess, parent: parent)
            _totalBytes += fileBytes
        }
    }

    func contains(tag16: Data) -> Bool {
        lock.withLock { entries[tag16] != nil }
    }

    /// Probe one complete checkpoint without scanning unrelated entries. Read
    /// size and recency together; eviction or replacement is validated again
    /// when the caller authenticates the file. A probe does not extend its TTL.
    func freshFileBytes(tag16: Data, now: Int64, ttlSeconds: Int64) -> Int? {
        lock.withLock { entries[tag16].flatMap { Self.freshBytes($0, now: now, ttlSeconds: ttlSeconds) } }
    }

    private static func freshBytes(_ entry: Entry, now: Int64, ttlSeconds: Int64) -> Int? {
        if ttlSeconds > 0, now >= entry.lastAccess {
            let (age, overflow) = now.subtractingReportingOverflow(entry.lastAccess)
            guard !overflow, age < ttlSeconds else { return nil }
        }
        return entry.fileBytes
    }

    func setParent(tag16: Data, parent: Data) { lock.withLock { entries[tag16]?.parent = parent } }

    /// The chain ending at `tag16`, root first, with its bytes, if every link
    /// is present and fresh (`ttlSeconds` 0 never expires).
    func chain(tag16: Data, now: Int64 = 0, ttlSeconds: Int64 = 0) -> (tags: [Data], bytes: Int)? {
        lock.withLock {
            var tags: [Data] = [], bytes = 0, next: Data? = tag16
            while let tag = next {
                guard tags.count < SSDCheckpointDeltaLayout.maximumChainFiles, let entry = entries[tag],
                    let size = Self.freshBytes(entry, now: now, ttlSeconds: ttlSeconds) else { return nil }
                (tags, bytes, next) = ([tag] + tags, bytes + size, entry.parent)
            }
            return (tags, bytes)
        }
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

    /// The entry's last hit or write, nil when it is not indexed.
    func lastAccess(tag16: Data) -> Int64? {
        lock.withLock { entries[tag16]?.lastAccess }
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
        // Budget selection needs one candidate, not an ordered copy of every
        // model's index. Keep the order of `OldestFirstSnapshot.precedes`.
        lock.withLock {
            entries.min {
                if $0.value.lastAccess != $1.value.lastAccess {
                    return $0.value.lastAccess < $1.value.lastAccess
                }
                return $0.key.lexicographicallyPrecedes($1.key)
            }.map { (tag16: $0.key, lastAccess: $0.value.lastAccess, fileBytes: $0.value.fileBytes) }
        }
    }

    /// Every entry in eviction order (oldest last hit first, then
    /// lexicographic tag), produced on demand: O(n) to copy and heapify, then
    /// O(log n) per entry taken, so a walk that stops early never sorts the
    /// whole index. Only the copy holds the index lock; iteration never
    /// observes later index changes.
    func oldestFirstSnapshot() -> OldestFirstSnapshot {
        OldestFirstSnapshot(lock.withLock {
            entries.map { (tag16: $0.key, lastAccess: $0.value.lastAccess, fileBytes: $0.value.fileBytes) }
        })
    }

    /// Binary min-heap over a copied snapshot; see `oldestFirstSnapshot()`.
    struct OldestFirstSnapshot: Sequence, IteratorProtocol {
        typealias Element = (tag16: Data, lastAccess: Int64, fileBytes: Int)

        private var heap: [Element]

        fileprivate init(_ entries: [Element]) {
            heap = entries
            for parent in stride(from: heap.count / 2 - 1, through: 0, by: -1) {
                siftDown(from: parent)
            }
        }

        mutating func next() -> Element? {
            guard let last = heap.popLast() else { return nil }
            guard !heap.isEmpty else { return last }
            let oldest = heap[0]
            heap[0] = last
            siftDown(from: 0)
            return oldest
        }

        private mutating func siftDown(from start: Int) {
            var parent = start
            while true {
                let left = 2 * parent + 1
                guard left < heap.count else { return }
                let right = left + 1
                let child = right < heap.count && Self.precedes(heap[right], heap[left]) ? right : left
                guard Self.precedes(heap[child], heap[parent]) else { return }
                heap.swapAt(parent, child)
                parent = child
            }
        }

        /// Eviction order, the same as `oldest()`. Tags are unique keys, so the
        /// order is total and the heap yields exactly the sorted sequence.
        /// Raw-byte comparison equals `Data.lexicographicallyPrecedes` without
        /// copying each tag into a `Data.Iterator`.
        private static func precedes(_ a: Element, _ b: Element) -> Bool {
            if a.lastAccess != b.lastAccess {
                return a.lastAccess < b.lastAccess
            }
            return a.tag16.withUnsafeBytes { lhs in
                b.tag16.withUnsafeBytes { rhs in lhs.lexicographicallyPrecedes(rhs) }
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
/// bytes, the age of its oldest entry, and the ability to evict it
/// (unlink + index removal).
protocol SSDEvictableStore: AnyObject, Sendable {
    var evictionRoot: URL { get }
    /// False once the store is closed or a different-binding successor has
    /// taken its root. It then refuses every file removal, so whole-root
    /// maintenance must not pick it to bracket one.
    var ownsEvictionRoot: Bool { get }
    var diskBytesOnDisk: Int { get }
    /// lastAccess of the store's LRU entry, or nil when empty.
    func oldestEntryAccess() -> Int64?
    /// Evict the store's single oldest entry. Returns bytes freed (0 when
    /// nothing was evicted).
    func evictOldestEntry() -> Int
    /// Drop RAM-index entries whose files were removed by whole-root
    /// maintenance (including unloaded-model accounting).
    func reconcileExternalRemovals()
    /// Bracket whole-root deletion through an active store so the unlink and
    /// the index reconciliation run under the store's own removal
    /// serialization. The epoch is not rotated and the capability stays
    /// advertised throughout.
    func performExternalDestructiveChange(_ body: () -> Void) -> Bool
    /// Retire only the named owned files, preserving the generation of survivors.
    /// Return paths actually unlinked; arbitrary external destruction uses the
    /// separate index-reconciliation method above. With `unusedSince`, a file
    /// the index saw hit after that time stays, and that hit becomes its mtime.
    func retireOwnedEntries(_ urls: [URL], unusedSince: Int64?) -> Set<String>
}

/// Process-wide disk budget across all models, resolved by `PrefixCachePolicy`.
/// When the limit is hit, the globally-oldest-by-last-hit
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

    /// Runs `body` under a registered store that still owns this model root
    /// and returns true. Returns nil, without running `body`, when none does:
    /// either no store is registered for the root, or every one that is has
    /// been disowned or closed and would refuse. The caller then takes the
    /// unloaded-root path, so a lingering disowned store cannot stop TTL
    /// expiry and budget eviction under its root.
    func performActiveDestructiveChange(root: URL, _ body: () -> Void) -> Bool? {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        return lock.withLock {
            let owners = stores.values.filter {
                $0.evictionRoot.standardizedFileURL.resolvingSymlinksInPath().path == key
                    && $0.ownsEvictionRoot
            }
            // A store refuses without running the body, so an owner that was
            // disowned since the filter simply yields to the next one.
            for store in owners where store.performExternalDestructiveChange(body) {
                return true
            }
            return nil
        }
    }

    /// nil means no active owner; an empty set means the owner removed nothing.
    func retireActiveEntries(root: URL, urls: [URL], unusedSince: Int64? = nil) -> Set<String>? {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        return lock.withLock {
            guard let store = stores.values.first(where: {
                $0.evictionRoot.standardizedFileURL.resolvingSymlinksInPath().path == key
                    && $0.ownsEvictionRoot
            }) else { return nil }
            return store.retireOwnedEntries(urls, unusedSince: unusedSince)
        }
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
            var blockedStores: Set<ObjectIdentifier> = []
            let limit = max(0, budgetBytes)
            // Bounded: a pass either frees one entry or permanently excludes
            // one store for this enforcement call. One undeletable oldest
            // entry therefore cannot stop eviction in another store.
            while stores.values.reduce(0, { $0 + $1.diskBytesOnDisk }) > limit {
                var victim: SSDEvictableStore?
                var victimAccess = Int64.max
                for store in stores.values {
                    guard !blockedStores.contains(ObjectIdentifier(store)) else {
                        continue
                    }
                    if let access = store.oldestEntryAccess(), access < victimAccess {
                        victimAccess = access
                        victim = store
                    }
                }
                guard let victim else { return evicted }
                let indexedBytesBefore = victim.diskBytesOnDisk
                guard victim.evictOldestEntry() > 0 else {
                    // Stale accounting can disappear without unlinking a file.
                    // Re-evaluate the limit after that progress, and count only
                    // actual physical evictions in both telemetry counters.
                    if victim.diskBytesOnDisk >= indexedBytesBefore {
                        blockedStores.insert(ObjectIdentifier(victim))
                    }
                    continue
                }
                evicted += 1
                _evictions += 1
            }
            return evicted
        }
    }
}
