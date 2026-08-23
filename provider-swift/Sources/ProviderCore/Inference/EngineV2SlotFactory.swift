// Copyright © 2026 Eigen Labs.
//
// Shared production v2-slot bridge assembly (v0.7.5 one-engine).
//
// Both slot owners — the coordinator-serving `ProviderLoop` and the
// standalone `darkbloom start --local` server — construct their model
// slots through THIS one path so the assembly can never drift between
// them: snapshot the loaded module's EOS config out of the container,
// apply the model-specific EOS policy (`ModelEOSPolicy`), build the
// production CBv2 engine over the loaded module (using the Gemma 4 VLM's
// directly owned text tower), and wrap it in an `EngineV2Bridge` via the
// fail-loud `EngineV2Factory.makeBridge` (any construction failure emits the
// ERROR `engine_v2_refusal` telemetry and throws — the caller unloads and
// maps to a 503; there is no legacy fallback).
//
// Call-site differences stay at the call sites: the ProviderLoop
// registers the bridge with `EngineV2Runtime` (heartbeat/cancel fan-out)
// and supports its own `EngineV2SlotHooks` test seam; the standalone
// server keeps its slots private to the HTTP endpoint. Test seams here
// are limited to `makeEngineOverride` (scripted engines, no weights).

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation

enum GemmaOptimizationReason: String, Sendable, Equatable {
    case disabled
    case modelIneligible = "model_ineligible"
    case aotUnavailable = "aot_unavailable"
    case naxPrecedence = "nax_precedence"
    case effective
}

struct GemmaOptimizationState: Sendable, Equatable {
    let name: String
    let requested: Bool
    let effective: Bool
    let reason: GemmaOptimizationReason

    var compactDescription: String {
        "\(name)(requested=\(requested),effective=\(effective),reason=\(reason.rawValue))"
    }
}

/// Pure requested/effective resolution for the three retained Gemma controls.
/// Safe R1 is inferred from one unarmed device snapshot; this type never
/// resets, arms, or samples route counters.
struct GemmaOptimizationReport: Sendable, Equatable {
    let layer18: GemmaOptimizationState
    let weightedUnsort: GemmaOptimizationState
    let safeR1: GemmaOptimizationState

    init(
        layer18Requested: Bool,
        layer18Effective: Bool,
        weightedUnsortRequested: Bool,
        weightedUnsortEffective: Bool,
        safeR1Requested: Bool,
        safeR1GeometryEligible: Bool,
        safeR1AOTAvailable: Bool,
        safeR1NAXAvailable: Bool
    ) {
        layer18 = Self.resolve(
            name: "layer18",
            requested: layer18Requested,
            modelEligible: layer18Effective)
        weightedUnsort = Self.resolve(
            name: "weighted_unsort",
            requested: weightedUnsortRequested,
            modelEligible: weightedUnsortEffective)
        safeR1 = Self.resolve(
            name: "safe_r1",
            requested: safeR1Requested,
            modelEligible: safeR1GeometryEligible,
            aotAvailable: safeR1AOTAvailable,
            naxAvailable: safeR1NAXAvailable)
    }

    var states: [GemmaOptimizationState] {
        [layer18, weightedUnsort, safeR1]
    }

    func logLine(modelId: String) -> String {
        "engine_v2: \(modelId) gemma optimizations "
            + states.map(\.compactDescription).joined(separator: " ")
    }

    func telemetryEvents(modelId: String) -> [TelemetryEvent] {
        states.map { state in
            var event = TelemetryEvent(
                source: .provider,
                severity: .info,
                kind: .engineHealth,
                message: "engine_v2: gemma optimization "
                    + state.compactDescription)
            event.fields = TelemetryFieldFilter.filter([
                "component": .string("engine"),
                "operation": .string("gemma_optimization_\(state.name)"),
                "backend": .string("engine_v2"),
                "model": .string(modelId),
                // Existing allowlisted field, carrying the bounded 2-bit
                // requested/effective state without a telemetry schema change.
                "target": .string(
                    "requested_\(state.requested ? 1 : 0)_effective_"
                        + "\(state.effective ? 1 : 0)"),
                "reason": .string(state.reason.rawValue),
            ])
            return event
        }
    }

