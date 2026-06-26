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
//   * `BatchScheduler+ModelLifecycle.swift` — loadModel/unloadModel + vision
//   * `BatchScheduler+EngineFactory.swift`  — BatchedEngine + prefix-tier build
//   * `BatchScheduler+CheckpointRestore.swift` — restored-KV plan/materialize
//   * `BatchScheduler+Admission.swift`    — KV reservation + admission
//   * `BatchScheduler+Submit.swift`       — submit/cancel paths
//   * `BatchScheduler+PrefixCacheSizing.swift` — pure sizing/binding helpers
//   * `BatchScheduler+Liveness.swift`     — backend-liveness watchdog
//   * `BatchScheduler+KVQuantScheme.swift`— engine KV-quant scheme
//   * `BatchScheduler+Testing.swift`      — test-only seams
//
// Access note: stored state and the methods reached across the split above are
// `internal` (not `private`) so the actor can be split by concern in-module
// (Swift `private` is file-scoped). Only members actually reached across the
// split are widened; behavior is unchanged.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation
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
    /// Opt-in adaptive cold-prefill chunk sizing flag from provider config.
    /// False preserves the fixed 512-token production scheduler path.
    let adaptivePrefillEnabled: Bool

    /// Detected local hardware. Drives the adaptive cold-prefill roofline seed
    /// (`AdaptivePrefillSeed`). nil ⇒ unknown hardware ⇒ generic empirical ladder.
    let hardwareInfo: HardwareInfo?

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
    var adaptivePrefillRuntime: AdaptivePrefillRuntime?

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
    internal var _forceEnginePrefixCacheActiveForTest = false

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

    /// In-flight B=1 greedy fast-path tasks, keyed by request id. The fast path
    /// (see `BatchScheduler+B1FastPath.swift`) bypasses the batched engine for a
    /// single exclusive greedy request and runs `ModelContainer.generate`
    /// directly, so it is NOT registered with `engine.core` — `cancel` /
    /// `cancelAll` / `stopCurrentEngine` must cancel these tasks here (the
    /// engine abort path can't reach them). Each task removes its own entry on
    /// completion via `clearFastPathTask`.
    var fastPathTasks: [String: Task<Void, Never>] = [:]

    /// Test-only override for the B=1 fast-path enablement gate. `nil` (the
    /// production default) defers to the env flags via `b1GreedyFastPathEnabled()`.
    /// Set via `_setForceB1FastPathForTest` so a benchmark can A/B the fast path
    /// against the batched engine in one process without relying on mutating the
    /// (often cached) `ProcessInfo` environment mid-run. @testable-only.
    internal var _forceB1FastPathForTest: Bool? = nil

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

    // MARK: - Engine-health / first-token-wedge instrumentation
    //
    // MEASUREMENT ONLY (docs/reports/2026-06-22-cancel-root-cause-and-fix.md §C).
    // `wedgeMonitor` counts admits/first-tokens/engine-steps so the heartbeat
    // (`backendCapacity()`) and the offline telemetry trail can SEE a first-token
    // wedge. No routing/watchdog action is taken on these signals in this PR.

    /// Per-load engine-health counters. Reset in `stopCurrentEngine` (every load
    /// path runs it first), so a reload clears the wedge and `stepsExecuted`
    /// re-baselines against the fresh engine.
    var wedgeMonitor = WedgeMonitor()
    /// When the periodic `engine_health` telemetry snapshot was last emitted;
    /// nil until the first emit of the current load. Rate-limits the trail.
    var lastEngineHealthEmitAt: ContinuousClock.Instant?
    /// Last `wedgeSuspected` value pushed as a telemetry event, so a state
    /// transition (healthy→suspected / suspected→recovered) emits immediately.
    var lastWedgeSuspectedEmitted = false

    /// Per-load prefill-EWMA sampling health (accepted / floor-dropped /
    /// ceiling-dropped + last raw sample). Tracks why `observedPrefillTpsEwma`
    /// stays 0; surfaced on the `engine_health` trail. MEASUREMENT ONLY. Reset in
    /// `stopCurrentEngine` alongside `observedPrefillTpsEwma` (which is also reset
    /// there) so a model swap doesn't carry the previous model's counts.
    var prefillHealth = PrefillSamplingHealth()

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
        kvQuantEnabled: Bool = false,
        adaptivePrefillEnabled: Bool = false,
        hardwareInfo: HardwareInfo? = nil
    ) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.pendingTimeout = pendingTimeout
        self.defaultMaxTokens = defaultMaxTokens
        self.initDefaultMaxTokens = defaultMaxTokens
        self.kvBudget = kvBudget
        self.diskAccountant = diskAccountant
        self.kvQuantEnabled = kvQuantEnabled
        self.adaptivePrefillEnabled = adaptivePrefillEnabled
        self.hardwareInfo = hardwareInfo
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

    internal func stopCurrentEngine() async {
        generationEpoch &+= 1
        // Per-load engine-health reset: a fresh engine re-baselines stepsExecuted
        // from 0 and a reload clears any wedge, so the counters/cadence start clean.
        wedgeMonitor.reset()
        lastEngineHealthEmitAt = nil
        lastWedgeSuspectedEmitted = false
        // Detach the engine synchronously, before any suspension below. The teardown
        // awaits (stats logging, stopAndWait) let a submit interleave on the actor;
        // if self.engine still pointed at the stopping engine it would pass
        // engineStillCurrent (epoch already bumped, identity still matches) and get
        // enqueued onto an engine being torn down. Nil'ing it now makes those
        // submits fail the guard and reject/retry against the next model instead.
        var stoppingEngine = self.engine
        self.engine = nil
        // Tear down any in-flight B=1 fast-path tasks: they run off-engine via
        // `ModelContainer.generate`, so the engine abort below can't reach them.
        // We must FENCE (not just cancel) them here — before this teardown nil's
        // `modelContainer` and runs `MLX.Memory.clearCache()` below — because a
        // task still inside its `generate` loop holds and runs GPU work against
        // the model + its KV. `waitForFastPathTasks` cancels each task and awaits
        // its unwind (cancellation observation + finish bookkeeping: KV release,
        // bridge removal, terminal events). The await suspends this actor so those
        // callbacks make progress; no new fast path can start because `engine` is
        // already nil above (every submit path short-circuits on a nil engine).
        await waitForFastPathTasks()
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
        adaptivePrefillRuntime = nil
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
        // Reset prefill-sampling health alongside the EWMA it tracks, so a new
        // model's engine_health doesn't inherit the previous model's accepted/
        // dropped/last-sample counts.
        prefillHealth = PrefillSamplingHealth()
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

    internal func makePlanner(activeTokenBudget: Int) -> BatchQueuePlanner {
        BatchQueuePlanner(
            policy: BatchSchedulingPolicy(
                maxConcurrentRequests: maxConcurrentRequests,
                maxQueuedRequests: 128,
                maxActiveTokenBudget: activeTokenBudget,
                maxTokensPerBatch: resolvedMaxTokensPerBatch(activeTokenBudget: activeTokenBudget)
            )
        )
    }

    internal func refreshPlannerPolicy(activeTokenBudget: Int) async {
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
