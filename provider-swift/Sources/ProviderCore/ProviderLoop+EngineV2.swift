/// ProviderLoop -- ContinuousBatchingV2 (engine v2) slot wiring.
///
/// The single production call site that turns `DARKBLOOM_ENGINE_V2=1` /
/// `engine_v2 = true` into a running CBv2 engine: at model-load time
/// `ensureModelLoaded` calls `makeEngineV2BridgeForSlot`, which consults
/// `EngineV2Config` and — only when the v2 engine is selected for this model
/// — assembles the real engine over the just-loaded container, wraps it in
/// an `EngineV2Bridge`, and registers it with the `EngineV2Runtime` so the
/// capacity/cancellation hooks see it. The bridge is stored on `ModelSlot`
/// ALONGSIDE the legacy `BatchScheduler` (never replacing it): a v2 init
/// failure falls back to legacy with WARN telemetry (inside
/// `EngineV2Factory.makeBridgeIfSelected`), and flag-off providers return
/// before touching the container, the scheduler, or the runtime.

import Foundation
import MLXLMCommon
#if canImport(os)
import os
#endif

extension ProviderLoop {

    /// Whether any live slot serves through the v2 engine. Synchronous and
    /// actor-isolated — the zero-overhead guard the capacity/cancellation
    /// hooks check BEFORE hopping to `engineV2Runtime`, so flag-off
    /// providers never take the (pointless, empty-registry) actor hop.
    internal var hasEngineV2Slots: Bool {
        modelSlots.contains { $0.value.engineV2 != nil }
    }

    /// Test hooks for the slot factory (`ProviderLoop+Testing`): replace the
    /// process environment, the container-derived EOS snapshot, and the
    /// production engine builder so unit tests can drive the full wiring
    /// path with a scripted `CBv2Engine` — no model weights, no network.
    struct EngineV2SlotHooks: Sendable {
        let environment: [String: String]
        let eosTokenIds: Set<Int>
        let extraEOSTokens: [String]
        let emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?
        /// Scripted engine builder: (modelId, kvBytesCapacity) — the second
        /// argument is the FLEET-SIZED admission ceiling the production path
        /// would hand `makeProductionEngine`, exposed so tests can assert the
        /// multi-slot capacity derivation without building a real engine.
        let makeEngine: @Sendable (String, Int) throws -> any CBv2Engine

        init(
            environment: [String: String],
            eosTokenIds: Set<Int> = [],
            extraEOSTokens: [String] = [],
            emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
            makeEngine: @escaping @Sendable (String, Int) throws -> any CBv2Engine
        ) {
            self.environment = environment
            self.eosTokenIds = eosTokenIds
            self.extraEOSTokens = extraEOSTokens
            self.emitTelemetry = emitTelemetry
            self.makeEngine = makeEngine
        }
    }

