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
        let makeEngine: @Sendable (String) throws -> any CBv2Engine

        init(
            environment: [String: String],
            eosTokenIds: Set<Int> = [],
            extraEOSTokens: [String] = [],
            emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
            makeEngine: @escaping @Sendable (String) throws -> any CBv2Engine
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
    ///     `EngineV2Runtime` hop, no allocations;
    ///   * v2 engine construction throws — WARN `engine_health` telemetry
    ///     (`engine_v2_fallback`) is emitted by the factory and the slot
    ///     serves through the legacy scheduler exactly as before.
    ///
    /// On success the bridge is registered with `engineV2Runtime` BEFORE the
    /// caller installs the slot, so a request routed the instant the slot
    /// appears already has working capacity/cancel fan-out.
    internal func makeEngineV2BridgeForSlot(
        modelId: String,
        modelType: String?,
        isVLM: Bool = false,
        container: ModelContainer,
        tokenizer: TokenizerHandle,
        scheduler: BatchScheduler
    ) async -> EngineV2Bridge? {
        // VLM slots are permanently unsupported by the v2 engine (the loaded
        // module is a vision wrapper, not a CBv2-adapted text model), so gate
        // them out BEFORE selection: an allowlist name match on a vision
        // build (e.g. `gemma-4*`) would otherwise emit a WARN
        // `engine_v2_fallback` on every load of a shape that can never serve
        // v2. Silent legacy is the correct steady state here.
        guard !isVLM else { return nil }
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
        let kvBytesPerToken = await scheduler.kvBytesPerToken
        let defaultMaxTokens = await scheduler.defaultMaxTokens
        let weightBytes = await scheduler.modelWeightBytes
        // KNOWN LIMIT (acceptable for the flag-gated rollout): this ceiling
        // is computed ONCE at load from THIS model's weights only — it does
        // not track co-resident models or live legacy KV afterwards, unlike
        // the legacy scheduler's live headroom checks. The engine admission
        // cap (no preallocation) plus the conservative v2 concurrency (4)
        // bound the exposure; revisit before enabling v2 on multi-slot boxes.
        let kvBytesCapacity = Int(
            min(
                UnifiedMemoryCap.kvBudgetBytes(
                    residentWeightBytes: UInt64(max(0, weightBytes))),
                UInt64(Int.max)))

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
            makeEngine = { try hookBuilder(modelId) }
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
            makeEngine = {
                try EngineV2Factory.makeProductionEngine(
                    model: snapshot.model,
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
                emitTelemetry: emitTelemetry,
                makeEngine: makeEngine)
        else {
            // Selection said v2, so a nil bridge here is the init-failure
            // fallback (the factory already emitted the WARN event).
            logger.warning(
                "engine_v2: init failed for \(modelId) — serving via the legacy engine")
            return nil
        }

        // Register before the slot goes live so capacity heartbeats and
        // cancellation fan-out see the bridge from the first request.
        await engineV2Runtime.register(modelId: modelId, bridge: bridge)
        logger.info(
            "engine_v2: serving \(modelId) via ContinuousBatchingV2 "
                + "(legacy scheduler retained for fallback)")
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
