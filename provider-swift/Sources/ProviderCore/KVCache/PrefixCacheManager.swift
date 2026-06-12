/// PrefixCacheManager — orchestrates the three-tier prefix KV cache
/// (design §4). One manager per loaded model, owned by the BatchScheduler
/// (which builds it in `makeBatchedEngine`, drives `lookup`/`store` from the
/// submit + capture paths, and tears it down via `deregisterFromAccountant` on
/// unload). This file is the standalone, fully-testable orchestration layer;
/// the scheduler wiring lives in `BatchScheduler`.
///
/// Tiers, in lookup order:
///   1. RAM  — decrypted `[any KVCache]` (PrefixCacheRAM), keyed by
///             (modelHash, checkpoint digest).
///   2. SSD  — encrypted `.darkbloom-kv` files (EncryptedKVStore),
///             located via PrefixCacheIndex; promoted to RAM on hit.
///   3. miss — caller runs a cold prefill.
///
/// EXACT-CHECKPOINT (design §4.4): lookup matches only when the incoming
/// prompt's prefix is byte-identical to a cached checkpoint boundary
/// (PrefixDigest). The longest matching checkpoint wins.
///
/// MB-1 model-binding guard (design §8.1.1): the RAM tier is keyed by
/// modelHash (structural). The SSD tier additionally verifies
/// `metadata.modelHash == binding.modelHash` AND the architectural shape
/// (numLayers/kvHeads/headDim) BEFORE unwrapping/decrypting — because a
/// structurally-valid cache file from the wrong model decrypts cleanly
/// (the AAD is the file's own metadata). On mismatch the entry is
/// dropped and the caller falls through to cold prefill.
///
/// PCR-1 (Sendable across the actor boundary): `lookup` returns and
/// `store` accepts the non-Sendable `[any KVCache]` via `sending` — the
/// caches handed out are fresh copies/reconstructions (no aliasing of
/// actor-isolated state), and stored caches are sent in (caller gives up
/// the region), so region-based isolation makes this sound.
///
/// SSD capability: only models whose layer caches are
/// KVCacheSerializer-supported (KVCacheSimple/RotatingKVCache — Gemma-4,
/// GPT-OSS, pure-attention) get the SSD tier. Hybrid recurrent models
/// (Qwen3.5/Next) run RAM-tier only; `ssdEnabled = false` disables the
/// SSD read/flush paths for them.

import Foundation
import MLXLMCommon
import os

private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "prefix-cache-manager")

// MARK: - Model binding

public struct PrefixCacheModelBinding: Sendable {
    public let modelHash: String
    public let modelDtype: String
    public let modelArch: String
    public let vocabSize: Int
    public let numLayers: Int
    public let kvHeads: Int
    public let headDim: Int
    /// Per-layer reference KV shape `[kvHeads, headDim]` captured from the
    /// live `model.newCache()`. REQUIRED for heterogeneous models (e.g.
    /// Gemma-4 interleaves sliding `[8,256]` and full `[2,512]` layers); the
    /// scalar `kvHeads`/`headDim` above cannot describe them and would make
    /// the load-time shape guard reject the model's own files. nil ⇒ fall
    /// back to the scalar check (uniform models / older callers / tests).
    public let layerShapes: [[Int]]?

    public init(
        modelHash: String, modelDtype: String, modelArch: String, vocabSize: Int,
        numLayers: Int, kvHeads: Int, headDim: Int, layerShapes: [[Int]]? = nil
    ) {
        self.modelHash = modelHash
        self.modelDtype = modelDtype
        self.modelArch = modelArch
        self.vocabSize = vocabSize
        self.numLayers = numLayers
        self.kvHeads = kvHeads
        self.headDim = headDim
        self.layerShapes = layerShapes
    }
}

// MARK: - Result

/// `@unchecked Sendable` is justified, NOT a sidestep: the `caches`
/// handed out are always FRESH — RAM hits return `copy()` of the stored
/// caches, SSD hits are freshly deserialized — and the manager never
/// retains a reference to them after returning. A lookup result has a
/// single owner (the requesting inference task), so there is no shared
/// mutable state to race on. (`sending` would be the pure-Swift-6 way,
/// but values produced via the actor-isolated `PrefixCacheRAM` are
/// inferred into the actor's region and can't be `sending`-returned;
/// the whole KV subsystem traffics in non-Sendable MLXArrays, so this
/// matches the existing `UncheckedSendable*` idiom in the codebase.)
public struct PrefixLookupResult: @unchecked Sendable {
    /// One cache per layer, ready to seed a batch row. Caller owns these.
    public let caches: [any KVCache]
    /// Prompt tokens covered by the snapshot — caller skips prefill on
    /// `tokens[0..<tokenCount]`.
    public let tokenCount: Int
    /// Which tier served it (telemetry).
    public let tier: PrefixCacheTier
}

/// Ownership-transfer box for handing freshly-extracted caches INTO the
/// manager. The caller (BatchScheduler) extracts caches via
/// `extractBatched` and transfers ownership — it MUST NOT mutate them
/// after boxing. `@unchecked Sendable` for the same reason as
/// `PrefixLookupResult`: single-owner, no shared mutable state.
public struct SendableKVCaches: @unchecked Sendable {
    public let caches: [any KVCache]
    public init(_ caches: [any KVCache]) { self.caches = caches }
}

public enum PrefixCacheTier: String, Sendable {
    case ram, ssd, miss
}

// MARK: - Stats

public struct PrefixCacheManagerStats: Sendable, Equatable {
    public var ramHits = 0
    public var ssdHits = 0
    public var misses = 0
    public var stores = 0
    public var ssdFlushes = 0
    public var modelMismatches = 0
    public var shapeMismatches = 0
    public var prefixHashMismatches = 0
    public var ssdReadErrors = 0
    public var diskEvictions = 0
    /// SSD entries dropped because they passed the sliding TTL (expired).
    public var ttlExpirations = 0
}

// MARK: - Manager