    /// Build + register the v2 bridge for a freshly-loaded model slot, iff
    /// `EngineV2Config` selects the v2 engine for `modelId`. Returns nil on
    /// every legacy path:
    ///
    ///   * flag off / model not allowlisted — the ZERO-OVERHEAD steady
    ///     state: no container access, no scheduler reads, no
    ///     `EngineV2Runtime` hop, no allocations. This also covers
    ///     NON-allowlisted VLM builds (silent legacy — no WARN spam);
    ///   * v2 engine construction throws — WARN `engine_health` telemetry
    ///     (`engine_v2_fallback`) is emitted by the factory and the slot
    ///     serves through the legacy scheduler exactly as before. For an
    ///     ALLOWLISTED VLM slot this covers text-model extraction failures
    ///     (see below) — loud, never silently wrong.
    ///
    /// VLM slots (v0.7.2): every production Gemma 4 checkpoint ships a
    /// vision tower, so its slot loads MLXVLM's wrapper — which has no CBv2
    /// hooks. Instead of gating the whole slot out (which kept 100% of prod
    /// Gemma traffic on legacy), an allowlisted VLM slot builds the engine
    /// over `EngineV2VLMTextExtraction`'s weight-sharing MLXLLM text model:
    /// TEXT requests then serve through v2 while image/video requests keep
    /// the legacy VLM path (per-request routing in
    /// `MultiModelBatchSchedulerEngine.streamChatCompletion`, which peels
    /// media off to the vision path BEFORE the bridge branch).
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
        scheduler: BatchScheduler
    ) async -> EngineV2Bridge? {
        let configEnabled = loopConfig.config.backend.engineV2
        let environment = engineV2SlotHooks?.environment
            ?? ProcessInfo.processInfo.environment
        // Zero-overhead gate: the common (flag-off / non-allowlisted) case
        // returns here without touching anything else.
        guard
            EngineV2Config.selection(
                modelId: modelId, environment: environment, configEnabled: configEnabled
            ) == .v2
        else {
            return nil
        }

        // Legacy-comparable knobs, read from the already-loaded scheduler so
        // v2 heartbeat numbers and max-token defaulting match what the
        // legacy engine would have reported for the same model.
        //
        // KV byte cost: engine_v2 builds UNQUANTIZED (fp16) caches even when
        // the provider's `kv_quant` is on (KV-quant is not yet composed with
        // v2). The scheduler's live `kvBytesPerToken` is the QUANTIZED rate in
        // that case; sizing the bridge with it would overstate v2 token
        // budgets 2–4× and under-size the shared KV reservation. Pick the fp16
        // rate for v2 and WARN once that kv_quant is being ignored on this
        // path — see `EngineV2KVSizing`.
        let quantizedKVBytesPerToken = await scheduler.kvBytesPerToken
        let fp16KVBytesPerToken = await scheduler.fp16KVBytesPerToken
        let kvSizing = EngineV2KVSizing.resolve(
            quantizedRate: quantizedKVBytesPerToken, fp16Rate: fp16KVBytesPerToken)
        let kvBytesPerToken = kvSizing.rate
        let defaultMaxTokens = await scheduler.defaultMaxTokens
        let weightBytes = await scheduler.modelWeightBytes
        // FLEET-WIDE ceiling (round-2 PR#499 P2): size this engine's KV
        // admission cap against ALL resident models' weights plus the
        // ceilings already granted to co-resident v2 engines — not just this
        // slot's weights — so Σ(v2 ceilings) can never exceed the
        // unified-memory KV budget on a multi-slot provider. Snapshot the
        // slots once (each read awaits an actor hop; `modelSlots` could
        // mutate across suspensions otherwise). The new model's own slot is
        // not installed yet at this point; a same-id slot present during a
        // reload is excluded so its weights are not double-counted against
        // the fresh scheduler's figure. When nothing is left under the
        // budget the capacity is 0 and `makeProductionEngine` throws
        // `noKVHeadroom` → this slot serves via the legacy scheduler (whose
        // per-request shared-budget gate needs no static ceiling).
        var coResidentWeightBytes: UInt64 = 0
        var existingEngineKVCapacities: [Int] = []
        for (slotModelId, slot) in modelSlots where slotModelId != modelId {
            let slotWeights = await slot.scheduler.modelWeightBytes
            let (sum, overflow) = coResidentWeightBytes
                .addingReportingOverflow(UInt64(max(0, slotWeights)))
            coResidentWeightBytes = overflow ? .max : sum
            if let existingBridge = slot.engineV2 {
                existingEngineKVCapacities.append(
                    await existingBridge.engineKVBytesCapacity())
            }
        }
        // `memory_reserve_gb` (round-3 PR#499 P2): the shared KV gate and the
        // load gate hold back max(configReserve, cap-implied reserve); the
        // static v2 ceiling must be derived under the same effective cap or a
        // 16/32 GiB box (default 4 GiB reserve > implied reserve) advertises
        // capacity the shared gate rejects post-acceptance.
        let kvBytesCapacity = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: weightBytes,
            coResidentWeightBytes: coResidentWeightBytes,
            existingEngineKVCapacities: existingEngineKVCapacities,
            configReserveBytes: Self.memoryReserveBytes(
                forGiB: loopConfig.config.provider.memoryReserveGB))

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
            // Handing the module reference to the v2 engine mirrors the
            // legacy path exactly (`BatchScheduler.makeBatchedEngine` builds
            // its engine over `ctx.model` the same way): the engine
            // serializes all forward passes on its own step thread.
            let snapshot = await container.perform { ctx in
                EngineV2ModelSnapshot(
                    model: ctx.model,
                    eosTokenIds: ctx.configuration.eosTokenIds,
                    extraEOSTokens: ctx.configuration.extraEOSTokens.sorted())
            }
            // Same model-specific EOS augmentation as the legacy scheduler
            // (GPT-OSS/Harmony adds its generation-config action stops).
            eosTokenIds = BatchScheduler.effectiveEOSTokenIds(
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
                // VLM slot: the loaded module is a vision wrapper with no
                // CBv2 hooks. Extract the CBv2-adapted MLXLLM text model
                // over the SAME weight arrays (zero extra weight memory) and
                // build the engine on that; any extraction/verify/parity
                // failure throws into the factory's engine_v2_fallback WARN.
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
                    kvBytesCapacity: kvBytesCapacity)
            }
        }

        guard
            let bridge = EngineV2Factory.makeBridgeIfSelected(
                modelId: modelId,
                configEnabled: configEnabled,
                environment: environment,
                tokenizer: tokenizer,
                eosTokenIds: eosTokenIds,
                extraEOSTokens: extraEOSTokens,
                defaultMaxTokens: defaultMaxTokens,
                maxConcurrentRequests: EngineV2Factory.productionMaxConcurrentRequests,
                kvBytesPerToken: kvBytesPerToken,
                // Shared KV ledger: v2 submissions RESERVE their worst-case
                // KV here before engine admission (process-wide gate) and the
                // reservation is what the model-LOAD gate + legacy live-KV
                // gate subtract. nil ⇒ no shared gating/accounting (unit
                // tests / the standalone path).
                kvBudget: kvBudget,
                emitTelemetry: emitTelemetry,
                makeEngine: makeEngine)
        else {
            // Selection said v2, so a nil bridge here is the init-failure
            // fallback (the factory already emitted the WARN event).
            logger.warning(
                "engine_v2: init failed for \(modelId) — serving via the legacy engine")
            return nil
        }

        // WARN once (per load) that kv_quant is being ignored on the v2 path.
        // Emitted ONLY after the v2 bridge actually built (below the guard):
        // if v2 init failed and the model fell back to the legacy engine,
        // legacy DOES honor kv_quant, so a "kv_quant unsupported" WARN there
        // would be untruthful.
        if kvSizing.warnKVQuantUnsupported {
            EngineV2Factory.emitKVQuantUnsupportedTelemetry(
                modelId: modelId, emitTelemetry: emitTelemetry)
        }

        // Register before the slot goes live so capacity heartbeats and
        // cancellation fan-out see the bridge from the first request.
        await engineV2Runtime.register(modelId: modelId, bridge: bridge)
        if isVLM {
            // Distinguish the VLM text-routing mode in prod logs: text
            // requests serve via v2 over the extracted text model, image/
            // video requests keep the legacy VLM path.
            logger.info(
                "engine_v2: serving \(modelId) via ContinuousBatchingV2 "
                    + "(vlm_text_routing=true: text→v2, image/video→legacy VLM path; "
                    + "legacy scheduler retained for fallback)")
        } else {
            logger.info(
                "engine_v2: serving \(modelId) via ContinuousBatchingV2 "
                    + "(legacy scheduler retained for fallback)")
        }
        return bridge
    }
}

/// Model handle + EOS config snapshot pulled out of `ModelContainer.perform`.
///
/// `@unchecked Sendable` justification: the module reference crosses the
/// container's isolation exactly once, at load time, to be handed to the v2
/// engine — which serializes every use on its own engine thread. This is the
/// same ownership handoff the legacy `BatchedEngine` performs with
/// `ctx.model` in `BatchScheduler+EngineFactory`.
struct EngineV2ModelSnapshot: @unchecked Sendable {
    let model: any LanguageModel
    let eosTokenIds: Set<Int>
    let extraEOSTokens: [String]
}
