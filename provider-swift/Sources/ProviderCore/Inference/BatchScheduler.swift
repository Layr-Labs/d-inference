// Copyright © 2026 Eigen Labs.
//
// Continuous-batching inference scheduler for the Darkbloom provider.
// Wraps `MLXLMCommon.BatchedEngine` with the provider-specific policy
// layer: GPU enforcement, byte-level KV budgets, admission control,
// pending-queue timeouts, and the adaptive concurrency cap.
//
// The engine itself drives the GPU step loop on its own dispatch queue;
// this actor's job is to gate submission, surface capacity, and bridge
// per-request `RequestOutput` streams to our public `GenerationEvent`
// stream.
//
// This file holds the actor declaration, instance state, public
// surface (`init`/`loadModel`/`unloadModel`/`submit`/`cancel`/
// `cancelAll`/`capacity`) and tiny internal helpers used by all
// extensions. Bigger units of behaviour live in:
//
//   * `BatchSchedulerTypes.swift`        — supporting types
//   * `BatchScheduler+EngineBridge.swift`— per-request stream bridge,
//                                           bridge bookkeeping, the
//                                           pending-timeout watchdog
//   * `BatchScheduler+KVEstimation.swift`— pure config.json parsing +
//                                           KV-bytes math (no actor
//                                           state)
//   * `BatchScheduler+Telemetry.swift`   — `backendCapacity` heartbeat,
//                                           EWMA + adaptive cap,
//                                           pending-summary cache

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os

// `internal` (not `private`) so the BatchScheduler extension files
// (e.g. +EngineBridge) can log under the same category.
let prefixCacheLogger = Logger(subsystem: "dev.darkbloom.provider", category: "prefix-cache-wiring")

