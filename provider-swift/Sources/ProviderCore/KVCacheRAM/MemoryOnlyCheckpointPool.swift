import Foundation

/// Every RAM-only complete checkpoint of the process, across loaded models:
/// one budget, one least-recently-used order and one set of counters. Each
/// slot's `MemoryOnlyCheckpointTier` is a namespace here.
///
/// The pool yields memory before anything else does: an entry is admitted only
/// while the process ledger keeps a whole budget of headroom beyond it, and
/// entries are released on a refused memory charge, on memory pressure, before
/// a model load, before the Mac sleeps (so no hibernation image holds them), on
/// unload and at shutdown. Entries expire with the SSD tier's TTL and TTL mode:
/// sliding on reuse, or fixed from the store.
final class MemoryOnlyCheckpointPool: @unchecked Sendable {
    static let shared = MemoryOnlyCheckpointPool()

    enum EvictionReason: String, CaseIterable, Sendable {
        case lru, ttl, pressure, load, shortfall, sleep, unload, shutdown
    }

    enum StoreOutcome: String, CaseIterable, Sendable {
        case stored
        /// The prefix is already held: nothing is copied, and a fixed TTL
        /// keeps counting from the first store.
        case duplicate
        case refusedBudget = "refused_budget"
        /// The donation queue was full.
        case refusedBusy = "refused_busy"
        case refusedHeadroom = "refused_headroom"
        case refusedLock = "refused_lock"
        case refusedPolicy = "refused_policy"
    }

    enum LookupOutcome: String, CaseIterable, Sendable { case hit, miss, skipped }

    struct Key: Hashable, Sendable {
        let namespace: UUID
        /// The full HMAC tag of the checkpoint's scoped prefix chain.
        let tag: Data
    }

    /// One payload segment's place in the entry's region.
    struct Segment: Sendable {
        let tensor: Int
        let offset: Int
        let regionOffset: Int
        let bytes: Int
    }

    /// The region holds the encoded manifest at offset 0, then the segments.
    /// Nothing else here is derived from the request. `release` frees the
    /// region, then refunds its ledger charge.
    final class Entry: @unchecked Sendable {
        let region: LockedHostRegion
        let manifestBytes: Int
        let segments: [Segment]
        let createdAt: Int64
        fileprivate(set) var lastUsedAt: Int64
        fileprivate(set) var useOrder: UInt64 = 0
        private let lock = NSLock()
        private var charge: ProcessHostBufferReservation?

        init(region: LockedHostRegion, admission: Admission, manifestBytes: Int, segments: [Segment],
             createdAt: Int64) {
            self.region = region
            self.charge = admission.charge
            self.manifestBytes = manifestBytes
            self.segments = segments
            self.createdAt = createdAt
            self.lastUsedAt = createdAt
        }

        deinit { release() }

        var bytes: UInt64 { UInt64(region.length) }

        func release() {
            region.release()
            lock.withLock {
                defer { charge = nil }
                return charge
            }?.closeAfterDroppingBuffers()
        }
    }

    /// Room reserved for one entry while its bytes are copied in. Exactly one
    /// of `commit` or `cancel` settles it.
    final class Admission: @unchecked Sendable {
        let bytes: UInt64
        /// The ledger charge, handed to the entry.
        let charge: ProcessHostBufferReservation?
        /// A release of the whole pool while the bytes were copied in also
        /// covers this entry.
        fileprivate let releaseEpoch: UInt64
        private weak var pool: MemoryOnlyCheckpointPool?
        private let lock = NSLock()
        private var settled = false

        fileprivate init(
            bytes: UInt64, charge: ProcessHostBufferReservation?, releaseEpoch: UInt64, pool: MemoryOnlyCheckpointPool
        ) {
            self.bytes = bytes
            self.charge = charge
            self.releaseEpoch = releaseEpoch
            self.pool = pool
        }

        fileprivate func settle() -> Bool {
            lock.withLock {
                defer { settled = true }
                return !settled
            }
        }

