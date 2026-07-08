// Copyright © 2026 Eigen Labs.
//
// BatchScheduler engine construction: build the MLXLMCommon.BatchedEngine with
// the provider policy layer, and (optionally) the prefix-cache backing tier.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation
import os

extension BatchScheduler {
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

    internal static func makeBatchedEngine(
        container: ModelContainer,
        modelId: String,
        weightHash: String?,
        weightBytes: Int,
        maxConcurrentRequests: Int,
        eosTokenIds: Set<Int>,
        architecture: ModelArchitecture,
        diskAccountant: GlobalDiskAccountant? = nil,
        kvQuantEnabled: Bool = false,
        adaptivePrefillRuntime: AdaptivePrefillRuntime? = nil
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

            // streamInterval: emit one SSE frame per N decoded tokens instead
            // of per-token. This dramatically reduces the WebSocket frame rate
            // under concurrent load — the provider funnels ALL concurrent
            // inference chunks through a single serial WS write loop
            // (OutboundRouter → CoordinatorClient+Connection Task 2), so at
            // streamInterval=1 with B concurrent requests the per-stream
            // inter-token gap scales ~linearly with B (each token's WS frame
            // waits behind B-1 other tokens' frames). At interval=8 the frame
            // count drops 8× and per-stream TPS recovers proportionally; vs the
            // prior interval=4 this halves the WS frame count from ~230 to ~115
            // per 918-token response. Combined with NWConnection's non-blocking
            // sends, this further reduces the CPU overhead from per-frame
            // encoding + encryption.
            //
            // UX impact: at 130 tok/s the client receives an 8-token burst every
            // ~62ms — smoother than 60 fps, visually indistinguishable from
            // per-token streaming. The client TPS metric (total tokens / elapsed)
            // is unaffected because it measures total delivery, not chunk cadence.
            let streamInterval = 4

            let scheduler = Scheduler(
                model: ctx.model,
                tokenizer: ctx.tokenizer,
                config: SchedulerConfig(
                    maxNumSeqs: maxConcurrentRequests,
                    maxNumBatchedTokens: 8192,
                    prefillStepSize: 512,
                    streamInterval: streamInterval,
                    maxKVCacheTokens: 0,  // unlimited — our kvBudget gates by bytes
                    kvQuantization: kvQuantScheme?.schedulerConfig
                ),
                eosTokenIds: eosTokenIds,
                prefixCache: enginePrefixCache  // nil unless .engine + flag (TB-007)
            )
            if let adaptivePrefillRuntime {
                scheduler.adaptivePrefillChunkSizer = adaptivePrefillRuntime.proposeChunkSize
                scheduler.onColdPrefillChunk = adaptivePrefillRuntime.record
                adaptivePrefillLogger.notice(
                    "adaptive-prefill enabled: starting cold-prefill chunk \(adaptivePrefillRuntime.snapshotState().currentChunkSize)"
                )
            }
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

    /// Build the shared encrypted-cache backing. As of v0.7.5 the prefix
    /// cache is DORMANT BY DEFAULT (resident RAM belongs to live serving —
    /// see `PrefixCachePolicy`'s header); a box opts IN with
    /// `DARKBLOOM_PREFIX_CACHE=1`. Returns nil (cache stays off) when not
    /// opted in, the model architecture is incomplete, or the persisted KEK
    /// is unavailable (no Secure Enclave / entitlement) — in the last case we
    /// refuse rather than use an ephemeral key that wouldn't survive restart.
    ///
    /// SECURITY (TB-007): the prefix cache shares KV prefixes across consumers
    /// and the hit/miss TTFT difference is a cross-tenant timing side channel
    /// that encryption-at-rest does NOT mitigate — the dormant default keeps
    /// that channel closed unless a deployment explicitly opts in (SEC-035
    /// then applies to the opted-in box). The cache is bound
    /// to the WEIGHT identity (`weightHash`) when known, not just the mutable
    /// model id — a re-download under the same id with different weights must not
    /// serve stale KV. Falls back to modelId when no weight hash is available.
    private static func makePrefixCacheBackingIfEnabled(
        modelId: String,
        weightHash: String?,
        architecture: ModelArchitecture
    ) async -> PrefixCacheBacking? {
        // OPT-IN (v0.7.5): gate semantics shared with the v2 engine via
        // `PrefixCachePolicy.isEnabled` — one flag governs both engines
        // (T-041); absent ⇒ dormant.
        guard PrefixCachePolicy.isEnabled() else {
            prefixCacheLogger.info(
                "prefix cache DORMANT (default; opt in with DARKBLOOM_PREFIX_CACHE=1).")
            return nil
        }

        // `.notice` not `.warning`: os.Logger maps warning()->OSLogType.error,
        // so this routine banner showed as type=Error in log reports.
        prefixCacheLogger.notice(
            "Prefix cache is ON (explicit DARKBLOOM_PREFIX_CACHE opt-in) — TB-007: cross-tenant sharing / TTFT side-channel; encrypted-at-rest only."
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
        let modelKey = SHA256.hash(data: Data(modelId.utf8)).hexString.prefix(12)
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

}
