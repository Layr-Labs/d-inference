/// ProviderLoop -- ContinuousBatchingV2 (engine v2) slot wiring.
///
/// v0.7.5 ONE-ENGINE: every model slot serves through a v2 bridge — there
/// is no selection gate and no legacy fallback. At model-load time
/// `ensureModelLoaded` calls `resliceAndBuildEngineV2Slot`, which:
///
///   1. snapshots every existing slot's CURRENT engine KV grant,
///   2. computes fair-share grants for existing + newcomer against the
///      fleet KV budget (`EngineV2KVSizing.resliceGrants` — a single-model
///      box keeps the FULL budget; ≥2 share ∝ fp16 rate × capped context),
///   3. refuses the load (fail loud, 503) if any share would fall below
///      the serviceability floor,
///   4. SHRINKS existing engines via `updateKVBytesCapacity` (engine-safe:
///      in-flight reservations untouched, new admits fail until drain),
///   5. builds the newcomer's engine + bridge with its grant
///      (`EngineV2Factory.makeBridge`, throwing) — and on ANY throw
///      RESTORES every existing grant exactly before rethrowing,
///   6. applies any grow-side targets and registers the bridge.
///
/// `unloadModel` calls `resliceGrowSurvivors()` after teardown so the
/// remaining slots grow back to their re-sliced shares.

import Foundation
import MLX
import MLXLMCommon
#if canImport(os)
import os
#endif

/// Ownership box for a loading model's container (the "newcomer").
/// `ensureModelLoaded` routes every container access through this box so
/// failure unwinds can drop the LAST strong reference to the weights —
/// `release()` — BEFORE survivor grants are restored or regrown (Codex
/// review): restoring first would let Σ(engine grants) transiently exceed
/// the true fleet budget while the failed newcomer's weights are still
/// resident, over-advertising capacity the shared KV gate then rejects
/// (the gray-box class). NSLock-guarded and `@unchecked Sendable` only so
/// test seams can hand it across the ProviderLoop actor boundary; all
/// production access is ProviderLoop-actor confined.
final class EngineV2NewcomerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _container: MLXLMCommon.ModelContainer?

    init(_ container: MLXLMCommon.ModelContainer) {
        self._container = container
    }

    /// The container, or nil after `release()`.
    var container: MLXLMCommon.ModelContainer? {
        lock.withLock { _container }
    }

    /// Transient access for a single call. NEVER bind the result to a
    /// long-lived local — that would keep the weights alive past
    /// `release()` and defeat the unwind ordering.
    func borrow() throws -> MLXLMCommon.ModelContainer {
        guard let container = (lock.withLock { _container }) else {
            // Only reachable through a wiring bug (use-after-release);
            // maps to 500 via the existing InferenceError handling.
            throw InferenceError.noModelLoaded
        }
        return container
    }

    /// Drop the strong reference to the container. The weights become
    /// reclaimable; pair with `MLX.Memory.clearCache()` so the pool
    /// returns their buffers before anything re-reads live residency.
    func release() {
        lock.withLock { _container = nil }
    }
}

extension ProviderLoop {

    /// Whether any live slot exists. Every slot serves through the v2
    /// engine as of v0.7.5, so this is a plain occupancy check — the
    /// capacity/cancellation hooks use it to skip the runtime actor hop
    /// when nothing is loaded.
    internal var hasEngineV2Slots: Bool {
        !modelSlots.isEmpty
    }

    /// Test hooks for the slot factory (`ProviderLoop+Testing`): replace the
    /// container-derived EOS snapshot and the production engine builder so
    /// unit tests can drive the full wiring path with a scripted
    /// `CBv2Engine` — no model weights, no network. `physicalMemoryBytes`
    /// additionally overrides the machine memory the re-slice budget is
    /// computed from, so grant arithmetic is deterministic in tests.
    struct EngineV2SlotHooks: Sendable {
        /// Environment the prefix-cache gate/budget/carve policy reads
        /// (`DARKBLOOM_PREFIX_CACHE*`). Defaults to EMPTY — the dormant
        /// fleet default — so grant-arithmetic tests are hermetic; carve
        /// tests inject an opted-in environment explicitly.
        let environment: [String: String]
        let eosTokenIds: Set<Int>
        let extraEOSTokens: [String]
        let emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?
        /// Machine-memory override for the re-slice fleet budget (nil ⇒
        /// real physical memory).
        let physicalMemoryBytes: UInt64?
        /// Scripted engine builder: (modelId, kvBytesCapacity) — the second
        /// argument is the RE-SLICED, POST-CARVE admission ceiling the
        /// production path would hand `makeProductionEngine`, exposed so
        /// tests can assert the multi-slot grant + carve derivation without
        /// building a real engine.
        let makeEngine: @Sendable (String, Int) throws -> any CBv2Engine