public actor PrefixCacheManager: PrefixCacheOwner {

    private let binding: PrefixCacheModelBinding
    private let ram: PrefixCacheRAM
    private let index: PrefixCacheIndex?
    private let kek: KVCacheKEK?
    private let cacheDir: URL?
    private let ssdEnabled: Bool
    private let boundaries: [Int]
    /// On-disk budget (bytes) for this model's persisted checkpoints. After
    /// each flush, LRU entries (file + index entry together) are evicted to
    /// stay under it, so the SSD tier and index.json are both bounded under
    /// sustained diverse traffic. 0 = unbounded (not recommended in prod).
    /// Phase 3: when accountant != nil, this is set to 0 (unbounded) so the
    /// two budgets never fight — accountant is sole authority.
    private let diskBudgetBytes: Int
    /// TB-016 sub-feature B: Minimum token count for SSD persistence. Gates
    /// PERSISTENCE only, not RAM admission (short within-window prefixes
    /// still cache in RAM). 0 = today's behavior (all checkpoints persist).
    private let minPersistTokens: Int
    /// Prefill cost per token (ms) for benefit-per-byte eviction scoring.
    /// TB-016 sub-feature C: drives the benefit numerator.
    private let prefillCostPerToken: Double
    /// Half-life (seconds) for recency decay in benefit-per-byte scoring.
    /// TB-016 sub-feature C: freshly-promoted entries stay hot.
    private let evictionHalfLifeSeconds: Double
    /// Sliding TTL (seconds) for persisted SSD checkpoints. An entry is expired
    /// when `now() - lastHitAt > ttlSeconds` (sliding: `lastHitAt` is bumped on
    /// every hit, so hot prefixes stay warm). 0 ⇒ no TTL (infinite — legacy /
    /// capacity-driven only). Enforced on read (loadFromSSD) and proactively
    /// reclaimed in the disk sweep. Privacy: bounds how long KV derived from one
    /// prompt lingers on disk, shrinking the TB-007 cross-tenant TTFT-oracle
    /// window. SSD tier only — the RAM tier keeps its deterministic LRU.
    private let ttlSeconds: Int64
    private let now: @Sendable () -> Int64

    /// Phase 3: global disk accountant (process-wide, shared across models).
    /// nil ⇒ today's per-model behavior (backward compat).
    private let accountant: GlobalDiskAccountant?
    /// 12-char modelKey (sha256(modelId)[:12]) for accountant registration.
    private let modelKey: String
    /// Accountant registration token (stored after register, used for deregister).
    private var accountantToken: AccountantToken?
    /// Set true on deregister (model unload). Disk mutators (store/persist/flush/
    /// evict) bail when closed, so an in-flight/queued capture or promotion Task
    /// — which holds its own `self` reference and can outlive the manager being
    /// dropped — cannot write to SSD after deregistration (which would look
    /// unowned to the accountant or race a reused-modelKey reload).
    private var closed = false

    #if DEBUG
    /// Test seam: fired right after `EncryptedKVStore.write`
    /// returns and BEFORE the post-write `closed` re-check, so a regression test
    /// can deterministically simulate a deregister landing during the write
    /// suspension (instead of racing a real concurrent unload). nil in prod
    /// (never set outside tests). Awaited on the manager actor, so a hook that
    /// calls `deregisterFromAccountant()` runs to completion before the re-check.
    var _afterWriteHookForTest: (@Sendable () async -> Void)?
    #endif

    private var stats = PrefixCacheManagerStats()

    /// Digests currently being written by an in-flight flushToSSD. The
    /// capture hook fires one detached `Task { store; flushToSSD }` per
    /// checkpoint, so multiple flushToSSD run concurrently on this actor and
    /// interleave at the `await` inside the write loop. Without this guard
    /// two of them can both pass the "already persisted?" check for the same
    /// digest and redundantly serialize+encrypt+fsync the same (large) blob.
    /// Actor-isolated, so check-and-insert before the await is atomic.
    private var inFlightWrites: Set<String> = []
    /// Continuations parked by `deregisterFromAccountant` while
    /// in-flight writes drain. A write that lands the LAST in-flight file (so
    /// `inFlightWrites` becomes empty) resumes them. This lets teardown await
    /// quiescence: every file the old manager will ever write is on disk before
    /// `deregisterFromAccountant` returns — hence before `loadModel` constructs
    /// and reconciles a new same-modelKey manager (loadModel awaits
    /// stopCurrentEngine -> deregisterFromAccountant fully first). Without this,
    /// a stale write whose atomic rename lands AFTER the new manager's one-shot
    /// reconcileWithDisk leaves an orphan: on disk, in no index, and skipped by
    /// tick() (owned dir) until the NEXT unload — invisible to the global budget.
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []
    /// Writes accumulated since the last index.save(), to amortize the O(N)
    /// full-index re-encode + atomic write + fsync away from every flush.
    private var unsavedWrites = 0
    /// Save the index after this many new writes (or on shutdown/idle flush).
    private static let saveCoalesceThreshold = 8
    /// Last wall-clock second a touch-driven index save ran (PR #290 review):
    /// hit-recency (`lastHitAt`) is bumped in memory on every RAM/SSD hit, but
    /// without periodic persistence a crash loses those bumps and the next
    /// restart's reconcile reaps recently-hot entries off stale timestamps.
    /// Saves are time-coalesced (at most one per `touchSaveIntervalSeconds`),
    /// bounding both the hot-path fsync cost and the crash-loss window.
    private var lastTouchSaveAt: Int64 = 0
    /// Max recency staleness a crash can cause (seconds). 60s against the 300s
    /// default TTL means a crash under-credits an entry's recency by ≤ 20%.
    static let touchSaveIntervalSeconds: Int64 = 60
    /// TB-016 sub-feature B: pinned digests are always eligible for
    /// persistence regardless of minPersistTokens. Internal-only (no
    /// public pin() API this phase).
    private var pinnedDigests: Set<String> = []

    /// 12-char model-hash prefix used as the per-model SSD subdirectory.
    private var modelDirComponent: String {
        String(binding.modelHash.replacingOccurrences(of: "sha256:", with: "").prefix(12))
    }

    /// Per-tenant scope (`SHA256(prompt_cache_key)`, empty ⇒ unscoped) recovered
    /// by the write paths, which hold a digest but not the scope string and must
    /// stamp it into the AAD metadata `scope`. Two complementary keyings:
    ///   • by UNSCOPED prefix-digest hex — for `store` (the capture hook gives
    ///     it tokens only; it computes the unscoped digest to recover scope,
    ///     THEN forms the scoped digest);
    ///   • by SCOPED checkpoint-digest hex — for `flushToSSD`/`persistDigest`,
    ///     which iterate RAM entries keyed by the scoped digest.
    /// `lookup` (tokens + scope in hand) populates both; `store` also re-records
    /// the scoped keying so a flush of a first-written (never-looked-up)
    /// checkpoint still finds its scope. Unscoped ("") is never recorded
    /// (writers default to "" — byte-identical back-compat).
    ///
    /// FAIL-OPEN SEMANTICS (intentional, security-reviewed): this map is a
    /// best-effort *write-side* scope recovery, NEVER a read/match control —
    /// reads always recompute the digest from `(tokens, scope)`, so a wrong/
    /// missing map entry can never make tenant B MATCH tenant A's key (no
    /// cross-tenant content hit). The only failure mode is a scoped checkpoint
    /// getting stamped UNSCOPED (scope "") when its entry was evicted between
    /// `lookup` and the capture-hook `store` — which merely re-exposes that one
    /// entry to the *existence/TTFT timing oracle* (TB-007), not its contents.
    /// In practice `store` runs microseconds after its own `lookup` (same B==1
    /// request), so only a wholesale wipe by an interleaving request is a risk;
    /// the cap is generous and eviction is bounded, so this is a rare, benign
    /// degradation, not a leak. (A fully race-free fix would thread `scope`
    /// through the engine's `onCheckpointCapture` hook — deferred with the
    /// engine-tier scoping work.)
    private var scopeByDigest: [String: String] = [:]
    private static let scopeMapCap = 65536

    private func recordScopeDigest(_ digestHex: String, _ scope: String) {
        guard !scope.isEmpty else { return }
        // Bounded backstop. removeAll only triggers far above the working set of
        // any single batch, so it cannot drop an in-flight request's just-
        // recorded scope before that request's store() runs.
        if scopeByDigest.count > Self.scopeMapCap { scopeByDigest.removeAll(keepingCapacity: true) }
        scopeByDigest[digestHex] = scope
    }

    /// Record `scope` under BOTH the unscoped and scoped digests of every
    /// checkpoint-boundary of `tokens`.
    private func recordScope(_ scope: String, tokens: [Int]) {
        guard !scope.isEmpty else { return }
        let unscoped = PrefixDigest.checkpoints(tokens: tokens, boundaries: boundaries)
        let scoped = PrefixDigest.checkpoints(tokens: tokens, boundaries: boundaries, scope: scope)
        for cp in unscoped { recordScopeDigest(cp.digest.dbkvHexString, scope) }
        for cp in scoped { recordScopeDigest(cp.digest.dbkvHexString, scope) }
    }

    /// Recover the scope for a digest hex (empty ⇒ unscoped/back-compat).
    private func scopeFor(_ digestHex: String) -> String {
        scopeByDigest[digestHex] ?? ""
    }

    /// Absolute expiry stamped into a freshly-written file's metadata:
    /// `createdAt + ttl`, or nil when TTL is disabled. This is the EARLIEST
    /// possible expiry (a never-hit entry, where lastHitAt == createdAt); the
    /// live check slides off the mutable `lastHitAt` in the index, so a hit
    /// extends effective lifetime without re-sealing the file. Informational +
    /// a hard floor for any future offline reaper; the authoritative runtime
    /// check is the lastHitAt comparison in loadFromSSD/sweep.
    private func expiresAtForWrite() -> Int64? {
        ttlSeconds > 0 ? saturatingExpiry(from: now()) : nil
    }

    /// Saturating `base + ttlSeconds`. An operator-set "effectively infinite"
    /// TTL (e.g. Int64.max) must clamp to never-expires, not trap on overflow.
    private func saturatingExpiry(from base: Int64) -> Int64 {
        let (sum, overflow) = base.addingReportingOverflow(ttlSeconds)
        return overflow ? Int64.max : sum
    }

    /// THE sliding-TTL expiry predicate — single source of truth for the read
    /// path (loadFromSSD) and the sweeps (reapExpired). Expired when the entry
    /// hasn't been hit within `ttlSeconds`; `lastHitAt` is bumped on every hit
    /// (SSD loads AND RAM serves), so hot prefixes stay warm. Overflow-safe:
    /// index.json is plaintext and can be crash-corrupted — an extreme
    /// `lastHitAt` (e.g. Int64.min) counts as expired/reapable, never a trap.
    /// `ttlSeconds == 0` ⇒ never expires (infinite retention).
    private func isExpired(lastHitAt: Int64) -> Bool {
        guard ttlSeconds > 0 else { return false }
        let (age, overflow) = now().subtractingReportingOverflow(lastHitAt)
        return overflow || age > ttlSeconds
    }

    /// Time-coalesced index save after a hit-recency touch (PR #290 review).
    /// `index.touch` only mutates in memory; if the process dies before a
    /// graceful flush, restart reconcile would reap recently-hot entries off
    /// stale persisted timestamps. At most one save per
    /// `touchSaveIntervalSeconds` bounds the crash-loss window without putting
    /// an fsync on every warm request. TTL-gated: with TTL off nothing reaps
    /// on recency, so the persistence urgency disappears.
    private func persistRecencyIfDue(_ index: PrefixCacheIndex) {
        guard ttlSeconds > 0, !closed, index.isDirty else { return }
        let t = now()
        guard t - lastTouchSaveAt >= Self.touchSaveIntervalSeconds else { return }
        if (try? index.save()) != nil {
            lastTouchSaveAt = t
            unsavedWrites = 0
        }
    }

    /// Steady-state TTL sweep (PR #290 review): reconcile-time reaping only
    /// covers model (re)load, and the lazy read-path check only fires when the
    /// SAME prefix is looked up again — so entries that go cold while the
    /// model stays loaded would otherwise sit on disk until restart. Called
    /// periodically by BatchScheduler while the engine is alive. Persists the
    /// shrunken index and pushes the corrected footprint to the accountant
    /// (mirroring dropUnusableSSDFile). No-op when TTL disabled / SSD off /
    /// closed.
    public func reapExpiredTick() async {
        guard ssdEnabled, let index, let cacheDir else { return }
        let before = stats.ttlExpirations
        reapExpired(index: index, cacheDir: cacheDir)
        guard stats.ttlExpirations > before else { return }
        if index.isDirty { _ = try? index.save() }
        await notifyAccountant()
    }

    public init(
        binding: PrefixCacheModelBinding,
        ram: PrefixCacheRAM,
        index: PrefixCacheIndex? = nil,
        kek: KVCacheKEK? = nil,
        cacheDir: URL? = nil,
        ssdEnabled: Bool,
        boundaries: [Int] = PrefixDigest.defaultCheckpoints,
        diskBudgetBytes: Int = 0,
        minPersistTokens: Int = 0,
        prefillCostPerToken: Double = 1.0,
        evictionHalfLifeSeconds: Double = 86400,
        ttlSeconds: Int64 = 0,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        accountant: GlobalDiskAccountant? = nil,
        modelKey: String = ""
    ) {
        self.binding = binding
        self.ram = ram
        self.index = index
        self.kek = kek
        self.cacheDir = cacheDir
        // SSD requires all three backing pieces; otherwise RAM-only.
        self.ssdEnabled = ssdEnabled && index != nil && kek != nil && cacheDir != nil
        self.boundaries = boundaries
        // Phase 3: when accountant != nil, set diskBudgetBytes to 0 (unbounded)
        // so the two budgets never fight — accountant is sole authority.
        self.diskBudgetBytes = accountant != nil ? 0 : max(0, diskBudgetBytes)
        self.minPersistTokens = minPersistTokens
        self.prefillCostPerToken = prefillCostPerToken
        self.evictionHalfLifeSeconds = evictionHalfLifeSeconds
        self.ttlSeconds = max(0, ttlSeconds)
        self.now = now
        self.accountant = accountant
        self.modelKey = modelKey
    }

    public var isSSDEnabled: Bool { ssdEnabled }
    public func snapshotStats() -> PrefixCacheManagerStats { stats }
    public func ramTierStats() -> PrefixCacheRAMStats { ram.snapshotStats() }

    #if DEBUG
    /// Test seam: install the after-write hook (see
    /// `_afterWriteHookForTest`). DEBUG-only; never called in prod.
    func _setAfterWriteHookForTest(_ hook: @escaping @Sendable () async -> Void) {
        _afterWriteHookForTest = hook
    }
    /// Test seam: does this manager's index hold an entry for
    /// `digestHex`? Used to assert a post-close write did NOT record.
    func _indexHasEntryForTest(digestHex: String) -> Bool {
        index?.entry(modelHash: binding.modelHash, digestHex: digestHex) != nil
    }
    /// Test seam: set `closed` WITHOUT the full deregister drain.
    /// The post-close-write regression test fires this from `_afterWriteHookForTest`
    /// (i.e. from INSIDE an in-flight write); calling the real
    /// `deregisterFromAccountant()` there
    /// would self-deadlock — its `drainInFlightWrites()` awaits the very write
    /// that is parked in the hook. Production never does this: deregister runs
    /// on the BatchScheduler task while the write is suspended off-actor, so the
    /// drain parks, the actor frees, the write resumes/bails/finishes, and the
    /// drain wakes. This seam reproduces only the `closed=true` precondition.
    func _markClosedForTest() { closed = true }
    /// Test seam: drop just the index entry for `digestHex` (leaving the
    /// on-disk file), turning it into an orphan a live reconcile would re-index.
    func _dropIndexEntryForTest(digestHex: String) {
        index?.remove(modelHash: binding.modelHash, digestHex: digestHex)
    }
    /// Test seam: number of teardown waiters currently parked in
    /// `drainInFlightWrites`. Lets the drain test confirm deregister actually
    /// blocked on the drain (rather than passing trivially because no write was
    /// in flight).
    func _drainWaiterCountForTest() -> Int { drainContinuations.count }
    #endif

    // MARK: - Lookup

    /// Find the longest cached checkpoint whose prefix is byte-identical
    /// to `tokens`. RAM first, then SSD (with the MB-1 guard). Returns
    /// fresh, caller-owned caches via `sending`, or nil on miss.
    public func lookup(tokens: [Int], scope: String = "") async -> PrefixLookupResult? {
        // A closed (deregistered/unloaded) manager must not
        // serve hits. Without this, a lookup that started before unload — or one
        // racing teardown — could return KV from a manager whose model is gone,
        // which (combined with the stale-engine submit window) risks seeding a
        // superseded engine. The SSD path re-checks `closed` after its read await.
        guard !closed else { return nil }
        // Record this request's scope for the boundary prefixes so the
        // capture-hook-driven store() (tokens-only) can recover it.
        recordScope(scope, tokens: tokens)
        let checkpoints = PrefixDigest.checkpoints(tokens: tokens, boundaries: boundaries, scope: scope)
        guard !checkpoints.isEmpty else {
            stats.misses += 1
            return nil
        }

        // RAM tier: longest checkpoint first.
        for cp in checkpoints.reversed() {
            if let hit = ram.get(modelHash: binding.modelHash, digest: cp.digest) {
                stats.ramHits += 1
                let digestHex = cp.digest.dbkvHexString
                if ssdEnabled, let index {
                    if index.entry(modelHash: binding.modelHash, digestHex: digestHex) != nil {
                        // The prefix is ALSO on SSD. A RAM hit must slide the
                        // SSD entry's lastHitAt: the sliding TTL is "time since
                        // last use", and use includes RAM serves. Without this,
                        // a RAM-hot prefix older than the TTL gets reaped as
                        // "expired" the moment RAM pressure evicts it and the
                        // next lookup falls through to SSD. Gated on TTL being
                        // enabled so ttl=0 behavior stays byte-identical.
                        if ttlSeconds > 0 {
                            index.touch(modelHash: binding.modelHash, digestHex: digestHex, now: now())
                            persistRecencyIfDue(index)
                        }
                    } else if hit.tokenCount >= minPersistTokens {
                        // TB-016 sub-feature B: 2nd-use promotion. RAM hit above
                        // the persist threshold and NOT already on SSD — schedule
                        // a detached promotion (no blocking the lookup actor).
                        let cpScope = scope
                        Task.detached { [weak self] in
                            await self?.persistDigest(cp.digest, scope: cpScope)
                        }
                    }
                }
                return PrefixLookupResult(caches: hit.caches, tokenCount: hit.tokenCount, tier: .ram)
            }
        }

        // SSD tier.
        if ssdEnabled, let result = await loadFromSSD(tokens: tokens, scope: scope) {
            stats.ssdHits += 1
            return result
        }

        stats.misses += 1
        return nil
    }

    /// Drop an unusable SSD file (corrupt header, wrong model/
    /// shape/prefix, or undecryptable) discovered during a lookup — removing the
    /// file AND its index entry, then refreshing durable + accountant state.
    /// Before this, the five `loadFromSSD` removal sites dropped file+entry but
    /// left the index unsaved and the accountant still counting the deleted
    /// bytes, so enforcement could evict against phantom entries until a later
    /// write happened to republish usage. Persist the now-dirty index and notify
    /// the accountant — but ONLY if `!closed`: a deregistered manager must not
    /// save its index or push usage, lest it clobber a reloaded same-modelKey
    /// manager's index.json or resurrect usage in the accountant.
    private func dropUnusableSSDFile(_ fileURL: URL, digestHex: String, index: PrefixCacheIndex) async {
        // Check `closed` BEFORE deleting. A lookup can suspend in
        // EncryptedKVStore.read, the manager be deregistered (closed=true) during
        // that await, and the read then fail and reach here — at which point a NEW
        // same-modelKey manager may already own this dir (the path is deterministic
        // from binding.modelHash). A closed manager deleting that file is the
        // cross-actor live-delete the ownership model forbids: it could nuke the
        // new owner's freshly-written checkpoint. A closed manager must leave the
        // file (the live owner's lookup/reconcile re-validates and drops it if
        // genuinely unusable). Matches the entry-guard discipline in
        // store/flushToSSD/persistDigest.
        guard !closed else { return }
        try? FileManager.default.removeItem(at: fileURL)
        index.remove(modelHash: binding.modelHash, digestHex: digestHex)
        // The removal made the index dirty; persist it now (a single-entry drop
        // is cheap, and leaving it only in memory would let a crash resurrect the
        // stale entry → another failed lookup → re-drop). notifyAccountant pushes
        // the corrected (smaller) footprint so enforcement stops counting it.
        if index.isDirty { _ = try? index.save() }
        await notifyAccountant()
    }

    private func loadFromSSD(tokens: [Int], scope: String = "") async -> PrefixLookupResult? {
        guard let index, let kek, let cacheDir else { return nil }

        // Sliding TTL: an entry is expired when it hasn't been hit within
        // `ttlSeconds` (lastHitAt is bumped on every hit — SSD loads AND RAM
        // serves — so hot prefixes stay warm). Checked BEFORE decrypt — an
        // expired entry is reclaimed (same drop path as a corrupt file) and
        // the search CONTINUES with the next-longest checkpoint: an expired 8k
        // checkpoint must not mask a shorter, still-fresh one (e.g. a hot
        // shared system-prefix). Each drop removes the entry from the index,
        // so findLongestCheckpoint yields the next candidate; progress is
        // guaranteed. ttlSeconds == 0 disables (infinite retention). Bounds
        // how long prompt-derived KV survives on disk (TB-007 window shrink).
        var selected: PrefixIndexEntry?
        // Defensive cap: dropUnusableSSDFile no-ops when the manager closed
        // mid-loop (it must not delete in a handed-off dir), which would
        // otherwise refetch the same entry forever. The `closed` re-check
        // breaks that cycle; the cap is belt-and-braces against any future
        // drop path that leaves the entry behind.
        var attempts = boundaries.count + 1
        while attempts > 0, !closed, let candidate = index.findLongestCheckpoint(
            modelHash: binding.modelHash, tokens: tokens, boundaries: boundaries, scope: scope
        ) {
            attempts -= 1
            guard isExpired(lastHitAt: candidate.lastHitAt) else {
                selected = candidate
                break
            }
            stats.ttlExpirations += 1
            let rel = "\(modelDirComponent)/\(candidate.digestHex).\(EncryptedKVStore.fileExtension)"
            await dropUnusableSSDFile(
                cacheDir.appendingPathComponent(rel), digestHex: candidate.digestHex, index: index)
        }
        guard let entry = selected else { return nil }

        // Path safety: the on-disk index JSON is plaintext and NOT
        // authenticated, so a tampered entry.relativePath could contain
        // "../" and escape cacheDir (an out-of-sandbox read). The path is
        // written deterministically by flushToSSD, so reconstruct it from
        // the trusted model binding + the index key (entry.digestHex, which
        // findLongestCheckpoint already matched against a computed pure-hex
        // digest) instead of trusting the stored path.
        let relPath = "\(modelDirComponent)/\(entry.digestHex).\(EncryptedKVStore.fileExtension)"
        let fileURL = cacheDir.appendingPathComponent(relPath)

        // MB-1: validate metadata BEFORE unwrap/decrypt. A wrong-model
        // file decrypts cleanly (AAD is its own metadata), so the cipher
        // can't catch this — the equality check must.
        let meta: EncryptedKVStoreMetadata
        do {
            meta = try EncryptedKVStore.readMetadataOnly(from: fileURL)
        } catch {
            stats.ssdReadErrors += 1
            // Truncated/corrupt header (e.g. crash mid-write): drop BOTH the
            // index entry AND the unusable file, so it can't linger on disk
            // (leaking + escaping the budget) and be re-read every lookup.
            await dropUnusableSSDFile(fileURL, digestHex: entry.digestHex, index: index)
            return nil
        }
        // The model-dir path is reconstructed from THIS model's binding, so a
        // mismatching file here is genuinely stale/wrong for this model (e.g.
        // a weight change under the same id) — drop the file too, not just the
        // index entry, so it can't linger and escape the disk budget.
        guard meta.modelHash == binding.modelHash else {
            stats.modelMismatches += 1
            logger.warning("MB-1: prefix file model mismatch — dropping entry \(entry.digestHex, privacy: .public)")
            await dropUnusableSSDFile(fileURL, digestHex: entry.digestHex, index: index)
            return nil
        }
        guard meta.numLayers == binding.numLayers,
              meta.kvHeads == binding.kvHeads,
              meta.headDim == binding.headDim else {
            stats.shapeMismatches += 1
            await dropUnusableSSDFile(fileURL, digestHex: entry.digestHex, index: index)
            return nil
        }
        // Prefix binding: the file authenticates under its OWN metadata, so
        // a stale/corrupt index entry (or a same-model file at the wrong
        // path) would otherwise decrypt cleanly and return KV for a
        // DIFFERENT prompt prefix. Require the file's prefix hash to match
        // the index entry's digest, or drop it and cold-prefill.
        guard meta.tokenPrefixHash == entry.digestHex else {
            stats.prefixHashMismatches += 1
            logger.warning("SSD prefix-hash mismatch (index stale/corrupt) — dropping \(entry.digestHex, privacy: .public)")
            await dropUnusableSSDFile(fileURL, digestHex: entry.digestHex, index: index)
            return nil
        }
        // Per-tenant scope re-check (defense-in-depth on top of the scoped
        // digest, which already makes a cross-scope filename match infeasible).
        // Normalize nil/"" to the same unscoped value. A mismatch should be
        // unreachable — the scoped digest in findLongestCheckpoint guarantees
        // the matched entry was keyed with THIS scope — so REFUSE without
        // deleting: the file legitimately belongs to another scope (only the
        // owning scope's lookup may reclaim it), exactly like a foreign file.
        let fileScope = meta.scope ?? ""
        guard fileScope == scope else {
            stats.modelMismatches += 1
            logger.warning("SSD scope mismatch — refusing (not deleting) entry \(entry.digestHex, privacy: .public)")
            return nil
        }

        // Decrypt + deserialize.
        let caches: [any KVCache]
        do {
            let (readMeta, chunks) = try await EncryptedKVStore.read(from: fileURL, kek: kek)
            guard let layoutJSON = readMeta.metaState.first,
                  let layout = try? JSONDecoder().decode(
                    KVCacheLayout.self, from: Data(layoutJSON.utf8)) else {
                throw KVCacheSerializerError.reconstructionFailed("missing/invalid layout in metaState")
            }
            // Bind the actual KV tensor shapes (not just the metadata
            // integers) to the live model before seeding attention.
            // Per-layer shape validation for heterogeneous models (Gemma-4);
            // fall back to the scalar check when no per-layer reference.
            if let layerShapes = binding.layerShapes {
                try KVCacheSerializer.validateLayout(layout, layerShapes: layerShapes)
            } else {
                try KVCacheSerializer.validateLayout(
                    layout, kvHeads: binding.kvHeads, headDim: binding.headDim)
            }
            caches = try KVCacheSerializer.deserialize(chunks: chunks, layout: layout)
        } catch {
            stats.ssdReadErrors += 1
            logger.warning("SSD prefix read failed for \(entry.digestHex, privacy: .public): \(String(describing: error))")
            // Drop BOTH the index entry AND the unusable file (corrupt,
            // truncated, KEK-unwrap failure) so it can't linger on disk
            // forever consuming the budget and being re-read every lookup.
            await dropUnusableSSDFile(fileURL, digestHex: entry.digestHex, index: index)
            return nil
        }

        // The manager may have been deregistered (closed) while
        // we were suspended in the read above. A closed manager must not serve a
        // hit (its model is gone — seeding a superseded engine) nor mutate RAM/
        // index state a new same-modelKey manager may now own. Bail.
        guard !closed else { return nil }

        // Promote to RAM for the next hit, and bump index recency.
        if let digestData = Data(hex: entry.digestHex) {
            ram.put(
                modelHash: binding.modelHash, digest: digestData,
                caches: caches.map { $0.copy() }, tokenCount: entry.tokenCount
            )
        }
        index.touch(modelHash: binding.modelHash, digestHex: entry.digestHex, now: now())
        persistRecencyIfDue(index)

        return PrefixLookupResult(caches: caches, tokenCount: entry.tokenCount, tier: .ssd)
    }

    // MARK: - Store

    /// Store a freshly-extracted snapshot in the RAM tier, keyed by the
    /// checkpoint digest of `tokens[0..<checkpointLength]`. SSD
    /// persistence happens later via `flushToSSD` (write-back).
    /// Returns true if stored, false if rejected (e.g., exceeds maxBytes).
    /// When RAM rejects an over-budget checkpoint AND it is
    /// persistable (>= minPersistTokens or pinned) AND ssdEnabled, fall back
    /// to a direct SSD write so highest-value checkpoints aren't silently lost.
    @discardableResult
    public func store(tokens: [Int], checkpointLength: Int, caches: SendableKVCaches) async -> Bool {
        guard !closed else { return false }
        guard checkpointLength > 0, checkpointLength <= tokens.count else { return false }
        // Recover the originating request's scope. The capture hook hands us
        // tokens only, so key off the UNSCOPED digest (which lookup recorded).
        // Empty ⇒ unscoped (back-compat). Then form the SCOPED digest that
        // actually keys the cache, and re-record it so a later flush/promote of
        // this checkpoint (which sees only the scoped digest) recovers the scope.
        let unscopedHex = PrefixDigest.digest(tokens: tokens, length: checkpointLength).dbkvHexString
        let scope = scopeFor(unscopedHex)
        let digest = PrefixDigest.digest(tokens: tokens, length: checkpointLength, scope: scope)
        let digestHex = digest.dbkvHexString
        recordScopeDigest(digestHex, scope)
        let stored = ram.put(
            modelHash: binding.modelHash, digest: digest,
            caches: caches.caches, tokenCount: checkpointLength
        )
        if stored {
            stats.stores += 1
            return true
        }

        // RAM rejected (over its maxBytes). If this checkpoint is
        // persistable (>= minPersistTokens or pinned) AND ssdEnabled, persist
        // it directly to SSD so highest-value checkpoints aren't silently lost
        // on memory-constrained hosts (where RAM maxBytes = physMem/8 may be
        // smaller than a past-window checkpoint).
        let isPersistable = checkpointLength >= minPersistTokens || pinnedDigests.contains(digestHex)
        guard ssdEnabled, isPersistable, let index, let kek, let cacheDir else { return false }
        guard KVCacheSerializer.areSupported(caches.caches) else { return false }

        // Dedup: already persisted or in-flight.
        if index.entry(modelHash: binding.modelHash, digestHex: digestHex) != nil { return false }
        if inFlightWrites.contains(digestHex) { return false }

        inFlightWrites.insert(digestHex)
        defer { finishWrite(digestHex) }

        do {
            let (chunks, layout) = try KVCacheSerializer.serialize(caches.caches)
            let layoutJSON = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            let relativePath = "\(modelDirComponent)/\(digestHex).\(EncryptedKVStore.fileExtension)"
            let fileURL = cacheDir.appendingPathComponent(relativePath)
            let meta = EncryptedKVStoreMetadata(
                modelHash: binding.modelHash, modelDtype: binding.modelDtype, modelArch: binding.modelArch,
                vocabSize: binding.vocabSize, numLayers: binding.numLayers,
                kvHeads: binding.kvHeads, headDim: binding.headDim, tokenCount: checkpointLength,
                tokenPrefixHash: digestHex, kvCacheClass: "mixed",
                metaState: [layoutJSON], chunkPlaintextSizes: chunks.map { $0.count }, createdAt: now(),
                expiresAt: expiresAtForWrite(),
                scope: scope
            )
            try await EncryptedKVStore.write(to: fileURL, metadata: meta, chunks: chunks, kek: kek)

            #if DEBUG
            if let hook = _afterWriteHookForTest { await hook() }
            #endif
            // The manager may have been deregistered
            // (closed=true via deregisterFromAccountant) DURING the await above.
            // The `closed` contract is that no SSD bookkeeping survives
            // deregistration: recording here pushes a now-orphaned index entry,
            // and a later index.save() could clobber a freshly-loaded
            // same-modelKey manager's index.json. We deliberately do NOT delete
            // the file — that path/dir may already be OWNED by the new manager
            // (same modelHash → same modelDirComponent), so removing it would be
            // the forbidden cross-actor live-delete (and could nuke the new
            // owner's identical-digest file). The file is reclaimed and counted
            // by the new manager's reconcileWithDisk (validates model + prefix
            // binding). Bail without recording/saving/notifying.
            if closed { return false }

            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileBytes = (attrs?[.size] as? Int) ?? 0
            index.record(PrefixIndexEntry(
                modelHash: binding.modelHash, digestHex: digestHex, tokenCount: checkpointLength,
                relativePath: relativePath, fileBytes: fileBytes, createdAt: now(), lastHitAt: now()
            ))

            stats.ssdFlushes += 1
            enforceDiskBudget(index: index, cacheDir: cacheDir)

            unsavedWrites += 1
            if unsavedWrites >= Self.saveCoalesceThreshold {
                if (try? index.save()) != nil { unsavedWrites = 0 }
            }
            await notifyAccountant()
            // The checkpoint is now on SSD (not in RAM), so report success.
            return true
        } catch {
            logger.warning("store: direct SSD persist failed for oversized checkpoint \(digestHex, privacy: .public): \(String(describing: error))")
            return false
        }
    }

    // MARK: - Flush (write-back to SSD)

    /// Serialize RAM-tier entries for this model that aren't already on
    /// SSD, encrypt them, and record them in the index. Best-effort: a
    /// per-entry failure is logged and skipped. No-op when SSD disabled.
    /// Returns the number of entries newly written.
    ///
    /// TB-016 sub-feature B: skips entries with tokenCount <
    /// minPersistTokens UNLESS pinned (defensive so a stray bulk-flush
    /// caller can't persist sub-threshold one-offs).
    @discardableResult
    public func flushToSSD() async -> Int {
        guard !closed else { return 0 }
        guard ssdEnabled, let index, let kek, let cacheDir else { return 0 }

        var written = 0
        for snap in ram.entriesForFlush(modelHash: binding.modelHash) {
            let digestHex = snap.key.digest.dbkvHexString
            // TB-016: skip sub-threshold entries unless pinned.
            if snap.tokenCount < minPersistTokens,
               !pinnedDigests.contains(digestHex) {
                continue
            }
            // Skip entries already persisted OR being written right now by a
            // concurrent flush (reentrancy: the dedup check + the write are
            // separated by an await, so without the in-flight set two flushes
            // would both serialize+encrypt+fsync the same large blob).
            if index.entry(modelHash: binding.modelHash, digestHex: digestHex) != nil { continue }
            if inFlightWrites.contains(digestHex) { continue }
            // Only serialize SSD-capable stacks (defensive; ssdEnabled
            // should already guarantee this for the model).
            guard KVCacheSerializer.areSupported(snap.caches) else { continue }

            inFlightWrites.insert(digestHex)
            do {
                let (chunks, layout) = try KVCacheSerializer.serialize(snap.caches)
                let layoutJSON = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
                let relativePath = "\(modelDirComponent)/\(digestHex).\(EncryptedKVStore.fileExtension)"
                let fileURL = cacheDir.appendingPathComponent(relativePath)
                let meta = EncryptedKVStoreMetadata(
                    modelHash: binding.modelHash,
                    modelDtype: binding.modelDtype,
                    modelArch: binding.modelArch,
                    vocabSize: binding.vocabSize,
                    numLayers: binding.numLayers,
                    kvHeads: binding.kvHeads,
                    headDim: binding.headDim,
                    tokenCount: snap.tokenCount,
                    tokenPrefixHash: digestHex,
                    kvCacheClass: "mixed",
                    metaState: [layoutJSON],
                    chunkPlaintextSizes: chunks.map { $0.count },
                    createdAt: now(),
                    expiresAt: expiresAtForWrite(),
                    scope: scopeFor(digestHex)
                )
                try await EncryptedKVStore.write(to: fileURL, metadata: meta, chunks: chunks, kek: kek)

                #if DEBUG
                if let hook = _afterWriteHookForTest { await hook() }
                #endif
                // Deregistered (closed) DURING the write
                // await — stop recording/notifying. See store() for the full
                // rationale; the file is left for the new manager's reconcile to
                // reclaim (never cross-actor live-deleted). Drop the in-flight
                // marker and break the loop (no more writes after close).
                if closed {
                    finishWrite(digestHex)
                    break
                }

                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileBytes = (attrs?[.size] as? Int) ?? 0
                index.record(PrefixIndexEntry(
                    modelHash: binding.modelHash, digestHex: digestHex,
                    tokenCount: snap.tokenCount, relativePath: relativePath,
                    fileBytes: fileBytes, createdAt: now(), lastHitAt: now()
                ))
                written += 1
            } catch {
                logger.warning("flushToSSD: failed to persist \(digestHex, privacy: .public): \(String(describing: error))")
            }
            finishWrite(digestHex)
        }

        // If we were deregistered mid-loop, do NOT run the
        // post-loop bookkeeping — enforceDiskBudget deletes files (cross-actor
        // live-delete on a dir the new owner may hold) and index.save() would
        // clobber the new same-modelKey manager's index.json. `written` is the
        // count BEFORE close; any pre-close records stay in this dead manager's
        // in-memory index (never saved), and the files are reclaimed by the new
        // manager's reconcile.
        if written > 0 && !closed {
            stats.ssdFlushes += written
            enforceDiskBudget(index: index, cacheDir: cacheDir)
            // Coalesce the O(N) full-index re-encode + atomic write + fsync:
            // saving on EVERY flush head-of-line-blocks lookups on this actor
            // and is amplified by concurrent flushes. Save once per
            // threshold; flushIndexNow() forces a save on idle/shutdown.
            unsavedWrites += written
            if unsavedWrites >= Self.saveCoalesceThreshold {
                // Only reset on a successful save; a transient I/O failure
                // (ENOSPC/EACCES) must keep the counter so the next flush —
                // or teardown — retries rather than dropping durability.
                if (try? index.save()) != nil { unsavedWrites = 0 }
            }
            // Phase 3: notify the accountant after byte-changing op.
            await notifyAccountant()
        }
        return written
    }

    /// Force-persist the index if there are unsaved writes (call on idle /
    /// before teardown so coalesced entries aren't lost). The in-memory RAM
    /// tier already serves them this session; this is durability across
    /// restart for the entries written since the last coalesced save.
    public func flushIndexNow() {
        // A CLOSED (deregistered/superseded) manager must not save
        // its index — a new same-modelKey manager may own the dir, and saving this
        // dead manager's stale in-memory index would clobber the live index.json.
        // Legit teardown calls flushIndexNow BEFORE deregisterFromAccountant (so
        // closed is still false here); only a superseded Load A reaching this after
        // Load B closed it is blocked.
        guard !closed else { return }
        guard ssdEnabled, let index else { return }
        if unsavedWrites > 0 || index.isDirty {
            // Only clear the unsaved counter if the save actually succeeded;
            // otherwise a transient ENOSPC/EACCES would silently lose
            // durability tracking and leave entries permanently unpersisted.
            if (try? index.save()) != nil { unsavedWrites = 0 }
        }
    }

    /// Reconcile the on-disk `.darkbloom-kv` files with the index, ONCE at
    /// startup. Two directions, both needed for crash-consistency:
    ///   • files present but NOT in the index (orphans from a crash inside
    ///     the save-coalescing window, or a corrupt/missing index.json) are
    ///     re-indexed by reading their plaintext metadata header (no decrypt)
    ///     and validating model + prefix-hash binding — so they count toward
    ///     the disk budget AND are reusable instead of leaking forever;
    ///   • index entries whose file is missing are dropped.
    /// Files that fail header read / model-mismatch / prefix-hash mismatch
    /// are deleted (unusable). Best-effort; never throws. Call ONCE right
    /// after construction, before any flush/lookup, from the async setup path.
    public func reconcileWithDisk() {
        // A superseded Load A can resume after Load B closed this
        // manager (B ran stopCurrentEngine during A's claimAccountantRegistration
        // await) and still call reconcileWithDisk. A closed manager scanning +
        // deleting files / saving an index in a dir now owned by the new manager
        // is the forbidden cross-actor mutation — with a weight change it would
        // classify the new owner's files as foreign and delete them. Bail.
        guard !closed else { return }
        guard ssdEnabled, let index, let cacheDir else { return }
        let modelDir = cacheDir.appendingPathComponent(modelDirComponent, isDirectory: true)
        let fm = FileManager.default
        let suffix = ".\(EncryptedKVStore.fileExtension)"

        // Proactively reclaim TTL-expired entries before re-indexing, so a
        // restart doesn't resurrect stale KV (and disk is freed even if the
        // model is never looked up again this session).
        reapExpired(index: index, cacheDir: cacheDir)

        // Drop index entries whose backing file vanished.
        for entry in index.entries(modelHash: binding.modelHash) {
            let url = modelDir.appendingPathComponent("\(entry.digestHex)\(suffix)")
            if !fm.fileExists(atPath: url.path) {
                index.remove(modelHash: binding.modelHash, digestHex: entry.digestHex)
            }
        }

        // Re-index (or delete) on-disk files.
        guard let names = try? fm.contentsOfDirectory(atPath: modelDir.path) else {
            flushIndexNow(); return
        }
        for name in names where name.hasSuffix(suffix) && !name.contains(".\(EncryptedKVStore.tempInfix)") {
            let digestHex = String(name.dropLast(suffix.count))
            if index.entry(modelHash: binding.modelHash, digestHex: digestHex) != nil { continue }
            let url = modelDir.appendingPathComponent(name)
            // Validate via the unauthenticated metadata header (cheap; the
            // real decrypt-time MB-1 + prefix-hash + AAD checks still gate
            // any later serve). Re-index only files that match this model
            // and whose stored prefix hash equals the filename digest.
            guard let meta = try? EncryptedKVStore.readMetadataOnly(from: url),
                  meta.modelHash == binding.modelHash,
                  meta.numLayers == binding.numLayers,
                  meta.kvHeads == binding.kvHeads,
                  meta.headDim == binding.headDim,
                  meta.tokenPrefixHash == digestHex
            else {
                try? fm.removeItem(at: url)  // foreign / corrupt / mislabeled
                continue
            }
            // TTL: don't resurrect an orphan that's already expired. New files
            // carry expiresAt = createdAt + ttl; LEGACY files (written before
            // the TTL existed, or while it was disabled) have expiresAt == nil
            // — treat those as createdAt + ttl too, so old and new files get
            // identical semantics and a stale legacy orphan can't outlive the
            // privacy window by being re-indexed (PR #290 review).
            if ttlSeconds > 0 {
                let exp = meta.expiresAt ?? saturatingExpiry(from: meta.createdAt)
                if now() > exp {
                    try? fm.removeItem(at: url)
                    stats.ttlExpirations += 1
                    continue
                }
            }
            let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            // Seed lastHitAt from the file's own createdAt (NOT now()), so a
            // re-indexed orphan keeps its real age — re-indexing can't reset the
            // sliding TTL clock and indefinitely extend a stale entry.
            index.record(PrefixIndexEntry(
                modelHash: binding.modelHash, digestHex: digestHex,
                tokenCount: meta.tokenCount,
                relativePath: "\(modelDirComponent)/\(name)",
                fileBytes: bytes ?? 0, createdAt: meta.createdAt, lastHitAt: meta.createdAt))
        }
        // Apply the budget to the reconciled set, then persist.
        enforceDiskBudget(index: index, cacheDir: cacheDir)
        flushIndexNow()
        // No stale unstructured notify here. loadModel calls
        // publishUsageToAccountant() explicitly right after reconcile (and only
        // when not superseded), so a detached Task that could fire post-unload
        // is both unnecessary and a hazard.
    }

    /// TB-016 sub-feature B: persist a single digest from RAM to SSD.
    /// Reuses the flushToSSD dedup + enforceDiskBudget + save-coalescing.
    /// Called by 2nd-use promotion (detached Task, non-blocking).
    /// Returns true if successfully persisted, false otherwise.
    @discardableResult
    private func persistDigest(_ digest: Data, scope: String = "") async -> Bool {
        guard !closed else { return false }
        guard ssdEnabled, let index, let kek, let cacheDir else { return false }
        let digestHex = digest.dbkvHexString

        // Already persisted or in flight.
        if index.entry(modelHash: binding.modelHash, digestHex: digestHex) != nil { return false }
        if inFlightWrites.contains(digestHex) { return false }

        // Find only the target RAM entry. Calling entriesForFlush(...).first
        // copies every checkpoint for the model and can OOM during a single
        // second-use promotion.
        guard let snap = ram.entryForFlush(modelHash: binding.modelHash, digest: digest) else {
            return false
        }

        // Only serialize SSD-capable stacks.
        guard KVCacheSerializer.areSupported(snap.caches) else { return false }

        inFlightWrites.insert(digestHex)
        defer { finishWrite(digestHex) }

        do {
            let (chunks, layout) = try KVCacheSerializer.serialize(snap.caches)
            let layoutJSON = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            let relativePath = "\(modelDirComponent)/\(digestHex).\(EncryptedKVStore.fileExtension)"
            let fileURL = cacheDir.appendingPathComponent(relativePath)
            let meta = EncryptedKVStoreMetadata(
                modelHash: binding.modelHash,
                modelDtype: binding.modelDtype,
                modelArch: binding.modelArch,
                vocabSize: binding.vocabSize,
                numLayers: binding.numLayers,
                kvHeads: binding.kvHeads,
                headDim: binding.headDim,
                tokenCount: snap.tokenCount,
                tokenPrefixHash: digestHex,
                kvCacheClass: "mixed",
                metaState: [layoutJSON],
                chunkPlaintextSizes: chunks.map { $0.count },
                createdAt: now(),
                expiresAt: expiresAtForWrite(),
                scope: scope
            )
            try await EncryptedKVStore.write(to: fileURL, metadata: meta, chunks: chunks, kek: kek)

            #if DEBUG
            if let hook = _afterWriteHookForTest { await hook() }
            #endif
            // Deregistered (closed) DURING the write await.
            // Skip record/save/notify; leave the file for the new manager's
            // reconcile to reclaim (never cross-actor live-deleted). See store()
            // for the full rationale. The defer above drops the in-flight marker.
            if closed { return false }

            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileBytes = (attrs?[.size] as? Int) ?? 0
            index.record(PrefixIndexEntry(
                modelHash: binding.modelHash, digestHex: digestHex,
                tokenCount: snap.tokenCount, relativePath: relativePath,
                fileBytes: fileBytes, createdAt: now(), lastHitAt: now()
            ))

            stats.ssdFlushes += 1
            enforceDiskBudget(index: index, cacheDir: cacheDir)

            unsavedWrites += 1
            if unsavedWrites >= Self.saveCoalesceThreshold {
                if (try? index.save()) != nil { unsavedWrites = 0 }
            }
            // Phase 3: notify the accountant after byte-changing op.
            await notifyAccountant()
            return true
        } catch {
            logger.warning("persistDigest: failed for \(digestHex, privacy: .public): \(String(describing: error))")
            return false
        }
    }

    /// Evict least-recently-hit checkpoints (file + index entry together)
    /// until this model's on-disk usage is within `diskBudgetBytes`. Without
    /// this, sustained diverse-prompt traffic grows the SSD cache and
    /// index.json without bound and can fill the volume. 0 budget = no cap.
    ///
    /// TB-016 sub-feature C: Uses benefit-per-byte scoring instead of LRU.
    /// Proactively drop SSD entries past the sliding TTL (file + index entry),
    /// independent of the disk budget. Runs at load-time reconcile so expired
    /// KV is reclaimed even for a model that's never looked up again; the
    /// loadFromSSD check covers steady-state. No-op when TTL is disabled or the
    /// manager is closed (a closed manager must not mutate a handed-off dir).
    private func reapExpired(index: PrefixCacheIndex, cacheDir: URL) {
        guard !closed, ttlSeconds > 0 else { return }
        for entry in index.entries(modelHash: binding.modelHash) where isExpired(lastHitAt: entry.lastHitAt) {
            let url = cacheDir.appendingPathComponent(
                "\(modelDirComponent)/\(entry.digestHex).\(EncryptedKVStore.fileExtension)")
            try? FileManager.default.removeItem(at: url)
            index.remove(modelHash: binding.modelHash, digestHex: entry.digestHex)
            stats.ttlExpirations += 1
        }
    }

    private func enforceDiskBudget(index: PrefixCacheIndex, cacheDir: URL) {
        guard diskBudgetBytes > 0 else { return }
        var total = index.bytes(modelHash: binding.modelHash)
        guard total > diskBudgetBytes else { return }
        // Evict LOWEST-score entries first (benefit-per-byte, recency-weighted).
        for entry in index.entriesByScoreAscending(
            modelHash: binding.modelHash,
            now: now(),
            prefillCostPerToken: prefillCostPerToken,
            halfLifeSeconds: evictionHalfLifeSeconds
        ) {
            if total <= diskBudgetBytes { break }
            let url = cacheDir.appendingPathComponent(
                "\(modelDirComponent)/\(entry.digestHex).\(EncryptedKVStore.fileExtension)")
            try? FileManager.default.removeItem(at: url)
            index.remove(modelHash: binding.modelHash, digestHex: entry.digestHex)
            // The RAM tier keeps its own byte/entry LRU budget; a now-stale
            // RAM copy just serves from memory (no SSD file needed), so we
            // don't force-evict it here — only the on-disk footprint is bounded.
            total -= max(0, entry.fileBytes)
            stats.diskEvictions += 1
        }
    }

    // MARK: - Phase 3: Global disk accountant integration

    /// PrefixCacheOwner conformance: evict lowest-score entries to free at
    /// least `targetBytesToFree`. Called by the global disk accountant when
    /// the process-wide disk budget is exceeded. Reuses the enforceDiskBudget
    /// loop body (entriesByScoreAscending → removeItem + index.remove + stats,
    /// stop when freed >= target, coalesced index.save). Returns bytes freed.
    /// Runs on this actor's executor (auto-serialized vs flush/lookup/load).
    public func evictForGlobalBudget(targetBytesToFree: Int) async -> Int {
        guard !closed else { return 0 }
        guard let index, let cacheDir else { return 0 }
        guard targetBytesToFree > 0 else { return 0 }

        var freed = 0
        // Evict LOWEST-score entries first (benefit-per-byte, recency-weighted).
        for entry in index.entriesByScoreAscending(
            modelHash: binding.modelHash,
            now: now(),
            prefillCostPerToken: prefillCostPerToken,
            halfLifeSeconds: evictionHalfLifeSeconds
        ) {
            if freed >= targetBytesToFree { break }
            let url = cacheDir.appendingPathComponent(
                "\(modelDirComponent)/\(entry.digestHex).\(EncryptedKVStore.fileExtension)")
            try? FileManager.default.removeItem(at: url)
            index.remove(modelHash: binding.modelHash, digestHex: entry.digestHex)
            freed += max(0, entry.fileBytes)
            stats.diskEvictions += 1
        }

        // Coalesced index save (same logic as flushToSSD).
        if freed > 0 {
            unsavedWrites += 1
            if unsavedWrites >= Self.saveCoalesceThreshold {
                if (try? index.save()) != nil { unsavedWrites = 0 }
            }
            // Refresh the accountant after global-budget eviction so
            // runningTotals + valueSummaries reflect the post-eviction state
            // (freed bytes + removed entries). Without this, stale valueSummaries
            // cause the accountant to re-select the just-evicted ghosts on the
            // next enforce (a between-tick updateUsage from another model).
            await notifyAccountant()
        }

        return freed
    }

    /// Build value summary for the accountant: [EntryValue] with one entry
    /// per SSD file, including (modelKey, digestHex, fileBytes, score).
    /// Called after each byte-changing op (flush/persist/eviction) to push
    /// updated totals + summaries to the accountant.
    private func buildValueSummary() -> [EntryValue] {
        guard let index else { return [] }
        return index.entriesByScoreAscending(
            modelHash: binding.modelHash,
            now: now(),
            prefillCostPerToken: prefillCostPerToken,
            halfLifeSeconds: evictionHalfLifeSeconds
        ).map { entry in
            // Owned entries pass fileURL=nil; the accountant will
            // reconstruct from digestHex (safe: owned entries are never deleted
            // by the unowned path that had the traversal hole).
            EntryValue(
                modelKey: modelKey,
                digestHex: entry.digestHex,
                fileBytes: entry.fileBytes,
                score: PrefixCacheIndex.benefitScore(
                    entry, now: now(),
                    prefillCostPerToken: prefillCostPerToken,
                    halfLifeSeconds: evictionHalfLifeSeconds
                ),
                fileURL: nil
            )
        }
    }

    /// Push updated usage to the accountant after a byte-changing op.
    /// Cheap O(this-model-entries) push, no tree walk. No-op when accountant is nil.
    ///
    /// Gated on `accountantToken != nil`: a usage push BEFORE this manager is
    /// registered (e.g. the detached Task fired by the synchronous
    /// reconcileWithDisk, which runs before registerWithAccountant) would reach
    /// the accountant while this model is still absent from its registry. If the
    /// reconciled footprint already exceeds the global ceiling, the accountant
    /// would classify this not-yet-owned model as UNOWNED and DIRECT-DELETE its
    /// live checkpoint files — the cross-actor live-delete the design forbids.
    /// Dropping the pre-registration push is safe: registerWithAccountant does
    /// the initial usage push itself, right after registration.
    /// Pass the token so stale detached Tasks are NO-OP.
    private func notifyAccountant() async {
        // Also guard on !closed — a stale unstructured notify
        // Task (e.g. from reconcileWithDisk) could otherwise re-add this model's
        // runningTotals/valueSummaries after deregistration.
        guard let accountant, let index, let token = accountantToken, !closed else { return }
        let totalBytes = index.bytes(modelHash: binding.modelHash)
        let valueSummary = buildValueSummary()
        await accountant.updateUsage(token: token, totalBytes: totalBytes, valueSummary: valueSummary)
    }

    /// CLAIM ownership with the accountant BEFORE reconcileWithDisk runs.
    /// reconcileWithDisk mutates this model's files/index (reclaims orphans,
    /// drops vanished entries), and the accountant's tick() direct-deletes any
    /// dir whose modelKey is NOT in its registry. If we registered only AFTER
    /// reconcile, a concurrent tick (triggered by another already-registered
    /// model pushing the global total over ceiling) would classify this live,
    /// mid-reconcile dir as UNOWNED and delete its files — a cross-actor
    /// live-delete. Claiming first makes tick skip the dir. No usage is pushed
    /// here (reconcile hasn't run); call publishUsageToAccountant() after.
    public func claimAccountantRegistration() async {
        guard let accountant, accountantToken == nil, !closed else { return }
        let token = await accountant.register(modelKey: modelKey, owner: self)
        // if deregisterFromAccountant() ran DURING the register
        // await, it saw accountantToken == nil and returned without deregistering
        // — leaving a dead (closed) manager registered. Detect that here and undo
        // the registration so the accountant never holds a closed owner (whose
        // evictForGlobalBudget returns 0 while tick treats the dir as "owned").
        if closed {
            await accountant.deregister(token)
        } else {
            accountantToken = token
        }
    }

    /// Push the post-reconcile usage to the accountant (call AFTER reconcile +
    /// claimAccountantRegistration). Accounts the reconciled footprint as OWNED
    /// so it isn't invisible until the next flush.
    public func publishUsageToAccountant() async {
        await notifyAccountant()
    }

    /// Back-compat single call: claim + publish. (Tests / callers that don't
    /// need the reconcile window split.)
    public func registerWithAccountant() async {
        await claimAccountantRegistration()
        await publishUsageToAccountant()
    }

    /// Deregister from the accountant (called on unload). Sets `closed` FIRST so
    /// any in-flight/queued capture or promotion Task (which holds its own `self`
    /// reference and outlives the BatchScheduler dropping the manager) cannot
    /// write to SSD after deregistration — otherwise such a write would look
    /// unowned to the accountant, or race a newly-loaded manager that reuses the
    /// same modelKey (same modelId). No-op when accountant is nil.
    public func deregisterFromAccountant() async {
        closed = true
        // Drain in-flight writes BEFORE deregistering. A detached
        // capture/promotion Task may be suspended inside EncryptedKVStore.write;
        // its file lands on the atomic rename when it resumes. loadModel awaits
        // stopCurrentEngine() -> this method fully before it constructs and
        // reconciles a new same-modelKey manager, so waiting for quiescence here
        // guarantees every such file is on disk before the new manager's one-shot
        // reconcileWithDisk runs (which re-indexes it). Without the drain, a late
        // rename orphans the file: in no index, and tick() skips the now-owned
        // dir until the next unload. The post-write `closed` bail still prevents
        // the stale Task from recording/notifying (cross-actor safety); this only
        // makes teardown WAIT for the bytes to land so reconcile can reclaim them.
        await drainInFlightWrites()
        guard let accountant, let token = accountantToken else { return }
        await accountant.deregister(token)
        accountantToken = nil
    }

    /// Suspend until `inFlightWrites` is empty (all in-flight write Tasks have
    /// completed their EncryptedKVStore.write, so their files have landed). Each
    /// write's `finishWrite` resumes parked waiters when it empties the set.
    private func drainInFlightWrites() async {
        guard !inFlightWrites.isEmpty else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            drainContinuations.append(cont)
        }
    }

    /// Remove a digest from `inFlightWrites` and, if that drained the set, resume
    /// any teardown waiters parked in `drainInFlightWrites`. Replaces bare
    /// `inFlightWrites.remove(_:)` at every write-completion site.
    private func finishWrite(_ digestHex: String) {
        inFlightWrites.remove(digestHex)
        if inFlightWrites.isEmpty, !drainContinuations.isEmpty {
            let waiters = drainContinuations
            drainContinuations.removeAll()
            for w in waiters { w.resume() }
        }
    }

    // MARK: - Clear

    public func clearRAM() {
        ram.clear(modelHash: binding.modelHash)
    }
}

// MARK: - Hex decode

extension Data {
    /// Decode a lowercase/uppercase hex string. Returns nil on odd
    /// length or a non-hex character.
    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
            i += 2
        }
        self = Data(bytes)
    }
}
