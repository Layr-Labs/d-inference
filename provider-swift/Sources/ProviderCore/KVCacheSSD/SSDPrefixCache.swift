// Copyright © 2026 Eigen Labs.
//
// SSDPrefixCache — the encrypted SSD KV-offload prefix cache (v0.7.5).
// Conforms to the engine's frozen `CBv2PrefixCache` protocol and is handed
// to `EngineV2` in place of the (opt-in) RAM `PrefixCacheV2`:
//
//   * DONATION (engine donation queue → write-behind): `donate` chain-hashes
//     the finished request's tokens, dedupes against the index + in-flight
//     set, extracts ONLY the new blocks' KV to compact host buffers
//     (device slice → eval → asData(.copy), ~1–30 ms), returns — and a
//     bounded serial pipeline (`SSDWriteBehind`) encrypts and writes DBK2
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
        evictions: Int = 0, ttlExpired: Int = 0
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
        }
    }

    func snapshot() -> SSDPrefixCacheStats {
        lock.withLock { stats }
    }
}

// MARK: - SSDPrefixCache

public final class SSDPrefixCache: CBv2PrefixCache, SSDEvictableStore, @unchecked Sendable {

    struct Config: Sendable {
        let modelId: String
        /// Weight root hash (MB-1 binding); falls back to the model id
        /// when no hash is known — same degradation as the legacy tier.
        let weightHash: String
        let blockSize: Int
        /// `windowCount × maxWindow` — the engine's recompute bound; the
        /// staging benefit gate subtracts it from `matched`.
        let adoptionBoundTokens: Int
        let layoutEpoch: String
        /// `…/darkbloom/kv2/<modelKey>` — files live here, per-model, in
        /// the SSD tier's OWN root (never under the legacy `kv/` root the
        /// upgrade sweeper sheds).
        let root: URL
        let ttlSeconds: Int64
        let minEffectiveTokens: Int
        let maxStageBytes: Int
        let maxStageMillis: Int
        let nowSeconds: @Sendable () -> Int64
    }

    let config: Config
    private let kekKey: SymmetricKey
    private let lookupKeys: SSDLookupKeys
    let index: SSDBlockIndex
    private let kvBudget: GlobalKVCacheBudget?
    private let diskBudget: SSDDiskBudget
    let statsBox = SSDPrefixCacheStatsBox()
    private var writeBehind: SSDWriteBehind!

    /// One staged (rehydrated-from-disk) prefix awaiting adoption.
    private final class StagedEntry {
        let matched: Int
        let prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?]
        let deviceBytes: Int
        /// Requests that staged (or attached to) this entry and have not
        /// yet been released (endAdoption pops one per balanced hit; the
        /// bridge backstop closes stragglers).
        var openTickets: Set<String>
        /// Lookup hits not yet balanced by endAdoption — the entry's
        /// arrays stay parked while an adoption is in flight.
        var pinsInUse = 0

