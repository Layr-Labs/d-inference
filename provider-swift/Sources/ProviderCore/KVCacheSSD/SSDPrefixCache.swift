// Copyright © 2026 Eigen Labs.
//
// SSDPrefixCache — the encrypted SSD KV-offload prefix cache (v0.7.5).
// Conforms to the engine's frozen `CBv2PrefixCache` protocol and is the only
// reusable prefix-cache implementation wired into production `EngineV2`:
//
//   * DONATION (engine donation queue → write-behind): `donate` chain-hashes
//     the finished request's tokens, dedupes against the index + in-flight
//     set, extracts ONLY the new blocks' KV to compact host buffers
//     (device slice → eval → asData(.copy), ~1–30 ms), returns — and a
//     bounded serial pipeline (`SSDWriteBehind`) encrypts and writes DBK3
//     per-block files whose names are HMAC tags (`SSDLookupKeys`). The
//     device arrays are dropped immediately: steady-state resident prefix
//     KV is ZERO — RAM stays entirely with live serving.
//
//   * ADOPTION (read-through): the engine's synchronous `lookup()` stays
//     RAM-only — it probes a small STAGING map. The bridge's pre-submit
//     hook calls `stage(requestID:promptTokens:cacheScope:)` first, off the
//     engine/submit threads: probe the index for the longest contiguous
//     block run, apply the benefit gate, reserve the staged bytes in
//     `GlobalKVCacheBudget` (the vision-reservation pattern: reserve before
//     the read, refuse ⇒ silent recompute), read + decrypt + rebuild the
//     per-layer arrays, park them in the staging map. The engine's
//     unmodified makeAdoption → lookup → applyAdoption → endAdoption
//     machinery then consumes them; `endAdoption` (invoked by the engine on
//     EVERY outcome, incl. abandon/shutdown) releases the staging pin, and
//     the bridge backstops release on submit-failure and pump-terminal
//     paths (`completeStaging`).
//
// Threat model T-041: at-rest artifacts return with this tier, but names/
// index/metadata carry only HMAC tags under the SE-rooted per-install
// K_lookup (leak #2 CLOSED), the 15-minute sliding TTL bounds the at-rest
// window, and the AES-GCM per-file DEK/KEK scheme is the reviewed legacy
// core unchanged. Salt scoping is preserved on disk (folded into both the
// chain hash and the HMAC tag). SEC-035 (in-process TTFT oracle) stays the
// accepted residual, now extended across restarts within the TTL window.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
#if canImport(os)
import os
#endif

// MARK: - Stats

public struct SSDPrefixCacheStats: Sendable, Equatable {
    public var hits = 0
    public var misses = 0
    public var tokensSaved = 0
    /// Successful pre-submit stagings (disk → RAM rehydrations).
    public var stages = 0
    /// Device bytes currently parked in the staging map (gauge; 0 whenever
    /// no adoption is in flight — the RAM-discipline invariant).
    public var stagedBytesInUse = 0
    public var blocksWritten = 0
    public var bytesWritten = 0
    public var donationsDropped = 0
    public var writeRateLimited = 0
    public var corruptDropped = 0
    public var evictions = 0
    public var ttlExpired = 0
    /// WS-4.2. `windowSidecarsWritten` is a SUBSET of `blocksWritten` (they
    /// share the write-behind consumer); `windowsRestored` counts adoptions
    /// whose sliding window came off disk instead of being replayed. With no
    /// canary fleet these two are how the sidecar is observed in the field.
    public var windowSidecarsWritten = 0
    public var windowsRestored = 0
    /// Index size (filled at snapshot time).
    public var entries = 0
    public var bytesOnDisk = 0
}

final class SSDPrefixCacheStatsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stats = SSDPrefixCacheStats()

    func add(
        hits: Int = 0, misses: Int = 0, tokensSaved: Int = 0, stages: Int = 0,
        stagedBytesDelta: Int = 0, blocksWritten: Int = 0, bytesWritten: Int = 0,
        donationsDropped: Int = 0, writeRateLimited: Int = 0, corruptDropped: Int = 0,
        evictions: Int = 0, ttlExpired: Int = 0,
        windowSidecarsWritten: Int = 0, windowsRestored: Int = 0
    ) {
        lock.withLock {
            stats.hits += hits
            stats.misses += misses
            stats.tokensSaved += tokensSaved
            stats.stages += stages
            stats.stagedBytesInUse = max(0, stats.stagedBytesInUse + stagedBytesDelta)
            stats.blocksWritten += blocksWritten
            stats.bytesWritten += bytesWritten
            stats.donationsDropped += donationsDropped
            stats.writeRateLimited += writeRateLimited
            stats.corruptDropped += corruptDropped
            stats.evictions += evictions
            stats.ttlExpired += ttlExpired
            stats.windowSidecarsWritten += windowSidecarsWritten
            stats.windowsRestored += windowsRestored
        }
    }

    func snapshot() -> SSDPrefixCacheStats {
        lock.withLock { stats }
    }
}

// MARK: - SSDPrefixCache