        /// No entry took the charge: refund it and the room.
        func cancel(outcome: StoreOutcome) {
            guard settle() else { return }
            charge?.closeAfterDroppingBuffers()
            pool?.cancel(self, outcome: outcome)
        }

        /// False when a release of the whole pool came first: the entry is
        /// then dropped at once.
        @discardableResult
        func commit(key: Key, entry: Entry) -> Bool {
            guard settle(), let pool else {
                entry.release()
                return false
            }
            return pool.insert(entry, key: key, admission: self)
        }
    }

    struct Snapshot: Sendable, Equatable {
        var budgetBytes: UInt64 = 0
        var bytes: UInt64 = 0
        var entries = 0
        var lookups: [LookupOutcome: UInt64] = [:]
        var hitTokens: UInt64 = 0
        var stores: [StoreOutcome: UInt64] = [:]
        var evictions: [EvictionReason: UInt64] = [:]
        /// Calls with an ordinary request's receipt; stays 0.
        var unmarkedRefusals: UInt64 = 0
    }

    let ttlSeconds: Int64
    let ttlMode: SSDPrefixCachePolicy.TTLMode
    private let nowSeconds: @Sendable () -> Int64
    private let sweepInterval: Duration
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    /// Committed entries plus admissions still copying.
    private var reservedBytes: UInt64 = 0
    private var budget: UInt64 = 0
    private var clock: UInt64 = 0
    private var releaseEpoch: UInt64 = 0
    private var lastReleaseReason = EvictionReason.pressure
    private var counts = Snapshot()
    private var sweepTask: Task<Void, Never>?
    private var sleepRelease: SystemSleepRelease?

    init(
        ttlSeconds: Int64 = SSDPrefixCachePolicy.ttlSeconds(),
        ttlMode: SSDPrefixCachePolicy.TTLMode = SSDPrefixCachePolicy.ttlMode(),
        sweepInterval: Duration = .seconds(60),
        nowSeconds: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.ttlSeconds = ttlSeconds
        self.ttlMode = ttlMode
        self.sweepInterval = min(sweepInterval, .seconds(max(1, ttlSeconds)))
        self.nowSeconds = nowSeconds
    }

    deinit { sweepTask?.cancel() }

    var now: Int64 { nowSeconds() }

    // MARK: - Budget

    var budgetBytes: UInt64 { lock.withLock { budget } }
    var bytesInUse: UInt64 { lock.withLock { reservedBytes } }

    /// The budget is a share of the serving set's KV headroom, so the servers
    /// update it at each load and unload.
    func updateBudget(
        fleetKVHeadroomBytes: UInt64, environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        setBudget(MemoryOnlyPrefixCachePolicy.budgetBytes(
            fleetKVHeadroomBytes: fleetKVHeadroomBytes, environment: environment))
    }

    /// A smaller budget evicts least recently used entries down to it.
    func setBudget(_ bytes: UInt64) {
        let evicted = lock.withLock { () -> [Entry] in
            budget = bytes
            counts.budgetBytes = bytes
            return evictLocked(downTo: bytes, reason: .lru)
        }
        evicted.forEach { $0.release() }
    }