        init(
            matched: Int, prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?],
            deviceBytes: Int, firstTicket: String
        ) {
            self.matched = matched
            self.prefix = prefix
            self.deviceBytes = deviceBytes
            self.openTickets = [firstTicket]
        }
    }

    private let lock = NSLock()
    private var closed = false
    /// tag16 of the run's TERMINAL block → staged entry.
    private var stagedEntries: [Data: StagedEntry] = [:]
    /// requestID → terminal tag16 (the bridge-backstop handle).
    private var tickets: [String: Data] = [:]
    /// Blocks queued/being written — dedupe for concurrent donations.
    private var inFlightWrites: Set<Data> = []
    private var sweepTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

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
        diskBudgetBytes: @escaping @Sendable () -> Int
    ) {
        self.config = config
        self.kekKey = kekKey
        self.lookupKeys = SSDLookupKeys(kek: kekKey)
        self.index = SSDBlockIndex()
        self.kvBudget = kvBudget
        self.diskBudget = diskBudget
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
                nowSeconds: config.nowSeconds),
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

    /// Shutdown for model unload / bridge teardown: stop background work,
    /// drain staging pins (releasing their budget reservations), keep the
    /// files — durable warmth across unloads and restarts is the feature.
    public func close() {
        var releaseKeys: [String] = []
        lock.withLock {
            guard !closed else { return }
            closed = true
            releaseKeys = tickets.keys.map { Self.reservationKey(forRequestID: $0) }
            let stagedBytes = stagedEntries.values.reduce(0) { $0 + $1.deviceBytes }
            statsBox.add(stagedBytesDelta: -stagedBytes)
            tickets.removeAll()
            stagedEntries.removeAll()
            inFlightWrites.removeAll()
        }
        sweepTask?.cancel()
        scanTask?.cancel()
        writeBehind.close()
        diskBudget.deregister(self)
        if let kvBudget, !releaseKeys.isEmpty {
            Task { for key in releaseKeys { await kvBudget.release(requestID: key) } }
        }
    }

    // MARK: - CBv2PrefixCache: lookup (RAM-only staging probe)

    public func lookup(
        tokens: [Int], layerKinds: [CBv2LayerKind]
    ) -> (matched: Int, prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?])? {
        lookup(tokens: tokens, layerKinds: layerKinds, cacheSalt: nil)
    }

    public func lookup(
        tokens: [Int], layerKinds: [CBv2LayerKind], cacheSalt: String?
    ) -> (matched: Int, prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?])? {
        // SYNCHRONOUS + RAM-ONLY by contract: the engine calls this on the
        // submit thread — never any disk I/O here. All I/O happened in the
        // pre-submit `stage`.
        let maxStagedBlocks = lock.withLock { () -> Int in
            guard !closed, !stagedEntries.isEmpty else { return 0 }
            return stagedEntries.values.map { $0.matched / config.blockSize }.max() ?? 0
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
                guard let staged = stagedEntries[tag16],
                    staged.matched == k * config.blockSize,
                    staged.prefix.count == layerKinds.count
                else { return nil }
                // Defensive: the staged layer layout must agree with the
                // caller's cacheable positions (report 10 invariant 6).
                for (i, kind) in layerKinds.enumerated() {
                    let cacheable = Self.isCacheable(kind)
                    guard (staged.prefix[i] != nil) == cacheable else { return nil }
                }
                staged.pinsInUse += 1
                return (staged.matched, staged.prefix)
            }
            if let (matched, prefix) = hit {
                statsBox.add(hits: 1, tokensSaved: matched)
                return (matched, prefix)
            }
        }
        statsBox.add(misses: 1)
        return nil
    }

    // MARK: - CBv2PrefixCache: endAdoption (the staging release hook)

    public func endAdoption(tokens: [Int], matched: Int) {
        endAdoption(tokens: tokens, matched: matched, cacheSalt: nil)
    }

    public func endAdoption(tokens: [Int], matched: Int, cacheSalt: String?) {
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
            staged.pinsInUse = max(0, staged.pinsInUse - 1)
            // Balance ONE staging ticket per balanced hit (tickets are
            // symmetric: each reserved the same staged byte count).
            if let ticket = staged.openTickets.popFirst() {
                tickets.removeValue(forKey: ticket)
                releaseKey = Self.reservationKey(forRequestID: ticket)
            }
            removeStagedEntryIfDoneLocked(tag16)
        }
        if let releaseKey, let kvBudget {
            Task { await kvBudget.release(requestID: releaseKey) }
        }
    }

    // MARK: - CBv2PrefixCache: donate (write-behind)

    public func donate(tokens: [Int], state: [CBv2SequenceKV?], layerKinds: [CBv2LayerKind]) {
        donate(tokens: tokens, state: state, layerKinds: layerKinds, cacheSalt: nil)
    }

    public func donate(
        tokens: [Int], state: [CBv2SequenceKV?], layerKinds: [CBv2LayerKind], cacheSalt: String?
    ) {
        guard state.count == layerKinds.count else { return }
        var snapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?] = []
        snapshots.reserveCapacity(layerKinds.count)
        for (i, kind) in layerKinds.enumerated() {
            guard Self.isCacheable(kind), let seq = state[i] else {
                snapshots.append(nil)
                continue
            }
            guard seq.snapshotIsLossless else { return }  // quantized KV never donates
            snapshots.append(seq.snapshot())
        }
        donate(tokens: tokens, snapshots: snapshots, layerKinds: layerKinds, cacheSalt: cacheSalt)
    }

    public func donate(
        tokens: [Int],
        snapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?],
        layerKinds: [CBv2LayerKind]
    ) {
        donate(tokens: tokens, snapshots: snapshots, layerKinds: layerKinds, cacheSalt: nil)
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
        guard !isClosed, snapshots.count == layerKinds.count else { return }
        let salt = cacheSalt ?? ""
        let hasher = hasher(cacheSalt: salt)
        let blockCount = hasher.fullBlockCount(tokenCount: tokens.count)
        guard blockCount > 0 else { return }
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
        guard !floorOverflow, prefixTokens > donationFloor else { return }

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
            else { return }
            cacheable.append((i, snap.keys, snap.values))
        }
        guard !cacheable.isEmpty else { return }

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
        guard perBlockBytes > 0 else { return }
        let maxPersistBlocks = config.maxStageBytes / perBlockBytes

        let now = config.nowSeconds()
        var newBlockIndices: [Int] = []
        lock.withLock {
            guard !closed else { return }
            for (i, tag16) in tags16.enumerated() where i < maxPersistBlocks {
                if index.contains(tag16: tag16) || inFlightWrites.contains(tag16) { continue }
                inFlightWrites.insert(tag16)
                newBlockIndices.append(i)
            }
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
            try? FileManager.default.setAttributes(
                [.modificationDate: touchDate], ofItemAtPath: url.path)
        }
        guard !newBlockIndices.isEmpty else { return }

        // Endurance pre-check BEFORE any extraction: when the daily write
        // budget can't even cover ONE block, the consumer would drop every
        // one of these blocks at `tryConsume` — after this loop has already
        // paid the device-slice/eval/host-copy for each. Skip the whole
        // donation up front instead. Gated on a single block (not the full
        // donation) so a nearly-drained bucket still persists the leading
        // prefix-contiguous blocks it can afford — the consumer's per-block
        // `tryConsume` stays the authority. Settle the in-flight tags so a
        // later donation can retry these blocks once the bucket refills.
        guard writeBehind.mightAcceptWrite(bytes: perBlockBytes) else {
            lock.withLock {
                for i in newBlockIndices { inFlightWrites.remove(tags16[i]) }
            }
            statsBox.add(donationsDropped: newBlockIndices.count)
            return
        }

        // Per-block extraction: device slice → eval → compact host Data in
        // engine-native [B, kvHeads, block, headDim] layout. Device arrays
        // are dropped as soon as the bytes are copied out.
        var blocks: [SSDBlockWrite] = []
        var totalBytes = 0
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

        guard writeBehind.submit(SSDDonationJob(blocks: blocks, totalBytes: totalBytes)) else {
            // Queue overflow / byte cap / closed: drop the donation, settle
            // the in-flight tags so a later donation can retry these blocks.
            lock.withLock {
                for block in blocks { inFlightWrites.remove(block.tag16) }
            }
            statsBox.add(donationsDropped: blocks.count)
            return
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
    /// Returns true iff a run was staged (or attached to). Every `true`
    /// MUST eventually be balanced by the engine's `endAdoption` (normal
    /// path) or `completeStaging(requestID:)` (bridge backstop) — both are
    /// idempotent per request.
    func stage(requestID: String, promptTokens: [Int], cacheScope: String) async -> Bool {
        guard !isClosed, index.count > 0 else { return false }
        let salt = cacheScope
        let hasher = hasher(cacheSalt: salt)
        let maxBlocks = hasher.maxLookupBlocks(tokenCount: promptTokens.count)
        guard maxBlocks > 0 else { return false }
        // Cheap pre-floor: a run can only clear the benefit gate when even
        // a FULL match would (matched − bound ≥ minEffective). Overflow-safe
        // like the donate-path floor (line ~418): an operator-set
        // `DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS` near Int.max
        // must DISABLE staging (saturated floor never passes), not trap the
        // provider on every request.
        let (preFloor, preFloorOverflow) =
            config.adoptionBoundTokens.addingReportingOverflow(config.minEffectiveTokens)
        guard !preFloorOverflow, maxBlocks * config.blockSize >= preFloor
        else { return false }

        let hashes = hasher.chainHashes(tokens: promptTokens, maxBlocks: maxBlocks)
        var fullTags: [Data] = []
        var tags16: [Data] = []
        for hash in hashes {
            let full = lookupKeys.tag(chainHash: hash, cacheSalt: salt)
            fullTags.append(full)
            tags16.append(full.prefix(SSDLookupKeys.truncatedTagLength))
        }

        // Longest contiguous run, trimmed to the stage caps (bytes/time)
        // while it still clears the benefit floor.
        var k = index.longestRun(tags16: tags16)
        var runBytes = 0
        var runSizes: [Int] = []
        while k > 0 {
            let matched = k * config.blockSize
            let effective = matched - min(config.adoptionBoundTokens, matched)
            guard effective >= config.minEffectiveTokens else { return false }
            guard let sizes = index.fileBytes(tags16: tags16[0 ..< k]) else {
                // Raced an eviction — re-probe.
                k = min(k - 1, index.longestRun(tags16: tags16))
                continue
            }
            runSizes = sizes
            runBytes = sizes.reduce(0, +)
            if runBytes <= config.maxStageBytes,
                SSDPrefixCachePolicy.estimatedStageMillis(bytes: runBytes) <= config.maxStageMillis
            {
                break
            }
            k -= 1
        }
        guard k > 0 else { return false }

        // Concurrent same-prefix request: attach to the existing staged
        // entry (one entry, per-request reservation + ticket).
        let terminalTag = tags16[k - 1]
        let reservationKey = Self.reservationKey(forRequestID: requestID)
        if let kvBudget {
            guard await kvBudget.reserveBytes(requestID: reservationKey, bytes: UInt64(runBytes))
            else { return false }  // memory pressure ⇒ silent recompute
        }
        let attached = lock.withLock { () -> Bool in
            guard !closed else { return false }
            guard let existing = stagedEntries[terminalTag], existing.matched == k * config.blockSize
            else { return false }
            existing.openTickets.insert(requestID)
            tickets[requestID] = terminalTag
            return true
        }
        if attached { return true }

        // Read + decrypt + verify blocks 1..k off the engine threads.
        var blockPayloads: [(metadata: SSDBlockMetadata, chunks: [Data])] = []
        var usableBlocks = k
        for i in 0 ..< k {
            if Task.isCancelled {
                await releaseReservation(reservationKey)
                return false
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
                try? FileManager.default.removeItem(at: url)
                index.remove(tag16: tags16[i])
                #if canImport(os)
                Self.logger.warning(
                    "ssd prefix cache (\(self.config.modelId, privacy: .public)): dropped unreadable block (\(String(describing: error), privacy: .public)) — recompute fallback")
                #endif
                usableBlocks = i
                break
            }
        }
        // Re-apply the benefit gate to the (possibly shortened) run.
        let matched = usableBlocks * config.blockSize
        let effective = matched - min(config.adoptionBoundTokens, matched)
        guard usableBlocks > 0, effective >= config.minEffectiveTokens else {
            await releaseReservation(reservationKey)
            return false
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
        if usableBlocks < k {
            stagedRunBytes = runSizes.prefix(usableBlocks).reduce(0, +)
            if let kvBudget, stagedRunBytes != runBytes {
                await kvBudget.release(requestID: reservationKey)
                guard stagedRunBytes > 0,
                    await kvBudget.reserveBytes(
                        requestID: reservationKey, bytes: UInt64(stagedRunBytes))
                else { return false }
            }
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
            return false
        }
        if Task.isCancelled {
            await releaseReservation(reservationKey)
            return false
        }

        let inserted = lock.withLock { () -> Bool in
            guard !closed else { return false }
            if let existing = stagedEntries[terminalTag], existing.matched == matched {
                existing.openTickets.insert(requestID)
                tickets[requestID] = terminalTag
                return true
            }
            let usedTag = tags16[usableBlocks - 1]
            if let existing = stagedEntries[usedTag], existing.matched == matched {
                existing.openTickets.insert(requestID)
                tickets[requestID] = usedTag
                return true
            }
            stagedEntries[usedTag] = StagedEntry(
                matched: matched, prefix: prefix, deviceBytes: stagedRunBytes,
                firstTicket: requestID)
            tickets[requestID] = usedTag
            statsBox.add(stages: 1, stagedBytesDelta: stagedRunBytes)
            return true
        }
        guard inserted else {
            await releaseReservation(reservationKey)
            return false
        }
        // Sliding TTL: bump index recency AND file mtimes so warmth
        // survives a restart (the scan seeds lastAccess from mtime).
        let now = config.nowSeconds()
        index.touch(tags16: tags16.prefix(usableBlocks), now: now)
        let touchDate = Date(timeIntervalSince1970: TimeInterval(now))
        for i in 0 ..< usableBlocks {
            let url = SSDBlockStore.fileURL(
                root: config.root, tag16Hex: SSDLookupKeys.hex(tags16[i]))
            try? FileManager.default.setAttributes(
                [.modificationDate: touchDate], ofItemAtPath: url.path)
        }
        return true
    }

    /// Bridge backstop: release a request's staging ticket on every
    /// terminal path the engine's `endAdoption` did not already balance
    /// (submit failure before lookup, teardown, defensive). Idempotent.
    func completeStaging(requestID: String) {
        var releaseKey: String?
        lock.withLock {
            guard let tag = tickets.removeValue(forKey: requestID) else { return }
            releaseKey = Self.reservationKey(forRequestID: requestID)
            guard let staged = stagedEntries[tag] else { return }
            staged.openTickets.remove(requestID)
            removeStagedEntryIfDoneLocked(tag)
        }
        if let releaseKey, let kvBudget {
            Task { await kvBudget.release(requestID: releaseKey) }
        }
    }

    // MARK: - TTL sweep + eviction (SSDEvictableStore)

    var diskBytesOnDisk: Int { index.totalBytes }

    func oldestEntryAccess() -> Int64? { index.oldest()?.lastAccess }

    /// Unlink the LRU entry (box-wide budget enforcement).
    func evictOldestEntry() -> Int {
        guard let victim = index.oldest() else { return 0 }
        let url = SSDBlockStore.fileURL(
            root: config.root, tag16Hex: SSDLookupKeys.hex(victim.tag16))
        try? FileManager.default.removeItem(at: url)
        let bytes = index.remove(tag16: victim.tag16)
        statsBox.add(evictions: 1)
        return bytes
    }

    /// Opportunistic TTL sweep (on write via the write-behind consumer +
    /// the periodic low-frequency task): unlink entries whose last hit is
    /// older than the sliding TTL.
    func sweepExpiredEntries() {
        let expired = index.expired(now: config.nowSeconds(), ttlSeconds: config.ttlSeconds)
        guard !expired.isEmpty else { return }
        for tag16 in expired {
            let url = SSDBlockStore.fileURL(
                root: config.root, tag16Hex: SSDLookupKeys.hex(tag16))
            try? FileManager.default.removeItem(at: url)
            index.remove(tag16: tag16)
        }
        statsBox.add(ttlExpired: expired.count)
    }

    // MARK: - Startup scan (the recovery protocol — no index sidecar)

    /// Rebuild the RAM index from the on-disk tree: temp-sweep, then a
    /// header-only pass over every `.dbk2` file. Stale bindings
    /// (weightHash / layoutEpoch / blockSize) and TTL-expired files are
    /// deleted; everything else is indexed with mtime as lastAccess.
    func scanOnDisk() {
        SSDBlockStore.sweepStaleTempFiles(under: config.root)
        let fm = FileManager.default
        let now = config.nowSeconds()
        guard let fanouts = try? fm.contentsOfDirectory(
            at: config.root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return }
        var indexed = 0
        var dropped = 0
        var expired = 0
        for dir in fanouts where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for url in files where url.pathExtension == SSDBlockStore.fileExtension {
                if isClosed { return }
                let name = url.deletingPathExtension().lastPathComponent
                guard let tag16 = Self.hexDecode(name),
                    tag16.count == SSDLookupKeys.truncatedTagLength,
                    let metadata = try? SSDBlockStore.readMetadataOnly(from: url),
                    metadata.weightHash == config.weightHash,
                    metadata.layoutEpoch == config.layoutEpoch,
                    metadata.blockSize == config.blockSize,
                    metadata.lookupTag.hasPrefix(name)
                else {
                    try? fm.removeItem(at: url)
                    dropped += 1
                    continue
                }
                let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey])
                let mtime = Int64(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
                if config.ttlSeconds > 0, now - mtime >= config.ttlSeconds {
                    try? fm.removeItem(at: url)
                    expired += 1
                    continue
                }
                index.insert(
                    tag16: tag16, fileBytes: values?.fileSize ?? 0, lastAccess: mtime)
                indexed += 1
            }
        }
        if expired > 0 { statsBox.add(ttlExpired: expired) }
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
            blockSize: config.blockSize, modelName: config.modelId, cacheSalt: cacheSalt)
    }

    static func reservationKey(forRequestID id: String) -> String { "ssd-stage-\(id)" }

    private func releaseReservation(_ key: String) async {
        guard let kvBudget else { return }
        await kvBudget.release(requestID: key)
    }

    /// Must be called with `lock` held.
    private func removeStagedEntryIfDoneLocked(_ tag16: Data) {
        guard let staged = stagedEntries[tag16],
            staged.openTickets.isEmpty, staged.pinsInUse <= 0
        else { return }
        stagedEntries.removeValue(forKey: tag16)
        statsBox.add(stagedBytesDelta: -staged.deviceBytes)
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