/// Continuous-batching scheduler. Wraps a single `MLXLMCommon.BatchedEngine`
/// per loaded model. The engine owns the GPU step loop; this actor owns
/// admission control, KV-byte budgeting, the pending-queue timeout, and
/// the adaptive concurrency cap.
public actor BatchScheduler {

    // MARK: - Configuration (immutable after init)

    let maxConcurrentRequests: Int
    let pendingTimeout: Duration
    /// Default max output tokens when the consumer omits `max_tokens`.
    /// Starts at the init value (typically 4096) and is raised post-load
    /// when the model's context length is known.
    var defaultMaxTokens: Int
    let kvBudget: GlobalKVCacheBudget?
    /// Phase 3: global disk accountant (process-wide, shared across models).
    /// nil ⇒ today's per-model disk budget behavior.
    let diskAccountant: GlobalDiskAccountant?
    let adaptiveCapPolicy = AdaptiveBatchCapPolicy.default

    // MARK: - Model-specific state (set by `loadModel`)

    var modelContainer: ModelContainer?
    var modelId: String = ""
    var modelWeightBytes: Int = 0
    var kvBytesPerToken: Int = 400_000
    var dynamicTokenBudgetMax: Int = 0
    /// The model's maximum context window read from config.json
    /// (`max_position_embeddings`). Used to size `maxTokensPerBatch`
    /// so prompts up to the model's context length are admissible.
    var maxContextLength: Int = 0
    var tokenizer: TokenizerHandle?
    var engine: BatchedEngine?

    /// Checkpoint-tier KV cache for hybrid sliding-window models (Gemma-4,
    /// GPT-OSS). Non-nil only when the model's caches classify as
    /// `.checkpoint` AND the prefix cache is enabled (on by default; opt out
    /// with `DARKBLOOM_PREFIX_CACHE=0`) — mutually exclusive with the engine
    /// block tier, which serves pure-attention `.engine` models. Looked up in
    /// `submit` to seed a request's `restoredCheckpoint`; stored to via the
    /// scheduler's capture hook. nil ⇒ feature off for this model.
    var checkpointManager: PrefixCacheManager?
    /// Sliding-window-derived checkpoint boundaries for the current model.
    var checkpointBoundaries: [Int] = []

    /// Engine-tier owner (EncryptedPrefixCachePersistence) for pure-
    /// attention models. Non-nil only when the model classifies as `.engine` AND
    /// the prefix cache flag is on. Registered with the accountant at load time,
    /// deregistered at stopCurrentEngine.
    var engineTierOwner: EncryptedPrefixCachePersistence?
    var engineTierAccountantToken: AccountantToken?

    /// Admission control + token budget tracking. `nil` until `loadModel()`.
    var planner: BatchQueuePlanner?

    /// Watchdog for planner-pending requests that exceed `pendingTimeout`.
    var pendingTimeoutTask: Task<Void, Never>?

    /// Periodic prefix-cache hit/miss stats logger. Started in `loadModel`
    /// when a checkpoint-tier manager is installed, cancelled in
    /// `stopCurrentEngine`. Logs a single line per interval so operators (and
    /// soak harnesses) can read the live hit rate, which `snapshotStats()`
    /// otherwise only exposes to in-process tests. Covers the CHECKPOINT tier
    /// only — the engine tier (`EncryptedPrefixCachePersistence`) keeps no
    /// hit/miss counters, so pure-attention `.engine` models log nothing here.
    var prefixCacheStatsTask: Task<Void, Never>?
    /// Interval (seconds) for the stats logger. Default 120s when a checkpoint
    /// manager is active (one info line every two minutes is negligible even
    /// across a fleet, and gives hit-rate observability out of the box). A
    /// positive `DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS` overrides the
    /// interval; `0` disables the logger entirely; a malformed value falls back
    /// to the default.
    static let defaultPrefixCacheStatsIntervalSecs = 120
    static func prefixCacheStatsIntervalSecs() -> Int {
        resolveStatsInterval(
            env: ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS"])
    }

    /// Pure stats-interval policy (testable). Unset / malformed / negative ⇒
    /// default; `0` ⇒ disabled; a positive value sets the cadence in seconds.
    static func resolveStatsInterval(env: String?) -> Int {
        guard let v = env else { return defaultPrefixCacheStatsIntervalSecs }
        guard let n = Int(v), n >= 0 else { return defaultPrefixCacheStatsIntervalSecs }
        return n  // n == 0 ⇒ disabled
    }
    /// Bumped on every `loadModel` / `stopCurrentEngine` so stale model
    /// loads can detect they've been superseded.
    var generationEpoch: UInt64 = 0

    // MARK: - Per-request state (mutated by bridge + admission paths)

    /// Populated in `submit(...)` before `engine.core.addRequest`; torn
    /// down by the per-request streaming Task on finish/abort.
    var activeBridges: [String: BridgeState] = [:]
    /// Bridges aborted by the pending-timeout watchdog. Drives the
    /// distinct "request timed out waiting for capacity" error string
    /// (vs. "request cancelled" for client-initiated aborts).
    var timedOutBridges: Set<String> = []

    // MARK: - Telemetry state (read by `backendCapacity`)

    var observedDecodeTpsEwma: Double = 0
    var ewmaInitialized = false
    /// Per-batch-size TPS samples that drive `AdaptiveBatchCapPolicy`.
    var performanceByBatchSize: [Int: AdaptiveBatchPerformanceBucket] = [:]
    var lastBatchSampleAt: ContinuousClock.Instant = .now
    var dynamicMaxConcurrentRequests: Int
    var pendingSummaryCache: PendingSummary = .empty

    /// Memory-kind selector for `gpuMemory(_:)` in the telemetry extension.
    enum MemoryKind { case active, peak, cache }

    // Computed admission / capacity properties (tokenBudgetMax,
    // activeTokenBudgetUsed, effectiveMaxConcurrentRequests, etc.)
    // live in `BatchScheduler+Telemetry.swift` next to the heartbeat
    // surface that consumes them.

    // MARK: - Init

    /// The init-time default; restored on `stopCurrentEngine()`.
    private let initDefaultMaxTokens: Int

    public init(
        maxConcurrentRequests: Int = 4,
        pendingTimeout: Duration = .seconds(120),
        defaultMaxTokens: Int = 4096,
        kvBudget: GlobalKVCacheBudget? = nil,
        diskAccountant: GlobalDiskAccountant? = nil
    ) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.pendingTimeout = pendingTimeout
        self.defaultMaxTokens = defaultMaxTokens
        self.initDefaultMaxTokens = defaultMaxTokens
        self.kvBudget = kvBudget
        self.diskAccountant = diskAccountant
        self.dynamicMaxConcurrentRequests = min(4, max(1, maxConcurrentRequests))
    }

    // MARK: - Model lifecycle

    public func loadModel(container: ModelContainer, modelId: String, weightHash: String? = nil) async {
        // Hard-fail if Metal is unavailable; CPU inference is not acceptable.
        do {
            _ = try GPUEnforcement.requireMetal()
        } catch {
            FileHandle.standardError.write(Data(
                "[FATAL] Cannot load model: \(error)\n".utf8
            ))
            return
        }

        await stopCurrentEngine()
        let loadEpoch = generationEpoch

        let snapshot = await Self.snapshotContainer(container)
        // Detect concurrent reload that won the race; bail before we
        // overwrite the new model's state with our stale snapshot.
        guard loadEpoch == generationEpoch else { return }

        self.modelContainer = container
        self.modelId = modelId
        self.modelWeightBytes = snapshot.bytes
        self.tokenizer = snapshot.tokenizer

        let build = await Self.makeBatchedEngine(
            container: container,
            modelId: modelId,
            weightHash: weightHash,
            weightBytes: snapshot.bytes,
            maxConcurrentRequests: maxConcurrentRequests,
            eosTokenIds: snapshot.eosTokenIds,
            architecture: snapshot.architecture,
            diskAccountant: diskAccountant
        )
        let engine = build.engine
        // Re-check epoch after the engine.start suspension. If another
        // load/unload won the race, tear down the engine we just built
        // and bail before we overwrite the winner's state.
        guard loadEpoch == generationEpoch else {
            await engine.stop()
            return
        }
        self.engine = engine
        self.checkpointManager = build.checkpointManager
        self.checkpointBoundaries = build.checkpointBoundaries
        self.engineTierOwner = build.engineTierOwner
        await engine.start()
        // Final epoch check after start() — start can suspend too.
        // Identity-checked cleanup — only nil self.engine if it's
        // the one THIS load assigned (self.engine === engine). If a newer load
        // already replaced it, leave the winner's self.* intact.
        guard loadEpoch == generationEpoch else {
            if self.engine === engine { self.engine = nil }
            if self.checkpointManager === build.checkpointManager { self.checkpointManager = nil }
            if self.checkpointBoundaries == build.checkpointBoundaries { self.checkpointBoundaries = [] }
            if self.engineTierOwner === build.engineTierOwner { self.engineTierOwner = nil }
            await engine.stop()
            return
        }

        // Crash-consistency: reconcile the on-disk checkpoint files against
        // the index once, before serving. Reclaims orphans left by a crash
        // inside the index save-coalescing window (so they count toward the
        // disk budget and are reusable) and drops index entries whose files
        // vanished. Safe here: no requests admitted yet, so no concurrent
        // flush/lookup races the reconcile.
        if let mgr = checkpointManager {
            // Phase 3: CLAIM accountant ownership BEFORE reconcile.
            // reconcileWithDisk mutates this model's files/index; if we registered
            // only after, a concurrent accountant tick (another model pushed the
            // global total over ceiling) would see this live, mid-reconcile dir
            // as UNOWNED and direct-delete its files. Claiming first makes tick
            // skip it. Usage is published AFTER reconcile (reconciled footprint).
            // claimAccountantRegistration is internally guarded: if this load was
            // superseded (stopCurrentEngine ran during the await → manager closed),
            // it deregisters the just-claimed token rather than registering a dead
            // manager.
            await mgr.claimAccountantRegistration()
            // Re-check epoch after claimAccountantRegistration's
            // await. If a newer load/unload superseded us during that await, this
            // manager was closed by stopCurrentEngine — do NOT reconcile/publish.
            // reconcileWithDisk now also self-guards on `closed` (defence in
            // depth), but bailing here avoids touching the accountant for a dead
            // manager and falls through to the identity-checked cleanup below.
            if loadEpoch == generationEpoch {
                await mgr.reconcileWithDisk()
                await mgr.publishUsageToAccountant()
            }
        }
        // re-check epoch after the checkpoint setup awaits. If a
        // newer load/unload superseded us, bail (the manager already deregistered
        // itself via the closed-guard above; nil it so we don't serve stale).
        // Identity-checked cleanup (same as above).
        guard loadEpoch == generationEpoch else {
            if self.engine === engine { self.engine = nil }
            if self.checkpointManager === build.checkpointManager { self.checkpointManager = nil }
            if self.checkpointBoundaries == build.checkpointBoundaries { self.checkpointBoundaries = [] }
            if self.engineTierOwner === build.engineTierOwner { self.engineTierOwner = nil }
            await engine.stop()
            return
        }

        // Register the engine-tier owner with the accountant.
        // Without this, the engine tier's live dir is UNOWNED → tick() directly
        // deletes its files, racing saveBlock/loadBlock (cross-actor live-delete).
        if let owner = engineTierOwner, let accountant = diskAccountant {
            let token = await accountant.register(
                modelKey: owner.modelKey,  // need to expose modelKey on the owner
                owner: owner)
            // if this load was superseded during register's
            // await, undo the registration so we don't leave a stale engine owner.
            if loadEpoch != generationEpoch {
                await accountant.deregister(token)
                owner.setAccountantToken(nil)
            } else {
                engineTierAccountantToken = token
                // Thread the token through to the owner so its usage
                // pushes are token-scoped (stale detached Tasks are NO-OP).
                owner.setAccountantToken(token)
                // Publish the pre-existing flat
                // files NOW so they count against the global budget immediately,
                // not only once a later saveBlock crosses the debounce.
                await owner.publishUsageNow()
                // Re-check epoch after publishUsageNow() await. If
                // superseded, deregister the engine-tier token and bail without
                // touching the winner's planner/watchdog.
                guard loadEpoch == generationEpoch else {
                    await accountant.deregister(token)
                    owner.setAccountantToken(nil)
                    if self.engineTierAccountantToken == token {
                        self.engineTierAccountantToken = nil
                    }
                    if self.engine === engine { self.engine = nil }
                    if self.checkpointManager === build.checkpointManager { self.checkpointManager = nil }
                    if self.checkpointBoundaries == build.checkpointBoundaries { self.checkpointBoundaries = [] }
                    if self.engineTierOwner === build.engineTierOwner { self.engineTierOwner = nil }
                    await engine.stop()
                    return
                }
            }
        }

        applyPostLoadBudgets(snapshot: snapshot)
        // Apply the conservative startup cap before admitting any request,
        // otherwise the first few submits could run at the hard cap until
        // the adaptive policy kicks in.
        engine.setMaxNumSeqs(dynamicMaxConcurrentRequests)
        self.planner = makePlanner(activeTokenBudget: tokenBudgetMax)
        // Engine has no pending-queue TTL; we enforce `pendingTimeout`.
        startPendingTimeoutWatchdog()
        // Periodic checkpoint-tier hit/miss logger (no-op if disabled or
        // engine-tier model). Cancelled in stopCurrentEngine.
        startPrefixCacheStatsLogger()
    }

    /// Snapshot model bytes + tokenizer + architecture out of the
    /// container. Runs inside `container.perform` (off-actor); returns
    /// a Sendable struct so the actor can resume on its own executor.
    private static func snapshotContainer(_ container: ModelContainer) async -> LoadSnapshot {
        await container.perform { ctx in
            let bytes = ctx.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }

            // Read architecture from config.json: covers hybrid models
            // (Gemma 3/3n/4) that don't conform to KVCacheDimensionProvider.
            let architecture: ModelArchitecture
            if case .directory(let modelDir) = ctx.configuration.id {
                let configURL = modelDir.appendingPathComponent("config.json")
                architecture = KVEstimation.parseModelArchitecture(at: configURL)
            } else {
                architecture = .empty
            }
            return LoadSnapshot(
                bytes: bytes,
                tokenizer: TokenizerHandle(ctx.tokenizer),
                eosTokenIds: ctx.configuration.eosTokenIds,
                architecture: architecture
            )
        }
    }

    /// Build a `BatchedEngine` with our scheduler config. Pulled out
    /// of `loadModel` so the lifecycle code reads as a sequence of
    /// 5-line steps. SECURITY (TB-007): the engine's prefix cache
    /// persists token sequences across requests in process memory.
    /// Cross-tenant data-leak risk; do not enable without a fresh
    /// threat model.
    /// Checkpoint-tier lookup: on a hit, attach the restored per-layer caches
    /// to the request so the scheduler decodes only the suffix. No-op when
    /// the checkpoint manager is nil (engine/none models, or flag off). Done
    /// in the async submit path because the engine step loop can't await the
    /// manager actor. The tokenCount guard mirrors the scheduler's so a
    /// degenerate hit (no suffix) is never attached.
    private func maybeRestoreCheckpoint(_ req: Request, promptTokens: [Int], scope: String) async {
        guard let mgr = checkpointManager else { return }
        guard let hit = await mgr.lookup(tokens: promptTokens, scope: scope),
              hit.tokenCount >= 1, hit.tokenCount < promptTokens.count
        else { return }
        req.restoredCheckpoint = (caches: hit.caches, tokenCount: hit.tokenCount)
    }

    /// Stale-engine enqueue guard: `submit`/`submitTokenized` capture
    /// `engine` at the top, then `await` planner admission, KV reservation, and
    /// checkpoint restore before `engine.core.addRequest`. A concurrent
    /// `stopCurrentEngine()`/`loadModel()` can bump `generationEpoch` and
    /// `engine.stop()` the captured engine during those awaits — enqueuing onto a
    /// stopped/superseded engine (request hangs / lands on the wrong model).
    /// Returns true iff `capturedEpoch` still matches AND `self.engine` is still
    /// the captured instance, so the caller may proceed to addRequest. The
    /// epoch + identity pair mirrors the load-side guards in `loadModel`.
    private func engineStillCurrent(_ capturedEpoch: UInt64, _ capturedEngine: BatchedEngine) -> Bool {
        capturedEpoch == generationEpoch && self.engine === capturedEngine
    }

    /// Stale-engine enqueue guard, part 2: the pre-`addRequest` guard
    /// (`engineStillCurrent`) is necessary but NOT sufficient. `EngineCore.addRequest`
    /// does the real `scheduler.addRequest` inside an `engineQueue.async` block
    /// with no `_running` check, and `stopCurrentEngine`'s `abortAllRequests()`
    /// snapshots the collector keys BEFORE dispatching aborts — so a stop that
    /// interleaves between our guard and the queued add executing will (a) miss
    /// this request in the abort snapshot and (b) still run `scheduler.addRequest`
    /// on a stopped scheduler → the request never steps and the stream hangs.
    /// `addRequest`'s continuation resumes only AFTER its queued block ran, so by
    /// the time this is called the request IS registered. Two ways it can be
    /// unsafe to proceed to `runBridge`:
    ///
    ///   1. The engine was superseded (reload/unload) during the submit awaits —
    ///      `!engineStillCurrent`. The add landed on a stopped/replaced engine.
    ///   2. The request was cancelled or timed out WHILE the submit task was
    ///      suspended (planner.admit / KV reserve / checkpoint restore). The
    ///      cancel path / pending-timeout watchdog called `abortRequest` — which
    ///      no-op'd because the engine had no collector yet — and `dropBridge`'d
    ///      this id, so its bridge is gone from `activeBridges`. The submit task
    ///      then resumed and enqueued the request anyway; without this check it
    ///      would run untracked (KV/planner budget not accounted, no bridge to
    ///      tear it down) — the residual gap left after the pre-registration
    ///      cleanup fix.
    ///
    /// In either case abort the just-added request on the engine we added to
    /// (removes it from the scheduler and delivers a terminal output to unblock
    /// any stream) and release this request's resources. Returns true iff safe
    /// to runBridge.
    private func confirmEnqueuedOrAbort(
        requestId: String, capturedEpoch: UInt64, capturedEngine: BatchedEngine
    ) async -> Bool {
        let superseded = !engineStillCurrent(capturedEpoch, capturedEngine)
        let bridgeDropped = activeBridges[requestId] == nil
        if !superseded && !bridgeDropped { return true }
        _ = capturedEngine.core.abortRequest(requestId)
        await releaseRequestResources(requestId)
        return false
    }

    /// Release everything a request holds, regardless of how far submit got.
    /// dropBridge handles the normal case (bridge still present → removes it,
    /// releases KV, cancels the planner, refreshes the summary), but it guards
    /// ALL of that behind "bridge was present", so it's a full no-op when the
    /// cancel/timeout path already removed the bridge — and that path can run
    /// BEFORE this submit reserved KV (cancel fires during planner.admit; the
    /// resumed submit then reserves at kvBudget.reserve). That late reservation
    /// would otherwise leak. So also release KV + cancel the planner entry
    /// UNCONDITIONALLY (both are idempotent: release/cancel on an unknown id is a
    /// no-op). Safe to call whether or not the bridge is still present.
    /// `internal` (not `private`) so the leak regression test can drive it
    /// directly — the full submit→cancel→resume interleaving needs a live engine.
    func releaseRequestResources(_ requestId: String) async {
        await dropBridge(requestId: requestId)
        await releaseKVReservation(requestID: requestId)
        if let planner = self.planner {
            _ = await planner.cancel(requestID: requestId)
        }
    }

    /// TEST SEAM: install a checkpoint manager + capture hook onto the live
    /// engine, replicating exactly what `makeBatchedEngine` wires for a
    /// `.checkpoint` model. Production builds the manager with an SE-wrapped
    /// Keychain KEK, which an UNSIGNED `swift test` binary can't create
    /// (errSecMissingEntitlement) — so the end-to-end serve-loop test injects
    /// a manager with an in-memory KEK here to exercise the real
    /// submit→lookup→admit→capture path that the SE gate otherwise blocks.
    /// Must be called after `loadModel`. Not used in production.
    func _installCheckpointManagerForTest(_ mgr: PrefixCacheManager, boundaries: [Int]) {
        self.checkpointManager = mgr
        self.checkpointBoundaries = boundaries
        engine?.core.scheduler.checkpointBoundaries = boundaries
        engine?.core.scheduler.onCheckpointCapture = { prefixTokens, length, caches in
            let box = SendableKVCaches(caches)
            // TB-016 sub-feature B: test seam also RAM-only (no eager flush).
            Task { await mgr.store(tokens: prefixTokens, checkpointLength: length, caches: box) }
        }
    }

    /// Result of building the engine: the engine itself plus the optional
    /// checkpoint-tier manager + its boundaries (non-nil only for hybrid
    /// `.checkpoint` models with the flag on). The caller stores the manager
    /// on the actor and uses it for `submit`-time lookup.
    /// Added engineTierOwner (EncryptedPrefixCachePersistence) for
    /// accountant registration when strategy == .engine.
    struct EngineBuild {
        let engine: BatchedEngine
        let checkpointManager: PrefixCacheManager?
        let checkpointBoundaries: [Int]
        let engineTierOwner: EncryptedPrefixCachePersistence?
    }

    private static func makeBatchedEngine(
        container: ModelContainer,
        modelId: String,
        weightHash: String?,
        weightBytes: Int,
        maxConcurrentRequests: Int,
        eosTokenIds: Set<Int>,
        architecture: ModelArchitecture,
        diskAccountant: GlobalDiskAccountant? = nil
    ) async -> EngineBuild {
        // TB-007: the prefix cache is ON by default (operator decision) with an
        // ENCRYPTED-at-rest backend; opt out with DARKBLOOM_PREFIX_CACHE=0.
        // Encryption does NOT close the in-process cross-tenant sharing / TTFT
        // side-channel — untrusted multi-tenant deployments must opt out. See
        // docs/ssd-kv-cache-design.md.
        //
        // Two mutually-exclusive tiers, selected by the model's cache types
        // (PrefixCacheStrategy): pure-attention (.engine) models use the
        // in-GPU block PrefixCache; hybrid sliding-window (.checkpoint) models
        // (Gemma-4, GPT-OSS) use the whole-cache exact-checkpoint
        // PrefixCacheManager. Recurrent (.none) models get neither.
        let blockSize = 256
        let backing = await makePrefixCacheBackingIfEnabled(
            modelId: modelId, weightHash: weightHash, architecture: architecture
        )
        let kvBytesPerToken = resolvedKVBytesPerToken(architecture: architecture, weightBytes: weightBytes)
        let maxBlocks = prefixCacheMaxBlocks(
            kvBytesPerToken: kvBytesPerToken,
            budgetBytes: prefixCacheBudgetBytes(),
            blockSize: blockSize
        )
        // now() for the manager index timestamps — wall clock is fine here.
        let nowFn: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }

        return await container.perform { ctx -> EngineBuild in
            // Classify from the model's own cache layout.
            let strategy = backing == nil
                ? PrefixCacheStrategy.none
                : PrefixCacheStrategy.classify(ctx.model.newCache(parameters: nil))

            var enginePrefixCache: PrefixCache? = nil
            var checkpointManager: PrefixCacheManager? = nil
            var boundaries: [Int] = []
            // Capture the engine-tier owner for accountant registration.
            var engineTierOwner: EncryptedPrefixCachePersistence? = nil

            if let backing {
                switch strategy {
                case .engine:
                    if maxBlocks >= 1 {
                        prefixCacheLogger.info(
                            "engine prefix cache: \(maxBlocks) blocks × \(blockSize) tok (~\(kvBytesPerToken) B/tok)")
                        // Keep a reference to the owner for registration.
                        let persistence = EncryptedPrefixCachePersistence(
                            kekKey: backing.kekKey, dir: backing.dir,
                            binding: backing.binding, diskBudgetBytes: backing.diskBudgetBytes,
                            accountant: diskAccountant, modelKey: backing.modelKey)
                        engineTierOwner = persistence
                        enginePrefixCache = PrefixCache(
                            config: PrefixCacheConfig(blockSize: blockSize, maxBlocks: maxBlocks),
                            modelName: modelId,
                            persistence: persistence)
                    } else {
                        prefixCacheLogger.warning(
                            "prefix cache disabled: model KV (\(kvBytesPerToken) B/tok) exceeds the memory budget for even one block")
                    }
                case .checkpoint:
                    // Boundaries capped at the smallest sliding window so a
                    // snapshot never claims tokens a window has discarded.
                    let window = PrefixCacheStrategy.minSlidingWindow(ctx.model.newCache(parameters: nil)) ?? 0
                    // TB-016 sub-feature A: lift ladder past window for proven
                    // families. Use modelId as the arch string (safe fallback;
                    // proven=false for unmatched families keeps today's ladder).
                    let maxContext = architecture.maxContextLength ?? 0
                    let proven = PrefixCachePastWindow.isProven(arch: modelId)
                    boundaries = PrefixDigest.checkpoints(
                        forSlidingWindow: window,
                        maxContext: maxContext,
                        pastWindowProven: proven
                    )
                    // Capture PER-LAYER [kvHeads, headDim] ground truth from a
                    // 1-token probe prefill. Heterogeneous models (Gemma-4:
                    // sliding [8,256] + full [2,512]) need this — a single
                    // (kvHeads, headDim) pair can't describe them and the
                    // load-time shape guard would reject the model's own files.
                    let layerShapes = Self.probeLayerShapes(model: ctx.model)
                    let checkpointBinding = PrefixCacheModelBinding(
                        modelHash: backing.binding.modelHash,
                        modelDtype: backing.binding.modelDtype,
                        modelArch: backing.binding.modelArch,
                        vocabSize: backing.binding.vocabSize,
                        numLayers: backing.binding.numLayers,
                        kvHeads: backing.binding.kvHeads,
                        headDim: backing.binding.headDim,
                        layerShapes: layerShapes)
                    checkpointManager = PrefixCacheManager(
                        binding: checkpointBinding,
                        // RAM tier respects the same memory budget as the
                        // engine block tier (DARKBLOOM_PREFIX_CACHE_MAX_GB).
                        ram: PrefixCacheRAM(maxBytes: prefixCacheBudgetBytes()),
                        index: PrefixCacheIndex(
                            fileURL: backing.dir.appendingPathComponent("index.json")),
                        kek: backing.kek,
                        cacheDir: backing.dir,
                        ssdEnabled: true,
                        boundaries: boundaries,
                        // Bound the on-disk checkpoint footprint (+ index.json)
                        // so sustained diverse traffic can't fill the volume —
                        // same 50%-of-free default as the block tier.
                        // Phase 3: when diskAccountant != nil, this becomes 0
                        // (unbounded) — accountant is sole authority.
                        diskBudgetBytes: backing.diskBudgetBytes,
                        // TB-016 sub-feature B: min persist threshold (16384
                        // for Gemma, 0 otherwise). Env override available.
                        minPersistTokens: Self.prefixCacheMinPersistTokens(arch: modelId),
                        now: nowFn,
                        accountant: diskAccountant,
                        modelKey: backing.modelKey)
                    prefixCacheLogger.info(
                        "checkpoint prefix cache: window \(window), boundaries \(boundaries)")
                case .none:
                    prefixCacheLogger.warning(
                        "prefix cache disabled: model has recurrent/unsupported cache layers")
                }
            }

            let scheduler = Scheduler(
                model: ctx.model,
                tokenizer: ctx.tokenizer,
                config: SchedulerConfig(
                    maxNumSeqs: maxConcurrentRequests,
                    maxNumBatchedTokens: 8192,
                    prefillStepSize: 512,
                    streamInterval: 1,
                    maxKVCacheTokens: 0  // unlimited — our kvBudget gates by bytes
                ),
                eosTokenIds: eosTokenIds,
                prefixCache: enginePrefixCache  // nil unless .engine + flag (TB-007)
            )
            // Wire the checkpoint capture hook: store snapshots to the manager
            // out-of-band (the hook is sync on the engine queue; storing hops
            // to the manager actor via a detached Task). nil-safe: only set
            // when a manager exists, so .engine/.none models are untouched.
            if let mgr = checkpointManager {
                scheduler.checkpointBoundaries = boundaries
                scheduler.onCheckpointCapture = { prefixTokens, length, caches in
                    let box = SendableKVCaches(caches)
                    // TB-016 sub-feature B: capture = RAM-ONLY. Store to RAM
                    // (fast); 2nd-use promotion handles SSD persistence when the
                    // prefix is re-accessed (RAM-first admission stops the write
                    // storm). No eager flushToSSD.
                    Task {
                        await mgr.store(tokens: prefixTokens, checkpointLength: length, caches: box)
                    }
                }
            }
            return EngineBuild(
                engine: BatchedEngine(
                    scheduler: scheduler,
                    tokenizer: ctx.tokenizer,
                    modelName: modelId,
                    config: ContinuousBatchingConfig(
                        schedulerConfig: scheduler.config,
                        stepInterval: 0.001,
                        prefixCacheConfig: nil,
                        mtpEnabled: false
                    ),
                    externalChatTemplate: nil
                ),
                checkpointManager: checkpointManager,
                checkpointBoundaries: boundaries,
                engineTierOwner: engineTierOwner
            )
        }
    }

    /// Shared encrypted-cache backing (KEK + per-model dir + MB-1 binding +
    /// disk budget) used by BOTH tiers: the engine block `PrefixCache`
    /// (pure-attention models) and the checkpoint `PrefixCacheManager`
    /// (hybrid models). Sendable: SymmetricKey/URL/struct/Int are all value
    /// types safe to hand into `container.perform`.
    struct PrefixCacheBacking: Sendable {
        let kekKey: SymmetricKey
        /// The KEK actor (already warmed via loadOrCreate) for the
        /// checkpoint-tier PrefixCacheManager, which takes the actor form.
        /// Shares the same persisted Keychain key as `kekKey`.
        let kek: KVCacheKEK
        let dir: URL
        let binding: PrefixCacheModelBinding
        let diskBudgetBytes: Int
        /// Phase 3: 12-char modelKey (sha256(modelId)[:12]) for accountant.
        let modelKey: String
    }

    /// Build the shared encrypted-cache backing. The prefix cache is ON BY
    /// DEFAULT; an operator opts OUT via `DARKBLOOM_PREFIX_CACHE=0` (also
    /// `false`/`off`/`no`). Returns nil (cache stays off) when explicitly
    /// disabled, the model architecture is incomplete, or the persisted KEK is
    /// unavailable (no Secure Enclave / entitlement) — in the last case we refuse
    /// rather than use an ephemeral key that wouldn't survive restart.
    ///
    /// SECURITY (TB-007): the prefix cache shares KV prefixes across consumers
    /// and the hit/miss TTFT difference is a cross-tenant timing side channel
    /// that encryption-at-rest does NOT mitigate. It is now default-on per an
    /// explicit operator decision; deployments that must not expose this channel
    /// (untrusted multi-tenant) set `DARKBLOOM_PREFIX_CACHE=0`. The cache is bound
    /// to the WEIGHT identity (`weightHash`) when known, not just the mutable
    /// model id — a re-download under the same id with different weights must not
    /// serve stale KV. Falls back to modelId when no weight hash is available.
    private static func makePrefixCacheBackingIfEnabled(
        modelId: String,
        weightHash: String?,
        architecture: ModelArchitecture
    ) async -> PrefixCacheBacking? {
        // Default ON: only an explicit opt-out disables it.
        let env = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE"]?
            .trimmingCharacters(in: .whitespaces).lowercased()
        let disabled = env == "0" || env == "false" || env == "off" || env == "no"
        guard !disabled else {
            prefixCacheLogger.info(
                "DARKBLOOM_PREFIX_CACHE is OFF (explicit opt-out) — prefix cache disabled.")
            return nil
        }

        prefixCacheLogger.warning(
            "Prefix cache is ON (default; opt out with DARKBLOOM_PREFIX_CACHE=0) — TB-007: cross-tenant sharing / TTFT side-channel; encrypted-at-rest only."
        )

        guard let numLayers = architecture.numLayers,
              let kvHeads = architecture.kvHeads,
              let headDim = architecture.headDim else {
            prefixCacheLogger.warning("prefix cache disabled: incomplete model architecture")
            return nil
        }

        // KEK must be SE-wrapped + Keychain-persisted so cache files
        // survive restart. If unavailable, disable rather than fall back
        // to an ephemeral key (which would silently break restart-reuse).
        let kekKey: SymmetricKey
        var kek: KVCacheKEK
        do {
            let se = try PersistentEnclaveKey.loadOrCreate()
            kek = KVCacheKEK(
                wrapper: SecureEnclaveKeyWrappingService(enclaveKey: se),
                storage: KeychainWrappedKEKStorage()
            )
            kekKey = try await kek.loadOrCreate()
        } catch {
            // STRESS/TEST-ONLY escape hatch: an UNSIGNED build (no
            // keychain-access-groups entitlement) can't reach the SE-wrapped KEK,
            // so the cache would normally stay off. DARKBLOOM_PREFIX_CACHE_ALLOW_
            // EPHEMERAL=1 lets such a build run the cache with a process-random
            // in-memory KEK so the cache LOGIC can be exercised/soak-tested. The
            // key does NOT persist across restart (files written this run become
            // undecryptable next run — reconcile drops them), so this is unsafe
            // for production reuse and MUST NOT be set on a signed deployment.
            let ephEnv = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"]?
                .lowercased() ?? ""
            let allowEphemeral: Bool = (ephEnv == "1" || ephEnv == "true" || ephEnv == "yes" || ephEnv == "on")
            guard allowEphemeral else {
                prefixCacheLogger.warning("prefix cache disabled: KEK unavailable (\(String(describing: error)))")
                return nil
            }
            prefixCacheLogger.warning(
                "prefix cache: SE KEK unavailable (\(String(describing: error))) — using an EPHEMERAL in-memory KEK (DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL). TEST/STRESS ONLY: cache files do NOT survive restart; do not set this on a signed/production build.")
            kek = KVCacheKEK(
                wrapper: InMemoryKeyWrappingService(),
                storage: InMemoryWrappedKEKStorage(identifier: "ephemeral-stress"))
            guard let ephKey = try? await kek.loadOrCreate() else {
                prefixCacheLogger.warning("prefix cache disabled: ephemeral KEK init failed")
                return nil
            }
            kekKey = ephKey
        }

        // The on-disk directory is keyed by the MODEL id (stable across
        // weight changes) so a re-download under the same id reuses the dir
        // instead of orphaning it. The MB-1 binding (metadata modelHash) is
        // keyed by the WEIGHT identity, so a stale-weight file is rejected
        // AND deleted by loadBlock on access, and any not-yet-accessed stale
        // file is aged out by the disk sweep — invalidation without leaking
        // directories. (Keying the dir by weightHash would create a fresh,
        // never-swept directory on every re-download.)
        let bindingId = prefixCacheBindingId(modelId: modelId, weightHash: weightHash)
        let modelKey = SHA256.hash(data: Data(modelId.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(12)
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("darkbloom/kv/\(modelKey)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Sweep any atomic-write temp files orphaned by a prior process kill
        // (SIGKILL/OOM/power-loss between createFile and rename), so they
        // can't accumulate across crashes.
        EncryptedKVStore.sweepStaleTempFiles(in: dir)

        let binding = PrefixCacheModelBinding(
            modelHash: bindingId, modelDtype: "unknown", modelArch: "unknown",
            vocabSize: 0, numLayers: numLayers, kvHeads: kvHeads, headDim: headDim
        )
        let diskBudget = prefixCacheDiskBudgetBytes(cacheDir: dir)
        prefixCacheLogger.info(
            "encrypted prefix cache active for \(modelId, privacy: .public) (bound to \(weightHash == nil ? "modelId" : "weightHash", privacy: .public)) at \(dir.path, privacy: .public), disk budget \(diskBudget) bytes (default = 50% of free volume space)")
        return PrefixCacheBacking(
            kekKey: kekKey, kek: kek, dir: dir, binding: binding, diskBudgetBytes: diskBudget, modelKey: String(modelKey))
    }

    // MARK: - Prefix cache sizing/binding helpers (testable)

    /// Per-layer `[kvHeads, headDim]` ground truth for a model, derived by
    /// running a tiny 1-token prefill through a throwaway cache so every
    /// layer materializes its KV (the cache state is empty before any
    /// update). Needed because heterogeneous models (Gemma-4: sliding
    /// `[8,256]` + full `[2,512]` layers) can't be described by a single
    /// (kvHeads, headDim), and the load-time shape guard validates per layer.
    /// Returns nil on any failure (caller falls back to the scalar guard).
    static func probeLayerShapes(model: any LanguageModel) -> [[Int]]? {
        let caches = model.newCache(parameters: nil)
        guard !caches.isEmpty else { return nil }
        let probe = MLXArray([Int32(0)]).reshaped([1, 1])
        _ = model.callAsFunction(probe, cache: caches)
        for c in caches { eval(c.innerState()) }
        var shapes: [[Int]] = []
        shapes.reserveCapacity(caches.count)
        for c in caches {
            guard let k = c.state.first, k.shape.count == 4 else { return nil }
            shapes.append([k.dim(1), k.dim(3)])  // [kvHeads, headDim]
        }
        return shapes
    }

    /// Cache identity: bind to the weight hash so a re-download under the
    /// same model id with different weights invalidates old KV. Falls back
    /// to the model id when no weight hash is known.
    static func prefixCacheBindingId(modelId: String, weightHash: String?) -> String {
        if let w = weightHash, !w.isEmpty { return w }
        return modelId
    }

    /// Block count for the engine prefix cache, bounded by a memory budget.
    /// The cache retains up to blocks*blockSize tokens of KV OUTSIDE the
    /// scheduler's active kvBudget, so a fixed 4096 would OOM large models.
    /// Returns 0 when even one block exceeds the budget (caller disables).
    static func prefixCacheMaxBlocks(
        kvBytesPerToken: Int, budgetBytes: Int, blockSize: Int, ceiling: Int = 4096
    ) -> Int {
        let perBlock = max(1, blockSize) * max(1, kvBytesPerToken)
        let fromBudget = max(0, budgetBytes) / perBlock
        return min(ceiling, fromBudget)
    }

    /// In-memory budget for the engine prefix cache. Operator override:
    /// DARKBLOOM_PREFIX_CACHE_MAX_GB; default = 1/8 of physical memory.
    /// NOTE: this is read UNCONDITIONALLY at every model load (to size
    /// maxBlocks) even when the cache is disabled, so a malformed value must
    /// degrade — never crash. See resolveMemoryBudget.
    static func prefixCacheBudgetBytes() -> Int {
        let envGB = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_MAX_GB"]
            .flatMap(Double.init)
        return resolveMemoryBudget(envGB: envGB, physicalMemory: Int(ProcessInfo.processInfo.physicalMemory))
    }

    /// Pure memory-budget policy (testable). A valid positive env override
    /// wins; a non-finite or out-of-Int-range value is REJECTED back to the
    /// physicalMemory/8 default rather than crashing (Int(Double) traps on
    /// inf/NaN/overflow, and this is read even when the cache is off).
    static func resolveMemoryBudget(envGB: Double?, physicalMemory: Int) -> Int {
        if let gb = envGB, gb > 0, gb.isFinite, gb < gbToBytesCeiling {
            return Int(gb * 1_073_741_824)
        }
        return max(1, physicalMemory / 8)
    }

    /// Largest GB value that won't overflow Int when multiplied by 2^30.
    private static var gbToBytesCeiling: Double { Double(Int.max) / 1_073_741_824 }

    /// Conservative per-model on-disk default (bytes) when the operator sets
    /// no explicit `DARKBLOOM_PREFIX_CACHE_DISK_GB`. Deliberately a small
    /// FIXED cap, NOT a fraction of free space: the budget is PER MODEL (see
    /// docs / issue #266), so a "50% of free" default lets N models
    /// collectively fill the disk. A fixed cap keeps the default-on prefix cache
    /// safe out of the box for a low-churn / few-model rollout (≈ N × 10 GB
    /// aggregate); operators raise it explicitly when they have the headroom.
    static let defaultDiskBudgetBytes = 10 * 1_073_741_824

    /// On-disk budget for persisted prefix files. Operator override:
    /// DARKBLOOM_PREFIX_CACHE_DISK_GB — a positive value sets the cap; unset / 0 /
    /// non-numeric falls back to the default (NOT unlimited). Default = a fixed
    /// 10 GB per model, clamped down to 50% of free space on a tight volume.
    static func prefixCacheDiskBudgetBytes(cacheDir: URL) -> Int {
        let envGB = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_DISK_GB"]
            .flatMap(Double.init)
        return resolveDiskBudget(envGB: envGB, freeBytes: volumeFreeBytes(at: cacheDir))
    }

    /// Pure disk-budget policy (testable). An explicit env override wins
    /// (including 0 = unlimited; non-finite/overflowing values are rejected
    /// back to the default). Otherwise use a FIXED conservative cap
    /// (`defaultDiskBudgetBytes`, per model) so multiple models can't each
    /// claim a large fraction of free space — but clamp to half of measured
    /// free so a near-full volume yields a smaller (still positive) budget
    /// rather than over-committing. When free space is unknown, use the
    /// fixed default directly.
    static func resolveDiskBudget(envGB: Double?, freeBytes: Int?) -> Int {
        if let gb = envGB, gb >= 0, gb.isFinite, gb < gbToBytesCeiling {
            return Int(gb * 1_073_741_824)
        }
        guard let free = freeBytes else { return defaultDiskBudgetBytes }
        return max(1, min(defaultDiskBudgetBytes, free / 2))
    }

    /// GLOBAL disk ceiling (bytes) for the GlobalDiskAccountant, parsed from
    /// `DARKBLOOM_PREFIX_CACHE_DISK_GB`. Returns the explicit byte cap when the
    /// operator set a positive value, else 0 = "derive from live free disk"
    /// (the accountant uses min(10GiB, free/2) and re-evaluates each tick).
    ///
    /// Previously the env var was parsed only into the per-model
    /// backing's diskBudgetBytes, which is forced to 0 when the accountant is
    /// active — so an operator-set global cap was silently ignored. The
    /// accountant is the sole authority now, so the env cap must reach IT.
    static func prefixCacheGlobalDiskCeiling() -> Int {
        guard let gb = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_DISK_GB"]
            .flatMap(Double.init), gb > 0, gb.isFinite, gb < gbToBytesCeiling
        else { return 0 }
        return Int(gb * 1_073_741_824)
    }
    // Under the global accountant, DISK_GB semantics differ from
    // the legacy per-model parser: `0` (or unset / non-numeric) means "derive a
    // cap from live free disk" (min(10GiB, free/2)), NOT "unlimited". An
    // unlimited GLOBAL cache would defeat the accountant's purpose (fill the
    // volume), so there is intentionally no unbounded mode here; an operator who
    // wants effectively-unbounded sets a very large explicit value. Documented
    // in docs/ssd-kv-cache.md §11.

    /// Best-effort free capacity (bytes) of the volume containing `url`.
    /// Prefers the "important usage" figure Apple recommends for storage
    /// decisions, falling back to the raw available capacity.
    static func volumeFreeBytes(at url: URL) -> Int? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 {
            return Int(important)
        }
        if let plain = v.volumeAvailableCapacity, plain > 0 { return plain }
        return nil
    }

    /// TB-016 sub-feature B: Minimum token count for SSD persistence.
    /// Default: 16384 for Gemma family (proven past-window restore),
    /// 0 otherwise (all checkpoints persist). Env override:
    /// DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS.
    static func prefixCacheMinPersistTokens(arch: String) -> Int {
        if let env = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS"],
           let val = Int(env), val >= 0 {
            return val
        }
        // Default: 16384 for Gemma, 0 otherwise.
        return PrefixCachePastWindow.isProven(arch: arch) ? 16384 : 0
    }

    /// Set the post-load budgets driven by architecture + physical
    /// memory. Pulled out of `loadModel` so the lifecycle reads as a
    /// short sequence; the arithmetic itself is unchanged.
    private func applyPostLoadBudgets(snapshot: LoadSnapshot) {
        self.kvBytesPerToken = Self.resolvedKVBytesPerToken(
            architecture: snapshot.architecture,
            weightBytes: snapshot.bytes
        )
        let totalMemory = Int(ProcessInfo.processInfo.physicalMemory)
        let osReserve = 4 * 1024 * 1024 * 1024
        let safetyMargin = totalMemory / 10
        let availableForKV = totalMemory - snapshot.bytes - osReserve - safetyMargin
        if availableForKV > 0 && kvBytesPerToken > 0 {
            self.dynamicTokenBudgetMax = max(availableForKV / kvBytesPerToken, 1024)
        } else {
            self.dynamicTokenBudgetMax = 1024
        }

        // Derive context-aware limits from config.json.
        self.maxContextLength = snapshot.architecture.maxContextLength ?? 0
        if maxContextLength > 0 {
            // Raise the default max output tokens so consumers that omit
            // `max_tokens` get a reasonable budget for the model's class.
            // Cap at 8192 so we don't over-reserve with very-long-context
            // models (e.g. 131K Qwen).
            self.defaultMaxTokens = min(maxContextLength, 8192)
        }

        self.dynamicMaxConcurrentRequests = min(4, maxConcurrentRequests)
        self.performanceByBatchSize.removeAll()
        self.lastBatchSampleAt = .now
    }

    public func unloadModel() async {
        await stopCurrentEngine()
    }

    // MARK: - Submit / cancel

    /// Submit a pre-tokenized prompt. Used by `MultiModelBatchSchedulerEngine`
    /// which tokenizes the full OpenAI request (including tools, tool_call_id,
    /// reasoning_content, etc.) itself, then hands the token IDs here.
    ///
    /// This bypasses the lossy `ChatMessage → applyChatTemplate` path in the
    /// `ChatCompletionRequest` overload, which drops tool-related fields.
    public func submitTokenized(
        promptTokens: [Int],
        maxTokens: Int,
        temperature: Float = 0.0,
        topP: Float? = nil,
        topK: Int? = nil,
        seed: UInt64? = nil,
        requestId: String? = nil,
        cacheScope: String = ""
    ) async -> AsyncStream<GenerationEvent> {
        let id = requestId ?? "req-\(UUID().uuidString.prefix(12))"
        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()

        guard let engine = self.engine else {
            continuation.yield(.error("No model loaded"))
            continuation.finish()
            return stream
        }
        // Pin the load epoch with the captured engine so we can detect
        // a concurrent unload/reload across the awaits below (planner, KV, restore).
        let submitEpoch = generationEpoch

        let requestBudget = promptTokens.count + maxTokens
        guard requestBudget <= tokenBudgetMax else {
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(tokenBudgetMax) available"
            ))
            continuation.finish()
            return stream
        }

        let activeUsed = activeTokenBudgetUsed
        if activeUsed + requestBudget > tokenBudgetMax {
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(tokenBudgetMax - activeUsed) available"
            ))
            continuation.finish()
            return stream
        }
        let bridge = BridgeState(
            requestId: id,
            promptTokens: promptTokens.count,
            maxTokens: maxTokens,
            submittedAt: .now
        )
        activeBridges[id] = bridge

        if let planner = self.planner {
            await refreshPlannerPolicy(activeTokenBudget: tokenBudgetMax)
            let result = await planner.admit(
                id: id,
                promptTokenCount: promptTokens.count,
                maxOutputTokens: maxTokens
            )
            if case .rejected(_, let reason) = result {
                await dropBridge(requestId: id)
                continuation.yield(.error(Self.errorMessage(for: reason)))
                continuation.finish()
                return stream
            }
            await refreshPendingSummaryCache()
        }

        if let kvBudget {
            let reserved = await kvBudget.reserve(
                requestID: id,
                kvBytesPerToken: kvBytesPerToken,
                tokenCount: requestBudget
            )
            guard reserved else {
                await dropBridge(requestId: id)
                continuation.yield(.error("token_budget_exhausted: insufficient global KV cache headroom"))
                continuation.finish()
                return stream
            }
        }

        var sp = SamplingParams(maxTokens: maxTokens, temperature: temperature)
        if let topP { sp.topP = topP }
        if let topK { sp.topK = topK }
        if let seed { sp.seed = seed }

        let req = Request(
            requestId: id,
            prompt: promptTokens as AnyHashable,
            samplingParams: sp
        )
        await maybeRestoreCheckpoint(req, promptTokens: promptTokens, scope: cacheScope)
        // Re-check the engine is still the one we captured (a reload/
        // unload may have run during the awaits above). Enqueuing onto a stopped/
        // superseded engine hangs the request or runs it on the wrong model.
        // Use releaseRequestResources (not bare dropBridge): a cancel/timeout
        // could have dropped the bridge during planner.admit BEFORE we reserved
        // KV above, so dropBridge alone would no-op and leak the reservation.
        guard engineStillCurrent(submitEpoch, engine) else {
            await releaseRequestResources(id)
            continuation.yield(.error("model reloaded during submit; please retry"))
            continuation.finish()
            return stream
        }
        _ = await engine.core.addRequest(req)
        // The add is now registered (addRequest's continuation only
        // resumes after its engineQueue block ran). Re-confirm currency; if a stop
        // interleaved across the add, abort it so it doesn't hang on a stopped
        // scheduler that abortAllRequests' pre-add snapshot missed.
        guard await confirmEnqueuedOrAbort(
            requestId: id, capturedEpoch: submitEpoch, capturedEngine: engine
        ) else {
            continuation.yield(.error("model reloaded during submit; please retry"))
            continuation.finish()
            return stream
        }

        runBridge(
            requestId: id,
            outputStream: engine.core.streamOutputs(requestId: id),
            continuation: continuation
        )

        let scheduler = self
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { await scheduler.cancel(requestId: id) }
            }
        }

        return stream
    }

    public func submit(
        request: ChatCompletionRequest,
        requestId: String? = nil
    ) async -> AsyncStream<GenerationEvent> {
        let id = requestId ?? "req-\(UUID().uuidString.prefix(12))"
        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()

        guard let engine = self.engine, let tk = tokenizer else {
            continuation.yield(.error("No model loaded"))
            continuation.finish()
            return stream
        }
        // Pin the load epoch with the captured engine (see submitTokenized).
        let submitEpoch = generationEpoch

        // Pre-tokenize so chat-template errors surface as `.error` events;
        // engine's internal `buildPrompt` silently falls back to role:content.
        let messages: [[String: any Sendable]] = request.messages.map { msg in
            ["role": msg.role, "content": msg.content]
        }
        let promptTokens: [Int]
        do {
            promptTokens = try tk.inner.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: nil
            )
        } catch {
            continuation.yield(.error("Failed to tokenize: \(error.localizedDescription)"))
            continuation.finish()
            return stream
        }

        let maxTokens = Self.resolvedMaxTokens(
            requested: request.max_tokens, defaultMaxTokens: defaultMaxTokens
        )

        let requestBudget = promptTokens.count + maxTokens
        guard requestBudget <= tokenBudgetMax else {
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(tokenBudgetMax) available"
            ))
            continuation.finish()
            return stream
        }

        // Atomic: the cumulative gate + slot reservation must
        // run in one synchronous block. Actor reentrancy across the
        // upcoming `planner.admit` / `kvBudget.reserve` awaits would
        // otherwise let two concurrent submits both read the same
        // `activeTokenBudgetUsed` and both pass the check.
        //
        // Reserve our slot by inserting the bridge into `activeBridges`
        // BEFORE the first await. Other interleaving submits will see
        // this request's budget in `activeTokenBudgetUsed`. Any early
        // exit below (planner reject, KV reject) must roll back the
        // bridge via `dropBridge(...)`.
        let activeUsed = activeTokenBudgetUsed
        if activeUsed + requestBudget > tokenBudgetMax {
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(tokenBudgetMax - activeUsed) available"
            ))
            continuation.finish()
            return stream
        }
        let bridge = BridgeState(
            requestId: id,
            promptTokens: promptTokens.count,
            maxTokens: maxTokens,
            submittedAt: .now
        )
        activeBridges[id] = bridge

        if let planner = self.planner {
            await refreshPlannerPolicy(activeTokenBudget: tokenBudgetMax)
            let result = await planner.admit(
                id: id,
                promptTokenCount: promptTokens.count,
                maxOutputTokens: maxTokens
            )
            if case .rejected(_, let reason) = result {
                await dropBridge(requestId: id)
                continuation.yield(.error(Self.errorMessage(for: reason)))
                continuation.finish()
                return stream
            }
            await refreshPendingSummaryCache()
        }

        if let kvBudget {
            let reserved = await kvBudget.reserve(
                requestID: id,
                kvBytesPerToken: kvBytesPerToken,
                tokenCount: requestBudget
            )
            guard reserved else {
                await dropBridge(requestId: id)
                continuation.yield(.error("token_budget_exhausted: insufficient global KV cache headroom"))
                continuation.finish()
                return stream
            }
        }

        // Greedy (temperature == 0) hits the engine's vectorized argmax
        // fast path automatically; just pass the requested value through.
        let temperature = request.temperature ?? 0.0
        var sp = SamplingParams(maxTokens: maxTokens, temperature: temperature)
        if let topP = request.top_p { sp.topP = topP }
        if let topK = request.top_k { sp.topK = topK }
        if let seed = request.seed { sp.seed = seed }

        let req = Request(
            requestId: id,
            prompt: promptTokens as AnyHashable,
            samplingParams: sp
        )
        await maybeRestoreCheckpoint(req, promptTokens: promptTokens, scope: request.cacheScope)
        // Re-check the captured engine is still current after the awaits.
        // releaseRequestResources (not bare dropBridge): a cancel/timeout during
        // planner.admit could have dropped the bridge BEFORE we reserved KV, so
        // dropBridge alone would no-op and leak the reservation made above.
        guard engineStillCurrent(submitEpoch, engine) else {
            await releaseRequestResources(id)
            continuation.yield(.error("model reloaded during submit; please retry"))
            continuation.finish()
            return stream
        }
        _ = await engine.core.addRequest(req)
        // Re-confirm currency AFTER the add registered (see
        // submitTokenized); abort the just-added request if a stop interleaved.
        guard await confirmEnqueuedOrAbort(
            requestId: id, capturedEpoch: submitEpoch, capturedEngine: engine
        ) else {
            continuation.yield(.error("model reloaded during submit; please retry"))
            continuation.finish()
            return stream
        }

        // Hand the per-request stream to the bridge extension. Bridge
        // teardown / finish-event mapping all live in
        // `BatchScheduler+EngineBridge.swift`.
        runBridge(
            requestId: id,
            outputStream: engine.core.streamOutputs(requestId: id),
            continuation: continuation
        )

        let scheduler = self
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { await scheduler.cancel(requestId: id) }
            }
        }

        return stream
    }

    public func cancel(requestId: String) async {
        if let engine = self.engine {
            // Engine delivers a terminal RequestOutput synchronously; the
            // streaming Task handles `recordFinish` + KV release.
            //
            // AbortRequest returns false when the engine has no
            // collector for this id yet — i.e. the request is in `activeBridges`
            // but not yet registered with EngineCore (still mid-submit awaiting
            // planner/KV/restore, or its `addRequest` engineQueue block hasn't
            // run). In that window the engine abort is a no-op, so the streaming
            // Task will never see a terminal output and our local bridge/planner/
            // KV state would leak. Fall through to drop it locally. (If the add
            // later lands, the orphaned request is removed from `activeBridges`,
            // so its terminal output is a harmless no-op on recordFinish/release.)
            if engine.core.abortRequest(requestId) {
                return
            }
        }
        // No engine, or the engine had no in-flight collector for this id:
        // tear down whatever local state exists (planner-pending and/or a
        // not-yet-registered bridge). dropBridge releases the KV reservation +
        // cancels the planner entry; the explicit calls below cover the
        // engine-nil path where no bridge was created.
        await dropBridge(requestId: requestId)
        if let planner = self.planner {
            await planner.cancel(requestID: requestId)
            await refreshPendingSummaryCache()
        }
        await releaseKVReservation(requestID: requestId)
    }

    public func cancelAll() async {
        if let engine = self.engine {
            _ = engine.core.abortAllRequests()
        }
        // Planner pending queue: engine only knows about admitted requests.
        if let planner = self.planner {
            let snapshot = await planner.snapshot()
            for entry in snapshot.pendingRequests {
                await planner.cancel(requestID: entry.id)
            }
            for entry in snapshot.activeRequests {
                await planner.cancel(requestID: entry.id)
            }
            await refreshPendingSummaryCache()
        }
        let bridgeIds = Array(activeBridges.keys)
        for id in bridgeIds {
            await releaseKVReservation(requestID: id)
        }
        activeBridges.removeAll()
        timedOutBridges.removeAll()
    }

    // MARK: - Capacity

    public func capacity() -> SchedulerCapacity {
        SchedulerCapacity(
            model: modelId,
            activeRequests: activeBridges.count,
            pendingRequests: pendingRequestCount,
            maxConcurrent: effectiveMaxConcurrentRequests,
            engineMaxConcurrent: maxConcurrentRequests,
            gpuMemoryActiveBytes: gpuMemory(.active),
            gpuMemoryPeakBytes: gpuMemory(.peak),
            gpuMemoryCacheBytes: gpuMemory(.cache),
            totalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    // MARK: - Internal helpers

    private func stopCurrentEngine() async {
        generationEpoch &+= 1
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil
        // Log a final stats line before teardown, then stop the periodic logger.
        await logPrefixCacheStats()
        prefixCacheStatsTask?.cancel()
        prefixCacheStatsTask = nil

        if let engine = self.engine {
            _ = engine.core.abortAllRequests()
            await engine.stop()
        }
        self.engine = nil
        modelContainer = nil
        tokenizer = nil
        // Persist any coalesced index writes before dropping the manager, so
        // checkpoints written since the last coalesced save survive restart.
        if let mgr = checkpointManager {
            await mgr.flushIndexNow()
            // Phase 3: deregister from the accountant before dropping the manager.
            await mgr.deregisterFromAccountant()
        }
        // Drop the checkpoint manager so a stale one can't serve the next
        // model (the new model's loadModel reinstalls its own, or nil).
        checkpointManager = nil
        checkpointBoundaries = []

        // Close the engine-tier owner FIRST (before deregister) so no disk
        // mutation slips through between deregistration and the dir being handed
        // to a reloaded same-modelKey owner: a stale engine step finishing after
        // `engine.stop()` (which doesn't fence an in-flight engineQueue step) or
        // a late accountant eviction signal will now no-op. `engine.stop()` was
        // already awaited above, so the GPU step loop is winding down by here.
        engineTierOwner?.close()
        // Deregister the engine-tier owner from the accountant.
        if let accountant = diskAccountant, let token = engineTierAccountantToken {
            await accountant.deregister(token)
        }
        // Clear the token from the owner so stale Tasks are NO-OP.
        engineTierOwner?.setAccountantToken(nil)
        engineTierOwner = nil
        engineTierAccountantToken = nil

        let bridgeIds = Array(activeBridges.keys)
        for id in bridgeIds {
            await releaseKVReservation(requestID: id)
        }
        activeBridges.removeAll()
        timedOutBridges.removeAll()
        pendingSummaryCache = .empty

        modelWeightBytes = 0
        modelId = ""
        kvBytesPerToken = 400_000
        dynamicTokenBudgetMax = 0
        maxContextLength = 0
        defaultMaxTokens = initDefaultMaxTokens
        planner = nil
        observedDecodeTpsEwma = 0
        ewmaInitialized = false
        performanceByBatchSize.removeAll()
        dynamicMaxConcurrentRequests = min(4, maxConcurrentRequests)
    }

    /// Cumulative active-bridge gate, called from tests.
    ///
    /// `submit()` inlines the same check synchronously before its
    /// first `await` (so the gate is atomic with respect to actor
    /// reentrancy). This helper exists so unit tests can probe the
    /// gate without a loaded model + non-nil engine.
    ///
    /// Returns the canonical `token_budget_exhausted:` error string on
    /// rejection, or `nil` on accept. Does NOT reserve a slot — that
    /// happens inline in `submit()` to keep the (check + reserve)
    /// pair atomic.
    func checkCumulativeTokenBudget(
        requestId: String,
        requestBudget: Int
    ) -> String? {
        let activeUsed = activeTokenBudgetUsed
        guard activeUsed + requestBudget > tokenBudgetMax else { return nil }
        return "token_budget_exhausted: request requires \(requestBudget) tokens but only \(tokenBudgetMax - activeUsed) available"
    }

    private func makePlanner(activeTokenBudget: Int) -> BatchQueuePlanner {
        BatchQueuePlanner(
            policy: BatchSchedulingPolicy(
                maxConcurrentRequests: maxConcurrentRequests,
                maxQueuedRequests: 128,
                maxActiveTokenBudget: activeTokenBudget,
                maxTokensPerBatch: resolvedMaxTokensPerBatch(activeTokenBudget: activeTokenBudget)
            )
        )
    }

    private func refreshPlannerPolicy(activeTokenBudget: Int) async {
        guard let planner else { return }
        let updatedPolicy = BatchSchedulingPolicy(
            maxConcurrentRequests: maxConcurrentRequests,
            maxQueuedRequests: 128,
            maxActiveTokenBudget: activeTokenBudget,
            maxTokensPerBatch: resolvedMaxTokensPerBatch(activeTokenBudget: activeTokenBudget)
        )
        let snapshot = await planner.snapshot()
        guard snapshot.policy != updatedPolicy else { return }

        if activeTokenBudget >= snapshot.policy.maxActiveTokenBudget {
            await planner.updatePolicy(updatedPolicy)
            return
        }

        guard snapshot.pendingRequests.isEmpty,
              snapshot.activeRequests.isEmpty else { return }
        await planner.updatePolicy(updatedPolicy)
    }

    /// Derive the per-request prompt admission limit from the model's
    /// context window. Falls back to 8192 when `config.json` is missing
    /// or doesn't declare `max_position_embeddings`. Capped by the live
    /// token budget so we never admit a prompt that couldn't possibly
    /// fit in memory.
    private func resolvedMaxTokensPerBatch(activeTokenBudget: Int) -> Int {
        let contextBased = maxContextLength > 0 ? maxContextLength : 8192
        return min(contextBased, max(activeTokenBudget, 1))
    }

    // Static helpers live in adjacent extensions:
    //   * `resolvedMaxTokens`, `resolvedKVBytesPerToken` →
    //     `BatchScheduler+KVEstimation.swift`
    //   * `errorMessage(for:)` → `BatchSchedulerTypes.swift`
}