    /// Room for `bytes` inside the budget, evicting least recently used
    /// entries for it, and the matching ledger charge. Nil when the entry is
    /// larger than the budget, or the ledger can't keep a whole budget of
    /// headroom beside it.
    func admit(bytes: Int, ledger: GlobalKVCacheBudget?) -> Admission? {
        guard bytes > 0, let rounded = LockedHostRegion.pageRounded(bytes) else { return nil }
        let size = UInt64(rounded)
        let (evicted, requiredHeadroom, epoch) = lock.withLock { () -> ([Entry], UInt64?, UInt64) in
            // Entries of other slots still copying in can't be evicted for it.
            let copying = reservedBytes - committedBytesLocked()
            guard budget > 0, size <= budget, copying <= budget - size else {
                counts.stores[.refusedBudget, default: 0] += 1
                return ([], nil, releaseEpoch)
            }
            let evicted = evictLocked(downTo: budget - size, reason: .lru)
            reservedBytes += size
            return (evicted, budget, releaseEpoch)
        }
        evicted.forEach { $0.release() }
        guard let requiredHeadroom else { return nil }
        var charge: ProcessHostBufferReservation?
        if let ledger {
            charge = ledger.reserveHostBuffers(bytes: size)
            guard let charge, ledger.processLedger.snapshot().remainingBytes >= requiredHeadroom else {
                charge?.closeAfterDroppingBuffers()
                lock.withLock {
                    reservedBytes -= size
                    counts.stores[.refusedHeadroom, default: 0] += 1
                }
                return nil
            }
        }
        return Admission(bytes: size, charge: charge, releaseEpoch: epoch, pool: self)
    }

    private func cancel(_ admission: Admission, outcome: StoreOutcome) {
        lock.withLock {
            reservedBytes -= admission.bytes
            counts.stores[outcome, default: 0] += 1
        }
    }

    private func insert(_ entry: Entry, key: Key, admission: Admission) -> Bool {
        let (stored, dropped) = lock.withLock { () -> (Bool, [Entry]) in
            precondition(entry.bytes == admission.bytes)
            guard admission.releaseEpoch == releaseEpoch else {
                reservedBytes -= entry.bytes
                counts.evictions[lastReleaseReason, default: 0] += 1
                return (false, [entry])
            }
            clock &+= 1
            entry.useOrder = clock
            var dropped = removeLocked(key).map { [$0] } ?? []
            entries[key] = entry
            counts.stores[.stored, default: 0] += 1
            // A budget that shrank while the bytes were copied in still holds.
            dropped += evictLocked(downTo: budget, reason: .lru)
            if sweepTask == nil { sweepTask = makeSweepTask() }
            if sleepRelease == nil {
                sleepRelease = SystemSleepRelease { [weak self] in self?.releaseAll(reason: .sleep) }
            }
            return (true, dropped)
        }
        dropped.forEach { $0.release() }
        return stored
    }

    // MARK: - Lookup

    /// The first live entry among `tags`, deepest prefix first. Expired
    /// entries met on the way are released.
    func lookup(namespace: UUID, tags: [Data]) -> (tag: Data, entry: Entry)? {
        let now = nowSeconds()
        let (found, expired) = lock.withLock { () -> ((tag: Data, entry: Entry)?, [Entry]) in
            var found: (tag: Data, entry: Entry)?
            var expired: [Entry] = []
            for tag in tags {
                let key = Key(namespace: namespace, tag: tag)
                guard let entry = entries[key] else { continue }
                if !isExpiredLocked(entry, now: now) {
                    found = (tag: tag, entry: entry)
                    break
                }
                _ = removeLocked(key)
                counts.evictions[.ttl, default: 0] += 1
                expired.append(entry)
            }
            if !expired.isEmpty { refreshSizeLocked() }
            return (found, expired)
        }
        expired.forEach { $0.release() }
        return found
    }

    /// Whether a live entry holds this prefix: then a donation of it copies
    /// nothing and counts as a duplicate, and counts as a use like a restore.
    func holdsDuplicate(namespace: UUID, tag: Data) -> Bool {
        let now = nowSeconds()
        let held = lock.withLock { () -> Bool in
            guard let entry = entries[Key(namespace: namespace, tag: tag)], !isExpiredLocked(entry, now: now)
            else { return false }
            counts.stores[.duplicate, default: 0] += 1
            return true
        }
        if held { touch(namespace: namespace, tag: tag) }
        return held
    }

    /// A restored entry becomes the most recently used one, and under the
    /// sliding mode its TTL restarts.
    func touch(namespace: UUID, tag: Data) {
        let now = nowSeconds()
        lock.withLock {
            guard let entry = entries[Key(namespace: namespace, tag: tag)] else { return }
            clock &+= 1
            entry.useOrder = clock
            entry.lastUsedAt = now
        }
    }