    private static func resolve(
        name: String,
        requested: Bool,
        modelEligible: Bool,
        aotAvailable: Bool? = nil,
        naxAvailable: Bool = false
    ) -> GemmaOptimizationState {
        let reason: GemmaOptimizationReason
        if !requested {
            reason = .disabled
        } else if !modelEligible {
            reason = .modelIneligible
        } else if aotAvailable == false {
            reason = .aotUnavailable
        } else if naxAvailable {
            reason = .naxPrecedence
        } else {
            reason = .effective
        }
        return GemmaOptimizationState(
            name: name,
            requested: requested,
            effective: reason == .effective,
            reason: reason)
    }
}

enum EngineV2SlotFactory {

    /// Narrow assembly seams for production-order regression tests. Normal
    /// callers use the empty value and execute only concrete production code.
    struct AssemblyOverrides {
        var promptContractID: String? = nil
        var pagedPreflight: (([CBv2LayerKind]) throws -> Void)? = nil
        var makePrefixCache:
            (([CBv2LayerKind], CBv2PrefixReuseCapability) async -> SSDPrefixCache?)? = nil
    }

    /// Human-readable cache state for the slot-serving log line.
    static func prefixCacheStateDescription(
        residentEnabled: Bool = false,
        ssdCache: SSDPrefixCache?
    ) -> String {
        let resident = residentEnabled ? "memory=on (zero-copy paged L1)" : "memory=off"
        if let ssdCache {
            // Saturating sum: an operator-set
            // DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS near Int.max
            // must not trap while FORMATTING this load-time log line (the
            // actual staging/donation gates already saturate — mirror them).
            let (floor, floorOverflow) = ssdCache.config.adoptionBoundTokens
                .addingReportingOverflow(ssdCache.config.minEffectiveTokens)
            let floorDesc = floorOverflow ? "Int.max (saturated)" : "\(floor)"
            return "on (\(resident), ssd=on: encrypted offload, HMAC-keyed names, "
                + "15-min sliding TTL, NO memory carve, per-donation gate "
                + "> \(floorDesc) tok — T-041)"
        }
        return residentEnabled ? "on (\(resident), ssd=off)" : "off"
    }

