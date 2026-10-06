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
// process restart (the scan seeds `lastAccess` from mtime).
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

    /// Probe one complete checkpoint without scanning unrelated entries. Read
    /// size and recency together; eviction or replacement is validated again
    /// when the caller authenticates the file. A probe does not extend its TTL.
    func freshFileBytes(tag16: Data, now: Int64, ttlSeconds: Int64) -> Int? {
        lock.withLock {
            guard let entry = entries[tag16] else { return nil }
            if ttlSeconds > 0, now >= entry.lastAccess {
                let (age, overflow) = now.subtractingReportingOverflow(entry.lastAccess)
                guard !overflow, age < ttlSeconds else { return nil }
            }
            return entry.fileBytes
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
        // Budget selection needs one candidate, not a sorted copy of every
        // model's index. Keep the same tag tie-break as oldestEntries().
        lock.withLock {
            entries.min {
                if $0.value.lastAccess != $1.value.lastAccess {
                    return $0.value.lastAccess < $1.value.lastAccess
                }
                return $0.key.lexicographicallyPrecedes($1.key)
            }.map { (tag16: $0.key, lastAccess: $0.value.lastAccess, fileBytes: $0.value.fileBytes) }
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
    /// separate index-reconciliation method above.
    func retireOwnedEntries(_ urls: [URL]) -> Set<String>
    /// An upper bound of the stored bytes of proven writes this store has
    /// accepted and not started: they hold no reservation yet, and a
    /// speculative write anywhere on the budget must leave them room.
    /// Read under the budget lock: an implementation takes at most a lock
    /// whose holders never call the budget.
    var queuedWriteBytes: Int { get }
}

/// How the box-wide budget moves when bytes land on, or leave, its volume.
/// A speculative write must fit the budget as it will be once its bytes are
/// on disk, so its admission evaluates the basis at a projected byte count.
enum SSDDiskBudgetBasis: Sendable, Equatable {
    /// An operator override, the measurement fallback or an injected value:
    /// bytes written do not move it.
    case fixed(Int)
    /// Half of the volume's free bytes (`PrefixCachePolicy`): every byte
    /// written lowers the budget by half a byte.
    case halfOfFree(freeBytes: Int)

    /// The budget once `pendingBytes` more bytes are on the volume.
    func bytes(afterWriting pendingBytes: Int = 0) -> Int {
        switch self {
        case .fixed(let bytes):
            return bytes
        case .halfOfFree(let freeBytes):
            let (remaining, overflow) = freeBytes.subtractingReportingOverflow(max(0, pendingBytes))
            return max(1, (overflow ? 0 : max(0, remaining)) / 2)
        }
    }

    /// The budget as it is without `removedBytes` that are on the volume
    /// now: the limit that holds once a write in flight is withdrawn.
    func bytes(afterRemoving removedBytes: Int) -> Int {
        switch self {
        case .fixed(let bytes):
            return bytes
        case .halfOfFree(let freeBytes):
            let (restored, overflow) = freeBytes.addingReportingOverflow(max(0, removedBytes))
            return max(1, (overflow ? Int.max : restored) / 2)
        }
    }
}

/// One in-flight fresh write's claim on the box-wide disk budget, for the
/// complete length of the file it will publish. Every writer on the budget
/// holds one from before its first byte until its file is indexed or gone,
/// so an admission in another store sees bytes that no index counts yet.
final class SSDDiskReservation: @unchecked Sendable {
    enum Disposition {
        /// The file is indexed by a store: its bytes moved to that index.
        case committed
        /// The file is on disk but no index counts it.
        case abandonedOnDisk
        /// Nothing of the write remains on disk.
        case discarded
    }

    /// `<model root>/<32 hex tag>` of each file the write may create. The
    /// whole-root pass matches temp and not-yet-indexed files against them.
    let keys: [String]
    let isSpeculative: Bool
    fileprivate let wholeRootKey: String
    // All three under `SSDDiskBudget.lock`.
    fileprivate var bytes: Int
    fileprivate var released = false
    /// Released with its file indexed: its bytes are an entry's from then on.
    fileprivate var committed = false
    // Read by the writer at every chunk, and written by it as bytes land,
    // without the budget lock, which an eviction pass can hold for a whole
    // loop. `revoked` is written under the budget lock.
    private let progress = NSLock()
    private var revoked = false
    private var landed = 0

    fileprivate init(bytes: Int, keys: [String], wholeRootKey: String, isSpeculative: Bool) {
        self.bytes = max(0, bytes)
        self.keys = keys
        self.wholeRootKey = wholeRootKey
        self.isSpeculative = isSpeculative
    }

    /// True once the room this speculative write was granted is needed by
    /// a proven write or is gone. The write stops at its next chunk.
    var isRevoked: Bool { progress.withLock { revoked } }
    fileprivate func revoke() { progress.withLock { revoked = true } }

    /// An upper bound of the bytes this write has put on the volume so far.
    var landedBytes: Int { progress.withLock { landed } }
    func noteLanded(upTo bytes: Int) { progress.withLock { landed = max(landed, bytes) } }
}

/// Process-wide disk budget across all models, resolved by `PrefixCachePolicy`.
/// When the limit is hit, the globally-oldest-by-last-hit
/// entry is unlinked, across every registered model store, until the
/// total is back under budget.
///
/// Enforcement runs only on the (serial, utility-QoS) write-behind
/// consumers. The byte total is read under the same lock when a speculative
/// checkpoint is offered (`hasSpeculativeRoom`), on the engine's
/// publication path, so such an offer can wait for an enforcement pass.
///
/// The budget also keeps the ledger that makes a speculative (first-sight)
/// write safe to admit: reservations for the complete stored size of every
/// in-flight fresh write, and the bytes under each whole root that no
/// registered index counts. A speculative write is granted room only while
/// indexed + unowned + reserved + its own bytes fit the budget as it will
/// be after those bytes land; a proven write is never refused. While a
/// speculative write is in flight its bytes are on the volume without being
/// anybody's entry, so no enforcement evicts for them: they are left out of
/// what is counted and out of what lowers a half-of-free limit. Lock order:
/// the whole-root maintenance lock, then this lock, then a store's
/// `removalLock`. No store's state lock is held when this lock is taken, and
/// no volume is queried under it. A store's state lock and a write-behind's
/// queue lock are taken under this lock as leaves (`ownsEvictionRoot`,
/// `queuedWriteBytes`, the closure of `registerProven`): their holders never
/// call the budget.
///
/// What the ledger assumes of its callers, as both factories arrange it: the
/// stores on one budget share one whole root when the budget moves with the
/// volume, and a store whose budget moves passes its basis and runs the
/// whole-root pass. A store built without them is held to a fixed budget.
final class SSDDiskBudget: @unchecked Sendable {

    static let shared = SSDDiskBudget()

    private struct Registration {
        let store: SSDEvictableStore
        let modelRootKey: String
        let wholeRootKey: String
    }

    private let lock = NSLock()
    private var stores: [ObjectIdentifier: Registration] = [:]
    private var _evictions = 0
    private var reservations: [ObjectIdentifier: SSDDiskReservation] = [:]
    private var reservedBytes = 0
    /// Bytes under each whole root that no registered store's index counts:
    /// files of unloaded or closed models, temp files of no reservation,
    /// files published but never indexed. Published by every whole-root
    /// pass and raised when a store deregisters with its files on disk.
    private var unownedBytes: [String: Int] = [:]
    /// Moves whenever bytes change sides between `unownedBytes` and an
    /// index, so a whole-root pass that walked across such a move does not
    /// lower the figure to one that misses them.
    private var generation: UInt64 = 0
    private var observations: [UInt64: WholeRootObservation] = [:]
    private var nextObservation: UInt64 = 0
    /// Counts speculative writes that ended without an entry. A volume
    /// reading taken while such a write's bytes were on disk is stale once
    /// they are gone; `enforce` reads the volume again when this moved.
    private var speculativeWithdrawals: UInt64 = 0
    /// Bytes whose record was released with the file left on disk. A volume
    /// reading taken before such a release may not have those bytes on it,
    /// while the ledger no longer counts them as still to land; a
    /// speculative write's publish and commit checks subtract what was
    /// settled since their reading.
    private var settledBytes: UInt64 = 0

    struct WholeRootObservation {
        fileprivate(set) var generation: UInt64 = 0
        /// Keys of speculative reservations outstanding at any time while
        /// the pass walked the tree.
        fileprivate(set) var speculativeKeys: Set<String> = []
        /// The same for reservations of every class.
        fileprivate(set) var reservedKeys: Set<String> = []
        /// An upper bound of the bytes those speculative writes had on the
        /// volume in the window, without the ones indexed in it: a write that
        /// was withdrawn before the walk reached its directory lowered the
        /// free figure read in the window all the same.
        fileprivate(set) var speculativeLandedBytes = 0
        fileprivate var speculative: [SSDDiskReservation] = []

        fileprivate mutating func record(_ reservation: SSDDiskReservation) {
            reservedKeys.formUnion(reservation.keys)
            guard reservation.isSpeculative else { return }
            speculativeKeys.formUnion(reservation.keys)
            speculative.append(reservation)
        }
    }

    var evictionCount: Int { lock.withLock { _evictions } }

    func register(_ store: SSDEvictableStore) {
        // Resolved here, once: nothing under the lock touches the file system.
        let registration = Registration(
            store: store, modelRootKey: Self.rootKey(store.evictionRoot),
            wholeRootKey: Self.wholeRootKey(ofModelRoot: store.evictionRoot))
        lock.withLock {
            stores[ObjectIdentifier(store)] = registration
            generation &+= 1
        }
    }

    func deregister(_ store: SSDEvictableStore) {
        lock.withLock {
            guard let registration = stores.removeValue(forKey: ObjectIdentifier(store)) else { return }
            // Its files stay on disk and still count against the whole
            // root, so they stay in the occupancy a speculative write sees.
            addUnownedLocked(store.diskBytesOnDisk, wholeRootKey: registration.wholeRootKey)
            generation &+= 1
        }
    }

    func reconcileAll() {
        lock.withLock {
            for registration in stores.values { registration.store.reconcileExternalRemovals() }
        }
    }

    /// Runs `body` under a registered store that still owns this model root
    /// and returns true. Returns nil, without running `body`, when none does:
    /// either no store is registered for the root, or every one that is has
    /// been disowned or closed and would refuse. The caller then takes the
    /// unloaded-root path, so a lingering disowned store cannot stop TTL
    /// expiry and budget eviction under its root.
    func performActiveDestructiveChange(root: URL, _ body: () -> Void) -> Bool? {
        let key = Self.rootKey(root)
        return lock.withLock {
            let owners = stores.values.filter { $0.modelRootKey == key && $0.store.ownsEvictionRoot }
            // A store refuses without running the body, so an owner that was
            // disowned since the filter simply yields to the next one.
            for owner in owners where owner.store.performExternalDestructiveChange(body) {
                return true
            }
            return nil
        }
    }

    /// nil means no active owner; an empty set means the owner removed nothing.
    func retireActiveEntries(root: URL, urls: [URL]) -> Set<String>? {
        let key = Self.rootKey(root)
        return lock.withLock {
            guard let owner = stores.values.first(where: {
                $0.modelRootKey == key && $0.store.ownsEvictionRoot
            }) else { return nil }
            return owner.store.retireOwnedEntries(urls)
        }
    }

    var totalBytes: Int {
        lock.withLock { stores.values.reduce(0) { $0 + $1.store.diskBytesOnDisk } }
    }

    // MARK: Reservations

    /// Symlinks are resolved in the part of the path that exists, so a root
    /// has the same key before and after its directory is created.
    static func rootKey(_ root: URL) -> String {
        var existing = root.standardizedFileURL
        var missing: [String] = []
        while existing.pathComponents.count > 1, !FileManager.default.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }

    static func wholeRootKey(ofModelRoot root: URL) -> String {
        rootKey(root.deletingLastPathComponent())
    }

    static func reservationKey(modelRootKey: String, tag16Hex: String) -> String {
        modelRootKey + "/" + tag16Hex
    }

    /// Advisory, for the engine's publication path: whether a speculative
    /// write of `bytes` stored bytes would be granted room now. Reserves
    /// nothing; the writer makes the binding reservation.
    func hasSpeculativeRoom(bytes: Int, wholeRootKey: String, basis: SSDDiskBudgetBasis) -> Bool {
        lock.withLock {
            fitsLocked(bytes: bytes, includesReserved: true, ownBytesStillToLand: bytes,
                       wholeRootKey: wholeRootKey, basis: basis)
        }
    }

    /// Grants a speculative write room for its complete stored size, or
    /// nil when granting it could make any enforcement pass evict: the
    /// caller then declines the write before I/O.
    func reserveSpeculative(
        bytes: Int, keys: [String], wholeRootKey: String, basis: SSDDiskBudgetBasis
    ) -> SSDDiskReservation? {
        lock.withLock {
            guard fitsLocked(bytes: bytes, includesReserved: true, ownBytesStillToLand: bytes,
                             wholeRootKey: wholeRootKey, basis: basis)
            else { return nil }
            return addReservationLocked(bytes: bytes, keys: keys, wholeRootKey: wholeRootKey, isSpeculative: true)
        }
    }

    /// True while any speculative write is in flight. A proven writer reads
    /// it to skip the volume query its registration needs only then.
    var hasSpeculativeReservations: Bool {
        lock.withLock { reservations.values.contains { $0.isSpeculative } }
    }

    /// Records a proven write's stored bytes. Never refused and never
    /// waits for room. When the sum no longer fits, the room that in-flight
    /// speculative writes were granted is what gives: they are revoked.
    /// `basis` is nil when the caller saw no speculative write to revoke, or
    /// records bytes it will only write later. A speculative write reserved
    /// after the caller looked is then not told to stop here; it is still
    /// safe, because this record is counted against it from now on and its
    /// own publish and commit checks refuse it if the room is gone.
    /// `replacingQueued` runs under the budget lock, after the record is
    /// made and before the sum is tested: the caller drops the bound it
    /// reports through `queuedWriteBytes` for this write there, so the
    /// write is counted once at every instant.
    func registerProven(
        bytes: Int, keys: [String], wholeRootKey: String, basis: SSDDiskBudgetBasis?,
        replacingQueued: (() -> Void)? = nil
    ) -> SSDDiskReservation {
        lock.withLock {
            let reservation = addReservationLocked(
                bytes: bytes, keys: keys, wholeRootKey: wholeRootKey, isSpeculative: false)
            replacingQueued?()
            if let basis, !fitsLocked(bytes: 0, includesReserved: true, ownBytesStillToLand: 0,
                                      wholeRootKey: wholeRootKey, basis: basis) {
                revokeSpeculativeLocked()
            }
            return reservation
        }
    }

    /// Moves one block of a multi-block proven write from the record of the
    /// blocks still to come (`remainder`) to a record of its own, in one
    /// step, so the donation's bytes are on the ledger exactly once from its
    /// start to its last block. The revoke rule of `registerProven` applies
    /// to the block that is about to be written.
    func claimBlock(
        from remainder: SSDDiskReservation, bytes: Int, keys: [String], basis: SSDDiskBudgetBasis?
    ) -> SSDDiskReservation {
        lock.withLock {
            shrinkLocked(remainder, by: bytes)
            let reservation = addReservationLocked(
                bytes: bytes, keys: keys, wholeRootKey: remainder.wholeRootKey, isSpeculative: false)
            if let basis, !fitsLocked(bytes: 0, includesReserved: true, ownBytesStillToLand: 0,
                                      wholeRootKey: remainder.wholeRootKey, basis: basis) {
                revokeSpeculativeLocked()
            }
            return reservation
        }
    }

    /// A block of a multi-block proven write will not be written after all.
    func dropBlock(from remainder: SSDDiskReservation, bytes: Int) {
        lock.withLock { shrinkLocked(remainder, by: bytes) }
    }

    /// Before a speculative write publishes its finished temp file: false
    /// when its room is revoked or gone, so nothing is published. `basis`
    /// is read after the file's bytes are on the volume.
    func mayPublishSpeculative(
        _ reservation: SSDDiskReservation, fileBytes: Int, basis: SSDDiskBudgetBasis
    ) -> Bool {
        lock.withLock { speculativeStillFitsLocked(reservation, fileBytes: fileBytes, basis: basis) }
    }

    /// The same with the volume read by `basis` outside the lock. Bytes that
    /// other writers settled on disk between that reading and the lock are
    /// taken off it, so a proven write that lands and is indexed in between
    /// cannot make the check pass.
    func mayPublishSpeculative(
        _ reservation: SSDDiskReservation, fileBytes: Int, basis: () -> SSDDiskBudgetBasis
    ) -> Bool {
        let mark = lock.withLock { settledBytes }
        let reading = basis()
        return lock.withLock {
            speculativeStillFitsLocked(reservation, fileBytes: fileBytes, basis: reading, settledSince: mark)
        }
    }

    /// Indexes a speculative write's published file and releases its
    /// reservation in one step under the budget lock, only while the
    /// room still holds. Returns false, with the reservation still
    /// outstanding and nothing indexed, when the room is revoked or gone or
    /// `insert` declines: the caller removes its own file, then releases.
    func commitSpeculative(
        _ reservation: SSDDiskReservation, fileBytes: Int, basis: SSDDiskBudgetBasis, insert: () -> Bool
    ) -> Bool {
        lock.withLock {
            guard speculativeStillFitsLocked(reservation, fileBytes: fileBytes, basis: basis), insert()
            else { return false }
            releaseLocked(reservation, as: .committed)
            return true
        }
    }

    /// The same with the volume read by `basis` outside the lock, as
    /// `mayPublishSpeculative` reads it.
    func commitSpeculative(
        _ reservation: SSDDiskReservation, fileBytes: Int, basis: () -> SSDDiskBudgetBasis, insert: () -> Bool
    ) -> Bool {
        let mark = lock.withLock { settledBytes }
        let reading = basis()
        return lock.withLock {
            guard speculativeStillFitsLocked(reservation, fileBytes: fileBytes, basis: reading, settledSince: mark),
                insert()
            else { return false }
            releaseLocked(reservation, as: .committed)
            return true
        }
    }

    /// Indexes a proven write's file and releases its record in one step, so
    /// no reader of the ledger sees the bytes twice or not at all. Never
    /// refused. When `store`, whose index it is, has deregistered meanwhile,
    /// that index is no longer summed and the file's bytes are counted as
    /// unowned instead; a nil `store` is one that is gone if `storeIsKnown`,
    /// and otherwise a writer with no store behind it (tests). Returns what
    /// `insert` returned.
    func commitProven(
        _ reservation: SSDDiskReservation, store: SSDEvictableStore?, storeIsKnown: Bool = false,
        insert: () -> Bool
    ) -> Bool {
        lock.withLock {
            guard insert() else {
                releaseLocked(reservation, as: .discarded)
                return false
            }
            let registered = store.map { stores[ObjectIdentifier($0)] != nil } ?? !storeIsKnown
            releaseLocked(reservation, as: registered ? .committed : .abandonedOnDisk)
            return true
        }
    }

    /// Ends a reservation. Idempotent, so one deferred call covers every
    /// exit of a writer.
    func release(_ reservation: SSDDiskReservation, as disposition: SSDDiskReservation.Disposition) {
        lock.withLock { releaseLocked(reservation, as: disposition) }
    }

    /// Outstanding reservations, for tests and stats.
    var reservedBytesSnapshot: Int { lock.withLock { reservedBytes } }

    /// Bytes under a whole root that no registered index counts, as last
    /// published or adjusted. For tests and stats.
    func unownedBytesSnapshot(wholeRootKey: String) -> Int {
        lock.withLock { unownedBytes[wholeRootKey] ?? 0 }
    }

    // MARK: Whole-root accounting

    /// Opens a window in which every reservation that is or becomes
    /// outstanding is recorded, so the pass can tell an in-flight write's
    /// temp or not-yet-indexed file from committed bytes even when the write
    /// starts or ends while the tree is being walked.
    func beginWholeRootObservation() -> UInt64 {
        lock.withLock {
            nextObservation &+= 1
            var observation = WholeRootObservation(generation: generation)
            for reservation in reservations.values { observation.record(reservation) }
            observations[nextObservation] = observation
            return nextObservation
        }
    }

    func endWholeRootObservation(_ id: UInt64) -> WholeRootObservation {
        lock.withLock {
            guard var observation = observations.removeValue(forKey: id) else {
                return WholeRootObservation(generation: generation &- 1)
            }
            observation.speculativeLandedBytes = observation.speculative.reduce(0) {
                $1.committed ? $0 : Self.saturatingSum($0, $1.landedBytes)
            }
            observation.speculative = []
            return observation
        }
    }

    /// The pass found the root over its limit only when the bytes of
    /// in-flight speculative writes are counted. Those writes give way.
    func revokeSpeculativeWrites() {
        lock.withLock { revokeSpeculativeLocked() }
    }

    /// What one whole-root pass left on disk: readable block bytes per
    /// model root and temp bytes that belong to no reservation. A pass that
    /// walked while bytes changed sides, or that could not list a directory
    /// (`complete` false), may have missed some, so it can raise the figure
    /// and not lower it; the next whole, undisturbed pass sets it. Erring
    /// high declines a speculative write that would have fitted.
    func publishWholeRoot(
        wholeRootKey: String, bytesByModelRoot: [String: Int], unreservedTempBytes: Int,
        observation: WholeRootObservation, complete: Bool = true
    ) {
        lock.withLock {
            var indexed: [String: Int] = [:]
            for registration in stores.values {
                indexed[registration.modelRootKey, default: 0] += registration.store.diskBytesOnDisk
            }
            var unowned = max(0, unreservedTempBytes)
            for (modelRoot, bytes) in bytesByModelRoot {
                unowned = Self.saturatingSum(unowned, max(0, bytes - (indexed[modelRoot] ?? 0)))
            }
            unownedBytes[wholeRootKey] = complete && observation.generation == generation
                ? unowned : max(unowned, unownedBytes[wholeRootKey] ?? 0)
        }
    }

    private func addReservationLocked(
        bytes: Int, keys: [String], wholeRootKey: String, isSpeculative: Bool
    ) -> SSDDiskReservation {
        let reservation = SSDDiskReservation(
            bytes: bytes, keys: keys, wholeRootKey: wholeRootKey, isSpeculative: isSpeculative)
        reservations[ObjectIdentifier(reservation)] = reservation
        reservedBytes = Self.saturatingSum(reservedBytes, reservation.bytes)
        for id in observations.keys { observations[id]?.record(reservation) }
        return reservation
    }

    private func releaseLocked(_ reservation: SSDDiskReservation, as disposition: SSDDiskReservation.Disposition) {
        guard !reservation.released else { return }
        reservation.released = true
        reservation.committed = disposition == .committed
        if reservation.isSpeculative, disposition != .committed { speculativeWithdrawals &+= 1 }
        reservations.removeValue(forKey: ObjectIdentifier(reservation))
        // Summed again, not subtracted: a saturated sum cannot be undone.
        reservedBytes = reservations.values.reduce(0) { Self.saturatingSum($0, $1.bytes) }
        switch disposition {
        case .committed:
            settledBytes &+= UInt64(reservation.bytes)
            generation &+= 1
        case .abandonedOnDisk:
            settledBytes &+= UInt64(reservation.bytes)
            addUnownedLocked(reservation.bytes, wholeRootKey: reservation.wholeRootKey)
            generation &+= 1
        case .discarded:
            break
        }
    }

    private func speculativeStillFitsLocked(
        _ reservation: SSDDiskReservation, fileBytes: Int, basis: SSDDiskBudgetBasis,
        settledSince mark: UInt64? = nil
    ) -> Bool {
        guard !reservation.released, !reservation.isRevoked else { return false }
        // Its own bytes are on the volume already; the others' may not be,
        // and neither may the ones settled since the volume was read.
        let unseen = mark.map { Int(clamping: settledBytes &- $0) } ?? 0
        guard fitsLocked(bytes: fileBytes, includesReserved: true, excluding: reservation,
                         ownBytesStillToLand: unseen, wholeRootKey: reservation.wholeRootKey, basis: basis)
        else { return false }
        reservation.bytes = max(0, fileBytes)
        reservedBytes = reservations.values.reduce(0) { Self.saturatingSum($0, $1.bytes) }
        return true
    }

    /// Indexed + unowned + pending + `bytes` against the budget once every
    /// byte not yet on the volume has landed. Pending is every outstanding
    /// reservation but `excluding`, plus the proven writes every registered
    /// store has accepted and not started. Indexed and pending bytes are
    /// box-wide, as the budget is; unowned bytes are those of the write's own
    /// whole root, the tree its maintenance pass enforces. Saturating: an
    /// overflow is a refusal.
    private func fitsLocked(
        bytes: Int, includesReserved: Bool, excluding own: SSDDiskReservation? = nil,
        ownBytesStillToLand: Int, wholeRootKey: String, basis: SSDDiskBudgetBasis
    ) -> Bool {
        guard bytes >= 0 else { return false }
        var occupied = 0
        var pending = includesReserved ? max(0, reservedBytes - (own?.bytes ?? 0)) : 0
        for registration in stores.values {
            occupied = Self.saturatingSum(occupied, registration.store.diskBytesOnDisk)
            pending = Self.saturatingSum(pending, max(0, registration.store.queuedWriteBytes))
        }
        occupied = Self.saturatingSum(occupied, unownedBytes[wholeRootKey] ?? 0)
        occupied = Self.saturatingSum(occupied, pending)
        occupied = Self.saturatingSum(occupied, bytes)
        guard occupied < Int.max else { return false }
        return occupied <= basis.bytes(afterWriting: Self.saturatingSum(pending, ownBytesStillToLand))
    }

    private func shrinkLocked(_ reservation: SSDDiskReservation, by bytes: Int) {
        guard !reservation.released else { return }
        reservation.bytes = max(0, reservation.bytes - max(0, bytes))
        reservedBytes = reservations.values.reduce(0) { Self.saturatingSum($0, $1.bytes) }
    }

    private func revokeSpeculativeLocked() {
        for reservation in reservations.values where reservation.isSpeculative { reservation.revoke() }
    }

    /// Bytes that in-flight speculative writes have on the volume. They are
    /// nobody's entry yet and are withdrawn if their room is needed, so an
    /// enforcement limit is the one that holds without them.
    private func speculativeLandedBytesLocked() -> Int {
        reservations.values.reduce(0) { $1.isSpeculative ? Self.saturatingSum($0, $1.landedBytes) : $0 }
    }

    private func addUnownedLocked(_ bytes: Int, wholeRootKey: String) {
        guard bytes > 0 else { return }
        unownedBytes[wholeRootKey] = Self.saturatingSum(unownedBytes[wholeRootKey] ?? 0, bytes)
    }

    private static func saturatingSum(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : sum
    }

    /// Evict oldest-by-last-hit (across all stores) until the box-wide
    /// total is at most `budgetBytes`. Returns the number of evictions.
    @discardableResult
    func enforce(budgetBytes: Int) -> Int {
        enforce(basis: .fixed(budgetBytes))
    }

    /// The same against a budget that moves with the volume. A half-of-free
    /// budget is lower while an in-flight speculative write's bytes are on
    /// the volume; evicting to that lower limit would remove a committed
    /// entry on the write's account, so the limit is taken without them.
    @discardableResult
    func enforce(basis: SSDDiskBudgetBasis) -> Int {
        lock.withLock { enforceLocked(basis: basis) }
    }

    /// The same with the volume read by `basis` outside the lock. If a
    /// speculative write was withdrawn between that reading and the lock,
    /// the reading still has its bytes on the volume and nothing credits
    /// them any more, so the volume is read again. After three such
    /// readings nothing is evicted in this call; the next pass enforces.
    @discardableResult
    func enforce(basis: () -> SSDDiskBudgetBasis) -> Int {
        for _ in 0..<3 {
            let seen = lock.withLock { speculativeWithdrawals }
            let reading = basis()
            let evicted: Int? = lock.withLock {
                seen == speculativeWithdrawals ? enforceLocked(basis: reading) : nil
            }
            if let evicted { return evicted }
        }
        return 0
    }

    private func enforceLocked(basis: SSDDiskBudgetBasis) -> Int {
        do {
            var evicted = 0
            var blockedStores: Set<ObjectIdentifier> = []
            let limit = max(0, basis.bytes(afterRemoving: speculativeLandedBytesLocked()))
            // Bounded: a pass either frees one entry or permanently excludes
            // one store for this enforcement call. One undeletable oldest
            // entry therefore cannot stop eviction in another store.
            while stores.values.reduce(0, { $0 + $1.store.diskBytesOnDisk }) > limit {
                var victim: SSDEvictableStore?
                var victimAccess = Int64.max
                for registration in stores.values {
                    let store = registration.store
                    guard !blockedStores.contains(ObjectIdentifier(store)) else {
                        continue
                    }
                    if let access = store.oldestEntryAccess(), access < victimAccess {
                        victimAccess = access
                        victim = store
                    }
                }
                guard let victim else { return evicted }
                guard victim.evictOldestEntry() > 0 else {
                    blockedStores.insert(ObjectIdentifier(victim))
                    continue
                }
                evicted += 1
                _evictions += 1
            }
            return evicted
        }
    }
}