    /// Drops one entry whose bytes no longer restore.
    func remove(namespace: UUID, tag: Data) {
        let removed = lock.withLock { () -> Entry? in
            guard let entry = removeLocked(Key(namespace: namespace, tag: tag)) else { return nil }
            refreshSizeLocked()
            return entry
        }
        removed?.release()
    }

    // MARK: - Release

    func releaseAll(namespace: UUID, reason: EvictionReason) {
        release(reason: reason) { key, _ in key.namespace == namespace }
    }

    func releaseAll(reason: EvictionReason) {
        lock.withLock {
            releaseEpoch &+= 1
            lastReleaseReason = reason
        }
        release(reason: reason) { _, _ in true }
    }

    /// Releases least recently used entries until `bytes` are free, for a
    /// refused charge that this much room lets through.
    func release(bytes: UInt64, reason: EvictionReason) {
        let evicted = lock.withLock { () -> [Entry] in
            let committed = committedBytesLocked()
            return evictLocked(downTo: reservedBytes - min(bytes, committed), reason: reason)
        }
        evicted.forEach { $0.release() }
    }

    func sweepExpired() {
        let now = nowSeconds()
        release(reason: .ttl) { [self] _, entry in isExpiredLocked(entry, now: now) }
    }

    private func release(reason: EvictionReason, where matches: (Key, Entry) -> Bool) {
        let evicted = lock.withLock { () -> [Entry] in
            let evicted = entries.filter { matches($0.key, $0.value) }.keys.compactMap { removeLocked($0) }
            counts.evictions[reason, default: 0] += UInt64(evicted.count)
            refreshSizeLocked()
            return evicted
        }
        evicted.forEach { $0.release() }
    }

    private func evictLocked(downTo target: UInt64, reason: EvictionReason) -> [Entry] {
        var evicted: [Entry] = []
        while reservedBytes > target,
            let oldest = entries.min(by: { $0.value.useOrder < $1.value.useOrder })?.key,
            let entry = removeLocked(oldest)
        {
            counts.evictions[reason, default: 0] += 1
            evicted.append(entry)
        }
        refreshSizeLocked()
        return evicted
    }

    private func committedBytesLocked() -> UInt64 {
        entries.values.reduce(UInt64(0)) { $0 + $1.bytes }
    }

    /// Caller holds the lock. A committed entry's bytes leave the reservation
    /// only here.
    private func removeLocked(_ key: Key) -> Entry? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        reservedBytes -= entry.bytes
        return entry
    }

    private func isExpiredLocked(_ entry: Entry, now: Int64) -> Bool {
        let start = ttlMode.refreshesOnHit ? entry.lastUsedAt : entry.createdAt
        return now - start >= ttlSeconds || now < start
    }

    private func refreshSizeLocked() {
        counts.entries = entries.count
        counts.bytes = committedBytesLocked()
    }

    private func makeSweepTask() -> Task<Void, Never> {
        let interval = sweepInterval
        return Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.sweepExpired()
                let idle = self.lock.withLock { () -> Bool in
                    guard self.entries.isEmpty else { return false }
                    self.sweepTask = nil
                    return true
                }
                if idle { return }
            }
        }
    }

    // MARK: - Counters

    func recordLookup(_ outcome: LookupOutcome, hitTokens: Int = 0) {
        lock.withLock {
            counts.lookups[outcome, default: 0] += 1
            counts.hitTokens += UInt64(max(0, hitTokens))
        }
    }

    func recordStoreRefusal(_ outcome: StoreOutcome) {
        lock.withLock { counts.stores[outcome, default: 0] += 1 }
    }

    func recordUnmarkedRefusal() {
        lock.withLock { counts.unmarkedRefusals += 1 }
    }

    var snapshot: Snapshot { lock.withLock { counts } }
}
