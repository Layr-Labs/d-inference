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

private let prefixCacheLogger = Logger(subsystem: "dev.darkbloom.provider", category: "prefix-cache-wiring")

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
    /// `.checkpoint` AND `DARKBLOOM_PREFIX_CACHE` is on (mutually exclusive
    /// with the engine block tier, which serves pure-attention `.engine`
    /// models). Looked up in `submit` to seed a request's `restoredCheckpoint`;
    /// stored to via the scheduler's capture hook. nil ⇒ feature off for this
    /// model (today's behavior).
    var checkpointManager: PrefixCacheManager?
    /// Sliding-window-derived checkpoint boundaries for the current model.
    var checkpointBoundaries: [Int] = []

    /// Admission control + token budget tracking. `nil` until `loadModel()`.
    var planner: BatchQueuePlanner?

    /// Watchdog for planner-pending requests that exceed `pendingTimeout`.
    var pendingTimeoutTask: Task<Void, Never>?
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
        kvBudget: GlobalKVCacheBudget? = nil
    ) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.pendingTimeout = pendingTimeout
        self.defaultMaxTokens = defaultMaxTokens
        self.initDefaultMaxTokens = defaultMaxTokens
        self.kvBudget = kvBudget
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
            architecture: snapshot.architecture
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
        await engine.start()
        // Final epoch check after start() — start can suspend too.
        guard loadEpoch == generationEpoch else {
            self.engine = nil
            // Keep checkpointManager consistent with engine (don't leave a
            // stale manager pointing at the superseded model).
            self.checkpointManager = nil
            self.checkpointBoundaries = []
            await engine.stop()
            return
        }

        // Crash-consistency: reconcile the on-disk checkpoint files against
        // the index once, before serving. Reclaims orphans left by a crash
        // inside the index save-coalescing window (so they count toward the
        // disk budget and are reusable) and drops index entries whose files
        // vanished. Safe here: no requests admitted yet, so no concurrent
        // flush/lookup races the reconcile.
        if let mgr = checkpointManager { await mgr.reconcileWithDisk() }

        applyPostLoadBudgets(snapshot: snapshot)
        // Apply the conservative startup cap before admitting any request,
        // otherwise the first few submits could run at the hard cap until
        // the adaptive policy kicks in.
        engine.setMaxNumSeqs(dynamicMaxConcurrentRequests)
        self.planner = makePlanner(activeTokenBudget: tokenBudgetMax)
        // Engine has no pending-queue TTL; we enforce `pendingTimeout`.
        startPendingTimeoutWatchdog()
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
    private func maybeRestoreCheckpoint(_ req: Request, promptTokens: [Int]) async {
        guard let mgr = checkpointManager else { return }
        guard let hit = await mgr.lookup(tokens: promptTokens),
              hit.tokenCount >= 1, hit.tokenCount < promptTokens.count
        else { return }
        req.restoredCheckpoint = (caches: hit.caches, tokenCount: hit.tokenCount)
    }

    /// Result of building the engine: the engine itself plus the optional
    /// checkpoint-tier manager + its boundaries (non-nil only for hybrid
    /// `.checkpoint` models with the flag on). The caller stores the manager
    /// on the actor and uses it for `submit`-time lookup.
    struct EngineBuild {
        let engine: BatchedEngine
        let checkpointManager: PrefixCacheManager?
        let checkpointBoundaries: [Int]
    }

    private static func makeBatchedEngine(
        container: ModelContainer,
        modelId: String,
        weightHash: String?,
        weightBytes: Int,
        maxConcurrentRequests: Int,
        eosTokenIds: Set<Int>,
        architecture: ModelArchitecture
    ) async -> EngineBuild {
        // TB-007: the prefix cache is OFF by default. When the operator sets
        // DARKBLOOM_PREFIX_CACHE we enable it with an ENCRYPTED-at-rest
        // backend. This does NOT close the in-process cross-tenant sharing /
        // TTFT side-channel, so it ships only behind this flag + a
        // threat-model sign-off. See docs/ssd-kv-cache-design.md.
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

            if let backing {
                switch strategy {
                case .engine:
                    if maxBlocks >= 1 {
                        prefixCacheLogger.info(
                            "engine prefix cache: \(maxBlocks) blocks × \(blockSize) tok (~\(kvBytesPerToken) B/tok)")
                        enginePrefixCache = PrefixCache(
                            config: PrefixCacheConfig(blockSize: blockSize, maxBlocks: maxBlocks),
                            modelName: modelId,
                            persistence: EncryptedPrefixCachePersistence(
                                kekKey: backing.kekKey, dir: backing.dir,
                                binding: backing.binding, diskBudgetBytes: backing.diskBudgetBytes))
                    } else {
                        prefixCacheLogger.warning(
                            "prefix cache disabled: model KV (\(kvBytesPerToken) B/tok) exceeds the memory budget for even one block")
                    }
                case .checkpoint:
                    // Boundaries capped at the smallest sliding window so a
                    // snapshot never claims tokens a window has discarded.
                    let window = PrefixCacheStrategy.minSlidingWindow(ctx.model.newCache(parameters: nil)) ?? 0
                    boundaries = PrefixDigest.checkpoints(forSlidingWindow: window)
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
                        diskBudgetBytes: backing.diskBudgetBytes,
                        now: nowFn)
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
                    // Store to RAM (fast) then flush to encrypted SSD so the
                    // checkpoint survives restart — the whole point of the
                    // at-rest tier. Both run off the engine queue in a detached
                    // Task; flushToSSD is internally idempotent/skip-if-present.
                    Task {
                        await mgr.store(tokens: prefixTokens, checkpointLength: length, caches: box)
                        _ = await mgr.flushToSSD()
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
                checkpointBoundaries: boundaries
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
    }

    /// Build the shared encrypted-cache backing IFF the operator opted in via
    /// `DARKBLOOM_PREFIX_CACHE`. Returns nil (cache stays off) when the flag
    /// is unset, the model architecture is incomplete, or the persisted KEK
    /// is unavailable (no Secure Enclave / entitlement) — in the last case we
    /// refuse rather than use an ephemeral key that wouldn't survive restart.
    ///
    /// SECURITY (TB-007): see makeBatchedEngine. The cache is bound to the
    /// WEIGHT identity (`weightHash`) when known, not just the mutable model
    /// id — a re-download under the same id with different weights must not
    /// serve stale KV. Falls back to modelId when no weight hash is available.
    private static func makePrefixCacheBackingIfEnabled(
        modelId: String,
        weightHash: String?,
        architecture: ModelArchitecture
    ) async -> PrefixCacheBacking? {
        let env = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE"]
        guard env == "1" || env?.lowercased() == "true" else { return nil }

        prefixCacheLogger.warning(
            "DARKBLOOM_PREFIX_CACHE is ON — engine prefix cache enabled (TB-007: cross-tenant sharing / TTFT side-channel; encrypted-at-rest only)."
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
        let kek: KVCacheKEK
        do {
            let se = try PersistentEnclaveKey.loadOrCreate()
            kek = KVCacheKEK(
                wrapper: SecureEnclaveKeyWrappingService(enclaveKey: se),
                storage: KeychainWrappedKEKStorage()
            )
            kekKey = try await kek.loadOrCreate()
        } catch {
            prefixCacheLogger.warning("prefix cache disabled: KEK unavailable (\(String(describing: error)))")
            return nil
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
            kekKey: kekKey, kek: kek, dir: dir, binding: binding, diskBudgetBytes: diskBudget)
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

    /// On-disk budget for persisted prefix files. Operator override:
    /// DARKBLOOM_PREFIX_CACHE_DISK_GB (0 = unlimited). Default = 50% of the
    /// FREE space on the cache volume (measured live), so the cache scales
    /// to the disk and never fills it; falls back to 10 GB if free space
    /// can't be read.
    static func prefixCacheDiskBudgetBytes(cacheDir: URL) -> Int {
        let envGB = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_DISK_GB"]
            .flatMap(Double.init)
        return resolveDiskBudget(envGB: envGB, freeBytes: volumeFreeBytes(at: cacheDir))
    }

    /// Pure disk-budget policy (testable). An explicit env override wins
    /// (including 0 = unlimited). Otherwise take HALF of the measured free
    /// bytes — never 0, so a (near-)full disk yields a tiny positive budget
    /// (evict-almost-everything) rather than the env's "0 = unlimited".
    /// When free space is unknown, fall back to a conservative 10 GB.
    static func resolveDiskBudget(envGB: Double?, freeBytes: Int?) -> Int {
        // A valid in-range override wins (0 = unlimited). A non-finite or
        // overflowing value is rejected (Int(Double) would trap) and falls
        // through to the free-space default.
        if let gb = envGB, gb >= 0, gb.isFinite, gb < gbToBytesCeiling {
            return Int(gb * 1_073_741_824)
        }
        if let free = freeBytes { return max(1, free / 2) }
        return 10 * 1_073_741_824
    }

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
        requestId: String? = nil
    ) async -> AsyncStream<GenerationEvent> {
        let id = requestId ?? "req-\(UUID().uuidString.prefix(12))"
        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()

        guard let engine = self.engine else {
            continuation.yield(.error("No model loaded"))
            continuation.finish()
            return stream
        }

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
        await maybeRestoreCheckpoint(req, promptTokens: promptTokens)
        _ = await engine.core.addRequest(req)

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

        // P1 fix (atomic): the cumulative gate + slot reservation must
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
        await maybeRestoreCheckpoint(req, promptTokens: promptTokens)
        _ = await engine.core.addRequest(req)

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
            _ = engine.core.abortRequest(requestId)
            return
        }
        // No engine: request may still be planner-pending.
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

        if let engine = self.engine {
            _ = engine.core.abortAllRequests()
            await engine.stop()
        }
        self.engine = nil
        modelContainer = nil
        tokenizer = nil
        // Persist any coalesced index writes before dropping the manager, so
        // checkpoints written since the last coalesced save survive restart.
        if let mgr = checkpointManager { await mgr.flushIndexNow() }
        // Drop the checkpoint manager so a stale one can't serve the next
        // model (the new model's loadModel reinstalls its own, or nil).
        checkpointManager = nil
        checkpointBoundaries = []

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

    /// P1 fix: cumulative active-bridge gate, called from tests.
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
