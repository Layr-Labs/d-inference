// Copyright © 2026 Eigen Labs.
//
// BatchScheduler model lifecycle: loadModel (snapshot, EOS/type detection,
// post-load budgets, engine wiring), unloadModel, and the vision-request
// reservation surface. Engine construction itself lives in +EngineFactory.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation
import os

extension BatchScheduler {
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
        // Engine-health trail: record the load-start milestone (offline debug).
        emitModelLoadMilestone(operation: "model_load_start", model: modelId)

        let snapshot = await Self.snapshotContainer(container)
        // Detect concurrent reload that won the race; bail before we
        // overwrite the new model's state with our stale snapshot.
        guard loadEpoch == generationEpoch else { return }

        self.modelContainer = container
        self.modelId = modelId
        self.currentWeightHash = weightHash
        self.modelWeightBytes = snapshot.bytes
        self.tokenizer = snapshot.tokenizer
        let adaptivePrefillRuntime = makeAdaptivePrefillRuntime(
            modelId: modelId,
            weightHash: weightHash,
            snapshot: snapshot
        )

        let build = await Self.makeBatchedEngine(
            container: container,
            modelId: modelId,
            weightHash: weightHash,
            weightBytes: snapshot.bytes,
            maxConcurrentRequests: maxConcurrentRequests,
            eosTokenIds: Self.effectiveEOSTokenIds(
                modelId: modelId,
                modelType: snapshot.modelType,
                base: snapshot.eosTokenIds,
                tokenToId: snapshot.tokenizer.inner.convertTokenToId
            ),
            architecture: snapshot.architecture,
            diskAccountant: diskAccountant,
            kvQuantEnabled: kvQuantEnabled,
            adaptivePrefillRuntime: adaptivePrefillRuntime
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
        self.adaptivePrefillRuntime = adaptivePrefillRuntime
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
            if self.adaptivePrefillRuntime === adaptivePrefillRuntime { self.adaptivePrefillRuntime = nil }
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
            if self.adaptivePrefillRuntime === adaptivePrefillRuntime { self.adaptivePrefillRuntime = nil }
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
                    if self.adaptivePrefillRuntime === adaptivePrefillRuntime { self.adaptivePrefillRuntime = nil }
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
        // Engine-health trail: record the load-complete milestone + cold-start
        // duration (offline debug). Only reached on a successful, non-superseded
        // load (superseded loads return early above).
        emitModelLoadMilestone(
            operation: "model_load_complete", model: modelId, durationMs: lastModelLoadMs)
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
            let modelType: String?
            if case .directory(let modelDir) = ctx.configuration.id {
                let configURL = modelDir.appendingPathComponent("config.json")
                architecture = KVEstimation.parseModelArchitecture(at: configURL)
                modelType = Self.modelType(at: configURL)
            } else {
                architecture = .empty
                modelType = nil
            }
            return LoadSnapshot(
                bytes: bytes,
                tokenizer: TokenizerHandle(ctx.tokenizer),
                eosTokenIds: ctx.configuration.eosTokenIds,
                modelType: modelType,
                architecture: architecture
            )
        }
    }

    /// Return model-specific EOS tokens at the scheduler boundary. Most models
    /// keep the loader-provided set; GPT-OSS/Harmony adds its generation-config
    /// action stops via `GPTOSSHarmonyTemplateFix`.
    static func effectiveEOSTokenIds(
        modelId: String,
        modelType: String? = nil,
        base: Set<Int>,
        tokenToId: (String) -> Int?
    ) -> Set<Int> {
        let context = ChatTemplateFixContext(modelId: modelId, modelType: modelType)
        return ChatTemplateFixes.extraEOSTokenIds(
            context: context,
            base: base,
            tokenToId: tokenToId
        )
    }

    private static func modelType(at configURL: URL) -> String? {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["model_type"] as? String
    }

    /// Build a `BatchedEngine` with our scheduler config. Pulled out
    /// of `loadModel` so the lifecycle code reads as a sequence of
    /// 5-line steps. SECURITY (TB-007): the engine's prefix cache
    /// persists token sequences across requests in process memory.
    /// Cross-tenant data-leak risk; do not enable without a fresh
    /// threat model.
    internal struct RestoredCheckpointAdmission {
        let candidate: PrefixLookupCandidate
        let reservedTokens: Int
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

}