    /// Build the production `EngineV2Bridge` for a freshly-loaded model.
    /// THROWS on any construction failure (the factory emits the ERROR
    /// `engine_v2_refusal` event first) — the caller unloads + maps to 503.
    ///
    /// - Parameters:
    ///   - modelId: catalog id the slot serves under.
    ///   - modelType: `model_type` from config.json (EOS policy input).
    ///   - isVLM: config declares `vision_config` — the engine directly uses
    ///     the `Gemma4TextModel` owned by the loaded VLM wrapper.
    ///   - modelDirectory: checkpoint dir (prompt-contract identity input).
    ///   - tokenizer: the container's tokenizer handle.
    ///   - sizing: scheduler-free sizing snapshot (fp16 KV rate, context,
    ///     default max tokens).
    ///   - kvBytesCapacity: this slot's total live-KV grant, already
    ///     re-sliced against co-resident slots by the caller. SSD caching
    ///     does not carve this grant.
    ///   - maxConcurrentRequests: effective `engine_v2_max_concurrent`.
    ///   - kvBudget: process-wide shared KV reservation ledger (nil ⇒ no
    ///     shared gating — unit tests only; both production callers pass
    ///     their ledger).
    ///   - weightHash: the slot's verified weight hash binding for SSD
    ///     artifacts. Nil or blank disables reusable SSD caching.
    ///   - environment: prefix-cache policy environment
    ///     (`DARKBLOOM_PREFIX_CACHE*`); injectable for tests.
    ///   - emitTelemetry: injectable sink (tests); nil ⇒ shared client.
    ///   - makeEngineOverride: scripted engine builder for tests
    ///     ((modelId, engine capacity) — mirrors
    ///     `ProviderLoop.EngineV2SlotHooks`); nil ⇒ the real
    ///     `EngineV2Factory.makeProductionEngine`. SSD cache instances and
    ///     stats logging exist only on the production path.
    ///   - logInfo: sink for shared-tower + cache-state info lines.
    ///   - logWarning: sink for the both-tiers-requested WARN line.
    static func makeProductionBridge(
        modelId: String,
        modelType: String?,
        isVLM: Bool,
        modelDirectory: URL?,
        container: ModelContainer,
        tokenizer: TokenizerHandle,
        sizing: SlotSizingSnapshot,
        kvBytesCapacity: Int,
        maxConcurrentRequests: Int,
        kvBudget: GlobalKVCacheBudget?,
        kvBackendConfig: String = "auto",
        kvBackendConfigByModel: [String: String] = [:],
        weightHash: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        makeEngineOverride: (@Sendable (String, Int) throws -> any CBv2Engine)? = nil,
        logInfo: @escaping @Sendable (String) -> Void = { _ in },
        logWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> EngineV2Bridge {
        try await makeProductionBundle(
            modelId: modelId,
            modelType: modelType,
            isVLM: isVLM,
            modelDirectory: modelDirectory,
            container: container,
            tokenizer: tokenizer,
            sizing: sizing,
            kvBytesCapacity: kvBytesCapacity,
            maxConcurrentRequests: maxConcurrentRequests,
            kvBudget: kvBudget,
            kvBackendConfig: kvBackendConfig,
            kvBackendConfigByModel: kvBackendConfigByModel,
            weightHash: weightHash,
            specDecPreparation: SpecDecPreparation(
                artifact: nil,
                status: .disabled(.configDisabled, configured: false)),
            environment: environment,
            emitTelemetry: emitTelemetry,
            makeEngineOverride: makeEngineOverride,
            logInfo: logInfo,
            logWarning: logWarning
        ).bridge
    }

    /// Production bundle assembly. Assistant preparation is deliberately
    /// fail-open; direct target resolution and engine construction fail loud.
    static func makeProductionBundle(
        modelId: String,
        modelType: String?,
        isVLM: Bool,
        modelDirectory: URL?,
        container: ModelContainer,
        tokenizer: TokenizerHandle,
        sizing: SlotSizingSnapshot,
        kvBytesCapacity: Int,
        maxConcurrentRequests: Int,
        kvBudget: GlobalKVCacheBudget?,
        kvBackendConfig: String = "auto",
        kvBackendConfigByModel: [String: String] = [:],
        weightHash: String? = nil,
        specDecPreparation: SpecDecPreparation,
        preparedModel: EngineV2PreparedModel? = nil,
        assemblyOverrides: AssemblyOverrides = AssemblyOverrides(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        makeEngineOverride: (@Sendable (String, Int) throws -> any CBv2Engine)? = nil,
        assistantLoader: any ProviderMTPAssistantLoading = Gemma4ProviderMTPAssistantLoader(),
        logInfo: @escaping @Sendable (String) -> Void = { _ in },
        logWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> ProviderEngineBundle {
        // KV-backend gate, slot-veto layer (`EngineV2KVBackendPolicy`):
        // parse the operator selection (per-model override wins; typo →
        // WARN + auto), then force contiguous for slots the paged cache
        // cannot serve. That is a VLM slot whose paged cache does not
        // vouch for multimodal span masks — media would 4xx at submit.
        // The claim comes from the cache itself
        // (`PagedLayerCache.honorsSpanMaskContextsByConstruction`, the same
        // constant the engine's own submit-time gate resolves to), never
        // from a belief held here: the decision has to be made before any
        // pool exists, so it cannot ask a live instance, but it must still
        // ASK rather than assume. A veto is policy, so it is silent even
        // for an explicit paged request. kv_quant is gone from the product
        // entirely — it is no longer a veto, no longer a parameter, and no
        // longer warned about. `auto` resolves CONTIGUOUS as of v0.8.1;
        // that resolution, the fleet kill switch, physical-capacity
        // planning, and the degrade-or-REFUSE decision for an explicit
        // paged request all live in
        // `EngineV2Factory.prepareProductionBackend`. The RESOLVED backend
        // that comes back also decides whether this slot gets an SSD
        // prefix cache at all — see the construction gate below.
        let parsedKVBackend = EngineV2KVBackendPolicy.parseSelection(
            global: kvBackendConfig, byModel: kvBackendConfigByModel, modelID: modelId)
        if let unrecognized = parsedKVBackend.unrecognized {
            logWarning(
                "engine_v2: unrecognized engine_v2_kv_backend value "
                    + "\"\(unrecognized)\" for \(modelId) — using \"auto\"")
        }
        let vetoed = EngineV2KVBackendPolicy.applySlotVetoes(
            selection: parsedKVBackend.selection,
            isVLM: isVLM,
            pagedHonorsSpanMasks: PagedLayerCache.honorsSpanMaskContextsByConstruction)
        let kvBackendSelection = vetoed.selection
        if let veto = vetoed.veto {
            logInfo(
                "engine_v2: \(modelId) paged KV backend forced to contiguous "
                    + "(\(veto))")
        }
        let prepared: EngineV2PreparedModel
        if let preparedModel {
            prepared = preparedModel
        } else if makeEngineOverride != nil {
            // Scripted engines intentionally do not construct real assistants.
            prepared = try await prepareProductionModel(
                modelId: modelId,
                isVLM: isVLM,
                modelDirectory: modelDirectory,
                container: container,
                specDecPreparation: SpecDecPreparation(
                    artifact: nil, status: specDecPreparation.status),
                assistantLoader: assistantLoader,
                emitTelemetry: emitTelemetry,
                logInfo: logInfo,
                logWarning: logWarning)
        } else {
            prepared = try await prepareProductionModel(
                modelId: modelId,
                isVLM: isVLM,
                modelDirectory: modelDirectory,
                container: container,
                specDecPreparation: specDecPreparation,
                assistantLoader: assistantLoader,
                emitTelemetry: emitTelemetry,
                logInfo: logInfo,
                logWarning: logWarning)
        }
        let snapshot = prepared.snapshot
        let servingModel = prepared.servingModel
        let assistantHandle = prepared.assistant
        let mtpStatus = prepared.mtpStatus
        let automaticRectangularTokens = MTPAutomaticVerificationPolicy.maxRectangularTokens(
            environment: environment)
        let mtpVerification = providerMTPVerificationPolicy(
            for: assistantHandle?.drafter,
            automaticRectangularTokens: automaticRectangularTokens)
        let fixedDraftTokens = MTPAutomaticVerificationPolicy.fixedDraftTokens(
            usesRequestStatefulDrafter:
                assistantHandle?.drafter is any CBv2MTPRequestStatefulDrafter)
        let mtpConfig = CBv2MTPConfig(
            enabled: assistantHandle != nil,
            fixedDraftTokens: fixedDraftTokens,
            verificationMode: mtpVerification.mode,
            maxAutomaticRectangularTokens: mtpVerification.automaticRectangularTokens)
        // Same model-specific EOS augmentation as always (GPT-OSS/Harmony
        // adds its generation-config action stops) — from the
        // scheduler-free policy home.
        let eosTokenIds = ModelEOSPolicy.effectiveEOSTokenIds(
            modelId: modelId,
            modelType: modelType,
            base: snapshot.eosTokenIds,
            tokenToId: { tokenizer.inner.convertTokenToId($0) }
        )

        // SSD offload never carves the live KV grant.
        let engineKVBytesCapacity = kvBytesCapacity
        let promptContractID =
            assemblyOverrides.promptContractID
            ?? modelDirectory.flatMap {
                try? PromptContractIdentity.compute(modelDirectory: $0)
            }
        // Resident L1 must be configured before the paged backend is built;
        // unlike SSD L2 it owns no snapshot object that can be injected after
        // resolution. The backend consumes this only when it actually resolves
        // paged, and disables it for model capabilities that cannot restore
        // attention-only state.
        let residentPrefixCache = PrefixCachePolicy.residentConfig(
            modelId: modelId,
            promptContractID: promptContractID,
            environment: environment)
        let preparedBackend: EngineV2Factory.ProductionBackendPreparation?
        if makeEngineOverride == nil {
            do {
                preparedBackend = try EngineV2Factory.prepareProductionBackend(
                    model: servingModel,
                    kvBytesCapacity: engineKVBytesCapacity,
                    maxConcurrentRequests: maxConcurrentRequests,
                    kvBackend: kvBackendSelection,
                    maxContextLength: sizing.maxContextLength > 0
                        ? sizing.maxContextLength : nil,
                    environment: environment,
                    residentPrefixCache: residentPrefixCache,
                    pagedPreflightOverride: assemblyOverrides.pagedPreflight)
            } catch {
                EngineV2Factory.emitRefusalTelemetry(
                    modelId: modelId,
                    reason: EngineV2RefusalReason.classify(error),
                    error: error,
                    emitTelemetry: emitTelemetry)
                throw error
            }
        } else {
            preparedBackend = nil
        }

        // Encrypted SSD is the durable snapshot L2. The same object serves as
        // the ENGINE's `CBv2PrefixCache` and the BRIDGE's
        // staging/backstop/shutdown handle. Resident physical-page L1 was
        // installed above while constructing the paged backend; it uses the
        // same prompt-contract identity and request salt (at physical-page
        // rather than durable-block granularity) but needs neither this
        // object nor SSD staging. NOT funding-gated:
        // the tier gates each DONATION on the model's own adoption bound +
        // benefit floor instead (`SSDPrefixCache.donate`), so gemma-4's
        // long-context tail caches while gpt-oss's never-adoptable short
        // donations are skipped. Its budget is DISK (own kv3/ root, 20 GiB
        // box-wide LRU) — the engine keeps the FULL slot grant; the tier's
        // only RAM claims are per-request staging reservations in the
        // shared `GlobalKVCacheBudget` (refused ⇒ silent recompute).
        //
        // VLM slots use the layer kinds of the exact text tower already
        // resolved from the loaded wrapper. A family with no adapted serving
        // model gets no prepared backend and is refused before cache creation.
        var ssdPrefixCache: SSDPrefixCache?
        var cacheCapability: CBv2PrefixReuseCapability?
        var cacheConstructionStatus = PrefixCacheConstructionStatus.configDisabled
        let cacheConstructionStatusBox = PrefixCacheConstructionStatusBox()
        if makeEngineOverride != nil {
            cacheConstructionStatus = PrefixCacheConstructionStatus(
                state: .disabled, reason: .unsupportedBackend)
        } else if let preparedBackend,
            !preparedBackend.modelCapabilities.supportsPrefixReuse
        {
            // Recurrent targets require more than attention KV to restore a
            // request. Do not construct a cache the engine will later strip:
            // the bridge must never retain or stage an incomplete snapshot.
            cacheConstructionStatus = PrefixCacheConstructionStatus(
                state: .disabled, reason: .unsupportedLayout)
        } else if PrefixCachePolicy.isEnabled(environment: environment) {
            if let preparedBackend,
                !PrefixCachePolicy.adoptionIsExact(
                    onResolvedBackend: preparedBackend.kind)
            {
                // v0.8.1: no cache object at all for a resolved-contiguous
                // slot, because on both production checkpoints a contiguous
                // adoption answers differently from the same prompt's cold
                // run (see `PrefixCachePolicy.adoptionIsExact` for the
                // measurement and for why this gates CONSTRUCTION rather
                // than lookup). Nil here is the single switch that disarms
                // the whole tier: the engine gets no `CBv2PrefixCache`, the
                // bridge's pre-submit `stage` never runs, nothing is
                // donated, and no stats logger starts.
                //
                // Keyed on the RESOLVED kind, which is the only correct
                // input — a slot that asked for paged and degraded under
                // the kill switch is serving contiguous and diverges with
                // the contiguous rows.
                //
                // POLICY, so no construction-failure telemetry: this is the
                // `.disabled` shape the `DARKBLOOM_PREFIX_CACHE=0` path
                // already reports, not a failure to build something that
                // should have built.
                cacheCapability = PrefixCachePolicy.adoptionDisabledCapability(
                    layerKinds: preparedBackend.layerKinds)
                cacheConstructionStatus = PrefixCacheConstructionStatus(
                    state: .disabled, reason: .unsupportedBackend)
                logInfo(
                    "engine_v2: SSD prefix cache skipped for \(modelId) — "
                        + "prefix adoption is not bit-exact on the contiguous "
                        + "KV backend (v0.8.1); paged slots keep the cache")
            } else if let preparedBackend {
                let ssdLayerKinds = preparedBackend.layerKinds
                // Hoisted: `ProductionBackendPreparation` is non-Sendable, so
                // the @Sendable construction-failure closure below must
                // capture the resolved kind, not the preparation.
                let preparedKVBackendKind = preparedBackend.kind
                let resolvedSelection: EngineV2KVBackendSelection =
                    preparedBackend.kind == .paged ? .paged : .contiguous
                let prefixReuseCapability = PrefixCachePolicy.prefixReuseCapability(
                    layerKinds: ssdLayerKinds,
                    backendSelection: resolvedSelection)
                cacheCapability = prefixReuseCapability
                if let promptContractID {
                    if let makePrefixCache = assemblyOverrides.makePrefixCache {
                        ssdPrefixCache = await makePrefixCache(
                            ssdLayerKinds, prefixReuseCapability)
                        cacheConstructionStatus = ssdPrefixCache == nil
                            ? PrefixCacheConstructionStatus(
                                state: .error, reason: .cacheInitFailed)
                            : .scanPending
                    } else {
                        ssdPrefixCache = await SSDPrefixCacheFactory.make(
                            modelId: modelId,
                            promptContractID: promptContractID,
                            weightHash: weightHash,
                            layerKinds: ssdLayerKinds,
                            prefixReuseCapability: prefixReuseCapability,
                            kvBudget: kvBudget,
                            environment: environment,
                            onConstructionFailure: { failure in
                                cacheConstructionStatusBox.record(
                                    failure: failure, capability: prefixReuseCapability)
                                Self.emitPrefixCacheConstructionFailure(
                                    modelId: modelId,
                                    kvBackendKind: preparedKVBackendKind,
                                    capability: prefixReuseCapability,
                                    failure: failure,
                                    emitTelemetry: emitTelemetry)
                            })
                        cacheConstructionStatus = ssdPrefixCache == nil
                            ? (cacheConstructionStatusBox.snapshot
                                ?? PrefixCacheConstructionStatus(
                                    state: .error, reason: .cacheInitFailed))
                            : .scanPending
                    }
                } else {
                    cacheConstructionStatus = PrefixCacheConstructionStatus(
                        state: .error, reason: .cacheInitFailed)
                    Self.emitPrefixCacheConstructionFailure(
                        modelId: modelId,
                        kvBackendKind: preparedKVBackendKind,
                        capability: prefixReuseCapability,
                        failure: .promptContractUnavailable,
                        emitTelemetry: emitTelemetry)
                    logWarning(
                        "engine_v2: SSD prefix cache skipped for \(modelId) — "
                            + "prompt contract could not be computed from local artifacts")
                }
            } else {
                let unavailableCapability = PrefixCachePolicy.prefixReuseCapability(
                    layerKinds: [],
                    backendSelection: .contiguous)
                cacheCapability = unavailableCapability
                cacheConstructionStatus = PrefixCacheConstructionStatus(
                    state: .disabled, reason: .unsupportedLayout)
                Self.emitPrefixCacheConstructionFailure(
                    modelId: modelId,
                    // No prepared backend in this branch, so the KV kind was
                    // never resolved — the same reason `cacheBackend` below
                    // reports `.unknown`. Omitted, never guessed.
                    kvBackendKind: nil,
                    capability: unavailableCapability,
                    failure: .layoutUnavailable,
                    emitTelemetry: emitTelemetry)
                logInfo(
                    "engine_v2: SSD prefix cache skipped for \(modelId) — no "
                        + "derivable CBv2 layer kinds (non-adapted family)")
            }
        }

        let cacheBackend: PrefixCacheStatusBackend
        if let preparedBackend {
            cacheBackend = preparedBackend.kind == .paged ? .paged : .contiguous
        } else {
            cacheBackend = .unknown
        }
        let prefixCacheStatus = PrefixCacheModelStatus(
            modelId: modelId,
            backend: cacheBackend,
            replayStrategy: PrefixCacheReplayStrategy(cacheCapability),
            state: cacheConstructionStatus.state,
            reason: cacheConstructionStatus.reason)
        let enginePrefixCache: (any CBv2PrefixCache)? = ssdPrefixCache

        let makeEngine: () throws -> EngineV2Factory.ProductionBuild
        if let makeEngineOverride {
            // Scripted engines are backend-less stubs: report contiguous
            // (the shared-gate/reslice default) with no fallback.
            makeEngine = {
                EngineV2Factory.ProductionBuild(
                    engine: try makeEngineOverride(modelId, engineKVBytesCapacity),
                    fixedRequestBytes: 0,
                    kvBackendKind: .contiguous,
                    kvBackendFallbackReason: nil)
            }
        } else {
            guard let preparedBackend else {
                preconditionFailure("production backend preparation missing")
            }
            makeEngine = {
                try EngineV2Factory.assembleProductionBuild(
                    model: servingModel,
                    tokenizer: tokenizer.inner,
                    prefixCache: enginePrefixCache,
                    maxConcurrentRequests: maxConcurrentRequests,
                    mtpDrafter: assistantHandle?.drafter,
                    mtpConfig: mtpConfig,
                    preparedBackend: preparedBackend)
            }
        }

        let targetKVBytesPerToken: Int
        if let preparedBackend {
            targetKVBytesPerToken = slotKVBytesPerToken(
                resolvedKind: preparedBackend.kind,
                pagedPoolDType: preparedBackend.pagedPoolDType,
                layerKinds: preparedBackend.layerKinds,
                nominalFP16BytesPerToken: sizing.fp16KVBytesPerToken,
                servingModelIsGPTOSS: servingModel is GPTOSSModel)
        } else {
            targetKVBytesPerToken = sizing.fp16KVBytesPerToken
        }
        let assistantStateBytesPerToken = assistantHandle?.drafter?.requestStateBytesPerToken ?? 0
        let assistantStateTokenGranularity =
            assistantHandle?.drafter?.requestStateTokenGranularity ?? 1
        let assistantStateTokenAllocationPadding =
            assistantHandle?.drafter?.requestStateTokenAllocationPadding ?? 0
        let (processKVBytesPerToken, processRateOverflow) = targetKVBytesPerToken
            .addingReportingOverflow(assistantStateBytesPerToken)
        guard !processRateOverflow else {
            throw EngineV2ProductionError.noKVHeadroom
        }


        let bridge = try EngineV2Factory.makeBridge(
            modelId: modelId,
            tokenizer: tokenizer,
            eosTokenIds: eosTokenIds,
            extraEOSTokens: snapshot.extraEOSTokens,
            defaultMaxTokens: sizing.defaultMaxTokens,
            maxConcurrentRequests: maxConcurrentRequests,
            kvBytesPerToken: processKVBytesPerToken,
            auxiliaryBytesPerToken: assistantStateBytesPerToken,
            auxiliaryTokenGranularity: assistantStateTokenGranularity,
            auxiliaryTokenAllocationPadding: assistantStateTokenAllocationPadding,
            // Shared KV ledger: v2 submissions RESERVE their worst-case
            // KV here before engine admission (process-wide gate) and the
            // reservation is what the model-LOAD gate subtracts.
            kvBudget: kvBudget,
            // SSD tier handle for the bridge's pre-submit staging hook,
            // release backstops, and shutdown (closed by `makeBridge` on
            // an engine-init failure so background tasks never leak).
            ssdPrefixCache: ssdPrefixCache,
            prefixCacheStatus: prefixCacheStatus,
            emitTelemetry: emitTelemetry,
            makeEngine: makeEngine)

        if let ssdPrefixCache {
            await bridge.startSSDPrefixCacheStatsLogger(cache: ssdPrefixCache)
        }
        await bridge.configureMTPStatus(mtpStatus)
        if let gemmaModel = servingModel as? Gemma4TextModel {
            // One load-time snapshot only. Never arm the benchmark counters in
            // production: the QMM hot path remains free of counter atomics.
            let r1 = GPU.gemma4ExpertQMMDiagnostics()
            let layerInterval = gemmaModel.cbv2PrefillChunkEvalInterval
            let report = GemmaOptimizationReport(
                layer18Requested: layerInterval > 0,
                layer18Effective:
                    layerInterval > 0
                    && gemmaModel.cbv2LayerKinds.count >= layerInterval,
                weightedUnsortRequested: gemmaModel.weightedExpertUnsortRequested,
                weightedUnsortEffective: gemmaModel.weightedExpertUnsortEffective,
                safeR1Requested: r1.requested,
                safeR1GeometryEligible: gemmaModel.expertQMMGeometryEligible,
                safeR1AOTAvailable: r1.aotAvailable,
                safeR1NAXAvailable: r1.naxAvailable)
            logInfo(report.logLine(modelId: modelId))
            for event in report.telemetryEvents(modelId: modelId) {
                if let emitTelemetry {
                    emitTelemetry(event)
                } else {
                    TelemetryClient.shared.emit(event)
                }
            }
        }
        logInfo(
            "engine_v2: \(modelId) prefix cache "
                + prefixCacheStateDescription(
                    residentEnabled:
                        preparedBackend?.residentPrefixCacheEnabled == true,
                    ssdCache: ssdPrefixCache))

        let reason = mtpStatus.reason?.rawValue ?? "none"
        let revision = mtpStatus.revision ?? "none"
        logInfo(
            "mtp: model=\(modelId) configured=\(mtpStatus.configured) active=\(mtpStatus.active) "
                + "reason=\(reason) source=\(mtpStatus.source?.rawValue ?? "none") "
                + "revision=\(revision) artifact_bytes=\(mtpStatus.artifactBytes) "
                + "assistant_bytes=\(mtpStatus.assistantBytes)")
        return ProviderEngineBundle(
            bridge: bridge,
            assistant: assistantHandle,
            assistantBytes: mtpStatus.assistantBytes,
            mtpArtifact: prepared.mtpArtifact,
            mtpStatus: mtpStatus)
    }

    /// Per-token KV rate the bridge reserves at and the heartbeat divides
    /// by (`kv_bytes_per_token` / `activeTokenBudgetMax` in
    /// `EngineV2Bridge+Capacity`), derived from the backend the slot was
    /// ACTUALLY built with:
    ///
    ///   * contiguous + GPT-OSS ⇒ the native-width rate (fp32 owning
    ///     full-attention rows on top of the fp16 sizing snapshot),
    ///   * paged with fp32 pages (`DARKBLOOM_CBV2_PAGED_KV_DTYPE=float32`)
    ///     ⇒ a flat 2x — every page doubles, windowed layers included —
    ///     so the advertised token budget HALVES to match the pool's real
    ///     page count. Without this the byte figure is right and the
    ///     divisor is half the truth, and `BackendCapacity.Slots` being
    ///     scheduler-authoritative means the coordinator over-admits ~2x
    ///     against a pool that holds half the tokens,
    ///   * everything else ⇒ the nominal fp16 rate unchanged.
    ///
    /// `pagedPoolDType` must come off `ProductionBackendPreparation` (the
    /// CONSTRUCTED pool reporting itself), never the requested env value:
    /// an fp32 request that degraded to contiguous carries nil here and
    /// must not double a backend that has no pages. Pure and static so the
    /// dtype→rate→budget wiring is unit-testable without loading a model.
    static func slotKVBytesPerToken(
        resolvedKind: EngineV2KVBackendKind,
        pagedPoolDType: String?,
        layerKinds: [CBv2LayerKind],
        nominalFP16BytesPerToken: Int,
        servingModelIsGPTOSS: Bool
    ) -> Int {
        let capability = CBv2PrefixReuseCapability.derive(
            layerKinds: layerKinds,
            backend: .contiguousUnquantized)
        return EngineV2Factory.processKVBytesPerToken(
            nominalFP16BytesPerToken: nominalFP16BytesPerToken,
            fp16FullKVBytesPerToken: capability.fullKVBytesPerToken,
            fullRowsUseFP32:
                resolvedKind == .contiguous && servingModelIsGPTOSS,
            // Only a resolved PAGED backend has pages whose dtype can
            // widen the rate; a contiguous build ignores the knob.
            pagedPoolDType: resolvedKind == .paged ? pagedPoolDType : nil)
    }

    private static func emitPrefixCacheConstructionFailure(
        modelId: String,
        kvBackendKind: EngineV2KVBackendKind?,
        capability: CBv2PrefixReuseCapability,
        failure: SSDPrefixCacheConstructionFailure,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?
    ) {
        // `prefix_reuse_backend` keeps its own key alongside the shared
        // `backend` / `kv_backend` pair: it is the finer prefix-reuse ROW
        // identity, and contiguous_quantized vs contiguous_unquantized is a
        // distinction "contiguous" cannot express. Folding any of the three
        // together silently mis-buckets every `group by backend` dashboard.
        //
        // `kv_backend` is nil-ABLE here and that is the whole reason
        // EngineHealthEvent.make takes an optional. ABSENT ⇒ UNKNOWN, the same
        // contract as BackendSlotCapacity.KVBackend (`*string` + omitempty) on
        // the heartbeat wire: a slot whose backend was never resolved omits
        // the key. Do NOT substitute a third vocabulary value such as
        // "unknown" — omission must stay distinguishable from an observation,
        // and any value here would be read as one.
        emitEngineHealth(
            EngineHealthEvent.make(
                severity: .warn,
                message: "engine_v2: SSD prefix cache construction failed",
                operation: "prefix_cache_construction",
                model: modelId,
                kvBackend: kvBackendKind?.rawValue,
                extra: [
                    "prefix_reuse_backend": .string(capability.backend.rawValue),
                    "prefix_reuse_strategy": .string(
                        capability.strategy?.rawValue ?? "none"),
                    "prefix_construction_failure": .string(failure.rawValue),
                    "prefix_cold_fallback": .bool(true),
                ]),
            sink: emitTelemetry)
    }
}
