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
import MLXLMCommon
#if canImport(os)
import os
#endif

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
        let eosTokenIds: Set<Int>
        let extraEOSTokens: [String]
        let emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?
        /// Machine-memory override for the re-slice fleet budget (nil ⇒
        /// real physical memory).
        let physicalMemoryBytes: UInt64?
        /// Scripted engine builder: (modelId, kvBytesCapacity) — the second
        /// argument is the RE-SLICED grant the production path would hand
        /// `makeProductionEngine`, exposed so tests can assert the
        /// multi-slot grant derivation without building a real engine.
        let makeEngine: @Sendable (String, Int) throws -> any CBv2Engine

        init(
            eosTokenIds: Set<Int> = [],
            extraEOSTokens: [String] = [],
            emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
            physicalMemoryBytes: UInt64? = nil,
            makeEngine: @escaping @Sendable (String, Int) throws -> any CBv2Engine
        ) {
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
    /// Reads each engine's CURRENT grant (post-any-earlier-resize).
    private func existingSlotGrants(excludingModelId: String) async -> [ExistingSlotGrant] {
        var existing: [ExistingSlotGrant] = []
        for (slotModelId, slot) in modelSlots
        where slotModelId != excludingModelId && !modelsUnloading.contains(slotModelId) {
            let currentGrant = await slot.engineV2.engineKVBytesCapacity()
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

    /// Re-slice KV grants for the newcomer + existing slots, shrink
    /// existing engines, and build the newcomer's bridge. On ANY throw —
    /// re-slice floor, extraction failure, engine construction — every
    /// existing engine's grant is RESTORED exactly before the error
    /// propagates, so a failed load never leaves survivors squeezed.
    /// Returns the bridge, already registered with `engineV2Runtime`.
    internal func resliceAndBuildEngineV2Slot(
        modelId: String,
        modelType: String?,
        isVLM: Bool,
        modelDirectory: URL?,
        container: ModelContainer,
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
        guard EngineV2KVSizing.resliceMeetsServiceabilityFloor(targets) else {
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

        // Phase 2 — build the newcomer with its grant. Restore-on-throw:
        // grow every shrunk engine back to its exact previous grant.
        let bridge: EngineV2Bridge
        do {
            bridge = try await makeEngineV2BridgeForSlot(
                modelId: modelId,
                modelType: modelType,
                isVLM: isVLM,
                modelDirectory: modelDirectory,
                container: container,
                tokenizer: tokenizer,
                sizing: sizing,
                kvBytesCapacity: targets[modelId] ?? 0)
        } catch {
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

    /// Grow the surviving slots back to their re-sliced shares after an
    /// unload (a lone survivor gets the FULL fleet budget back). Shrink
    /// targets, if the budget somehow contracted, are applied first so the
    /// Σ ≤ budget invariant holds throughout.
    internal func resliceGrowSurvivors() async {
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
        let kvBytesPerToken = sizing.fp16KVBytesPerToken
        let maxConcurrent = engineV2MaxConcurrent(forModel: modelId)

        // Resolve the EOS/stop inputs + engine builder: from the test hooks
        // when installed, otherwise from the loaded container (production).
        let eosTokenIds: Set<Int>
        let extraEOSTokens: [String]
        let emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?
        let makeEngine: () throws -> any CBv2Engine
        if let hooks = engineV2SlotHooks {
            eosTokenIds = hooks.eosTokenIds
            extraEOSTokens = hooks.extraEOSTokens
            emitTelemetry = hooks.emitTelemetry
            let hookBuilder = hooks.makeEngine
            makeEngine = { try hookBuilder(modelId, kvBytesCapacity) }
        } else {
            // Snapshot the model handle + EOS config out of the container.
            // Handing the module reference to the v2 engine serializes all
            // forward passes on the engine's own step thread.
            let snapshot = await container.perform { ctx in
                EngineV2ModelSnapshot(
                    model: ctx.model,
                    eosTokenIds: ctx.configuration.eosTokenIds,
                    extraEOSTokens: ctx.configuration.extraEOSTokens.sorted())
            }
            // Same model-specific EOS augmentation as always (GPT-OSS/
            // Harmony adds its generation-config action stops) — from the
            // scheduler-free policy home.
            eosTokenIds = ModelEOSPolicy.effectiveEOSTokenIds(
                modelId: modelId,
                modelType: modelType,
                base: snapshot.eosTokenIds,
                tokenToId: { tokenizer.inner.convertTokenToId($0) }
            )
            extraEOSTokens = snapshot.extraEOSTokens
            emitTelemetry = nil  // production: TelemetryClient.shared
            let loadedModelDirectory = modelDirectory
            let slotLogger = logger
            makeEngine = {
                // VLM slot: extract the CBv2-adapted MLXLLM text model over
                // the SAME weight arrays (zero extra weight memory) and
                // build the engine on that; any extraction/verify/parity
                // failure throws into the factory's engine_v2_refusal ERROR.
                let servingModel: any LanguageModel
                if isVLM {
                    guard let loadedModelDirectory else {
                        throw EngineV2VLMTextExtractionError.missingModelDirectory
                    }
                    let extraction = try EngineV2VLMTextExtraction.extractTextModel(
                        from: snapshot.model, modelDirectory: loadedModelDirectory)
                    if let parityDiff = extraction.parityMaxAbsLogitDiff {
                        slotLogger.info(
                            "engine_v2: \(modelId) VLM text-model extraction passed the "
                                + "load-time forward parity gate (max |Δlogit| \(parityDiff))")
                    }
                    servingModel = extraction.model
                } else {
                    servingModel = snapshot.model
                }
                return try EngineV2Factory.makeProductionEngine(
                    model: servingModel,
                    tokenizer: tokenizer.inner,
                    kvBytesCapacity: kvBytesCapacity,
                    maxConcurrentRequests: maxConcurrent)
            }
        }

        let bridge = try EngineV2Factory.makeBridge(
            modelId: modelId,
            tokenizer: tokenizer,
            eosTokenIds: eosTokenIds,
            extraEOSTokens: extraEOSTokens,
            defaultMaxTokens: sizing.defaultMaxTokens,
            maxConcurrentRequests: maxConcurrent,
            kvBytesPerToken: kvBytesPerToken,
            // Shared KV ledger: v2 submissions RESERVE their worst-case
            // KV here before engine admission (process-wide gate) and the
            // reservation is what the model-LOAD gate subtracts. nil ⇒ no
            // shared gating/accounting (unit tests / the standalone path).
            kvBudget: kvBudget,
            emitTelemetry: emitTelemetry,
            makeEngine: makeEngine)

        // WARN once (per load) that kv_quant is ignored on the v2 path
        // (fp16 caches are what the engine builds).
        if loopConfig.config.backend.kvQuant {
            EngineV2Factory.emitKVQuantUnsupportedTelemetry(
                modelId: modelId, emitTelemetry: emitTelemetry)
        }

        // Register before the slot goes live so capacity heartbeats and
        // cancellation fan-out see the bridge from the first request.
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

/// Model handle + EOS config snapshot pulled out of `ModelContainer.perform`.
///
/// `@unchecked Sendable` justification: the module reference crosses the
/// container's isolation exactly once, at load time, to be handed to the v2
/// engine — which serializes every use on its own engine thread.
struct EngineV2ModelSnapshot: @unchecked Sendable {
    let model: any LanguageModel
    let eosTokenIds: Set<Int>
    let extraEOSTokens: [String]
}