public final class SSDPrefixCache:
    CBv2PrefixCache, CBv2SlidingWindowDonating, SSDEvictableStore, @unchecked Sendable
{

    struct Config: Sendable {
        let modelId: String
        let promptContractID: String
        /// Verified live weight root hash (MB-1 binding). Production
        /// construction refuses to create this reusable tier without it.
        let weightHash: String
        let blockSize: Int
        /// `windowCount × maxWindow` — the engine's recompute bound when the
        /// adopter's sliding rows are REPLAYED, which is the conservative and
        /// always-safe answer. The staging benefit gate subtracts it from
        /// `matched`.
        let adoptionBoundTokens: Int
        /// The bound that applies only at a boundary whose ENTIRE window is
        /// tiled by present, authenticated sidecars: zero, because there is
        /// nothing left to replay.
        ///
        /// Two fields rather than one because sidecar availability is a
        /// per-boundary fact, not a cache-wide one. Collapsing the cache-wide
        /// bound instead makes every candidate — including the ones whose
        /// tiling is incomplete and which therefore replay in full — advertise
        /// savings it will not deliver. Defaults to `adoptionBoundTokens`,
        /// so a cache with no restore consumer can only ever be conservative.
        let windowRestoredBoundTokens: Int
        /// Nominal fp16 full-row bytes per token used by SSD replay planning.
        /// The slot factory independently gives every contiguous request a
        /// resolved native-width process reservation before staging.
        let nominalFullKVBytesPerToken: Int
        let layoutEpoch: String
        let epochStore: SSDCacheEpochStore?
        /// `…/darkbloom/kv3/<modelKey>` — files live here, per-model, in
        /// the SSD tier's OWN root (never under the legacy `kv/` root the
        /// upgrade sweeper sheds).
        let root: URL
        /// Canonical `…/darkbloom/kv3` parent. Production construction pins
        /// the model directory as a direct child; direct test construction
        /// defaults to `root`'s parent.
        let dedicatedRoot: URL
        let ttlSeconds: Int64
        let minEffectiveTokens: Int
        let maxStageBytes: Int
        let maxStageMillis: Int
        /// WS-4.2 sliding-window sidecar geometry, or nil when the feature is
        /// off (`SSDPrefixCachePolicy.windowSidecarFlag`, default) or the
        /// model's window does not tile into whole blocks. One field rather
        /// than a flag plus a derivation, so the write and read paths cannot
        /// disagree about whether this cache has sidecars.
        let windowSidecar: SSDWindowSidecarGeometry?
        let nowSeconds: @Sendable () -> Int64

        init(
            modelId: String,
            promptContractID: String,
            weightHash: String,
            blockSize: Int,
            adoptionBoundTokens: Int,
            nominalFullKVBytesPerToken: Int = 0,
            layoutEpoch: String,
            epochStore: SSDCacheEpochStore? = nil,
            root: URL,
            dedicatedRoot: URL? = nil,
            ttlSeconds: Int64,
            minEffectiveTokens: Int,
            maxStageBytes: Int,
            maxStageMillis: Int,
            windowSidecar: SSDWindowSidecarGeometry? = nil,
            windowRestoredBoundTokens: Int? = nil,
            nowSeconds: @escaping @Sendable () -> Int64
        ) {
            self.modelId = modelId
            self.promptContractID = promptContractID
            self.weightHash = weightHash
            self.blockSize = blockSize
            self.adoptionBoundTokens = adoptionBoundTokens
            self.windowRestoredBoundTokens = windowRestoredBoundTokens ?? adoptionBoundTokens
            self.nominalFullKVBytesPerToken = max(0, nominalFullKVBytesPerToken)
            self.layoutEpoch = layoutEpoch
            self.epochStore = epochStore
            self.root = root
            self.dedicatedRoot = dedicatedRoot ?? root.deletingLastPathComponent()
            self.ttlSeconds = ttlSeconds
            self.minEffectiveTokens = minEffectiveTokens
            self.maxStageBytes = maxStageBytes
            self.maxStageMillis = maxStageMillis
            self.windowSidecar = windowSidecar
            self.nowSeconds = nowSeconds
        }
    }

    let config: Config
    private let kekKey: SymmetricKey
    private let lookupKeys: SSDLookupKeys
    /// Process-unique namespace for staging tickets and the process-global KV
    /// reservation ledger. Per-bridge receipt counters intentionally restart at
    /// one, so their raw values are not globally unique.
    private let cacheInstanceNamespace: String
    let index: SSDBlockIndex
    private let kvBudget: GlobalKVCacheBudget?
    private let diskBudget: SSDDiskBudget
    private let donationRecorder: any PrefixCacheDonationRecording
    let statsBox = SSDPrefixCacheStatsBox()
    private var writeBehind: SSDWriteBehind!

    /// One staged (rehydrated-from-disk) prefix awaiting adoption.
    private final class StagedEntry {
        let matched: Int
        let prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?]
        /// WS-4.2: the donor's sliding window at `matched`, restored from
        /// windowed sidecars, or nil when the adopter must replay. Indexed by
        /// model layer, nil at every non-sliding slot — the shape WS-4.1's
        /// `restoreWindow(_:at:)` consumes (bridged through
        /// `CBv2PagedWindowSnapshot`).
        let window: [SSDWindowSidecar.Window?]?
        let deviceBytes: Int
        let cacheEpoch: String?
        /// Requests attached to this entry that have not yet been balanced.
        /// PURE residency accounting — the shared-KV
        /// reservation is per-ENTRY (`reservationKey`), not per-ticket, so
        /// dropping an arbitrary ticket here can never strand another
        /// request's reservation.
        var openTickets: Set<String>
        /// Exact request tickets whose lookup hit has not yet been balanced by
        /// endAdoption. A peer can never consume or retire another request's
        /// ticket while its adoption is in flight.
        var pinnedTickets: Set<String> = []
        /// The ONE shared-KV-budget reservation covering this entry's
        /// `deviceBytes` (the CREATING request's key). Attaching requests
        /// release their redundant provisional reservation; this one is
        /// released exactly once, when the entry itself is retired. Holding
        /// it for the whole residency window is what closes the T-041
        /// orphan: while the staged arrays are resident, they stay reserved.
        let reservationKey: String

        init(
            matched: Int, prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?],
            window: [SSDWindowSidecar.Window?]?,
            deviceBytes: Int, cacheEpoch: String?, firstTicket: String, reservationKey: String
        ) {
            self.matched = matched
            self.prefix = prefix
            self.window = window
            self.deviceBytes = deviceBytes
            self.cacheEpoch = cacheEpoch
            self.openTickets = [firstTicket]
            self.reservationKey = reservationKey
        }
    }

    private let lock = NSLock()
    private var closed = false
    private var scanReady = false
    private var scanFailed = false
    private var cacheStatusFailure: PrefixCacheStatusReason?
    private var destructiveChangeInProgress = false
    /// tag16 of the run's TERMINAL block → staged entry.
    private var stagedEntries: [Data: StagedEntry] = [:]
    /// requestID → terminal tag16 (the bridge-backstop handle).
    private var tickets: [String: Data] = [:]
    /// Blocks queued/being written — dedupe for concurrent donations.
    private var inFlightWrites: Set<Data> = []
    private final class ReadyReceiptState {
        let callback: @Sendable (PrefixCacheReadyResult) -> Void
        var highestReadyTokens = 0

        init(callback: @escaping @Sendable (PrefixCacheReadyResult) -> Void) {
            self.callback = callback
        }
    }
    private var readyReceipts: [CBv2RequestID: ReadyReceiptState] = [:]
    private var sweepTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var closeReleaseTask: Task<Void, Never>?

    #if canImport(os)
    private static let logger = Logger(
        subsystem: "com.darkbloom.provider", category: "ssd_prefix_cache")
    #endif

    /// DType ↔ name map for chunk descriptors (complete over DType).
    private static let dtypeByName: [String: DType] = {
        Dictionary(uniqueKeysWithValues: DType.allCases.map { (String(describing: $0), $0) })
    }()

    init(
        config: Config,
        kekKey: SymmetricKey,
        kvBudget: GlobalKVCacheBudget?,
        diskBudget: SSDDiskBudget = .shared,
        maxWriteBytesPerDay: Int = SSDPrefixCachePolicy.defaultMaxWriteBytesPerDay,
        strictFsync: Bool = false,
        diskBudgetBytes: @escaping @Sendable () -> Int,
        maintainWholeRoot: (@Sendable () -> Void)? = nil,
        cacheInstanceNamespace: String = UUID().uuidString,
        donationRecorder: any PrefixCacheDonationRecording = PrefixCacheDonationTelemetry.shared
    ) {
        self.config = config
        self.kekKey = kekKey
        self.lookupKeys = SSDLookupKeys(kek: kekKey)
        self.cacheInstanceNamespace = cacheInstanceNamespace
        self.index = SSDBlockIndex()
        self.kvBudget = kvBudget
        self.diskBudget = diskBudget
        self.donationRecorder = donationRecorder
        let root = config.root
        self.writeBehind = SSDWriteBehind(
            config: SSDWriteBehind.Config(
                root: root,
                kekKey: kekKey,
                strictFsync: strictFsync,
                ttlSeconds: config.ttlSeconds,
                maxJobs: SSDPrefixCachePolicy.writeQueueMaxJobs,
                // One full max-size donation (≤ maxStageBytes after the
                // persisted-run byte cap, e.g. a ~600 MB gemma long-context
                // tail) must ALWAYS be admittable — a second concurrent
                // large donation may be dropped (counted), never stalled.
                maxQueuedBytes: max(
                    SSDPrefixCachePolicy.writeQueueMaxBytes,
                    config.maxStageBytes + SSDPrefixCachePolicy.writeQueueSlackBytes),
                diskBudgetBytes: diskBudgetBytes,
                volumeSpace: { Self.volumeSpace(at: root) },
                nowSeconds: config.nowSeconds,
                maintainWholeRoot: maintainWholeRoot,
                writeBlock: nil),
            rateLimiter: SSDWriteRateLimiter(capBytesPerDay: maxWriteBytesPerDay),
            index: index,
            diskBudget: diskBudget,
            stats: statsBox,
            onBlockSettled: { [weak self] tag16 in
                guard let self else { return }
                self.lock.withLock { _ = self.inFlightWrites.remove(tag16) }
            },
            sweepExpired: { [weak self] in
                self?.sweepExpiredEntries()
            })
        diskBudget.register(self)
    }

    // MARK: - Lifecycle

    /// Start the startup directory scan (async — lookups before it
    /// finishes just miss) and the low-frequency periodic TTL sweep.
    func startBackgroundTasks(sweepIntervalSeconds: Int = 60) {
        guard hasSafeRoot else { return }
        scanTask = Task.detached(priority: .utility) { [weak self] in
            self?.scanOnDisk()
        }
        sweepTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await taskSleep(.seconds(sweepIntervalSeconds))
                if Task.isCancelled { return }
                guard let self, !self.isClosed else { return }
                self.sweepExpiredEntries()
            }
        }
    }

    var isClosed: Bool { lock.withLock { closed } }

    func prefixCacheV2Capability() -> PrefixCacheV2Capability? {
        lock.withLock { prefixCacheV2CapabilityLocked() }
    }

    func prefixCacheModelStatus(base: PrefixCacheModelStatus) -> PrefixCacheModelStatus {
        lock.withLock { prefixCacheModelStatusLocked(base: base) }
    }

    func prefixCacheAdvertisement(base: PrefixCacheModelStatus) -> (
        capability: PrefixCacheV2Capability?,
        status: PrefixCacheModelStatus
    ) {
        lock.withLock {
            (
                prefixCacheV2CapabilityLocked(),
                prefixCacheModelStatusLocked(base: base)
            )
        }
    }

    private func prefixCacheV2CapabilityLocked() -> PrefixCacheV2Capability? {
        guard !closed,
            scanReady,
            !destructiveChangeInProgress,
            let epoch = config.epochStore?.current,
            config.blockSize > 0,
            config.blockSize <= Int(UInt32.max)
        else { return nil }
        return PrefixCacheV2Capability(
            modelId: config.modelId,
            modelAggregateHash: config.weightHash,
            promptContractId: config.promptContractID,
            blockHashVersion: CBv2BlockHasher.version,
            blockSize: UInt32(config.blockSize),
            cacheEpoch: epoch,
            enabled: true,
            ready: true)
    }

    private func prefixCacheModelStatusLocked(
        base: PrefixCacheModelStatus
    ) -> PrefixCacheModelStatus {
        let status: (PrefixCacheStatusState, PrefixCacheStatusReason)
        if closed {
            status = (.error, .cacheInitFailed)
        } else if scanFailed {
            status = (.error, .scanFailed)
        } else if let cacheStatusFailure {
            status = (.error, cacheStatusFailure)
        } else if !scanReady || destructiveChangeInProgress {
            status = (.pending, .scanPending)
        } else if config.epochStore != nil && config.epochStore?.current == nil {
            status = (.error, .cacheInitFailed)
        } else {
            status = (.ready, .ready)
        }
        return PrefixCacheModelStatus(
            modelId: base.modelId,
            backend: base.backend,
            replayStrategy: base.replayStrategy,
            state: status.0,
            reason: status.1)
    }

    func takeNextPrefixCacheV2Sequence(expectedEpoch: String) -> UInt64? {
        lock.withLock {
            guard !closed, !destructiveChangeInProgress else { return nil }
            return config.epochStore?.takeNextSequence(expectedEpoch: expectedEpoch)
        }
    }

    /// Shutdown for model unload / bridge teardown: stop background work,
    /// drain staging pins (releasing their budget reservations), keep the
    /// files — durable warmth across unloads and restarts is the feature.
    public func close() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            scanReady = false
            scanFailed = false
            cacheStatusFailure = nil
            // Release the PER-ENTRY reservations (each resident entry holds
            // exactly one, keyed by its creator). Attaching requests already
            // released their redundant provisional reservation at attach
            // time; any request still mid-`stage()` releases its own on the
            // `closed`-guarded false return.
            let releaseKeys = stagedEntries.values.map(\.reservationKey)
            let stagedBytes = stagedEntries.values.reduce(0) { $0 + $1.deviceBytes }
            statsBox.add(stagedBytesDelta: -stagedBytes)
            tickets.removeAll()
            stagedEntries.removeAll()
            inFlightWrites.removeAll()
            readyReceipts.removeAll()
            if let kvBudget, !releaseKeys.isEmpty {
                closeReleaseTask = Task {
                    for key in releaseKeys {
                        await kvBudget.release(requestID: key)
                    }
                }
            }
            return true
        }
        guard shouldClose else { return }
        sweepTask?.cancel()
        scanTask?.cancel()
        writeBehind.close()
        diskBudget.deregister(self)
    }

    /// Fully awaited shutdown used by serving-engine teardown. The synchronous
    /// `close()` remains safe for deinit/defer-style callers, while production
    /// lifecycle owners can wait until background scans, writes, and reservation
    /// releases have actually finished.
    func closeAndWait() async {
        close()
        let tasks = lock.withLock {
            (scan: scanTask, sweep: sweepTask, release: closeReleaseTask)
        }
        _ = await tasks.scan?.value
        _ = await tasks.sweep?.value
        await writeBehind.waitUntilDrained()
        _ = await tasks.release?.value
    }

    /// Deterministic write-behind barrier for cache integration tests.
    func waitForWritesForTesting() async {
        await writeBehind.waitUntilDrained()
    }

    // MARK: - CBv2PrefixCache: lookup (RAM-only staging probe)

    public func lookup(
        tokens: [Int], layerKinds: [CBv2LayerKind]
    ) -> (matched: Int, prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?])? {
        lookup(ticket: nil, tokens: tokens, layerKinds: layerKinds, cacheSalt: nil)
    }

    public func lookup(
        tokens: [Int], layerKinds: [CBv2LayerKind], cacheSalt: String?
    ) -> (matched: Int, prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?])? {
        lookup(ticket: nil, tokens: tokens, layerKinds: layerKinds, cacheSalt: cacheSalt)
    }

    public func lookup(
        requestID: CBv2RequestID,
        tokens: [Int],
        layerKinds: [CBv2LayerKind],
        cacheSalt: String?
    ) -> (matched: Int, prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?])? {
        lookup(
            ticket: ticketKey(requestID),
            tokens: tokens,
            layerKinds: layerKinds,
            cacheSalt: cacheSalt)
    }

    private func lookup(
        ticket: String?,
        tokens: [Int],
        layerKinds: [CBv2LayerKind],
        cacheSalt: String?
    ) -> (matched: Int, prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?])? {
        // SYNCHRONOUS + RAM-ONLY by contract: the engine calls this on the
        // submit thread — never any disk I/O here. All I/O happened in the
        // pre-submit `stage`.
        let maxStagedBlocks = lock.withLock { () -> Int in
            guard !closed, !destructiveChangeInProgress, !stagedEntries.isEmpty else { return 0 }
            let epoch = config.epochStore?.current
            guard config.epochStore == nil || epoch != nil else { return 0 }
            return stagedEntries.values
                .filter { $0.cacheEpoch == epoch }
                .map { $0.matched / config.blockSize }
                .max() ?? 0
        }
        guard maxStagedBlocks > 0 else {
            statsBox.add(misses: 1)
            return nil
        }
        let salt = cacheSalt ?? ""
        let hasher = hasher(cacheSalt: salt)
        let maxBlocks = min(hasher.maxLookupBlocks(tokenCount: tokens.count), maxStagedBlocks)
        guard maxBlocks > 0 else {
            statsBox.add(misses: 1)
            return nil
        }
        let hashes = hasher.chainHashes(tokens: tokens, maxBlocks: maxBlocks)
        for k in stride(from: hashes.count, through: 1, by: -1) {
            let tag16 = lookupKeys.tag16(chainHash: hashes[k - 1], cacheSalt: salt)
            let hit: (Int, [(keys: MLXArray, values: MLXArray, offset: Int)?])? = lock.withLock {
                let epoch = config.epochStore?.current
                guard !closed,
                    !destructiveChangeInProgress,
                    config.epochStore == nil || epoch != nil
                else { return nil }
                guard let staged = stagedEntries[tag16],
                    staged.cacheEpoch == epoch,
                    staged.matched == k * config.blockSize,
                    staged.prefix.count == layerKinds.count
                else { return nil }
                // Defensive: the staged layer layout must agree with the
                // caller's cacheable positions (report 10 invariant 6).
                for (i, kind) in layerKinds.enumerated() {
                    let cacheable = Self.isCacheable(kind)
                    guard (staged.prefix[i] != nil) == cacheable else { return nil }
                }
                let claimedTicket: String
                if let ticket {
                    guard tickets[ticket] == tag16,
                        staged.openTickets.contains(ticket),
                        !staged.pinnedTickets.contains(ticket)
                    else { return nil }
                    claimedTicket = ticket
                } else {
                    // Backwards-compatible uncorrelated callers are safe only
                    // when there is exactly one possible ticket. Never choose
                    // arbitrarily between concurrent same-prefix requests.
                    let available = staged.openTickets.subtracting(staged.pinnedTickets)
                    guard available.count == 1, let only = available.first else { return nil }
                    claimedTicket = only
                }
                staged.pinnedTickets.insert(claimedTicket)
                return (staged.matched, staged.prefix)
            }
            if let (matched, prefix) = hit {
                statsBox.add(hits: 1)
                return (matched, prefix)
            }
        }
        statsBox.add(misses: 1)
        return nil
    }

    /// Terminal engine truth for prefill work actually skipped. Lookup knows
    /// only M; hybrid replay still computes R and must not count it as saved.
    func recordPrefillTokensSaved(_ tokens: Int) {
        guard tokens > 0 else { return }
        statsBox.add(tokensSaved: tokens)
    }

    // MARK: - CBv2PrefixCache: endAdoption (the staging release hook)

    public func endAdoption(tokens: [Int], matched: Int) {
        endAdoption(ticket: nil, tokens: tokens, matched: matched, cacheSalt: nil)
    }

    public func endAdoption(tokens: [Int], matched: Int, cacheSalt: String?) {
        endAdoption(ticket: nil, tokens: tokens, matched: matched, cacheSalt: cacheSalt)
    }

    public func endAdoption(
        requestID: CBv2RequestID,
        tokens: [Int],
        matched: Int,
        cacheSalt: String?
    ) {
        endAdoption(
            ticket: ticketKey(requestID),
            tokens: tokens,
            matched: matched,
            cacheSalt: cacheSalt)
    }

    private func endAdoption(
        ticket: String?,
        tokens: [Int],
        matched: Int,
        cacheSalt: String?
    ) {
        guard matched > 0, matched % config.blockSize == 0 else { return }
        let blocks = matched / config.blockSize
        guard blocks * config.blockSize <= tokens.count else { return }
        let salt = cacheSalt ?? ""
        let hashes = hasher(cacheSalt: salt).chainHashes(tokens: tokens, maxBlocks: blocks)
        guard hashes.count == blocks else { return }
        let tag16 = lookupKeys.tag16(chainHash: hashes[blocks - 1], cacheSalt: salt)

        var releaseKey: String?
        lock.withLock {
            guard let staged = stagedEntries[tag16] else { return }
            let claimedTicket: String
            if let ticket {
                guard tickets[ticket] == tag16, staged.pinnedTickets.contains(ticket)
                else { return }
                claimedTicket = ticket
            } else {
                guard staged.pinnedTickets.count == 1,
                    let only = staged.pinnedTickets.first
                else { return }
                claimedTicket = only
            }
            staged.pinnedTickets.remove(claimedTicket)
            staged.openTickets.remove(claimedTicket)
            tickets.removeValue(forKey: claimedTicket)
            releaseKey = removeStagedEntryIfDoneLocked(tag16)
        }
        if let releaseKey, let kvBudget {
            Task { await kvBudget.release(requestID: releaseKey) }
        }
    }

    // MARK: - CBv2PrefixCache: donate (write-behind)

    func registerReadyReceipt(
        requestID: CBv2RequestID,
        callback: @escaping @Sendable (PrefixCacheReadyResult) -> Void
    ) {
        lock.withLock {
            guard !closed else { return }
            readyReceipts[requestID] = ReadyReceiptState(callback: callback)
        }
    }

    func discardReadyReceipt(requestID: CBv2RequestID) {
        lock.withLock { _ = readyReceipts.removeValue(forKey: requestID) }
    }

    /// Donation runs asynchronously after the engine terminal. Keep the
    /// correlation briefly so a queued terminal donation can settle, then
    /// discard requests that never produced an eligible donation.
    func markReadyReceiptTerminal(
        requestID: CBv2RequestID,
        cleanupDelay: Duration = readyReceiptRetention
    ) {
        guard let terminalState = lock.withLock({ readyReceipts[requestID] }) else { return }
        Task.detached { [weak self] in
            try? await taskSleep(cleanupDelay)
            guard let self else { return }
            self.lock.withLock {
                guard let current = self.readyReceipts[requestID], current === terminalState
                else { return }
                self.readyReceipts.removeValue(forKey: requestID)
            }
        }
    }

    static let readyReceiptRetention: Duration = .seconds(120)

    public func donate(tokens: [Int], state: [CBv2SequenceKV?], layerKinds: [CBv2LayerKind]) {
        donate(tokens: tokens, state: state, layerKinds: layerKinds, cacheSalt: nil)
    }

    public func donate(
        tokens: [Int], state: [CBv2SequenceKV?], layerKinds: [CBv2LayerKind], cacheSalt: String?
    ) {
        let settlement = PrefixCacheDonationSettlement(recorder: donationRecorder)
        guard state.count == layerKinds.count else {
            settlement.settle(.incompleteLayerState)
            return
        }
        var snapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?] = []
        var windows: [SSDWindowSidecar.Window?] = []
        snapshots.reserveCapacity(layerKinds.count)
        windows.reserveCapacity(layerKinds.count)
        for (i, kind) in layerKinds.enumerated() {
            // WS-4.2: sliding rows are NOT cacheable as blocks, but their ring
            // is exactly what a windowed sidecar persists. Probed through the
            // donor seam so contiguous and (once WS-4.1 lands) paged rows both
            // participate without this path knowing which backend it holds.
            windows.append((state[i] as? SSDWindowSnapshotting)?.windowSnapshot())
            guard Self.isCacheable(kind), let seq = state[i] else {
                snapshots.append(nil)
                continue
            }
            snapshots.append(seq.snapshot())
        }
        donate(
            tokens: tokens,
            snapshots: snapshots,
            windowSnapshots: windows,
            layerKinds: layerKinds,
            cacheSalt: cacheSalt,
            receiptRequestID: nil,
            settlement: settlement)
    }

    public func donate(
        tokens: [Int],
        snapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?],
        layerKinds: [CBv2LayerKind]
    ) {
        donate(tokens: tokens, snapshots: snapshots, layerKinds: layerKinds, cacheSalt: nil)
    }

    public func donate(
        requestID: CBv2RequestID,
        tokens: [Int],
        snapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?],
        layerKinds: [CBv2LayerKind],
        cacheSalt: String?
    ) {
        let settlement = PrefixCacheDonationSettlement(recorder: donationRecorder)
        donate(
            tokens: tokens,
            snapshots: snapshots,
            layerKinds: layerKinds,
            cacheSalt: cacheSalt,
            receiptRequestID: requestID,
            settlement: settlement)
    }

    /// Runs on the engine's donation queue. The engine holds the donor KV
    /// until this returns, so only the minimum happens synchronously:
    /// hashing, dedupe, and the device→host extraction of NEW blocks.
    /// Everything slow (encrypt, write, index, budgets) is behind the
    /// bounded write-behind queue.
    public func donate(
        tokens: [Int],
        snapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?],
        layerKinds: [CBv2LayerKind], cacheSalt: String?
    ) {
        let settlement = PrefixCacheDonationSettlement(recorder: donationRecorder)
        donate(
            tokens: tokens,
            snapshots: snapshots,
            layerKinds: layerKinds,
            cacheSalt: cacheSalt,
            receiptRequestID: nil,
            settlement: settlement)
    }

    /// Donation with an explicit sliding-window payload, already in
    /// `(keys, values, base)` form — the direct-injection seam for a caller
    /// that resolved the anchor itself. `nil` window entries are ignored; a
    /// sidecar is written only when EVERY storage-owning sliding layer is
    /// present and they agree on one absolute span.
    ///
    /// PRODUCTION does not come through here: the engine hands over
    /// `snapshot()` triples via `CBv2SlidingWindowDonating` (below), which
    /// resolves the anchor with `SSDWindowSidecar.windows(fromSnapshots:)`
    /// and then joins this same private path.
    func donate(
        requestID: CBv2RequestID?,
        tokens: [Int],
        snapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?],
        windowSnapshots: [SSDWindowSidecar.Window?],
        layerKinds: [CBv2LayerKind],
        cacheSalt: String?
    ) {
        let settlement = PrefixCacheDonationSettlement(recorder: donationRecorder)
        donate(
            tokens: tokens,
            snapshots: snapshots,
            windowSnapshots: windowSnapshots,
            layerKinds: layerKinds,
            cacheSalt: cacheSalt,
            receiptRequestID: requestID,
            settlement: settlement)
    }

    // MARK: CBv2SlidingWindowDonating — the PRODUCTION donation path

    /// Whether this cache persists sliding rows at all. The engine reads it
    /// once per donation BEFORE snapshotting anything, so a build with the
    /// sidecar knob off never pays for the (200 MiB on gemma-4) window graph.
    /// Resolved at construction from the operator knob and the layout, so
    /// this is a plain field read on the engine thread.
    public var wantsSlidingWindowDonation: Bool { config.windowSidecar != nil }

    /// The donation the engine ACTUALLY makes for a request that carries a
    /// `prefixCacheReceiptID` — i.e. every production request once the SSD
    /// cache is constructed (`EngineV2Bridge` mints one for each of them).
    ///
    /// This overload exists because the frozen
    /// `donate(requestID:tokens:snapshots:layerKinds:cacheSalt:)` carries no
    /// sliding rows — its `snapshots` array is nil at every windowed layer by
    /// contract — so routing production through it left the sidecar feature
    /// inert no matter what the operator knob said. The engine now hands the
    /// sliding triples over here, already snapshotted on its own thread.
    public func donate(
        requestID: CBv2RequestID,
        tokens: [Int],
        snapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?],
        slidingSnapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?],
        layerKinds: [CBv2LayerKind],
        cacheSalt: String?
    ) {
        let settlement = PrefixCacheDonationSettlement(recorder: donationRecorder)
        donate(
            tokens: tokens,
            snapshots: snapshots,
            windowSnapshots: SSDWindowSidecar.windows(fromSnapshots: slidingSnapshots),
            layerKinds: layerKinds,
            cacheSalt: cacheSalt,
            receiptRequestID: requestID,
            settlement: settlement)
    }

    private func donate(
        tokens: [Int],
        snapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?],
        windowSnapshots: [SSDWindowSidecar.Window?]? = nil,
        layerKinds: [CBv2LayerKind],
        cacheSalt: String?,
        receiptRequestID: CBv2RequestID?,
        settlement: PrefixCacheDonationSettlement
    ) {
        guard !isClosed else {
            settlement.settle(.cacheClosed)
            return
        }
        guard snapshots.count == layerKinds.count else {
            settlement.settle(.incompleteLayerState)
            return
        }
        let salt = cacheSalt ?? ""
        let hasher = hasher(cacheSalt: salt)
        let blockCount = hasher.fullBlockCount(tokenCount: tokens.count)
        guard blockCount > 0 else {
            settlement.settle(.noCompleteBlock)
            return
        }
        let prefixTokens = blockCount * config.blockSize

        // PER-DONATION gate (Gaj, 2026-07-07 — replaces the binary
        // per-model funding rule for the SSD tier): persist only prefixes
        // LONG ENOUGH TO EVER BE ADOPTED — donated whole-block length must
        // exceed the model's adoption bound (windowCount × maxWindow, the
        // engine's recompute span) plus the staging benefit floor. For
        // gpt-oss (bound 1,536 + 1,024 = 2,560) this skips sub-~2.5k
        // donations that could never clear adoption — pure disk-wear win,
        // no behavior change for adoptable traffic. For gemma-4 (bound
        // 25,600 + 1,024 = 26,624) it automatically enables the >26.6k
        // long-context tail that the old per-model gate excluded entirely.
        // A saturated/unknown bound (overflow) can never pass — such a
        // model is effectively never cached, by construction.
        let (donationFloor, floorOverflow) =
            config.adoptionBoundTokens.addingReportingOverflow(config.minEffectiveTokens)
        guard !floorOverflow, prefixTokens > donationFloor else {
            settlement.settle(.belowEffectiveTokenFloor)
            return
        }

        // Validate cacheable-layer coverage (PrefixCacheV2 semantics: a
        // cacheable layer with missing/short state makes the whole
        // donation unusable).
        var cacheable: [(layerIndex: Int, keys: MLXArray, values: MLXArray)] = []
        for (i, kind) in layerKinds.enumerated() {
            guard Self.isCacheable(kind) else { continue }
            guard let snap = snapshots[i],
                snap.offset >= prefixTokens,
                snap.keys.ndim == 4, snap.keys.dim(2) >= prefixTokens,
                snap.values.ndim == 4, snap.values.dim(2) >= prefixTokens
            else {
                settlement.settle(.incompleteLayerState)
                return
            }
            cacheable.append((i, snap.keys, snap.values))
        }
        guard !cacheable.isEmpty else {
            settlement.settle(.incompleteLayerState)
            return
        }

        // Chain hashes + HMAC tags; dedupe BEFORE any copy (spec §3.2).
        let hashes = hasher.chainHashes(tokens: tokens, maxBlocks: blockCount)
        var fullTags: [Data] = []
        var tags16: [Data] = []
        fullTags.reserveCapacity(blockCount)
        tags16.reserveCapacity(blockCount)
        for hash in hashes {
            let full = lookupKeys.tag(chainHash: hash, cacheSalt: salt)
            fullTags.append(full)
            tags16.append(full.prefix(SSDLookupKeys.truncatedTagLength))
        }
        // Persisted-run byte cap: blocks whose CUMULATIVE run bytes exceed
        // `maxStageBytes` can never be staged (the adoption trim loop cuts
        // the run at that cap), so writing them is pure wear. Cap the
        // persisted block range accordingly (leading blocks only — the run
        // must stay prefix-contiguous). Per-block bytes derived from the
        // snapshot shapes (exact for the uniform engine-native layout).
        var perBlockBytes = 0
        for layer in cacheable {
            let dims = [layer.keys.dim(0), layer.keys.dim(1), config.blockSize, layer.keys.dim(3)]
            let elements = dims.reduce(1, *)
            perBlockBytes += 2 * elements * layer.keys.dtype.size
        }
        guard perBlockBytes > 0 else {
            settlement.settle(.incompleteLayerState)
            return
        }
        let maxPersistBlocks = config.maxStageBytes / perBlockBytes
        let durableTags = Array(tags16.prefix(maxPersistBlocks))
        let durableFullTags = Array(fullTags.prefix(maxPersistBlocks))
        let durableChainHashes = Array(hashes.prefix(maxPersistBlocks))
        let (durableTokenCount, durableTokenOverflow) =
            durableTags.count.multipliedReportingOverflow(by: config.blockSize)
        guard !durableTokenOverflow, durableTokenCount > donationFloor else {
            settlement.settle(.stageSizeExceeded)
            return
        }
        let onDurable: (@Sendable () -> Bool)?
        if let receiptRequestID, !durableTags.isEmpty {
            onDurable = { [weak self] in
                self?.settleDurableDonation(
                    requestID: receiptRequestID,
                    tags16: durableTags,
                    fullTags: durableFullTags,
                    chainHashes: durableChainHashes,
                    cacheSalt: salt) ?? false
            }
        } else {
            onDurable = nil
        }

        let now = config.nowSeconds()
        var newBlockIndices: [Int] = []
        var skippedInFlight = false
        var closedDuringDedupe = false
        lock.withLock {
            guard !closed else {
                closedDuringDedupe = true
                return
            }
            for (i, tag16) in tags16.enumerated() where i < maxPersistBlocks {
                if index.contains(tag16: tag16) { continue }
                if inFlightWrites.contains(tag16) {
                    skippedInFlight = true
                    continue
                }
                inFlightWrites.insert(tag16)
                newBlockIndices.append(i)
            }
        }
        if closedDuringDedupe {
            settlement.settle(.cacheClosed)
            return
        }
        // Sliding-TTL bump for the blocks this active conversation reused —
        // index recency AND file mtimes (best-effort), so donation-only
        // warmth survives a restart (the startup scan seeds lastAccess from
        // mtime). Reused blocks = every tag NOT in newBlockIndices.
        index.touch(tags16: tags16, now: now)
        let newSet = Set(newBlockIndices)
        let touchDate = Date(timeIntervalSince1970: TimeInterval(now))
        for (i, tag16) in tags16.enumerated() where !newSet.contains(i) {
            guard index.contains(tag16: tag16) else { continue }
            let url = SSDBlockStore.fileURL(
                root: config.root, tag16Hex: SSDLookupKeys.hex(tag16))
            SSDBlockStore.setAttributesIfSafe(
                [.modificationDate: touchDate], at: url, under: config.root)
        }
        var blocks: [SSDBlockWrite] = []
        var totalBytes = 0

        if !newBlockIndices.isEmpty {
            // Endurance pre-check BEFORE any extraction: when the daily write
            // budget can't even cover ONE block, the consumer would drop every
            // one of these blocks at `tryConsume` — after the loop below had
            // already paid the device-slice/eval/host-copy for each. Skip the
            // whole donation up front instead. Gated on a single block (not
            // the full donation) so a nearly-drained bucket still persists the
            // leading prefix-contiguous blocks it can afford — the consumer's
            // per-block `tryConsume` stays the authority. Settle the in-flight
            // tags so a later donation can retry these blocks once the bucket
            // refills.
            guard writeBehind.mightAcceptWrite(bytes: perBlockBytes) else {
                lock.withLock {
                    for i in newBlockIndices { inFlightWrites.remove(tags16[i]) }
                }
                // Attribute to the write cap (same accounting as the consumer's
                // per-block tryConsume drop) so `rateLimited` stats stay
                // truthful now that this pre-check intercepts most
                // cap-exhausted donations.
                statsBox.add(
                    donationsDropped: newBlockIndices.count,
                    writeRateLimited: newBlockIndices.count)
                settlement.settle(.writeRateLimited)
                return
            }

            // Per-block extraction: device slice → eval → compact host Data in
            // engine-native [B, kvHeads, block, headDim] layout. Device arrays
            // are dropped as soon as the bytes are copied out.
            for b in newBlockIndices {
                let t0 = b * config.blockSize
                let t1 = t0 + config.blockSize
                var slices: [MLXArray] = []
                slices.reserveCapacity(cacheable.count * 2)
                for layer in cacheable {
                    slices.append(layer.keys[.ellipsis, t0 ..< t1, 0...])
                    slices.append(layer.values[.ellipsis, t0 ..< t1, 0...])
                }
                eval(slices)
                var chunks: [Data] = []
                var descriptors: [SSDBlockChunkDescriptor] = []
                var sizes: [Int] = []
                for (j, layer) in cacheable.enumerated() {
                    for tensor in 0 ..< 2 {
                        let arr = slices[j * 2 + tensor]
                        let data = arr.asData(access: .copy)
                        chunks.append(data.data)
                        sizes.append(data.data.count)
                        descriptors.append(
                            SSDBlockChunkDescriptor(
                                layerIndex: layer.layerIndex, tensor: tensor,
                                shape: data.shape, dtype: String(describing: data.dType)))
                    }
                }
                let tag16Hex = SSDLookupKeys.hex(tags16[b])
                let metadata = SSDBlockMetadata(
                    lookupTag: SSDLookupKeys.hex(fullTags[b]),
                    weightHash: config.weightHash,
                    layoutEpoch: config.layoutEpoch,
                    blockSize: config.blockSize,
                    layerCount: layerKinds.count,
                    chunks: descriptors,
                    chunkPlaintextSizes: sizes,
                    createdAt: now)
                let blockBytes = sizes.reduce(0, +)
                totalBytes += blockBytes
                blocks.append(
                    SSDBlockWrite(
                        tag16: tags16[b], tag16Hex: tag16Hex, metadata: metadata,
                        chunks: chunks, plaintextBytes: blockBytes))
            }
        }

        // WS-4.2 sidecars are appended AFTER the blocks — and claimed even
        // when every block deduped, because a repeat donation of an already-
        // durable prefix still ends at a different absolute offset and so
        // covers boundaries no earlier donation could; skipping it would leave
        // permanent holes in the window tiling.
        //
        // Order is load-bearing: `SSDWriteBehind.consume` charges the daily
        // endurance bucket per entry IN ARRAY ORDER, and one sidecar is an
        // order of magnitude larger than a block (52 MB vs 5 MB on gemma-4).
        // Queued first, a sidecar could spend the last of the allowance and
        // starve the very prefix blocks it can only accelerate.
        appendWindowSidecars(
            into: &blocks, totalBytes: &totalBytes,
            windowSnapshots: windowSnapshots, layerKinds: layerKinds,
            chainHashes: hashes, cacheSalt: salt,
            blockCount: min(blockCount, maxPersistBlocks), now: now)

        guard !newBlockIndices.isEmpty else {
            settlement.settle(skippedInFlight ? .alreadyQueued : .alreadyDurable)
            // Every block is already durable or owned by an earlier queued
            // write. Still pass correlated donations through the serial queue
            // so prior writes and maintenance settle before a ready receipt.
            // Already settled above, so the job's outcome is a no-op.
            if onDurable != nil || !blocks.isEmpty {
                let result = writeBehind.submitWithResult(SSDDonationJob(
                    blocks: blocks, totalBytes: totalBytes, onDurable: onDurable))
                if result != .accepted, !blocks.isEmpty {
                    lock.withLock {
                        for block in blocks { inFlightWrites.remove(block.tag16) }
                    }
                    statsBox.add(donationsDropped: blocks.count)
                }
            }
            return
        }

        let submitResult = writeBehind.submitWithResult(SSDDonationJob(
            blocks: blocks,
            totalBytes: totalBytes,
            onDurable: onDurable,
            onOutcome: { outcome in settlement.settle(outcome) }))
        guard submitResult == .accepted else {
            // Queue overflow / byte cap / closed: drop the donation, settle
            // the in-flight tags so a later donation can retry these blocks.
            lock.withLock {
                for block in blocks { inFlightWrites.remove(block.tag16) }
            }
            statsBox.add(donationsDropped: blocks.count)
            settlement.settle(submitResult == .closed ? .cacheClosed : .writeQueueFull)
            return
        }
    }

    /// WS-4.2: claim and extract the windowed sidecars this donation covers,
    /// appending them to the same write-behind job as the blocks.
    ///
    /// Coverage is bounded by physics, not policy: a donating row's ring holds
    /// exactly the last `W` positions ending at its own absolute offset, which
    /// is a mid-block position for all but 1 in `blockSize` requests. So one
    /// donation covers `W/blockSize − 1` whole blocks in the general case and
    /// `W/blockSize` when it happens to stop on a boundary. Successive
    /// donations end at different offsets and their covered ranges TILE, which
    /// is what eventually completes a boundary's window. A boundary whose
    /// tiling is incomplete is simply not restorable, and the adopter replays.
    private func appendWindowSidecars(
        into blocks: inout [SSDBlockWrite],
        totalBytes: inout Int,
        windowSnapshots: [SSDWindowSidecar.Window?]?,
        layerKinds: [CBv2LayerKind],
        chainHashes: [Data],
        cacheSalt: String,
        blockCount: Int,
        now: Int64
    ) {
        guard let geometry = config.windowSidecar,
            let windows = windowSnapshots,
            let span = SSDWindowSidecar.span(windows: windows, geometry: geometry)
        else { return }
        let covered = geometry.coveredBlocks(
            base: span.base, tokens: span.tokens,
            blockCount: min(blockCount, chainHashes.count))
        guard !covered.isEmpty else { return }
        // Endurance pre-check BEFORE extraction, charged on top of the blocks
        // already queued. One sidecar is an order of magnitude larger than the
        // block it accelerates (52 MB vs 5 MB on gemma-4), so extracting one
        // the consumer will refuse costs ~150–200 MiB of device slices, evals
        // and host copies on the engine's donation queue for nothing. Advisory
        // exactly like the block pre-check: the consumer's per-entry
        // `tryConsume` remains the authority for races.
        let elementSize = geometry.layers
            .compactMap { windows[$0.index]?.keys.dtype.size }.first ?? 0
        let sidecarBytes = geometry.bytesPerBlock(elementSize: elementSize)
        guard sidecarBytes > 0,
            writeBehind.mightAcceptWrite(bytes: totalBytes + sidecarBytes)
        else { return }

        var claimed: [(block: Int, tag16: Data, fullTag: Data)] = []
        var reused: [Data] = []
        lock.withLock {
            guard !closed else { return }
            for b in covered {
                let full = lookupKeys.windowTag(chainHash: chainHashes[b], cacheSalt: cacheSalt)
                let tag16 = full.prefix(SSDLookupKeys.truncatedTagLength)
                if index.contains(tag16: tag16) {
                    reused.append(tag16)
                    continue
                }
                if inFlightWrites.contains(tag16) { continue }
                inFlightWrites.insert(tag16)
                claimed.append((b, tag16, full))
            }
        }
        // Sliding-TTL bump for the sidecars this donation re-covered, exactly
        // as the block path bumps its reused tags. Without it a conversation
        // can keep its block run warm forever while the sidecars underneath it
        // expire at 15 minutes — silently re-arming the full replay and paying
        // their (much larger) write wear again on the next donation.
        if !reused.isEmpty {
            index.touch(tags16: reused, now: now)
            let touchDate = Date(timeIntervalSince1970: TimeInterval(now))
            for tag16 in reused {
                let url = SSDBlockStore.fileURL(
                    root: config.root, tag16Hex: SSDLookupKeys.hex(tag16))
                SSDBlockStore.setAttributesIfSafe(
                    [.modificationDate: touchDate], at: url, under: config.root)
            }
        }
        guard !claimed.isEmpty else { return }

        var written: Set<Data> = []
        for entry in claimed {
            guard let payload = SSDWindowSidecar.extract(
                blockIndex: entry.block, windows: windows,
                geometry: geometry, base: span.base)
            else { continue }
            let bytes = payload.sizes.reduce(0, +)
            guard bytes > 0 else { continue }
            let metadata = SSDBlockMetadata(
                lookupTag: SSDLookupKeys.hex(entry.fullTag),
                weightHash: config.weightHash,
                layoutEpoch: config.layoutEpoch,
                blockSize: config.blockSize,
                layerCount: layerKinds.count,
                chunks: payload.descriptors,
                chunkPlaintextSizes: payload.sizes,
                createdAt: now,
                windowKind: SSDWindowSidecar.kind,
                windowBaseTag: lookupKeys.windowBaseCommitmentHex(
                    windowTag: entry.fullTag, base: entry.block * config.blockSize),
                windowTokens: config.blockSize)
            blocks.append(
                SSDBlockWrite(
                    tag16: entry.tag16, tag16Hex: SSDLookupKeys.hex(entry.tag16),
                    metadata: metadata, chunks: payload.chunks, plaintextBytes: bytes))
            totalBytes += bytes
            written.insert(entry.tag16)
        }
        guard written.count != claimed.count else { return }
        // An extraction that failed must give its tag back, or the block can
        // never be rewritten for the life of the process.
        lock.withLock {
            for entry in claimed where !written.contains(entry.tag16) {
                inFlightWrites.remove(entry.tag16)
            }
        }
    }

    // MARK: - CBv2PrefixCache: evict / bytesInUse

    /// Engine-facing RAM eviction — a no-op by design: this cache retains
    /// ZERO resident block bytes at steady state (the staging map is
    /// transient and reservation-accounted; disk eviction is the
    /// LRU/TTL/budget machinery, not this hook).
    public func evict(toFit byteBudget: Int) {}

    /// Resident bytes: only the transient staging map.
    public var bytesInUse: Int {
        lock.withLock { stagedEntries.values.reduce(0) { $0 + $1.deviceBytes } }
    }

    // MARK: - Pre-submit staging (the bridge hook)

    /// Rehydrate the longest usable on-disk prefix run for `promptTokens`
    /// into the staging map so the engine's synchronous `lookup()` hits.
    /// Runs on the request's own task (never the engine/submit hot path).
    ///
    /// Returns a typed staging decision. Every `.staged`
    /// MUST eventually be balanced by the engine's `endAdoption` (normal
    /// path) or `completeStaging(requestID:)` (bridge backstop) — both are
    /// idempotent per request.
    func stage(
        requestID: String, promptTokens: [Int], cacheScope: String
    ) async -> SSDPrefixCacheStageResult {
        let started = ContinuousClock.now
        let hasher = hasher(cacheSalt: cacheScope)
        let maxBlocks = hasher.maxLookupBlocks(tokenCount: promptTokens.count)
        let evidenceHashes = maxBlocks > 0
            ? hasher.chainHashes(tokens: promptTokens, maxBlocks: maxBlocks)
            : []
        func finish(
            _ disposition: SSDPrefixCacheStageDisposition,
            deviceBytes: Int = 0
        ) -> SSDPrefixCacheStageResult {
            let elapsed = started.duration(to: .now).components
            let milliseconds =
                Double(elapsed.seconds) * 1_000
                + Double(elapsed.attoseconds) / 1_000_000_000_000_000
            return SSDPrefixCacheStageResult(
                disposition: disposition,
                stageMs: max(0, milliseconds),
                chainHashes: evidenceHashes,
                blockSize: config.blockSize,
                deviceBytes: deviceBytes)
        }
        let stageEpoch: String?
        if let epochStore = config.epochStore {
            guard let current = epochStore.current else { return finish(.skippedPolicy) }
            stageEpoch = current
        } else {
            stageEpoch = nil
        }
        guard !isClosed, hasSafeRoot else { return finish(.skippedPolicy) }
        guard index.count > 0 else { return finish(.missAbsent) }
        let salt = cacheScope
        guard maxBlocks > 0 else { return finish(.skippedCost) }
        // Cheap pre-floor: a run can only clear the benefit gate when even
        // a FULL match would (matched − bound ≥ minEffective). Overflow-safe
        // like the donate-path floor (line ~418): an operator-set
        // `DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS` near Int.max
        // must DISABLE staging (saturated floor never passes), not trap the
        // provider on every request.
        let (preFloor, preFloorOverflow) =
            config.adoptionBoundTokens.addingReportingOverflow(config.minEffectiveTokens)
        guard !preFloorOverflow, maxBlocks * config.blockSize >= preFloor
        else { return finish(.skippedCost) }

        let hashes = evidenceHashes
        var fullTags: [Data] = []
        var tags16: [Data] = []
        for hash in hashes {
            let full = lookupKeys.tag(chainHash: hash, cacheSalt: salt)
            fullTags.append(full)
            tags16.append(full.prefix(SSDLookupKeys.truncatedTagLength))
        }
        // WS-4.2: the terminal-four sidecars that would restore the donor's
        // window at each candidate boundary. Probed inside the trim loop so
        // their bytes are inside the stage byte/time caps rather than added
        // on top of a run those caps already saturated.
        let windowGeometry = config.windowSidecar

        // Longest contiguous run, trimmed to the stage caps (bytes/time)
        // while it still clears the benefit floor.
        var k = index.longestRun(tags16: tags16)
        guard k > 0 else { return finish(.missAbsent) }
        var runBytes = 0
        var runSizes: [Int] = []
        var windowTags: [Data] = []
        while k > 0 {
            let matched = k * config.blockSize
            // Monotone impossibility test. `windowRestoredBoundTokens` is the
            // SMALLEST bound this cache can ever apply, and shorter runs match
            // strictly less, so failing here means no candidate can pass.
            // (The per-candidate gate below is NOT monotone: a shorter
            // boundary can have a complete tiling where a longer one does not.)
            guard matched - min(config.windowRestoredBoundTokens, matched)
                >= config.minEffectiveTokens
            else { return finish(.skippedCost) }
            guard let sizes = index.fileBytes(tags16: tags16[0 ..< k]) else {
                // Raced an eviction — re-probe.
                k = min(k - 1, index.longestRun(tags16: tags16))
                continue
            }
            runSizes = sizes
            runBytes = 0
            for size in sizes {
                let (sum, overflow) = runBytes.addingReportingOverflow(max(0, size))
                guard !overflow else { return finish(.skippedCapacity) }
                runBytes = sum
            }
            windowTags = windowSidecarTags(
                geometry: windowGeometry, chainHashes: hashes, cacheSalt: salt, blocks: k)
            if let windowSizes = index.fileBytes(tags16: windowTags[...]), !windowTags.isEmpty {
                for size in windowSizes {
                    let (sum, overflow) = runBytes.addingReportingOverflow(max(0, size))
                    guard !overflow else { return finish(.skippedCapacity) }
                    runBytes = sum
                }
            } else {
                // Incomplete tiling (or a raced eviction): a PARTIAL window is
                // not exact, so the whole window is dropped and the adopter
                // replays. Never shortens the block run.
                windowTags = []
            }
            // The bound must describe the window this boundary will ACTUALLY
            // get. Charging the cache-wide restored bound to a candidate whose
            // tiling is incomplete advertises savings the adopter cannot
            // deliver — it still performs the full replay.
            let bound = windowTags.isEmpty
                ? config.adoptionBoundTokens : config.windowRestoredBoundTokens
            if matched - min(bound, matched) >= config.minEffectiveTokens,
                runBytes <= config.maxStageBytes,
                SSDPrefixCachePolicy.estimatedStageMillis(bytes: runBytes) <= config.maxStageMillis
            {
                break
            }
            k -= 1
        }
        guard k > 0 else { return finish(.skippedCost) }

        // Concurrent same-prefix request: attach BEFORE taking a provisional
        // reservation. The existing entry already owns one exact reservation;
        // requiring spare headroom for a zero-allocation ticket would produce
        // false cold fallbacks under a full but correctly-accounted budget.
        let terminalTag = tags16[k - 1]
        let reservationKey = reservationKey(forRequestID: requestID)
        let attached = lock.withLock { () -> (deviceBytes: Int, hasWindow: Bool)? in
            guard !closed,
                !destructiveChangeInProgress,
                cacheEpochMatches(stageEpoch)
            else { return nil }
            guard let existing = stagedEntries[terminalTag],
                existing.cacheEpoch == stageEpoch,
                existing.matched == k * config.blockSize
            else { return nil }
            existing.openTickets.insert(requestID)
            tickets[requestID] = terminalTag
            return (existing.deviceBytes, existing.window != nil)
        }
        if let attached {
            // The saving belongs to the entry we joined, not to our probe: an
            // entry staged without a window still costs its adopter the full
            // replay, whatever this request's own index probe just saw.
            let matched = k * config.blockSize
            let bound = attached.hasWindow
                ? config.windowRestoredBoundTokens : config.adoptionBoundTokens
            return finish(.staged(
                matchedTokens: matched,
                expectedPrefillTokensSaved: max(0, matched - min(bound, matched)),
                shortenedByCorruption: false),
                deviceBytes: attached.deviceBytes)
        }
        // Multi-block conversion temporarily holds three full representations:
        // decrypted host Data, per-block MLX inputs, and concatenated outputs.
        let (initialPeakBytes, initialPeakOverflow) = runBytes.multipliedReportingOverflow(by: 3)
        guard !initialPeakOverflow else { return finish(.skippedCapacity) }
        if let kvBudget {
            guard await kvBudget.reserveBytes(
                requestID: reservationKey,
                bytes: UInt64(initialPeakBytes))
            else { return finish(.skippedCapacity) }
        }

        // Read + decrypt + verify blocks 1..k off the engine threads.
        var blockPayloads: [(metadata: SSDBlockMetadata, chunks: [Data])] = []
        var usableBlocks = k
        var shortenedByCorruption = false
        for i in 0 ..< k {
            if Task.isCancelled {
                await releaseReservation(reservationKey)
                return finish(.skippedPolicy)
            }
            let tag16Hex = SSDLookupKeys.hex(tags16[i])
            let url = SSDBlockStore.fileURL(root: config.root, tag16Hex: tag16Hex)
            do {
                let (metadata, chunks) = try SSDBlockStore.read(from: url, kekKey: kekKey)
                guard metadata.weightHash == config.weightHash,
                    metadata.layoutEpoch == config.layoutEpoch,
                    metadata.blockSize == config.blockSize,
                    metadata.lookupTag == SSDLookupKeys.hex(fullTags[i])
                else {
                    throw SSDBlockStoreError.bindingMismatch(
                        "weightHash/layoutEpoch/blockSize/tag binding")
                }
                blockPayloads.append((metadata, chunks))
            } catch {
                // Corrupt / torn / stale-binding block: delete, drop from
                // the index, fall back to the shorter run (or recompute).
                statsBox.add(corruptDropped: 1)
                _ = performDestructiveChange {
                    _ = SSDBlockStore.removeItemIfSafe(at: url, under: config.root)
                    index.remove(tag16: tags16[i])
                }
                #if canImport(os)
                Self.logger.warning(
                    "ssd prefix cache (\(self.config.modelId, privacy: .public)): dropped unreadable block (\(String(describing: error), privacy: .public)) — recompute fallback")
                #endif
                usableBlocks = i
                shortenedByCorruption = true
                break
            }
        }
        // Re-apply the benefit gate to the (possibly shortened) run. A
        // corruption-shortened run ends at a DIFFERENT boundary than the one
        // the trim loop tiled, and never restores a window (below), so it can
        // only be judged against the conservative replay bound.
        let matched = usableBlocks * config.blockSize
        var settledBound = usableBlocks == k && !windowTags.isEmpty
            ? config.windowRestoredBoundTokens
            : config.adoptionBoundTokens
        guard usableBlocks > 0, matched - min(settledBound, matched) >= config.minEffectiveTokens
        else {
            await releaseReservation(reservationKey)
            return finish(shortenedByCorruption ? .missCorrupt : .skippedCost)
        }
        blockPayloads = Array(blockPayloads.prefix(usableBlocks))

        // A corrupt block SHORTENED the run: the reservation and the staging
        // accounting must track the bytes actually staged, not the original
        // run — the difference would otherwise falsely consume shared KV
        // headroom until this request's release. Reconcile by re-reserving
        // the smaller amount (release + reserve; a raced refusal means real
        // memory pressure ⇒ silent recompute, exactly as if the shortened
        // run had been probed first).
        var stagedRunBytes = runBytes
        var reservedPeakBytes = initialPeakBytes
        if usableBlocks < k {
            stagedRunBytes = 0
            for size in runSizes.prefix(usableBlocks) {
                let (sum, overflow) = stagedRunBytes.addingReportingOverflow(max(0, size))
                guard !overflow else {
                    await releaseReservation(reservationKey)
                    return finish(.skippedCapacity)
                }
                stagedRunBytes = sum
            }
            let (shortenedPeakBytes, shortenedPeakOverflow) =
                stagedRunBytes.multipliedReportingOverflow(by: 3)
            guard !shortenedPeakOverflow else {
                await releaseReservation(reservationKey)
                return finish(.skippedCapacity)
            }
            if let kvBudget, shortenedPeakBytes != reservedPeakBytes {
                guard await kvBudget.resizeReservationBytes(
                    requestID: reservationKey,
                    bytes: UInt64(shortenedPeakBytes))
                else {
                    await releaseReservation(reservationKey)
                    return finish(.skippedCapacity)
                }
            }
            reservedPeakBytes = shortenedPeakBytes
        }

        // Rebuild per-layer arrays: per (layer × tensor), one MLXArray per
        // block chunk, concatenated along the token axis (graph op), then
        // ONE eval — the staged bytes become real device arrays here,
        // covered by the reservation taken above.
        guard let prefix = Self.rebuildPrefix(
            blocks: blockPayloads, blockSize: config.blockSize, matched: matched)
        else {
            statsBox.add(corruptDropped: 1)
            await releaseReservation(reservationKey)
            return finish(.missCorrupt)
        }
        if Task.isCancelled {
            await releaseReservation(reservationKey)
            return finish(.skippedPolicy)
        }
        // WS-4.2: restore the donor's sliding window from the terminal-four
        // sidecars whose bytes the trim loop already budgeted. Attempted only
        // on an unshortened run — a corruption-shortened boundary has a
        // different tiling than the one accounted for, and a PARTIAL window is
        // not exact. Any failure drops the window ALONE: the block adoption
        // stands and the adopter replays, exactly as it does today.
        var restoredWindow: [SSDWindowSidecar.Window?]?
        if let geometry = windowGeometry, usableBlocks == k, !windowTags.isEmpty {
            restoredWindow = readWindowSidecars(
                geometry: geometry, chainHashes: hashes, cacheSalt: salt, blocks: usableBlocks)
        }
        // A sidecar that was indexed but unreadable leaves this boundary on
        // the replay path after all, so the benefit has to be re-settled
        // against the conservative bound — and re-gated, since a run that only
        // cleared the floor on the strength of a restored window is not worth
        // staging without one.
        if restoredWindow == nil, settledBound != config.adoptionBoundTokens {
            settledBound = config.adoptionBoundTokens
            guard matched - min(settledBound, matched) >= config.minEffectiveTokens else {
                await releaseReservation(reservationKey)
                return finish(.skippedCost)
            }
        }
        let effective = matched - min(settledBound, matched)
        var exactDeviceBytes = 0
        for entry in prefix {
            guard let entry else { continue }
            let (entryBytes, entryOverflow) = entry.keys.nbytes.addingReportingOverflow(
                entry.values.nbytes)
            let (total, totalOverflow) = exactDeviceBytes.addingReportingOverflow(entryBytes)
            guard !entryOverflow, !totalOverflow else {
                await releaseReservation(reservationKey)
                return finish(.skippedCapacity)
            }
            exactDeviceBytes = total
        }
        for entry in restoredWindow ?? [] {
            guard let entry else { continue }
            let (entryBytes, entryOverflow) = entry.keys.nbytes.addingReportingOverflow(
                entry.values.nbytes)
            let (total, totalOverflow) = exactDeviceBytes.addingReportingOverflow(entryBytes)
            guard !entryOverflow, !totalOverflow else {
                await releaseReservation(reservationKey)
                return finish(.skippedCapacity)
            }
            exactDeviceBytes = total
        }
        guard exactDeviceBytes > 0 else {
            await releaseReservation(reservationKey)
            return finish(.missCorrupt)
        }
        let (conversionPeakBytes, conversionPeakOverflow) =
            stagedRunBytes.addingReportingOverflow(exactDeviceBytes)
        guard !conversionPeakOverflow else {
            await releaseReservation(reservationKey)
            return finish(.skippedCapacity)
        }
        if let kvBudget, conversionPeakBytes != reservedPeakBytes {
            guard await kvBudget.resizeReservationBytes(
                requestID: reservationKey,
                bytes: UInt64(conversionPeakBytes))
            else {
                await releaseReservation(reservationKey)
                return finish(.skippedCapacity)
            }
        }
        // The evaluated prefix owns its MLX storage. Drop decrypted host chunks
        // before converting the provisional peak reservation to steady device
        // residence, so no unaccounted host+device overlap remains.
        blockPayloads.removeAll(keepingCapacity: false)
        if let kvBudget, exactDeviceBytes != conversionPeakBytes {
            guard await kvBudget.resizeReservationBytes(
                requestID: reservationKey,
                bytes: UInt64(exactDeviceBytes))
            else {
                await releaseReservation(reservationKey)
                return finish(.skippedCapacity)
            }
        }

        // Post-build resolution: another concurrent request may have won the
        // race and created the entry while we were reading off-thread, in
        // which case we ATTACH (and release our now-redundant provisional
        // reservation); otherwise we CREATE and our reservation becomes the
        // entry's per-entry reservation.
        enum StageResolution {
            case created
            case attached(deviceBytes: Int, hasWindow: Bool)
            case failed
        }
        let resolution: StageResolution = lock.withLock {
            guard !closed,
                !destructiveChangeInProgress,
                cacheEpochMatches(stageEpoch)
            else { return .failed }
            if let existing = stagedEntries[terminalTag],
                existing.cacheEpoch == stageEpoch,
                existing.matched == matched
            {
                existing.openTickets.insert(requestID)
                tickets[requestID] = terminalTag
                return .attached(deviceBytes: existing.deviceBytes, hasWindow: existing.window != nil)
            }
            let usedTag = tags16[usableBlocks - 1]
            if let existing = stagedEntries[usedTag],
                existing.cacheEpoch == stageEpoch,
                existing.matched == matched
            {
                existing.openTickets.insert(requestID)
                tickets[requestID] = usedTag
                return .attached(deviceBytes: existing.deviceBytes, hasWindow: existing.window != nil)
            }
            stagedEntries[usedTag] = StagedEntry(
                matched: matched, prefix: prefix, window: restoredWindow,
                deviceBytes: exactDeviceBytes,
                cacheEpoch: stageEpoch, firstTicket: requestID, reservationKey: reservationKey)
            tickets[requestID] = usedTag
            statsBox.add(
                stages: 1, stagedBytesDelta: exactDeviceBytes,
                windowsRestored: restoredWindow == nil ? 0 : 1)
            return .created
        }
        switch resolution {
        case .failed:
            await releaseReservation(reservationKey)
            return finish(.skippedPolicy)
        case .attached(let attachedDeviceBytes, let attachedHasWindow):
            // Redundant with the winner's per-entry reservation. The saving is
            // the WINNER's: our own window read does not apply to an entry we
            // did not create.
            await releaseReservation(reservationKey)
            let attachedBound = attachedHasWindow
                ? config.windowRestoredBoundTokens : config.adoptionBoundTokens
            return finish(.staged(
                matchedTokens: matched,
                expectedPrefillTokensSaved: max(0, matched - min(attachedBound, matched)),
                shortenedByCorruption: shortenedByCorruption),
                deviceBytes: attachedDeviceBytes)
        case .created:
            break  // reservation is now owned by the staged entry
        }
        // Sliding TTL: bump index recency AND file mtimes so warmth
        // survives a restart (the scan seeds lastAccess from mtime). The
        // window sidecars ride the same bump — letting them expire under a
        // still-warm block run would silently re-arm the 25,600-token replay
        // and pay their write wear again on the next donation.
        let now = config.nowSeconds()
        index.touch(tags16: tags16.prefix(usableBlocks), now: now)
        index.touch(tags16: windowTags, now: now)
        let touchDate = Date(timeIntervalSince1970: TimeInterval(now))
        for tag16 in tags16.prefix(usableBlocks) + windowTags {
            let url = SSDBlockStore.fileURL(
                root: config.root, tag16Hex: SSDLookupKeys.hex(tag16))
            SSDBlockStore.setAttributesIfSafe(
                [.modificationDate: touchDate], at: url, under: config.root)
        }
        return finish(.staged(
            matchedTokens: matched,
            expectedPrefillTokensSaved: effective,
            shortenedByCorruption: shortenedByCorruption),
            deviceBytes: exactDeviceBytes)
    }

    func stage(
        requestID: CBv2RequestID, promptTokens: [Int], cacheScope: String
    ) async -> SSDPrefixCacheStageResult {
        await stage(
            requestID: ticketKey(requestID),
            promptTokens: promptTokens,
            cacheScope: cacheScope)
    }

    /// Truncated sidecar tags tiling the window that ends at block boundary
    /// `blocks`, oldest first. Empty when the boundary is shorter than one
    /// window — there is nothing to restore below `W` tokens, because the row
    /// legitimately has no older entries and cold prefill is already exact.
    private func windowSidecarTags(
        geometry: SSDWindowSidecarGeometry?,
        chainHashes: [Data],
        cacheSalt: String,
        blocks: Int
    ) -> [Data] {
        guard let geometry, blocks >= geometry.blocksPerWindow, blocks <= chainHashes.count
        else { return [] }
        return (blocks - geometry.blocksPerWindow ..< blocks).map {
            lookupKeys.windowTag16(chainHash: chainHashes[$0], cacheSalt: cacheSalt)
        }
    }

    /// Whether EVERY sidecar tiling the window that ends at block boundary
    /// `blocks` is currently indexed — the same predicate the staging trim
    /// loop applies, in the RAM index only (no I/O), so a donation-settlement
    /// receipt can describe the replay an adopter would really face.
    private func windowTilingComplete(
        chainHashes: [Data], cacheSalt: String, blocks: Int
    ) -> Bool {
        let tags = windowSidecarTags(
            geometry: config.windowSidecar, chainHashes: chainHashes,
            cacheSalt: cacheSalt, blocks: blocks)
        guard !tags.isEmpty else { return false }
        return index.fileBytes(tags16: tags[...]) != nil
    }

    /// Read, authenticate and reassemble the sliding window that ends at
    /// block boundary `blocks`. nil ⇒ the adopter replays.
    ///
    /// An unreadable sidecar is deleted and de-indexed exactly like an
    /// unreadable block, but it never shortens the block run: the sidecar is
    /// an accelerator, and losing it costs replay, not correctness.
    private func readWindowSidecars(
        geometry: SSDWindowSidecarGeometry,
        chainHashes: [Data],
        cacheSalt: String,
        blocks: Int
    ) -> [SSDWindowSidecar.Window?]? {
        let first = blocks - geometry.blocksPerWindow
        guard first >= 0, blocks <= chainHashes.count else { return nil }
        var payloads: [(metadata: SSDBlockMetadata, chunks: [Data])] = []
        payloads.reserveCapacity(geometry.blocksPerWindow)
        for b in first ..< blocks {
            let fullTag = lookupKeys.windowTag(chainHash: chainHashes[b], cacheSalt: cacheSalt)
            let tag16 = fullTag.prefix(SSDLookupKeys.truncatedTagLength)
            let url = SSDBlockStore.fileURL(
                root: config.root, tag16Hex: SSDLookupKeys.hex(tag16))
            do {
                let (metadata, chunks) = try SSDBlockStore.read(from: url, kekKey: kekKey)
                guard metadata.weightHash == config.weightHash,
                    metadata.layoutEpoch == config.layoutEpoch,
                    metadata.lookupTag == SSDLookupKeys.hex(fullTag),
                    SSDWindowSidecar.isBound(
                        metadata,
                        expectedBaseTag: lookupKeys.windowBaseCommitmentHex(
                            windowTag: fullTag, base: b * config.blockSize),
                        geometry: geometry)
                else {
                    throw SSDBlockStoreError.bindingMismatch(
                        "window sidecar weightHash/layoutEpoch/tag/base binding")
                }
                payloads.append((metadata, chunks))
            } catch {
                statsBox.add(corruptDropped: 1)
                _ = performDestructiveChange {
                    _ = SSDBlockStore.removeItemIfSafe(at: url, under: config.root)
                    index.remove(tag16: tag16)
                }
                #if canImport(os)
                Self.logger.warning(
                    "ssd prefix cache (\(self.config.modelId, privacy: .public)): dropped unreadable window sidecar (\(String(describing: error), privacy: .public)) — replay fallback")
                #endif
                return nil
            }
        }
        return SSDWindowSidecar.rebuildWindow(
            blocks: payloads,
            geometry: geometry,
            base: blocks * config.blockSize - geometry.windowTokens,
            dtypeByName: Self.dtypeByName)
    }

    /// WS-4.2 adoption seam: the donor's sliding window staged for
    /// `requestID`, indexed by model layer. nil ⇒ nothing was restored and the
    /// adopter must replay. Consumed by WS-4.1's `restoreWindow(_:at:)`, via
    /// `CBv2PagedWindowSnapshot(keys:values:base:)`.
    func stagedWindow(requestID: String) -> [SSDWindowSidecar.Window?]? {
        lock.withLock {
            guard let tag = tickets[requestID], let staged = stagedEntries[tag] else { return nil }
            return staged.window
        }
    }

    func stagedWindow(requestID: CBv2RequestID) -> [SSDWindowSidecar.Window?]? {
        stagedWindow(requestID: ticketKey(requestID))
    }

    /// Bridge backstop: release a request's staging ticket on every
    /// terminal path the engine's `endAdoption` did not already balance
    /// (submit failure before lookup, teardown, defensive). Idempotent.
    func completeStaging(requestID: String) {
        let releaseKey = detachStagingTicket(requestID)
        if let releaseKey, let kvBudget {
            Task { await kvBudget.release(requestID: releaseKey) }
        }
    }


    func completeStaging(requestID: CBv2RequestID) {
        completeStaging(requestID: ticketKey(requestID))
    }

    /// Pre-submit abandonment used by the shared-budget fallback. The release
    /// is awaited before admission is retried, so optional staging can never
    /// consume the headroom needed by a request that fits cold.
    func abandonStaging(requestID: CBv2RequestID) async {
        guard let releaseKey = detachStagingTicket(ticketKey(requestID)) else { return }
        await releaseReservation(releaseKey)
    }

    private func detachStagingTicket(_ requestID: String) -> String? {
        lock.withLock {
            guard let tag = tickets.removeValue(forKey: requestID),
                let staged = stagedEntries[tag]
            else { return nil }
            staged.openTickets.remove(requestID)
            staged.pinnedTickets.remove(requestID)
            // Only the entry's own (per-entry) reservation is released, and
            // only when this was the last user. A concurrent peer keeps the
            // shared entry resident and reservation-accounted.
            return removeStagedEntryIfDoneLocked(tag)
        }
    }

    // MARK: - TTL sweep + eviction (SSDEvictableStore)

    var evictionRoot: URL { config.root }

    var diskBytesOnDisk: Int { index.totalBytes }

    func oldestEntryAccess() -> Int64? { index.oldest()?.lastAccess }

    /// Unlink the LRU entry (box-wide budget enforcement).
    func evictOldestEntry() -> Int {
        guard hasSafeRoot else { return 0 }
        // Bounded by the index snapshot. Invalid/missing entries are dropped
        // without touching their pathname; a valid-but-undeletable entry is
        // skipped so a newer victim can still satisfy the box-wide budget.
        let victims = index.oldestEntries()
        guard !victims.isEmpty else { return 0 }
        return performDestructiveChange {
            for victim in victims {
                let url = SSDBlockStore.fileURL(
                    root: config.root, tag16Hex: SSDLookupKeys.hex(victim.tag16))
                switch SSDBlockStore.indexedBlockFileStatus(at: url, under: config.root) {
                case .missing, .invalid:
                    index.remove(tag16: victim.tag16)
                case .regular:
                    if SSDBlockStore.removeItemIfSafe(at: url, under: config.root) {
                        let bytes = index.remove(tag16: victim.tag16)
                        statsBox.add(evictions: 1)
                        return bytes
                    }
                    // The entry may have changed between classification and unlink.
                    // Drop only when a second no-follow check proves it is no longer
                    // an owned regular file.
                    if SSDBlockStore.indexedBlockFileStatus(
                        at: url, under: config.root) != .regular
                    {
                        index.remove(tag16: victim.tag16)
                    }
                }
            }
            return 0
        } ?? 0
    }

    func reconcileExternalRemovals() {
        guard hasSafeRoot else { return }
        let removed = externallyRemovedTags()
        guard !removed.isEmpty else { return }
        _ = performDestructiveChange {
            for tag16 in removed {
                index.remove(tag16: tag16)
            }
        }
    }

    func performExternalDestructiveChange(_ body: () -> Void) -> Bool {
        let completed: Void? = performDestructiveChange {
            body()
            for tag16 in externallyRemovedTags() {
                index.remove(tag16: tag16)
            }
        }
        return completed != nil
    }

    private func externallyRemovedTags() -> [Data] {
        index.allTags().filter { tag16 in
            let url = SSDBlockStore.fileURL(
                root: config.root, tag16Hex: SSDLookupKeys.hex(tag16))
            return SSDBlockStore.indexedBlockFileStatus(
                at: url, under: config.root) != .regular
        }
    }

    /// Opportunistic TTL sweep (on write via the write-behind consumer +
    /// the periodic low-frequency task): unlink entries whose last hit is
    /// older than the sliding TTL.
    func sweepExpiredEntries() {
        guard hasSafeRoot else { return }
        let expired = index.expired(now: config.nowSeconds(), ttlSeconds: config.ttlSeconds)
        guard !expired.isEmpty else { return }
        _ = performDestructiveChange {
            var removed = 0
            for tag16 in expired {
                let url = SSDBlockStore.fileURL(
                    root: config.root, tag16Hex: SSDLookupKeys.hex(tag16))
                let status = SSDBlockStore.indexedBlockFileStatus(
                    at: url, under: config.root)
                if status == .regular,
                    SSDBlockStore.removeItemIfSafe(at: url, under: config.root)
                {
                    index.remove(tag16: tag16)
                    removed += 1
                } else if status != .regular {
                    // Missing/replaced paths are no longer owned cache bytes. Drop
                    // the stale RAM entry, but do not report a durable TTL removal.
                    index.remove(tag16: tag16)
                }
            }
            if removed > 0 {
                statsBox.add(ttlExpired: removed)
            }
        }
    }

    // MARK: - Startup scan (the recovery protocol — no index sidecar)

    /// Rebuild the RAM index from the on-disk tree: temp-sweep, then a
    /// header-only pass over every `.dbk3` file. Stale bindings
    /// (weightHash / layoutEpoch / blockSize) and TTL-expired files are
    /// deleted; everything else is indexed with mtime as lastAccess.
    func scanOnDisk() {
        lock.withLock {
            if !closed {
                scanReady = false
                scanFailed = false
            }
        }
        guard hasSafeRoot else {
            index.removeAll()
            markScanFailed()
            return
        }
        SSDBlockStore.sweepStaleTempFiles(under: config.root)
        let fm = FileManager.default
        let now = config.nowSeconds()
        guard let fanouts = try? fm.contentsOfDirectory(
            at: config.root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else {
            markScanFailed()
            return
        }
        var indexed = 0
        var dropped = 0
        var expired = 0
        // A recognized fanout symlink invalidates the whole scan. Skipping it
        // would leave active cache I/O able to follow the same path later.
        for dir in fanouts where SSDBlockStore.isLowerHex(dir.lastPathComponent, count: 2) {
            guard let dirValues = try? dir.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                dirValues.isDirectory == true, dirValues.isSymbolicLink != true,
                dir.standardizedFileURL.path
                    == dir.resolvingSymlinksInPath().standardizedFileURL.path
            else {
                index.removeAll()
                markScanFailed()
                return
            }
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [
                    .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles])
            else {
                index.removeAll()
                markScanFailed()
                return
            }
            for url in files where url.pathExtension == SSDBlockStore.fileExtension {
                if isClosed { return }
                guard let fileValues = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                    fileValues.isRegularFile == true, fileValues.isSymbolicLink != true,
                    SSDBlockStore.isSafeBlockURL(url, modelRoot: config.root)
                else {
                    index.removeAll()
                    markScanFailed()
                    return
                }
                let name = url.deletingPathExtension().lastPathComponent
                guard let tag16 = Self.hexDecode(name),
                    tag16.count == SSDLookupKeys.truncatedTagLength,
                    let metadata = try? SSDBlockStore.readMetadataOnly(from: url),
                    metadata.weightHash == config.weightHash,
                    metadata.layoutEpoch == config.layoutEpoch,
                    metadata.blockSize == config.blockSize,
                    metadata.lookupTag.hasPrefix(name)
                else {
                    _ = SSDBlockStore.removeItemIfSafe(at: url, under: config.root)
                    dropped += 1
                    continue
                }
                let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey])
                let mtime = Int64(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
                if config.ttlSeconds > 0, now - mtime >= config.ttlSeconds {
                    if SSDBlockStore.removeItemIfSafe(at: url, under: config.root) {
                        expired += 1
                    }
                    continue
                }
                index.insert(
                    tag16: tag16, fileBytes: values?.fileSize ?? 0, lastAccess: mtime)
                indexed += 1
            }
        }
        if expired > 0 { statsBox.add(ttlExpired: expired) }
        lock.withLock {
            if !closed {
                scanReady = true
                scanFailed = false
            }
        }
        #if canImport(os)
        Self.logger.info(
            "ssd prefix cache (\(self.config.modelId, privacy: .public)): startup scan indexed \(indexed) blocks (\(self.index.totalBytes) B), dropped \(dropped) stale, \(expired) expired")
        #endif
    }

    // MARK: - Stats

    public func stats() -> SSDPrefixCacheStats {
        var snapshot = statsBox.snapshot()
        snapshot.entries = index.count
        snapshot.bytesOnDisk = index.totalBytes
        return snapshot
    }

    // MARK: - Helpers

    private func hasher(cacheSalt: String) -> CBv2BlockHasher {
        CBv2BlockHasher(
            blockSize: config.blockSize,
            promptContractID: config.promptContractID,
            scopeID: cacheSalt)
    }

    private var hasSafeRoot: Bool {
        SSDBlockStore.isSafeModelRoot(config.root, dedicatedRoot: config.dedicatedRoot)
    }

    private func markScanFailed() {
        lock.withLock {
            guard !closed else { return }
            scanReady = false
            scanFailed = true
        }
    }

    /// Persist a fresh generation before deleting or forgetting durable
    /// blocks, and suppress capability publication until the mutation ends.
    private func performDestructiveChange<T>(_ body: () -> T) -> T? {
        guard beginDestructiveChange() else { return nil }
        defer { endDestructiveChange() }
        guard let epochStore = config.epochStore else { return body() }
        guard let result = epochStore.performOwnedDestructiveChange(body) else {
            lock.withLock {
                scanReady = false
                cacheStatusFailure = .cacheInitFailed
            }
            return nil
        }
        return result
    }

    private func beginDestructiveChange() -> Bool {
        lock.withLock {
            guard !closed, !destructiveChangeInProgress else { return false }
            destructiveChangeInProgress = true
            return true
        }
    }

    private func endDestructiveChange() {
        lock.withLock {
            precondition(destructiveChangeInProgress)
            destructiveChangeInProgress = false
        }
    }

    private func cacheEpochMatches(_ expected: String?) -> Bool {
        guard let epochStore = config.epochStore else { return expected == nil }
        guard let expected else { return false }
        return epochStore.current == expected
    }

    #if DEBUG
    func holdDestructiveEpochForTesting(_ body: () -> Void) -> Bool {
        performDestructiveChange(body) != nil
    }
    #endif

    private func reservationKey(forRequestID id: String) -> String {
        "ssd-stage:\(cacheInstanceNamespace):\(id)"
    }

    private func ticketKey(_ requestID: CBv2RequestID) -> String {
        "\(cacheInstanceNamespace):\(requestID.raw)"
    }

    private func releaseReservation(_ key: String) async {
        guard let kvBudget else { return }
        await kvBudget.release(requestID: key)
    }

    /// Called on the serial write-behind consumer only after every new block
    /// landed and whole-box maintenance completed. Re-open/decrypt the surviving
    /// leading run before advertising it; a corrupt/binding failure suppresses
    /// the entire receipt, while budget eviction may legitimately shorten the
    /// ready prefix.
    private func settleDurableDonation(
        requestID: CBv2RequestID,
        tags16: [Data],
        fullTags: [Data],
        chainHashes: [Data],
        cacheSalt: String
    ) -> Bool {
        guard tags16.count == fullTags.count,
            tags16.count == chainHashes.count,
            !tags16.isEmpty,
            !isClosed
        else { return false }
        var readableBlocks = 0
        for i in tags16.indices {
            guard index.contains(tag16: tags16[i]) else { break }
            let url = SSDBlockStore.fileURL(
                root: config.root,
                tag16Hex: SSDLookupKeys.hex(tags16[i]))
            do {
                let (metadata, _) = try SSDBlockStore.read(from: url, kekKey: kekKey)
                guard metadata.weightHash == config.weightHash,
                    metadata.layoutEpoch == config.layoutEpoch,
                    metadata.blockSize == config.blockSize,
                    metadata.lookupTag == SSDLookupKeys.hex(fullTags[i])
                else { return false }
                readableBlocks += 1
            } catch {
                // A durable-ready receipt must never attest through corruption,
                // a torn write, stale binding, or unreadable ciphertext.
                return false
            }
        }
        let readyTokens = readableBlocks * config.blockSize
        // The receipt has to describe the replay the ADOPTER will face. That
        // is the restored bound only when this boundary's window is fully
        // tiled by present sidecars; otherwise the adopter replays in full and
        // a zero-recompute receipt would send the coordinator a prefix that
        // does not exist.
        let recompute = min(
            windowTilingComplete(
                chainHashes: chainHashes, cacheSalt: cacheSalt, blocks: readableBlocks)
                ? config.windowRestoredBoundTokens
                : config.adoptionBoundTokens,
            readyTokens)
        let expectedSaved = max(0, readyTokens - recompute)
        guard expectedSaved >= config.minEffectiveTokens else { return false }
        guard let durableSizes = index.fileBytes(tags16: tags16.prefix(readableBlocks))
        else { return false }
        let durableBytes = durableSizes.reduce(0) { total, next in
            let (sum, overflow) = total.addingReportingOverflow(max(0, next))
            return overflow ? Int.max : sum
        }
        let stageMs = SSDPrefixCachePolicy.estimatedStageMillisDouble(bytes: durableBytes)

        let delivery: ((@Sendable (PrefixCacheReadyResult) -> Void), PrefixCacheReadyResult)? =
            lock.withLock {
                guard !closed, let state = readyReceipts[requestID],
                    readyTokens > state.highestReadyTokens
                else { return nil }
                state.highestReadyTokens = readyTokens
                return (
                    state.callback,
                    PrefixCacheReadyResult(
                        readyTokens: readyTokens,
                        requiredRecomputeTokens: recompute,
                        expectedPrefillTokensSaved: expectedSaved,
                        tier: .ssd,
                        stageMs: stageMs,
                        finalAnchor: PrefixCacheAnchor(
                            chainHash: chainHashes[readableBlocks - 1].map {
                                String(format: "%02x", $0)
                            }.joined(),
                            tokenCount: UInt64(readyTokens))))
            }
        if let delivery {
            delivery.0(delivery.1)
        }
        return true
    }

    /// Must be called with `lock` held. Returns the retired entry's
    /// per-entry reservation key (which the caller releases AFTER unlocking,
    /// since the budget is an actor) when the entry was actually removed —
    /// nil when the entry is still in use and stays resident+reserved.
    @discardableResult
    private func removeStagedEntryIfDoneLocked(_ tag16: Data) -> String? {
        guard let staged = stagedEntries[tag16],
            staged.openTickets.isEmpty, staged.pinnedTickets.isEmpty
        else { return nil }
        stagedEntries.removeValue(forKey: tag16)
        statsBox.add(stagedBytesDelta: -staged.deviceBytes)
        return staged.reservationKey
    }

    /// Same cacheability rule as `PrefixCacheV2`: full-attention AND
    /// storage-owning.
    static func isCacheable(_ kind: CBv2LayerKind) -> Bool {
        guard kind.sharesKVWithLayer == nil else { return false }
        if case .slidingWindow = kind.attention { return false }
        return true
    }

    /// Rebuild the per-layer adopted prefix from per-block chunk payloads.
    /// nil on any inconsistency (shape/dtype/order drift across blocks) —
    /// the caller treats it as corruption and recomputes.
    static func rebuildPrefix(
        blocks: [(metadata: SSDBlockMetadata, chunks: [Data])],
        blockSize: Int,
        matched: Int
    ) -> [(keys: MLXArray, values: MLXArray, offset: Int)?]? {
        guard let first = blocks.first else { return nil }
        let descriptors = first.metadata.chunks
        let layerCount = first.metadata.layerCount
        guard layerCount > 0, layerCount <= 4096,
            descriptors.count % 2 == 0, !descriptors.isEmpty
        else { return nil }
        // Every block must carry the identical chunk layout.
        for block in blocks {
            guard block.metadata.chunks == descriptors,
                block.metadata.layerCount == layerCount,
                block.chunks.count == descriptors.count
            else { return nil }
        }
        // Validate descriptors + byte counts BEFORE MLXArray init (its
        // shape/byte mismatch is an uncatchable trap).
        for (d, desc) in descriptors.enumerated() {
            guard desc.shape.count == 4, desc.shape[2] == blockSize,
                desc.layerIndex >= 0, desc.layerIndex < layerCount,
                desc.tensor == d % 2,
                let dtype = dtypeByName[desc.dtype]
            else { return nil }
            var expected = dtype.size
            for dim in desc.shape {
                guard dim > 0 else { return nil }
                let (product, overflow) = expected.multipliedReportingOverflow(by: dim)
                guard !overflow else { return nil }
                expected = product
            }
            for block in blocks {
                guard block.chunks[d].count == expected else { return nil }
            }
        }
        var prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?] =
            Array(repeating: nil, count: layerCount)
        var toEval: [MLXArray] = []
        var d = 0
        while d < descriptors.count {
            let keyDesc = descriptors[d]
            let valueDesc = descriptors[d + 1]
            guard keyDesc.layerIndex == valueDesc.layerIndex,
                keyDesc.tensor == 0, valueDesc.tensor == 1,
                prefix[keyDesc.layerIndex] == nil,
                let keyDType = dtypeByName[keyDesc.dtype],
                let valueDType = dtypeByName[valueDesc.dtype]
            else { return nil }
            var keyParts: [MLXArray] = []
            var valueParts: [MLXArray] = []
            for block in blocks {
                keyParts.append(MLXArray(block.chunks[d], keyDesc.shape, dtype: keyDType))
                valueParts.append(MLXArray(block.chunks[d + 1], valueDesc.shape, dtype: valueDType))
            }
            let keys = keyParts.count == 1 ? keyParts[0] : concatenated(keyParts, axis: 2)
            let values = valueParts.count == 1 ? valueParts[0] : concatenated(valueParts, axis: 2)
            guard keys.dim(2) == matched else { return nil }
            prefix[keyDesc.layerIndex] = (keys: keys, values: values, offset: matched)
            toEval.append(keys)
            toEval.append(values)
            d += 2
        }
        eval(toEval)
        return prefix
    }

    static func hexDecode(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var iterator = hex.makeIterator()
        while let high = iterator.next() {
            guard let low = iterator.next(),
                let h = high.hexDigitValue, let l = low.hexDigitValue
            else { return nil }
            data.append(UInt8(h << 4 | l))
        }
        return data
    }

    private static func volumeSpace(at url: URL) -> (free: Int, capacity: Int)? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
        ]
        // The block dir may not exist yet on first write — probe the
        // nearest existing ancestor.
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        guard let v = try? probe.resourceValues(forKeys: keys) else { return nil }
        let free: Int
        if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 {
            free = Int(important)
        } else if let plain = v.volumeAvailableCapacity, plain > 0 {
            free = plain
        } else {
            return nil
        }
        return (free, v.volumeTotalCapacity ?? 0)
    }
}