        init(
            environment: [String: String] = [:],
            eosTokenIds: Set<Int> = [],
            extraEOSTokens: [String] = [],
            emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
            physicalMemoryBytes: UInt64? = nil,
            makeEngine: @escaping @Sendable (String, Int) throws -> any CBv2Engine
        ) {
            self.environment = environment
            self.eosTokenIds = eosTokenIds
            self.extraEOSTokens = extraEOSTokens
            self.emitTelemetry = emitTelemetry
            self.physicalMemoryBytes = physicalMemoryBytes
            self.makeEngine = makeEngine
        }
    }

    // MARK: - Re-slice orchestration

    /// One existing slot's re-slice bookkeeping: its sizing inputs, its
    /// engine grant BEFORE this re-slice (the restore point), and the
    /// bridge whose ceiling gets updated.
    private struct ExistingSlotGrant {
        let slot: EngineV2KVSizing.ResliceSlot
        let previousGrant: Int
        let bridge: EngineV2Bridge
    }

    /// Fleet KV budget for a prospective residency set: the unified-memory
    /// cap minus Σ resident weights (ALL slots, including any mid-unload —
    /// their weights are still resident — plus the newcomer's), minus the
    /// activation reserve, honoring the operator `memory_reserve_gb`.
    private func fleetKVBudgetBytes(extraWeightBytes: Int) -> UInt64 {
        var totalWeights = UInt64(max(0, extraWeightBytes))
        for (_, slot) in modelSlots {
            let (sum, overflow) = totalWeights
                .addingReportingOverflow(UInt64(max(0, slot.sizing.weightsBytes)))
            totalWeights = overflow ? .max : sum
        }
        let physical = engineV2SlotHooks?.physicalMemoryBytes
            ?? ProcessInfo.processInfo.physicalMemory
        return UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physical,
            residentWeightBytes: totalWeights,
            configReserveBytes: Self.memoryReserveBytes(
                forGiB: loopConfig.config.provider.memoryReserveGB))
    }

    /// Existing v2 slots eligible for re-slicing: live (not mid-unload)
    /// slots other than `excludingModelId` (a same-id slot present during a
    /// reload is excluded so its weights/grant are not double-counted).
    /// Reads each slot's CURRENT TOTAL claim (post-any-earlier-resize):
    /// engine admission ceiling PLUS the slot's fixed prefix-cache budget
    /// (`slotKVBytesClaim`, T-041) — counting only the engine ceiling would
    /// re-grant the cache's bytes to a newcomer. Grants flowing back down
    /// (`updateKVBytesCapacity`) are totals too; the bridge nets out its
    /// own cache budget before touching the engine.
    private func existingSlotGrants(excludingModelId: String) async -> [ExistingSlotGrant] {
        var existing: [ExistingSlotGrant] = []
        for (slotModelId, slot) in modelSlots
        where slotModelId != excludingModelId && !modelsUnloading.contains(slotModelId) {
            let currentGrant = await slot.engineV2.slotKVBytesClaim()
            existing.append(
                ExistingSlotGrant(
                    slot: EngineV2KVSizing.ResliceSlot(
                        modelId: slotModelId,
                        fp16KVBytesPerToken: slot.sizing.fp16KVBytesPerToken,
                        maxContextLength: slot.sizing.maxContextLength),
                    previousGrant: currentGrant,
                    bridge: slot.engineV2))
        }
        return existing
    }

    /// Acquire the KV-grant re-slice gate (see the `isReslicing` doc in
    /// ProviderLoop.swift): only one grant-mutating section — a load's
    /// re-slice-through-install or an unload's regrow — runs at a time, so
    /// a snapshot of current grants can never go stale under a concurrent
    /// mutation. Internal: `ensureModelLoaded` holds it across the WHOLE
    /// shrink → build → guard → install-slot sequence — releasing at the
    /// end of `resliceAndBuildEngineV2Slot` would let a parked regrow run
    /// in the gap before the newcomer's slot is installed, recompute
    /// without it, and re-inflate the survivors past the fleet budget.
    internal func acquireResliceGate() async {
        while isReslicing {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                resliceGateWaiters.append(cont)
            }
        }
        isReslicing = true
    }

    internal func releaseResliceGate() {
        isReslicing = false
        let waiters = resliceGateWaiters
        resliceGateWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Re-slice KV grants for the newcomer + existing slots, shrink
    /// existing engines, and build the newcomer's bridge. On ANY throw —
    /// re-slice floor, extraction failure, engine construction — the
    /// newcomer's weights are RELEASED (box + clearCache) and only THEN is
    /// every existing engine's grant RESTORED exactly (Codex-review
    /// ordering: restoring first would let Σ(grants) exceed the true fleet
    /// budget while the failed newcomer's weights are still resident).
    /// Returns the bridge, already registered with `engineV2Runtime`.
    /// CALLER HOLDS the re-slice gate (see `acquireResliceGate`), spanning
    /// through slot installation, so a concurrent idle-timeout unload's
    /// regrow cannot interleave with the shrink→build→install sequence
    /// (Σ(grants) ≤ budget holds at every suspension point).
    internal func resliceAndBuildEngineV2Slot(
        modelId: String,
        modelType: String?,
        isVLM: Bool,
        modelDirectory: URL?,
        newcomer newcomerBox: EngineV2NewcomerBox,
        tokenizer: TokenizerHandle,
        sizing: SlotSizingSnapshot
    ) async throws -> EngineV2Bridge {
        let existing = await existingSlotGrants(excludingModelId: modelId)
        let newcomer = EngineV2KVSizing.ResliceSlot(
            modelId: modelId,
            fp16KVBytesPerToken: sizing.fp16KVBytesPerToken,
            maxContextLength: sizing.maxContextLength)
        let fleetBudget = fleetKVBudgetBytes(extraWeightBytes: sizing.weightsBytes)
        let targets = EngineV2KVSizing.resliceGrants(
            existing: existing.map(\.slot),
            newcomer: newcomer,
            fleetKVBudgetBytes: fleetBudget)

        // Serviceability floor (fail loud): a slice that would leave ANY
        // slot below the minimum serveable grant is refused outright —
        // thrashing every co-resident model below serviceability serves
        // no one. ERROR telemetry + 503 (the coordinator reroutes).
        // Existing slots' prefix-cache budgets are construction-FIXED
        // (T-041): the floor applies to what would remain for their
        // ENGINE (target − cache budget), never to the raw total. The
        // newcomer needs only the plain floor — its carve is elastic
        // (`PrefixCachePolicy.carve` shrinks the cache before the engine).
        var fixedCarveBytes: [String: Int] = [:]
        for entry in existing where entry.bridge.prefixCacheBudgetBytes > 0 {
            fixedCarveBytes[entry.slot.modelId] = entry.bridge.prefixCacheBudgetBytes
        }
        guard
            EngineV2KVSizing.resliceMeetsServiceabilityFloor(
                targets, fixedCarveBytes: fixedCarveBytes)
        else {
            let floorGb = String(
                format: "%.1f",
                Double(EngineV2KVSizing.minimumServiceableGrantBytes) / (1024 * 1024 * 1024))
            let message = "loading '\(modelId)' would re-slice some model's KV grant below "
                + "the \(floorGb) GB serviceability floor "
                + "(fleet KV budget \(fleetBudget) B across \(existing.count + 1) slots) — refused"
            EngineV2Factory.emitRefusalTelemetry(
                modelId: modelId,
                reason: .resliceFloor,
                error: nil,
                emitTelemetry: engineV2SlotHooks?.emitTelemetry)
            // Pre-shrink refusal: no grants were mutated, but drop the
            // newcomer's weights promptly so live residency reflects the
            // refusal before the caller's error handling runs.
            newcomerBox.release()
            MLX.Memory.clearCache()
            throw InferenceError.modelLoadFailed(message)
        }

        // Phase 1 — SHRINKS first, so Σ(ceilings) never exceeds the fleet
        // budget at any instant. Engine-side shrink semantics: in-flight
        // reservations untouched; new reserves fail until the pool drains.
        for entry in existing {
            if let target = targets[entry.slot.modelId], target < entry.previousGrant {
                await entry.bridge.updateKVBytesCapacity(target)
            }
        }

        // Phase 2 — build the newcomer with its grant. Restore-on-throw,
        // in the Codex-review order: (1) release the newcomer's weights,
        // (2) clearCache so the pool returns their buffers, (3) grow every
        // shrunk engine back to its exact previous grant. Restoring before
        // the weights are gone would let Σ(grants) exceed the true fleet
        // budget for as long as the failed container stayed resident.
        // `borrow()` is evaluated inline so the container reference lives
        // only for the duration of the call — by the time this catch runs,
        // the box holds the last strong reference and `release()` frees it.
        let bridge: EngineV2Bridge
        do {
            bridge = try await makeEngineV2BridgeForSlot(
                modelId: modelId,
                modelType: modelType,
                isVLM: isVLM,
                modelDirectory: modelDirectory,
                container: newcomerBox.borrow(),
                tokenizer: tokenizer,
                sizing: sizing,
                kvBytesCapacity: targets[modelId] ?? 0)
        } catch {
            newcomerBox.release()
            MLX.Memory.clearCache()
            for entry in existing {
                await entry.bridge.updateKVBytesCapacity(entry.previousGrant)
            }
            throw error
        }

        // Phase 3 — grow-side targets (rare on load: the budget shrank, so
        // proportional shares shrink too; kept for self-healing when a
        // previous state left a slot under-granted).
        for entry in existing {
            if let target = targets[entry.slot.modelId], target > entry.previousGrant {
                await entry.bridge.updateKVBytesCapacity(target)
            }
        }
        return bridge
    }

    /// Failure unwind AFTER a successful bridge build (the post-bridge
    /// headroom guard): retire the bridge, RELEASE the aborted newcomer's
    /// weights, and only then regrow the survivors — in that order (Codex
    /// review), so the regrow's fleet budget reflects true residency and
    /// Σ(grants) never exceeds it. Caller holds the re-slice gate.
    internal func unwindBuiltSlotAndRegrow(
        modelId: String,
        bridge: EngineV2Bridge,
        newcomer: EngineV2NewcomerBox
    ) async {
        await engineV2Runtime.unregister(modelId: modelId)
        await bridge.shutdown()
        newcomer.release()
        MLX.Memory.clearCache()
        await resliceGrowSurvivorsLocked()
    }

    /// Grow the surviving slots back to their re-sliced shares after an
    /// unload (a lone survivor gets the FULL fleet budget back). Gated: a
    /// regrow queued behind an in-flight load's re-slice-through-install
    /// recomputes AFTER it, over the then-current slots, so the two can
    /// never interleave.
    internal func resliceGrowSurvivors() async {
        await acquireResliceGate()
        defer { releaseResliceGate() }
        await resliceGrowSurvivorsLocked()
    }

    /// Regrow body — caller holds the re-slice gate. Shrink targets, if
    /// the budget somehow contracted, are applied first so the Σ ≤ budget
    /// invariant holds throughout. Used directly by `ensureModelLoaded`'s
    /// post-bridge-guard failure path, which already holds the gate.
    internal func resliceGrowSurvivorsLocked() async {
        let survivors = await existingSlotGrants(excludingModelId: "")
        guard !survivors.isEmpty else { return }
        let fleetBudget = fleetKVBudgetBytes(extraWeightBytes: 0)
        let targets = EngineV2KVSizing.resliceGrants(
            existing: survivors.map(\.slot),
            newcomer: nil,
            fleetKVBudgetBytes: fleetBudget)
        for entry in survivors {
            if let target = targets[entry.slot.modelId], target < entry.previousGrant {
                await entry.bridge.updateKVBytesCapacity(target)
            }
        }
        for entry in survivors {
            if let target = targets[entry.slot.modelId], target > entry.previousGrant {
                await entry.bridge.updateKVBytesCapacity(target)
            }
        }
    }

    // MARK: - Bridge construction

    /// Build + register the v2 bridge for a freshly-loaded model slot with
    /// an already-computed KV grant. THROWS on construction failure (the
    /// factory emits the ERROR `engine_v2_refusal` event first) — the
    /// caller unloads and maps to 503. There is no legacy path.
    ///
    /// VLM slots: every production Gemma 4 checkpoint ships a vision tower,
    /// so the loaded module is MLXVLM's wrapper — which has no CBv2 hooks.
    /// The engine is built over `EngineV2VLMTextExtraction`'s weight-sharing
    /// MLXLLM text model: TEXT requests serve through v2, IMAGE requests
    /// prefill through v2 via `EngineV2VisionPrefill`, and (in this branch
    /// state) VIDEO requests still run the legacy VLM container path — see
    /// `MultiModelBatchSchedulerEngine.streamChatCompletion`.
    ///
    /// On success the bridge is registered with `engineV2Runtime` BEFORE the
    /// caller installs the slot, so a request routed the instant the slot
    /// appears already has working capacity/cancel fan-out.
    internal func makeEngineV2BridgeForSlot(
        modelId: String,
        modelType: String?,
        isVLM: Bool = false,
        modelDirectory: URL? = nil,
        container: ModelContainer,
        tokenizer: TokenizerHandle,
        sizing: SlotSizingSnapshot,
        kvBytesCapacity: Int
    ) async throws -> EngineV2Bridge {
        let maxConcurrent = engineV2MaxConcurrent(forModel: modelId)

        // Assembly is shared with the standalone server via
        // `EngineV2SlotFactory` (one construction path, no drift) —
        // including THE single prefix-cache carve point (T-041, v0.7.5):
        // the slot's re-slice grant is split between the engine's admission
        // ceiling and the RAM-only v2 prefix cache INSIDE the factory
        // (order: re-slice grant → funding-gated carve (dormant ⇒
        // passthrough) → engine construction), so everything downstream
        // reads engine truth and the coordinator is never told about bytes
        // the cache will consume. The test hooks, when installed, replace
        // the container-derived EOS snapshot and the production engine
        // builder so unit tests can drive the wiring with a scripted
        // `CBv2Engine` — no weights, no container reads; the hooks path
        // runs the SAME carve policy (hooks' environment, adoption bound 0)
        // and hands the builder the REDUCED capacity, and the bridge the
        // budget bookkeeping, so the claim/heartbeat math is testable
        // without a real engine (no cache INSTANCE exists under hooks).
        let bridge: EngineV2Bridge
        if let hooks = engineV2SlotHooks {
            let carve = EngineV2SlotFactory.resolvePrefixCarve(
                modelId: modelId,
                isVLM: isVLM,
                modelDirectory: modelDirectory,
                model: nil,
                slotKVBytesCapacity: kvBytesCapacity,
                kvBytesPerToken: sizing.fp16KVBytesPerToken,
                environment: hooks.environment
            ).carve
            let hookBuilder = hooks.makeEngine
            bridge = try EngineV2Factory.makeBridge(
                modelId: modelId,
                tokenizer: tokenizer,
                eosTokenIds: hooks.eosTokenIds,
                extraEOSTokens: hooks.extraEOSTokens,
                defaultMaxTokens: sizing.defaultMaxTokens,
                maxConcurrentRequests: maxConcurrent,
                kvBytesPerToken: sizing.fp16KVBytesPerToken,
                kvBudget: kvBudget,
                prefixCacheBudgetBytes: carve.prefixCacheBudgetBytes,
                emitTelemetry: hooks.emitTelemetry,
                makeEngine: { try hookBuilder(modelId, carve.engineKVBytesCapacity) })
            // WARN once (per load) that kv_quant is ignored on the v2 path
            // (fp16 caches are what the engine builds).
            if loopConfig.config.backend.kvQuant {
                EngineV2Factory.emitKVQuantUnsupportedTelemetry(
                    modelId: modelId, emitTelemetry: hooks.emitTelemetry)
            }
        } else {
            let slotLogger = logger
            bridge = try await EngineV2SlotFactory.makeProductionBridge(
                modelId: modelId,
                modelType: modelType,
                isVLM: isVLM,
                modelDirectory: modelDirectory,
                container: container,
                tokenizer: tokenizer,
                sizing: sizing,
                kvBytesCapacity: kvBytesCapacity,
                maxConcurrentRequests: maxConcurrent,
                kvBudget: kvBudget,
                kvQuantConfigured: loopConfig.config.backend.kvQuant,
                logInfo: { slotLogger.info($0) })
        }

        // Register before the slot goes live so capacity heartbeats and
        // cancellation fan-out see the bridge from the first request.
        // (Prefix-cache construction, budget carve, stats logger, and the
        // cache-state log line all live inside the shared slot factory.)
        await engineV2Runtime.register(modelId: modelId, bridge: bridge)
        if isVLM {
            logger.info(
                "engine_v2: serving \(modelId) via ContinuousBatchingV2 "
                    + "(vlm routing: text→v2, image→v2 multimodal prefill, "
                    + "video→legacy VLM container path)")
        } else {
            logger.info("engine_v2: serving \(modelId) via ContinuousBatchingV2")
        }
        return bridge
    }
}
