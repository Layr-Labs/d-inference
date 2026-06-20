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
let kvQuantLogger = Logger(subsystem: "dev.darkbloom.provider", category: "kv-quant")

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
    /// Opt-in KV-cache quantization flag from provider config. Only takes effect
    /// for model families explicitly allow-listed by ``KVQuantPolicy``.
    let kvQuantEnabled: Bool

    // MARK: - Model-specific state (set by `loadModel`)

    var modelContainer: ModelContainer?
    var modelId: String = ""
    /// Weight hash of the currently-loaded model, captured at load. Retained so a
    /// liveness-watchdog self-restart can reload the same bytes via the normal
    /// `loadModel` path without re-deriving it. Cleared on teardown.
    var currentWeightHash: String?
    var modelWeightBytes: Int = 0
    var kvBytesPerToken: Int = 400_000
    /// FP16 (un-quantized) per-token KV cost. Equals `kvBytesPerToken` unless KV
    /// quantization is active for this model — in which case `kvBytesPerToken`
    /// holds the reduced (quantized) rate used for batched-engine admission while
    /// this holds the full fp16 rate. The non-batched VLM media path streams
    /// through `container.generate`, which allocates an fp16 KV cache (NOT the
    /// quantized batched cache), so its reservation (`reserveVisionRequest`) must
    /// size generation KV from THIS value; reserving at the quantized rate would
    /// under-count ~2x and risk unified-memory OOM under concurrent media traffic.
    var fp16KVBytesPerToken: Int = 400_000
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
    /// Per-layer cache class/window signature for restore validation.
    var checkpointLayerSignatures: [CheckpointLayerSignature] = []
    /// Bounded, single-consumer pipeline that drains checkpoint KV snapshots
    /// into `checkpointManager`. Caps the number of live KV snapshots retained
    /// in flight so a busy manager can't drive the live Metal buffer count to
    /// the 499000 ceiling (the Gemma-4 leak). Built with the engine; shut down
    /// in `stopCurrentEngine`. nil ⇒ feature off / no checkpoint manager.
    var capturePipeline: CheckpointCapturePipeline<CheckpointCapture>?

    /// Engine-tier owner (EncryptedPrefixCachePersistence) for pure-
    /// attention models. Non-nil only when the model classifies as `.engine` AND
    /// the prefix cache flag is on. Registered with the accountant at load time,
    /// deregistered at stopCurrentEngine.
    var engineTierOwner: EncryptedPrefixCachePersistence?
    var engineTierAccountantToken: AccountantToken?

    /// Test-only override backing `enginePrefixCacheActive`, set via
    /// `_setEnginePrefixCacheActiveForTest` so tests can exercise the engine-tier
    /// prefill-sampling skip without constructing a real
    /// `EncryptedPrefixCachePersistence`. Production code leaves this false and
    /// the gate derives solely from `engineTierOwner`.
    private var _forceEnginePrefixCacheActiveForTest = false

    /// True when an engine-tier (in-GPU block) prefix cache is active for the
    /// loaded model. The engine restores a matched prefix internally and does
    /// NOT surface a per-request restored-token count, so `restoredPrefixTokens`
    /// stays 0 even on a cache hit — a hit is therefore indistinguishable from a
    /// cold prefill. `recordFinish` skips prefill-EWMA sampling while this is
    /// active so an unrepresentative cache-hit window can't poison routing-v2's
    /// TTFT estimate. Single source of truth: `engineTierOwner` (set when the
    /// engine-tier cache is built, cleared on teardown). Checkpoint-tier models
    /// (Gemma-4, GPT-OSS) are unaffected — their `restoredPrefixTokens` IS set
    /// on a hit, so the cold-only guard already excludes their restores.
    var enginePrefixCacheActive: Bool {
        engineTierOwner != nil || _forceEnginePrefixCacheActiveForTest
    }

    /// Test seam: force `enginePrefixCacheActive` without a real engine-tier owner.
    func _setEnginePrefixCacheActiveForTest(_ active: Bool) {
        _forceEnginePrefixCacheActiveForTest = active
    }

    /// Admission control + token budget tracking. `nil` until `loadModel()`.
    var planner: BatchQueuePlanner?

    /// Watchdog for planner-pending requests that exceed `pendingTimeout`.
    var pendingTimeoutTask: Task<Void, Never>?

    // MARK: - Backend-liveness watchdog state
    //
    // A loaded model can stop serving while the process stays up and the engine
    // loop never crashes. These fields let the in-process watchdog detect that,
    // report a truthful heartbeat slot_state (so the coordinator stops routing
    // here), and self-restart the engine to clear the condition. The decision
    // itself is pure (`BackendLivenessPolicy`); these track its live inputs.

    /// Periodic backend-liveness watchdog (assess + proactive KV-pool sweep).
    /// Started in `loadModel`, cancelled in `stopCurrentEngine`.
    var livenessWatchdogTask: Task<Void, Never>?
    /// Pure liveness decision. `wedgeStallSeconds` is pinned to `pendingTimeout`
    /// in `init` so the wedge threshold tracks the queue-timeout window.
    let livenessPolicy: BackendLivenessPolicy
    /// Last diagnosis from the watchdog; drives the heartbeat slot_state.
    var livenessState: BackendLiveness = .healthy
    /// True while a recovery self-restart is in flight; drives a "reloading"
    /// slot_state and prevents the watchdog from launching a second restart.
    var isReloadingForRecovery = false
    /// The REAL model id being reloaded during a recovery self-restart, captured
    /// at the start of `selfRestartForRecovery` BEFORE `loadModel` →
    /// `stopCurrentEngine` transiently clears the live `modelId` to "". The
    /// heartbeat advertises THIS id (see `heartbeatSlotModel`), not the empty live
    /// `modelId`, for the whole reload window — so the coordinator keeps seeing the
    /// real model as `reloading` and deroutes it, instead of seeing a phantom
    /// `model:""` slot and treating the real model as cold/unknown here (which
    /// would let it route a request into a nil engine → "No model loaded" 500).
    /// Owned solely by `selfRestartForRecovery` (set before, cleared after); like
    /// `isReloadingForRecovery` it is intentionally NOT reset by `stopCurrentEngine`.
    var recoveryReloadModelId: String?
    /// When the token budget first went continuously collapsed (at/below
    /// `livenessPolicy.collapsedBudgetTokens`); nil when not collapsed.
    var budgetCollapsedSince: ContinuousClock.Instant?
    /// When the last request completed successfully (since the current load).
    var lastSuccessAt: ContinuousClock.Instant?
    /// When a request was last rejected at admission BEFORE any `activeBridges`
    /// entry existed — the early token-budget guards and the per-request KV
    /// reservation failure. A pinned KV pool rejects real traffic at exactly
    /// those sites, so it has no active/queued bridge to prove demand; the
    /// liveness watchdog reads a recent value here as DEMAND so the pin is
    /// detectable. Reset on each load (it is per-load demand state).
    var lastAdmissionRejectAt: ContinuousClock.Instant?
    /// When the watchdog last triggered a recovery restart (cooldown anchor).
    var lastSelfRestartAt: ContinuousClock.Instant?
    /// Minimum gap between recovery restarts, so a still-degraded backend can't
    /// thrash reloads.
    let livenessRestartCooldown: Duration = .seconds(120)
    /// How often the liveness watchdog ticks (assess + proactive sweep).
    let livenessWatchdogInterval: Duration = .seconds(2)

    /// Periodic prefix-cache hit/miss stats logger. Started in `loadModel`
    /// when a checkpoint-tier manager is installed, cancelled in
    /// `stopCurrentEngine`. Logs a single line per interval so operators (and
    /// soak harnesses) can read the live hit rate, which `snapshotStats()`
    /// otherwise only exposes to in-process tests. Covers the CHECKPOINT tier
    /// only — the engine tier (`EncryptedPrefixCachePersistence`) keeps no
    /// hit/miss counters, so pure-attention `.engine` models log nothing here.
    var prefixCacheStatsTask: Task<Void, Never>?
    /// Steady-state TTL reaper (PR #290 review): reapExpired otherwise runs
    /// only at load-time reconcile, so entries going cold while the model
    /// stays loaded would sit on disk until restart (the lazy read-path check
    /// fires only when the same prefix is looked up again). Started with the
    /// engine, cancelled in `stopCurrentEngine`.
    var ttlReapTask: Task<Void, Never>?
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
    /// EWMA of measured per-request prefill TPS (prompt tokens processed
    /// between engine admission and the first generated token). Same wall-clock
    /// methodology — and the same batch-load sensitivity — as the decode EWMA.
    var observedPrefillTpsEwma: Double = 0
    var prefillEwmaInitialized = false
    /// Measured cold-start load time (ms) for the currently-loaded model. Set at
    /// the end of `loadModel`; 0 until a load completes (omitted on the wire).
    var lastModelLoadMs: Int64 = 0
    /// Per-batch-size TPS samples that drive `AdaptiveBatchCapPolicy`.
    var performanceByBatchSize: [Int: AdaptiveBatchPerformanceBucket] = [:]
    var lastBatchSampleAt: ContinuousClock.Instant = .now
    var dynamicMaxConcurrentRequests: Int
    /// Last concurrency cap pushed to the engine via `setMaxNumSeqs`. `-1` means
    /// "nothing pushed yet", so the first `syncEngineConcurrency()` after a
    /// (re)load always pushes. Reset to `-1` in `stopCurrentEngine` because a
    /// freshly-built engine starts at its own default (`config.maxNumSeqs`), so
    /// the cap must be re-sent even when it numerically matches the prior model.
    /// Tracking the last-pushed value makes `syncEngineConcurrency()` a no-op
    /// unless the effective cap actually changed (no redundant engine calls).
    var lastPushedMaxNumSeqs: Int = -1
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
        diskAccountant: GlobalDiskAccountant? = nil,
        kvQuantEnabled: Bool = false
    ) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.pendingTimeout = pendingTimeout
        self.defaultMaxTokens = defaultMaxTokens
        self.initDefaultMaxTokens = defaultMaxTokens
        self.kvBudget = kvBudget
        self.diskAccountant = diskAccountant
        self.kvQuantEnabled = kvQuantEnabled
        // Cold-start concurrency seed. Start at the configured ceiling rather
        // than the old hard pin to 4: a startup burst of N concurrent requests
        // has no per-batch TPS samples yet, so the adaptive ramp hasn't engaged
        // — pinning to 4 forced e.g. 8-way load to run as two serialized waves
        // of 4 (≈halving aggregate throughput at concurrency). The value the
        // engine is actually told is always re-clamped to
        // `memoryBoundMaxConcurrentRequests` (OOM gate) and `maxConcurrentRequests`
        // inside `effectiveMaxConcurrentRequests` / `syncEngineConcurrency()`, so
        // seeding optimistically here can never over-admit. At construction time
        // no model is loaded (and `memoryBoundMaxConcurrentRequests` — file-private
        // to the telemetry extension — collapses to `maxConcurrentRequests`
        // anyway), so the ceiling IS the memory-bound value here.
        self.dynamicMaxConcurrentRequests = max(1, maxConcurrentRequests)
        // Wedge threshold tracks the pending-timeout window: a request admitted
        // but emitting 0 tokens for that long means the engine loop has stalled.
        let pendingSecs = Double(pendingTimeout.components.seconds)
            + Double(pendingTimeout.components.attoseconds) / 1e18
        self.livenessPolicy = BackendLivenessPolicy(
            wedgeStallSeconds: pendingSecs > 0 ? pendingSecs : BackendLivenessPolicy.defaultWedgeStallSeconds)
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

        // Pin MLX's memory ceiling below physical RAM (idempotent). MLX's default
        // (1.5× working set, above RAM) otherwise allows a jetsam OOM. See MLXMemoryGuard.
        MLXMemoryGuard.configureOnce(log: { limits in
            FileHandle.standardError.write(Data(
                "[mlx] memory ceiling set: limit=\(limits.memoryLimitBytes / (1024*1024*1024))GB cache=\(limits.cacheLimitBytes / (1024*1024*1024))GB\n".utf8
            ))
        })

        await stopCurrentEngine()
        let loadEpoch = generationEpoch
        // Cold-start load timing: measured from here (after any prior model is
        // unloaded) to the end of a successful load. Reported per-slot as
        // `model_load_time_ms`. Superseded loads return early below and never
        // set `lastModelLoadMs`, so a losing race never reports a bogus time.
        let loadStartedAt = ContinuousClock.now

        let snapshot = await Self.snapshotContainer(container)
        // Detect concurrent reload that won the race; bail before we
        // overwrite the new model's state with our stale snapshot.
        guard loadEpoch == generationEpoch else { return }

        self.modelContainer = container
        self.modelId = modelId
        self.currentWeightHash = weightHash
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
            diskAccountant: diskAccountant,
            kvQuantEnabled: kvQuantEnabled
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
        self.checkpointLayerSignatures = build.checkpointLayerSignatures
        self.engineTierOwner = build.engineTierOwner
        self.capturePipeline = build.capturePipeline
        await engine.start()
        // Final epoch check after start() — start can suspend too.
        // Identity-checked cleanup — only nil self.engine if it's
        // the one THIS load assigned (self.engine === engine). If a newer load
        // already replaced it, leave the winner's self.* intact.
        guard loadEpoch == generationEpoch else {
            if self.engine === engine { self.engine = nil }
            if self.checkpointManager === build.checkpointManager { self.checkpointManager = nil }
            if self.checkpointBoundaries == build.checkpointBoundaries { self.checkpointBoundaries = [] }
            if self.checkpointLayerSignatures == build.checkpointLayerSignatures { self.checkpointLayerSignatures = [] }
            if self.engineTierOwner === build.engineTierOwner { self.engineTierOwner = nil }
            if self.capturePipeline === build.capturePipeline { self.capturePipeline?.shutdown(); self.capturePipeline = nil }
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
            if self.checkpointLayerSignatures == build.checkpointLayerSignatures { self.checkpointLayerSignatures = [] }
            if self.engineTierOwner === build.engineTierOwner { self.engineTierOwner = nil }
            if self.capturePipeline === build.capturePipeline { self.capturePipeline?.shutdown(); self.capturePipeline = nil }
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
                    if self.checkpointLayerSignatures == build.checkpointLayerSignatures { self.checkpointLayerSignatures = [] }
                    if self.engineTierOwner === build.engineTierOwner { self.engineTierOwner = nil }
                    if self.capturePipeline === build.capturePipeline { self.capturePipeline?.shutdown(); self.capturePipeline = nil }
                    await engine.stop()
                    return
                }
            }
        }

        applyPostLoadBudgets(snapshot: snapshot)
        // Push the effective concurrency cap to the freshly-built engine before
        // admitting any request. `syncEngineConcurrency()` sends
        // min(maxConcurrentRequests, dynamicMaxConcurrentRequests,
        // memoryBoundMaxConcurrentRequests) — the SAME effective cap the
        // heartbeat reports — and records it so later adaptive-ramp / memory
        // updates only re-push when it actually changes. Previously the engine
        // was told the cold-start `dynamicMaxConcurrentRequests` here ONCE and
        // never heard the adaptive ramp, so it stayed pinned at the seed value.
        syncEngineConcurrency()
        self.planner = makePlanner(activeTokenBudget: tokenBudgetMax)
        // Engine has no pending-queue TTL; we enforce `pendingTimeout`.
        startPendingTimeoutWatchdog()
        // Backend-liveness watchdog: detect a wedged/pinned engine, report it
        // truthfully on the heartbeat, and self-restart to recover. Also drives
        // the proactive off-actor KV-pool sweep.
        startLivenessWatchdog()
        // Periodic checkpoint-tier hit/miss logger (no-op if disabled or
        // engine-tier model). Cancelled in stopCurrentEngine.
        startPrefixCacheStatsLogger()
        // Steady-state TTL sweep for the checkpoint SSD tier (no-op when TTL
        // disabled or engine-tier model). Cancelled in stopCurrentEngine.
        startTTLReaper()

        // Record the measured cold-start load time for this slot's heartbeat
        // telemetry. Only reached on a fully successful, non-superseded load.
        let loadElapsed = ContinuousClock.now - loadStartedAt
        let loadMs = Double(loadElapsed.components.seconds) * 1000.0
            + Double(loadElapsed.components.attoseconds) / 1e15
        lastModelLoadMs = Int64(max(0, loadMs.rounded()))
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
    private struct RestoredCheckpointAdmission {
        let candidate: PrefixLookupCandidate
        let reservedTokens: Int
    }

    /// Checkpoint-tier preflight: find a restore candidate and estimate its
    /// memory cost without copying RAM caches or decrypting SSD chunks. The
    /// caller reserves budget before `materializeRestoredCheckpoint` touches
    /// tensors.
    ///
    /// MLX shape/runtime errors are fatal traps, not Swift throws. Validate the
    /// restored checkpoint after materialization but before it reaches
    /// `EngineCore.addRequest`; any uncertainty becomes a cold prefill.
    private func planRestoredCheckpoint(
        promptTokens: [Int],
        scope: String,
        maxTokens: Int
    ) async -> RestoredCheckpointAdmission? {
        guard let mgr = checkpointManager else { return nil }
        guard let candidate = await mgr.lookupCandidate(tokens: promptTokens, scope: scope),
              candidate.tokenCount >= 1, candidate.tokenCount < promptTokens.count
        else { return nil }

        return RestoredCheckpointAdmission(
            candidate: candidate,
            reservedTokens: restoredCheckpointReservedTokens(
                restoredBytes: candidate.estimatedBytes,
                promptTokenCount: promptTokens.count,
                restoredTokenCount: candidate.tokenCount,
                maxTokens: maxTokens
            )
        )
    }

    /// Materialize an already-admitted checkpoint candidate and attach it to the
    /// MLX request. This intentionally runs after KV reservation.
    ///
    /// Returns `true` iff the restore was actually attached to `req`
    /// (`req.restoredCheckpoint` set). All four fallback branches — no manager,
    /// materialize returned nil, geometry unusable, or the materialized KV
    /// exceeded the admitted estimate — return `false` so the caller can
    /// downgrade BOTH the scheduler token budget and the global KV-byte
    /// reservation back to the cold-prefill footprint (otherwise the
    /// restore-sized reservation leaks for the request's whole life → admission
    /// starvation under exactly the OOM pressure that triggers restore failures).
    private func materializeRestoredCheckpoint(
        _ req: Request,
        admission: RestoredCheckpointAdmission,
        promptTokens: [Int],
        scope: String
    ) async -> Bool {
        guard let mgr = checkpointManager else { return false }
        guard let hit = await mgr.materialize(
            candidate: admission.candidate,
            tokens: promptTokens,
            scope: scope
        ) else { return false }

        // Use-after-release guard: `mgr.materialize` is an expensive await (RAM
        // copy / SSD decrypt). A cancel or pending-timeout can run the bridge's
        // cancel path (releaseKVReservation + bridge drop) while it is in flight.
        // If the bridge is gone, the reservation these caches were sized against
        // has already been released — attaching them would allocate KV against a
        // freed reservation. Discard the materialized caches and report failure;
        // the cancel path already released the reservation, and the submit path's
        // `confirmEnqueuedOrAbort` will refuse to runBridge on the missing bridge.
        // `activeBridges` is this actor's own state — no extra lock needed.
        guard activeBridges[req.requestId] != nil else { return false }

        guard Self.restoredCheckpointIsUsable(
            caches: hit.caches,
            expected: checkpointLayerSignatures,
            tokenCount: hit.tokenCount,
            promptTokenCount: promptTokens.count
        ) else {
            prefixCacheLogger.warning(
                "prefix cache restore rejected: invalid checkpoint geometry; falling back to cold prefill")
            return false
        }

        let actualReservation = restoredCheckpointReservedTokens(
            caches: hit.caches,
            promptTokenCount: promptTokens.count,
            restoredTokenCount: hit.tokenCount,
            maxTokens: req.maxTokens
        )
        guard actualReservation <= admission.reservedTokens else {
            prefixCacheLogger.warning(
                "prefix cache restore skipped: materialized KV exceeded admitted estimate; falling back to cold prefill")
            return false
        }

        req.restoredCheckpoint = (caches: hit.caches, tokenCount: hit.tokenCount)
        // Record the restored prefix length on the bridge so `recordFinish`
        // excludes it from the prefill-rate EWMA: the admitted→first-token window
        // only covers prefilling the UNCACHED suffix, so dividing the FULL prompt
        // by it would inflate `observed_prefill_tps` far above the true
        // cold-prefill rate (now consumed by routing-v2 for TTFT estimates).
        // The bridge is guaranteed present here (checked above, no awaits since).
        if var bridge = activeBridges[req.requestId] {
            bridge.restoredPrefixTokens = hit.tokenCount
            activeBridges[req.requestId] = bridge
        }
        return true
    }

    /// Shared restore finalizer for both submit paths. Runs the expensive
    /// materialize and, when it falls back (returns false), downgrades BOTH
    /// accounting systems from the restore-sized reservation back to the cold
    /// `requestBudget` footprint:
    ///
    ///   1. scheduler token budget — clear `bridge.reservedTokens` so
    ///      `activeTokenBudgetUsed` falls back to (promptTokens + maxTokens),
    ///      mirroring the downgrade in `reserveKVForRequest`.
    ///   2. global KV bytes — `reduceReservation` shrinks the live reservation to
    ///      the cold size, atomically freeing the over-charged difference.
    ///
    /// When materialize SUCCEEDS both reservations stay at the restore-sized
    /// amount — the restored KV is really materialized, so that charge is correct.
    /// Factored out so the two submit paths share one definition (no drift).
    private func finalizeRestore(
        _ req: Request,
        id: String,
        admission: RestoredCheckpointAdmission,
        promptTokens: [Int],
        scope: String,
        requestBudget: Int
    ) async {
        let attached = await materializeRestoredCheckpoint(
            req,
            admission: admission,
            promptTokens: promptTokens,
            scope: scope
        )
        guard !attached else { return }
        // Restore was planned + accepted (oversized reservations charged) but did
        // not materialize. Drop both systems back to the cold-prefill size.
        if var bridge = activeBridges[id] {
            bridge.reservedTokens = nil
            activeBridges[id] = bridge
        }
        await kvBudget?.reduceReservation(
            requestID: id,
            kvBytesPerToken: kvBytesPerToken,
            tokenCount: requestBudget
        )
    }

    static func restoredCheckpointIsUsable(
        caches: [any KVCache],
        expected: [CheckpointLayerSignature],
        tokenCount: Int,
        promptTokenCount: Int
    ) -> Bool {
        guard tokenCount >= 1, tokenCount < promptTokenCount else { return false }
        guard caches.count == expected.count, !caches.isEmpty else { return false }

        for (restored, signature) in zip(caches, expected) {
            guard restoredLayerIsUsable(restored, expected: signature, tokenCount: tokenCount) else {
                return false
            }
        }
        return true
    }

    private static func restoredLayerIsUsable(
        _ restored: any KVCache,
        expected: CheckpointLayerSignature,
        tokenCount: Int
    ) -> Bool {
        if restored is ArraysCache { return false }
        if restored is ChunkedKVCache { return false }
        if restored is QuantizedKVCache { return false }

        guard let shape = restoredKVShape(restored) else { return false }

        switch expected {
        case .rotating(let window, let expectedShape):
            guard let rot = restored as? RotatingKVCache, window > 0 else { return false }
            guard let restoredWindow = rot.maxSize, restoredWindow == window else { return false }
            guard restoredShapeMatches(shape, expected: expectedShape) else { return false }
            let storedTokens = shape.tokenCount
            let expectedStoredTokens = min(tokenCount, window)
            return storedTokens == expectedStoredTokens
        case .simple(let expectedShape):
            guard let simple = restored as? KVCacheSimple, !(restored is RotatingKVCache) else {
                return false
            }
            guard restoredShapeMatches(shape, expected: expectedShape) else { return false }
            return simple.offset == tokenCount && shape.tokenCount == tokenCount
        case .unsupported:
            return false
        }
    }

    private struct RestoredKVShape {
        let tokenCount: Int
        let kvHeads: Int
        let headDim: Int
    }

    private static func restoredKVShape(_ cache: any KVCache) -> RestoredKVShape? {
        let state = cache.state
        guard state.count >= 2 else { return nil }
        let k = state[0]
        let v = state[1]
        guard k.shape.count == 4, v.shape.count == 4 else { return nil }
        guard k.dim(0) == 1, v.dim(0) == 1 else { return nil }
        guard k.dim(1) == v.dim(1), k.dim(2) == v.dim(2) else { return nil }
        guard k.dim(3) == v.dim(3) else { return nil }
        guard k.dim(1) > 0, k.dim(2) > 0, k.dim(3) > 0 else { return nil }
        return RestoredKVShape(tokenCount: k.dim(2), kvHeads: k.dim(1), headDim: k.dim(3))
    }

    private static func restoredShapeMatches(_ restored: RestoredKVShape, expected: CheckpointLayerShape?) -> Bool {
        guard let expected else { return true }
        return restored.kvHeads == expected.kvHeads && restored.headDim == expected.headDim
    }

    /// Reserve for the original request plus restored-KV materialization.
    ///
    /// A checkpoint hit can hold multiple live copies briefly: the RAM/SSD hit
    /// copy returned by `PrefixCacheManager`, plus the B==1 batched cache that
    /// MLX builds for decode. Charge those copies explicitly so a restore that
    /// would fit as a cold prefill but not as restored KV is skipped before MLX
    /// can hit a fatal `metal::malloc`.
    private func restoredCheckpointReservedTokens(
        caches: [any KVCache],
        promptTokenCount: Int,
        restoredTokenCount: Int,
        maxTokens: Int
    ) -> Int {
        restoredCheckpointReservedTokens(
            restoredBytes: PrefixCacheRAM.byteSize(of: caches),
            promptTokenCount: promptTokenCount,
            restoredTokenCount: restoredTokenCount,
            maxTokens: maxTokens
        )
    }

    private func restoredCheckpointReservedTokens(
        restoredBytes: Int,
        promptTokenCount: Int,
        restoredTokenCount: Int,
        maxTokens: Int
    ) -> Int {
        let requestTokens = promptTokenCount + maxTokens
        guard kvBytesPerToken > 0 else { return requestTokens }
        let extraRestoredCopies = 2
        let chargedBytes = restoredBytes.multipliedReportingOverflow(by: extraRestoredCopies)
        let restoredEquivalentTokens: Int
        if chargedBytes.overflow {
            restoredEquivalentTokens = Int.max
        } else {
            let roundedBytes = chargedBytes.partialValue.addingReportingOverflow(kvBytesPerToken - 1)
            restoredEquivalentTokens = roundedBytes.overflow
                ? Int.max
                : roundedBytes.partialValue / kvBytesPerToken
        }
        let suffixAndOutputTokens = max(0, promptTokenCount - restoredTokenCount) + maxTokens
        let restoredTotal = restoredEquivalentTokens.addingReportingOverflow(suffixAndOutputTokens)
        return max(requestTokens, restoredTotal.overflow ? Int.max : restoredTotal.partialValue)
    }

    private func acceptRestoredCheckpointBudget(
        requestId: String,
        requestTokens: Int,
        admission: RestoredCheckpointAdmission?
    ) -> RestoredCheckpointAdmission? {
        guard let admission, admission.reservedTokens > requestTokens else {
            return admission
        }
        let usedWithoutThis = max(0, activeTokenBudgetUsed - requestTokens)
        let projected = usedWithoutThis.addingReportingOverflow(admission.reservedTokens)
        guard !projected.overflow, projected.partialValue <= tokenBudgetMax else {
            prefixCacheLogger.warning(
                "prefix cache restore skipped: restored KV exceeds token budget; falling back to cold prefill")
            return nil
        }
        if var bridge = activeBridges[requestId] {
            bridge.reservedTokens = admission.reservedTokens
            activeBridges[requestId] = bridge
        }
        return admission
    }

    /// Which reservation `reserveKVForRequest` actually secured. The submit
    /// paths MUST branch on this — capturing `acceptedRestore != nil` before the
    /// reserve is not enough, because the reserve can DOWNGRADE a restore to a
    /// cold prefill when the restore-sized headroom is unavailable. Materializing
    /// the restore-sized KV against a cold-sized reservation under-reserves and
    /// OOMs under exactly the memory pressure that forced the downgrade.
    enum KVReservationOutcome {
        /// The restore-sized reservation is held; the restore may materialize.
        case restoreReserved
        /// Only the cold (requestTokens) reservation is held — either no restore
        /// was planned, or a planned restore was downgraded. The restore must be
        /// SKIPPED entirely; the request proceeds as a cold prefill.
        case coldReserved
        /// No reservation could be secured; the submit must reject the request.
        case failed
    }

    private func reserveKVForRequest(
        requestId: String,
        requestTokens: Int,
        reservationTokens: Int,
        restorePlanned: Bool
    ) async -> KVReservationOutcome {
        // No budgeting: preserve the legacy "always proceed" behavior. If a
        // restore was planned, treat it as restore-reserved so the restore still
        // materializes when budgeting is disabled (the happy path is unchanged).
        guard let kvBudget else {
            return restorePlanned ? .restoreReserved : .coldReserved
        }
        if await kvBudget.reserve(
            requestID: requestId,
            kvBytesPerToken: kvBytesPerToken,
            tokenCount: reservationTokens
        ) {
            // The reservation we asked for landed. When a restore was planned
            // the requested amount IS the restore-sized reservation; otherwise
            // it's the cold footprint (reservationTokens == requestTokens).
            return restorePlanned ? .restoreReserved : .coldReserved
        }

        // A restored checkpoint hit can require materially more headroom than
        // a cold prefill because restored KV is already materialized. If that
        // larger reservation fails, drop the restore and retry the normal
        // request reservation so the cache miss is slow, not fatal.
        guard restorePlanned, reservationTokens > requestTokens else {
            return .failed
        }

        if var bridge = activeBridges[requestId] {
            bridge.reservedTokens = nil
            activeBridges[requestId] = bridge
        }
        prefixCacheLogger.warning(
            "prefix cache restore skipped: insufficient KV headroom; falling back to cold prefill")

        let coldReserved = await kvBudget.reserve(
            requestID: requestId,
            kvBytesPerToken: kvBytesPerToken,
            tokenCount: requestTokens
        )
        // Downgraded to cold: the caller MUST NOT materialize the restore — only
        // the cold reservation is held. bridge.reservedTokens is already nil
        // (cleared above) so activeTokenBudgetUsed already reflects the cold size.
        return coldReserved ? .coldReserved : .failed
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
    func _installCheckpointManagerForTest(_ mgr: PrefixCacheManager, boundaries: [Int]) async {
        self.checkpointManager = mgr
        self.checkpointBoundaries = boundaries
        self.checkpointLayerSignatures = await modelContainer?.perform { ctx in
            Self.checkpointLayerSignatures(
                for: ctx.model.newCache(parameters: nil),
                layerShapes: Self.probeLayerShapes(model: ctx.model)
            )
        } ?? []
        engine?.core.scheduler.checkpointBoundaries = boundaries
        // Same bounded + admission-gated wiring production uses, so the test
        // seam exercises the real backpressure path (not the old unbounded one).
        self.capturePipeline?.shutdown()
        let wiring = Self.makeCheckpointCaptureWiring(manager: mgr)
        self.capturePipeline = wiring.pipeline
        engine?.core.scheduler.onCheckpointCapture = wiring.hook
    }

    /// TEST SEAM: drive the real `finalizeRestore` fallback path without a live
    /// engine. `RestoredCheckpointAdmission` is `private` to this file, so the
    /// regression test (in another file) cannot build one — this seam constructs
    /// an admission with the given oversized `reservedTokens` and invokes the
    /// exact production helper the submit paths call. With no `checkpointManager`
    /// installed, `materializeRestoredCheckpoint` short-circuits to `false`, so
    /// this exercises the downgrade-both-systems branch end-to-end. Returns
    /// nothing; the caller inspects `activeTokenBudgetUsed`, the bridge's
    /// `reservedTokens`, and the kvBudget reservation. Not used in production.
    func _testFinalizeRestoreFallback(
        id: String,
        promptTokens: [Int],
        maxTokens: Int,
        reservedTokens: Int,
        requestBudget: Int
    ) async {
        let candidate = PrefixLookupCandidate(
            digest: Data(),
            digestHex: "",
            tokenCount: max(1, promptTokens.count - 1),
            estimatedBytes: 0,
            tier: .ram
        )
        let admission = RestoredCheckpointAdmission(
            candidate: candidate,
            reservedTokens: reservedTokens
        )
        let sp = SamplingParams(maxTokens: maxTokens, temperature: 0.0)
        let req = Request(
            requestId: id,
            prompt: promptTokens as AnyHashable,
            samplingParams: sp
        )
        await finalizeRestore(
            req,
            id: id,
            admission: admission,
            promptTokens: promptTokens,
            scope: "",
            requestBudget: requestBudget
        )
    }

    /// TEST SEAM: drive the real `reserveKVForRequest` and return the outcome so
    /// a non-live test can prove the downgrade path reports `.coldReserved` (so
    /// the submit paths skip restore) rather than secretly holding a cold
    /// reservation while reporting success. `reserveKVForRequest` is `private` to
    /// this file; this thin wrapper invokes the exact production helper. Not used
    /// in production.
    func _testReserveKVForRequest(
        requestId: String,
        requestTokens: Int,
        reservationTokens: Int,
        restorePlanned: Bool
    ) async -> KVReservationOutcome {
        await reserveKVForRequest(
            requestId: requestId,
            requestTokens: requestTokens,
            reservationTokens: reservationTokens,
            restorePlanned: restorePlanned
        )
    }

    /// TEST SEAM: replay the EXACT submit-path restore decision against the real
    /// `reserveKVForRequest`, then apply the same branch the submit paths use:
    /// call `finalizeRestore` ONLY when the outcome is `.restoreReserved`. Builds
    /// a real `Request` and a restore-sized `RestoredCheckpointAdmission` (both
    /// `private` to this file, so the cross-file test cannot construct them) and
    /// reports the outcome plus whether `req.restoredCheckpoint` stayed nil. This
    /// proves the BUG-3 fix end-to-end: a downgraded reserve (.coldReserved) must
    /// NOT attach a restored checkpoint. With no `checkpointManager` installed,
    /// `materializeRestoredCheckpoint` short-circuits to false, so even the
    /// `.restoreReserved` branch leaves the checkpoint nil — the load-bearing
    /// signal here is that the `.coldReserved` branch never calls finalizeRestore
    /// at all. Not used in production.
    func _testReserveThenMaybeRestore(
        id: String,
        promptTokens: [Int],
        maxTokens: Int,
        requestBudget: Int,
        reservationTokens: Int
    ) async -> (outcome: KVReservationOutcome, restoredCheckpointWasNil: Bool) {
        let sp = SamplingParams(maxTokens: maxTokens, temperature: 0.0)
        let req = Request(
            requestId: id,
            prompt: promptTokens as AnyHashable,
            samplingParams: sp
        )
        let candidate = PrefixLookupCandidate(
            digest: Data(),
            digestHex: "",
            tokenCount: max(1, promptTokens.count - 1),
            estimatedBytes: 0,
            tier: .ram
        )
        let admission = RestoredCheckpointAdmission(
            candidate: candidate,
            reservedTokens: reservationTokens
        )
        let outcome = await reserveKVForRequest(
            requestId: id,
            requestTokens: requestBudget,
            reservationTokens: reservationTokens,
            restorePlanned: true
        )
        // Mirror the submit paths: materialize the restore ONLY on .restoreReserved.
        if outcome == .restoreReserved {
            await finalizeRestore(
                req,
                id: id,
                admission: admission,
                promptTokens: promptTokens,
                scope: "",
                requestBudget: requestBudget
            )
        }
        return (outcome, req.restoredCheckpoint == nil)
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
        let checkpointLayerSignatures: [CheckpointLayerSignature]
        let engineTierOwner: EncryptedPrefixCachePersistence?
        /// Bounded capture pipeline (non-nil iff `checkpointManager` is). The
        /// caller stores it on the actor and shuts it down at teardown.
        let capturePipeline: CheckpointCapturePipeline<CheckpointCapture>?
    }

    private static func makeBatchedEngine(
        container: ModelContainer,
        modelId: String,
        weightHash: String?,
        weightBytes: Int,
        maxConcurrentRequests: Int,
        eosTokenIds: Set<Int>,
        architecture: ModelArchitecture,
        diskAccountant: GlobalDiskAccountant? = nil,
        kvQuantEnabled: Bool = false
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
        //
        // KV-quant + prefix cache are now composable for the
        // dequant scheme (GPT-OSS). The engine's checkpoint restore rebuilds a
        // QUANTIZED batched cache (re-quantizing the restored fp16 prefix via
        // the cold cache factory) so a restored row stays concrete-class-
        // compatible with quantized cold rows under `extendBatched` — the
        // assembly precondition that the v1 exclusion was really avoiding.
        // The native quantized-kernel scheme (Gemma g128) is NOT yet composed
        // (separate workstream), so it still disables the prefix cache. Drafter
        // -MTP remains disabled under KV-quant regardless (separable; handled
        // where the MTP runtime is wired, not here).
        let kvQuantScheme = Self.resolveKVQuantScheme(
            modelID: modelId,
            architecture: architecture,
            kvQuantEnabled: kvQuantEnabled
        )
        let blockSize = 256
        // Only the kernel scheme still blocks the prefix cache; dequant composes.
        let kvQuantBlocksPrefixCache =
            kvQuantScheme != nil && kvQuantScheme?.candidateMode.cacheKind != .dequant
        let backing = kvQuantBlocksPrefixCache
            ? nil
            : await makePrefixCacheBackingIfEnabled(
                modelId: modelId, weightHash: weightHash, architecture: architecture
            )
        let kvBytesPerToken = resolvedKVBytesPerToken(
            architecture: architecture,
            weightBytes: weightBytes,
            quantScheme: kvQuantScheme
        )
        // Make the switch observable: a beta provider can confirm via
        // `darkbloom logs` whether kv_quant actually engaged for this model.
        if let scheme = kvQuantScheme {
            let kind = scheme.candidateMode.cacheKind == .dequant ? "dequant" : "kernel"
            let pc = kvQuantBlocksPrefixCache ? "off (kernel scheme)" : "on"
            kvQuantLogger.notice(
                "KV-quant ENABLED for \(modelId, privacy: .public): \(kind, privacy: .public) scheme, \(kvBytesPerToken) KV bytes/token, prefix cache \(pc, privacy: .public)")
        } else if kvQuantEnabled {
            kvQuantLogger.notice(
                "KV-quant requested (kv_quant=true) but \(modelId, privacy: .public) is not a supported family — serving fp16")
        }
        let maxBlocks = prefixCacheMaxBlocks(
            kvBytesPerToken: kvBytesPerToken,
            budgetBytes: prefixCacheBudgetBytes(),
            blockSize: blockSize
        )
        // now() for the manager index timestamps — wall clock is fine here.
        let nowFn: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }

        return await container.perform { ctx -> EngineBuild in
            let cacheLayout = ctx.model.newCache(parameters: nil)
            // Classify from the model's own cache layout.
            let strategy = backing == nil
                ? PrefixCacheStrategy.none
                : PrefixCacheStrategy.classify(cacheLayout)

            var enginePrefixCache: PrefixCache? = nil
            var checkpointManager: PrefixCacheManager? = nil
            var capturePipeline: CheckpointCapturePipeline<CheckpointCapture>? = nil
            var boundaries: [Int] = []
            var checkpointLayerSignatures: [CheckpointLayerSignature] = []
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
                    let window = PrefixCacheStrategy.minSlidingWindow(cacheLayout) ?? 0
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
                    checkpointLayerSignatures = Self.checkpointLayerSignatures(
                        for: cacheLayout,
                        layerShapes: layerShapes
                    )
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
                        // Sliding SSD TTL (default 5min; 0 = infinite). Bounds
                        // how long prompt-derived KV lingers on disk.
                        ttlSeconds: Self.prefixCacheTTLSeconds(),
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
                    maxKVCacheTokens: 0,  // unlimited — our kvBudget gates by bytes
                    kvQuantization: kvQuantScheme?.schedulerConfig
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
                // Bound the capture pipeline: at most `max-in-flight` live KV
                // snapshots retained while the manager actor is busy (crypto +
                // fsync), dropping the surplus rather than queuing it. This is
                // the fix for the Gemma-4 Metal live-resource (499000) leak — the
                // old `Task { await mgr.store(...) }` per boundary was unbounded.
                let wiring = Self.makeCheckpointCaptureWiring(manager: mgr)
                capturePipeline = wiring.pipeline
                scheduler.onCheckpointCapture = wiring.hook
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
                        // MTP/drafter capture requires non-quantized KV;
                        // keep disabled when KV-quant is on (and off by default).
                        mtpEnabled: false
                    ),
                    externalChatTemplate: nil
                ),
                checkpointManager: checkpointManager,
                checkpointBoundaries: boundaries,
                checkpointLayerSignatures: checkpointLayerSignatures,
                engineTierOwner: engineTierOwner,
                capturePipeline: capturePipeline
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

        // `.notice` not `.warning`: os.Logger maps warning()->OSLogType.error,
        // so this routine banner showed as type=Error in log reports.
        prefixCacheLogger.notice(
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

    private static func checkpointLayerSignatures(
        for caches: [any KVCache],
        layerShapes: [[Int]]?
    ) -> [CheckpointLayerSignature] {
        caches.enumerated().map { idx, cache in
            let shape: [Int]? =
                if let layerShapes, idx < layerShapes.count {
                    layerShapes[idx]
                } else {
                    nil
                }
            return CheckpointLayerSignature.from(cache, layerShape: shape)
        }
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
        let envGB: Double? = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_MAX_GB"]
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
        let envGB: Double? = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_DISK_GB"]
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
        let envGB: Double? = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_DISK_GB"]
            .flatMap(Double.init)
        guard let gb = envGB, gb > 0, gb.isFinite, gb < gbToBytesCeiling else { return 0 }
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

    /// Sliding TTL (seconds) for persisted SSD prefix checkpoints. Default 300
    /// (5 min, matching Anthropic/OpenAI prompt-cache defaults); `0` disables
    /// (infinite — capacity-driven eviction only). Operator override:
    /// `DARKBLOOM_PREFIX_CACHE_TTL_SECONDS`.
    static let defaultPrefixCacheTTLSeconds: Int64 = 300
    static func prefixCacheTTLSeconds() -> Int64 {
        resolveTTLSeconds(env: ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_TTL_SECONDS"])
    }

    /// Pure TTL policy (testable). Unset / malformed / negative ⇒ default;
    /// `0` ⇒ disabled (infinite); a positive value sets the sliding window.
    static func resolveTTLSeconds(env: String?) -> Int64 {
        guard let v = env else { return defaultPrefixCacheTTLSeconds }
        guard let n = Int64(v), n >= 0 else { return defaultPrefixCacheTTLSeconds }
        return n  // 0 ⇒ disabled
    }

    /// Set the post-load budgets driven by architecture + physical
    /// memory. Pulled out of `loadModel` so the lifecycle reads as a
    /// short sequence; the arithmetic itself is unchanged.
    private func applyPostLoadBudgets(snapshot: LoadSnapshot) {
        let quantScheme = Self.resolveKVQuantScheme(
            modelID: modelId,
            architecture: snapshot.architecture,
            kvQuantEnabled: kvQuantEnabled
        )
        self.kvBytesPerToken = Self.resolvedKVBytesPerToken(
            architecture: snapshot.architecture,
            weightBytes: snapshot.bytes,
            quantScheme: quantScheme
        )
        // FP16 KV cost (no quantScheme): identical to kvBytesPerToken when KV
        // quant is off, but ~2x larger when it's on. The non-batched VLM media
        // path uses container.generate (fp16 KV, not the quantized batched
        // cache), so reserveVisionRequest sizes its generation-KV reservation
        // from this un-quantized value rather than the quantized rate the
        // batched engine admits against.
        self.fp16KVBytesPerToken = Self.resolvedKVBytesPerToken(
            architecture: snapshot.architecture,
            weightBytes: snapshot.bytes
        )
        // Static upper-bound budget from the unified 90% cap minus THIS model's
        // measured resident weights (snapshot.bytes) and the activation reserve.
        // Only the per-model clamp; cross-model headroom (other resident models'
        // weights/KV) is handled live by tokenBudgetMax / the shared
        // GlobalKVCacheBudget, which read process-global MLX usage.
        let availableForKV = UnifiedMemoryCap.kvBudgetBytes(
            residentWeightBytes: UInt64(max(0, snapshot.bytes)))
        if availableForKV > 0 && kvBytesPerToken > 0 {
            let availInt = Int(min(availableForKV, UInt64(Int.max)))
            self.dynamicTokenBudgetMax = max(availInt / kvBytesPerToken, 1024)
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

        // Cold-start concurrency seed for the just-loaded model. Start at the
        // configured ceiling, not the old hard pin to 4. The memory clamp is
        // applied authoritatively in `effectiveMaxConcurrentRequests` /
        // `syncEngineConcurrency()` (which `loadModel` calls immediately after
        // this), so the engine is never told more than
        // `memoryBoundMaxConcurrentRequests`. Seeding at the ceiling (rather than
        // min(ceiling, memoryBound)) also lets the effective cap track a RISING
        // memory bound instantly instead of waiting for the slow adaptive ramp to
        // re-raise it. (`memoryBoundMaxConcurrentRequests` is file-private to the
        // telemetry extension and not referenceable here.)
        self.dynamicMaxConcurrentRequests = max(1, maxConcurrentRequests)
        self.performanceByBatchSize.removeAll()
        self.lastBatchSampleAt = .now
    }

    public func unloadModel() async {
        await stopCurrentEngine()
    }

    /// Reserve unified memory for a VLM (vision-path) request against the shared
    /// 90% cap, via the process-wide GlobalKVCacheBudget this scheduler holds. A
    /// vision request bypasses the batched `submitTokenized` reservation entirely
    /// — it streams through `container.generate` directly — so without this it
    /// commits TWO kinds of memory the cap would otherwise track only reactively:
    ///
    /// 1. `mediaDecodeBytes` — the transient CIImage rasters + Swift `Data` pixel
    ///    buffers from media decode. These are NOT MLXArrays, so they are
    ///    invisible to the cap's live MLX counters (the original blind spot).
    /// 2. The generation KV cache — `fp16KVBytesPerToken × kvTokens` (the fp16
    ///    rate, since this path's `container.generate` allocates an un-quantized
    ///    KV cache even when batched admission uses quantized KV). This IS
    ///    MLXArray-backed (eventually visible to the live counters), but the
    ///    vision path's decode loop runs in a detached task with no per-request
    ///    reservation, so N concurrent media requests can grow KV simultaneously
    ///    against headroom none of them reserved — a transient over-commit the
    ///    cap would otherwise catch only on the NEXT admission. Reserving it up
    ///    front makes the vision path share the same preemptive 90% gate the
    ///    batched path gets from `reserveKVForRequest`.
    ///
    /// Both are charged to ONE reservation id and released together when the
    /// stream ends (decode buffers are actually freed after `prepare`, so holding
    /// them for the whole stream is conservative — never an under-reservation).
    /// Returns true if it fits (and was reserved) or budgeting is disabled
    /// (nil budget, legacy "always proceed"); false if it would exceed the cap,
    /// in which case the caller surfaces a retryable 503. Pair with
    /// `releaseVisionRequest`. Saturating; never traps.
    public func reserveVisionRequest(
        requestId: String, mediaDecodeBytes: UInt64, kvTokens: Int
    ) async -> Bool {
        guard let kvBudget else { return true }
        // KV bytes = per-token KV cost × the FULL token span the cache will hold:
        // prompt text + image/video soft tokens + generated output (the caller
        // computes that conservative total). Reserving only the output tokens
        // would badly under-count — a single image expands to hundreds of vision
        // tokens, all of which occupy KV.
        // Charge the FP16 (un-quantized) per-token KV cost: this request streams
        // through container.generate, which allocates an fp16 KV cache — NOT the
        // quantized batched cache. With KV quant on, kvBytesPerToken is the
        // reduced batched rate (~0.52x); sizing the reservation from it would
        // under-reserve the real fp16 allocation ~2x and risk OOM under
        // concurrent image/video traffic. When KV quant is off,
        // fp16KVBytesPerToken == kvBytesPerToken, so this is a no-op.
        var genKVBytes: UInt64 = 0
        if fp16KVBytesPerToken > 0, kvTokens > 0 {
            let (b, overflow) = UInt64(fp16KVBytesPerToken)
                .multipliedReportingOverflow(by: UInt64(kvTokens))
            genKVBytes = overflow ? .max : b
        }
        let (total, overflow) = mediaDecodeBytes.addingReportingOverflow(genKVBytes)
        let bytes = overflow ? UInt64.max : total
        return await kvBudget.reserveBytes(requestID: requestId, bytes: bytes)
    }

    /// The model's configured context window (`max_position_embeddings`), or 0 if
    /// unknown. The KV cache can never hold more than this many prompt+vision
    /// tokens, so the vision-path reservation clamps its prompt+vision estimate to
    /// it (output tokens are added on top, matching the batched path's
    /// `promptTokenCount + maxTokens`).
    public func contextLength() -> Int { maxContextLength }

    /// Release a prior `reserveVisionRequest` reservation. Safe/no-op if unknown
    /// or budgeting is disabled.
    public func releaseVisionRequest(requestId: String) async {
        await kvBudget?.release(requestID: requestId)
    }

    // MARK: - Submit / cancel

    /// The scheduler token gate (`tokenBudgetMax`) counts MLX's reclaimable pool as
    /// used, so a request can be rejected with `token_budget_exhausted` even though
    /// flushing that pool would admit it — and that gate runs before the per-request
    /// KV reservation (which has its own self-heal). Flush once here when the gate is
    /// tight (rate-limited + shortfall-gated, sharing the reservation gate's limiter)
    /// so the gate is re-evaluated against the reclaimed headroom. Call this BEFORE
    /// reading `activeTokenBudgetUsed`, so its only suspension is outside the atomic
    /// activeUsed→bridge section the cumulative gate relies on.
    private func reclaimPoolForTokenBudget(requestBudget: Int) async {
        guard kvBytesPerToken > 0, let kvBudget else { return }
        let need = activeTokenBudgetUsed + requestBudget
        guard need > tokenBudgetMax else { return }
        let shortfallBytes = UInt64(need - tokenBudgetMax) * UInt64(kvBytesPerToken)
        // Fire-and-forget signal (nonisolated — no actor hop, no GPU wait). The
        // flush runs off the budget actor; `tokenBudgetMax` is re-read below
        // against the current snapshot (a near-miss may reject — acceptable; the
        // background reclaim and proactive sweep keep the pool small so most
        // admits succeed without ever near-missing).
        kvBudget.reclaimForShortfall(shortfallBytes)
    }

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
        // Flush the reclaimable pool before the token gate if it's tight (the gate
        // counts the pool as used). The await is here, before the atomic
        // activeUsed→bridge section below, so it adds no reentrancy there.
        await reclaimPoolForTokenBudget(requestBudget: requestBudget)
        let budgetMax = tokenBudgetMax
        guard requestBudget <= budgetMax else {
            // Rejected before any bridge exists — record demand for the liveness
            // watchdog (a pinned pool is detectable only via this signal).
            noteAdmissionReject()
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(budgetMax) available"
            ))
            continuation.finish()
            return stream
        }

        let activeUsed = activeTokenBudgetUsed
        if activeUsed + requestBudget > budgetMax {
            noteAdmissionReject()
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(budgetMax - activeUsed) available"
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

        var sp = SamplingParams(maxTokens: maxTokens, temperature: temperature)
        if let topP { sp.topP = topP }
        if let topK { sp.topK = topK }
        if let seed { sp.seed = seed }

        let req = Request(
            requestId: id,
            prompt: promptTokens as AnyHashable,
            samplingParams: sp
        )
        let plannedRestore = await planRestoredCheckpoint(
            promptTokens: promptTokens,
            scope: cacheScope,
            maxTokens: maxTokens
        )
        let acceptedRestore = acceptRestoredCheckpointBudget(
            requestId: id,
            requestTokens: requestBudget,
            admission: plannedRestore
        )
        let kvReservationTokens = acceptedRestore?.reservedTokens ?? requestBudget
        let kvOutcome = await reserveKVForRequest(
            requestId: id,
            requestTokens: requestBudget,
            reservationTokens: kvReservationTokens,
            restorePlanned: acceptedRestore != nil
        )
        guard kvOutcome != .failed else {
            await dropBridge(requestId: id)
            // The per-request KV reservation failed (collapsed headroom): the
            // bridge is dropped, so this too returns with no active entry. Record
            // demand for the liveness watchdog.
            noteAdmissionReject()
            continuation.yield(.error("token_budget_exhausted: insufficient global KV cache headroom"))
            continuation.finish()
            return stream
        }
        // Materialize the restore ONLY when its restore-sized reservation is held
        // (`.restoreReserved`). On `.coldReserved` the reserve downgraded a planned
        // restore (or none was planned): only the cold reservation is held, so
        // attaching restore-sized KV here would under-reserve and OOM. The
        // downgrade already cleared bridge.reservedTokens; req.restoredCheckpoint
        // stays nil and the request runs as a cold prefill.
        if kvOutcome == .restoreReserved, let acceptedRestore {
            await finalizeRestore(
                req,
                id: id,
                admission: acceptedRestore,
                promptTokens: promptTokens,
                scope: cacheScope,
                requestBudget: requestBudget
            )
        }
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
        // Flush the reclaimable pool before the token gate if it's tight (the gate
        // counts the pool as used). This await is intentionally before the atomic
        // activeUsed→bridge section below, so it adds no reentrancy there.
        await reclaimPoolForTokenBudget(requestBudget: requestBudget)
        let budgetMax = tokenBudgetMax
        guard requestBudget <= budgetMax else {
            // Rejected before any bridge exists — record demand for the liveness
            // watchdog (a pinned pool is detectable only via this signal).
            noteAdmissionReject()
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(budgetMax) available"
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
        if activeUsed + requestBudget > budgetMax {
            noteAdmissionReject()
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(budgetMax - activeUsed) available"
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
        let plannedRestore = await planRestoredCheckpoint(
            promptTokens: promptTokens,
            scope: request.cacheScope,
            maxTokens: maxTokens
        )
        let acceptedRestore = acceptRestoredCheckpointBudget(
            requestId: id,
            requestTokens: requestBudget,
            admission: plannedRestore
        )
        let kvReservationTokens = acceptedRestore?.reservedTokens ?? requestBudget
        let kvOutcome = await reserveKVForRequest(
            requestId: id,
            requestTokens: requestBudget,
            reservationTokens: kvReservationTokens,
            restorePlanned: acceptedRestore != nil
        )
        guard kvOutcome != .failed else {
            await dropBridge(requestId: id)
            // The per-request KV reservation failed (collapsed headroom): the
            // bridge is dropped, so this too returns with no active entry. Record
            // demand for the liveness watchdog.
            noteAdmissionReject()
            continuation.yield(.error("token_budget_exhausted: insufficient global KV cache headroom"))
            continuation.finish()
            return stream
        }
        // Materialize the restore ONLY when its restore-sized reservation is held
        // (`.restoreReserved`). On `.coldReserved` the reserve downgraded a planned
        // restore (or none was planned): only the cold reservation is held, so
        // attaching restore-sized KV here would under-reserve and OOM. The
        // downgrade already cleared bridge.reservedTokens; req.restoredCheckpoint
        // stays nil and the request runs as a cold prefill.
        if kvOutcome == .restoreReserved, let acceptedRestore {
            await finalizeRestore(
                req,
                id: id,
                admission: acceptedRestore,
                promptTokens: promptTokens,
                scope: request.cacheScope,
                requestBudget: requestBudget
            )
        }
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
        // Detach the engine synchronously, before any suspension below. The teardown
        // awaits (stats logging, stopAndWait) let a submit interleave on the actor;
        // if self.engine still pointed at the stopping engine it would pass
        // engineStillCurrent (epoch already bumped, identity still matches) and get
        // enqueued onto an engine being torn down. Nil'ing it now makes those
        // submits fail the guard and reject/retry against the next model instead.
        var stoppingEngine = self.engine
        self.engine = nil
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil
        // Stop the backend-liveness watchdog; a recovery restart re-arms it via
        // loadModel. (Note: when this teardown is part of a recovery restart, the
        // watchdog task currently awaiting `assessBackendLiveness` is the caller —
        // cancelling it here is the clean handoff; loadModel starts a fresh one.)
        livenessWatchdogTask?.cancel()
        livenessWatchdogTask = nil
        // Log a final stats line before teardown, then stop the periodic logger.
        await logPrefixCacheStats()
        prefixCacheStatsTask?.cancel()
        prefixCacheStatsTask = nil
        ttlReapTask?.cancel()
        ttlReapTask = nil

        if let engine = stoppingEngine {
            _ = engine.core.abortAllRequests()
            // Stop the loop AND wait for it to fully exit: this fences any in-flight
            // step's MLX work and releases the loop's hold on the engine.
            await engine.core.stopAndWait()
        }
        // Drop our own reference too, so the engine — and its batch KV, including
        // rows from the requests we just aborted — is released to the reclaimable
        // pool before the clearCache at the end of teardown.
        stoppingEngine = nil
        modelContainer = nil
        tokenizer = nil
        // Drain the bounded capture pipeline FIRST (#374): the engine is stopped
        // (no more capture hooks fire), so finish the stream and cancel the
        // consumer. This releases retained KV snapshots and stops an in-flight
        // `mgr.store` from racing the purge below.
        capturePipeline?.shutdown()
        capturePipeline = nil
        // Then purge this model's KV from BOTH RAM and SSD on unload (#363) —
        // restart warmth is intentionally OFF, so no KV (memory or disk) outlives
        // the loaded model. purgeOnUnload drains in-flight writes, clears the RAM
        // tier, deletes the kv/<modelKey> dir, and deregisters the accountant
        // (subsumes the old flushIndexNow + deregisterFromAccountant).
        if let mgr = checkpointManager {
            await mgr.purgeOnUnload()
        }
        // Drop the checkpoint manager so a stale one can't serve the next
        // model (the new model's loadModel reinstalls its own, or nil).
        checkpointManager = nil
        checkpointBoundaries = []
        checkpointLayerSignatures = []

        // Now that everything holding KV is released — the engine chain (batch KV),
        // the capture pipeline (retained snapshots) and the RAM prefix tier — return
        // the freed pool to the OS. Done here, after those releases, so the flush
        // doesn't miss KV that those steps move into the pool. Fence async GPU
        // completion first (M4 IOKit guard). Teardown runs with no engine, so this
        // actor block can't starve request admission.
        MLX.Stream().synchronize()
        MLX.Memory.clearCache()

        // Purge the engine-tier owner's on-disk dir too (same kv/<modelKey> dir;
        // whichever tier ran first already removed it, so this no-ops then).
        // purgeDir latches `closed` first so any in-flight engine-step save that
        // resumes after `engine.stop()` no-ops at its post-write bail.
        engineTierOwner?.purgeDir()
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
        currentWeightHash = nil
        kvBytesPerToken = 400_000
        fp16KVBytesPerToken = 400_000
        dynamicTokenBudgetMax = 0
        maxContextLength = 0
        defaultMaxTokens = initDefaultMaxTokens
        planner = nil
        observedDecodeTpsEwma = 0
        ewmaInitialized = false
        observedPrefillTpsEwma = 0
        prefillEwmaInitialized = false
        lastModelLoadMs = 0
        performanceByBatchSize.removeAll()
        // Reset the cold-start seed to the configured ceiling (same rationale as
        // the init / applyPostLoadBudgets seeds). With no model loaded the memory
        // clamp collapses to `maxConcurrentRequests` anyway; the next load
        // re-seeds and `syncEngineConcurrency()` re-clamps against real memory.
        dynamicMaxConcurrentRequests = max(1, maxConcurrentRequests)
        // Force the next load's `syncEngineConcurrency()` to push: the new engine
        // is built fresh and starts at its own default (`config.maxNumSeqs`), so
        // the cap must be re-sent even if it equals what the prior engine held.
        lastPushedMaxNumSeqs = -1
        // Reset backend-liveness diagnosis tracking for the next load (fresh
        // engine = healthy until proven otherwise). `isReloadingForRecovery` is
        // intentionally not reset here: it is owned by `selfRestartForRecovery`
        // so the heartbeat keeps reporting "reloading" across this teardown until
        // the replacement engine is up.
        livenessState = .healthy
        budgetCollapsedSince = nil
        lastSuccessAt = nil
        lastAdmissionRejectAt = nil
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
