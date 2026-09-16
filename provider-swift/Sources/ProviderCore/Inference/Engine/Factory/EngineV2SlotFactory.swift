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

enum EngineV2SlotFactory {

    static func shouldLogPrefillDeadlineProjectionBypass(
        configuredMode: PrefillDeadlineMode?,
        environment: [String: String]
    ) -> Bool {
        PrefillDeadlineMode.resolve(
            configured: configuredMode,
            environment: environment) == .enforce
            && !EngineV2Factory.prefillDeadlineProjectionSupported(
                environment: environment)
    }

    /// Narrow assembly seams for production-order regression tests. Normal
    /// callers use the empty value and execute only concrete production code.
    struct AssemblyOverrides {
        var gemmaMTPVerification: EngineV2BenchmarkMTPVerification? = nil
        var promptContractID: String? = nil
        var completeCheckpointIdentity: CBv2CompleteCheckpointIdentity? = nil
        var pagedPreflight: (([CBv2LayerKind]) throws -> Void)? = nil
        var makePrefixCache:
            (([CBv2LayerKind], CBv2PrefixReuseCapability) async -> SSDPrefixCache?)? = nil
    }

    /// Human-readable cache state for the slot-serving log line.
    static func prefixCacheStateDescription(
        residentEnabled: Bool = false,
        hybridEnabled: Bool = false,
        ssdCache: SSDPrefixCache?,
        completeCheckpointEnabled: Bool = false
    ) -> String {
        let resident = hybridEnabled ? "memory=on (exact recurrent checkpoints)"
            : residentEnabled ? "memory=on (zero-copy paged L1)" : "memory=off"
        if completeCheckpointEnabled {
            return "on (\(resident), ssd=on: encrypted complete checkpoints, matched-request staging)"
        }
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
        return residentEnabled || hybridEnabled ? "on (\(resident), ssd=off)" : "off"
    }

    /// Build the production `EngineV2Bridge` for a freshly-loaded model.
    /// THROWS on any construction failure (the factory emits the ERROR
    /// `engine_v2_refusal` event first) — the caller unloads + maps to 503.
    ///
    /// - Parameters:
    ///   - modelId: catalog id the slot serves under.
    ///   - modelType: `model_type` from config.json (EOS policy input).
    ///   - isVLM: config declares `vision_config` — Gemma serves its owned
    ///     text tower, while Qwen3-VL serves the loaded wrapper directly.
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
    ///   - environment: runtime policy environment (including prefix-cache,
    ///     MTP, KV-backend, and prefill-deadline controls); injectable for
    ///     tests.
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
        prefillDeadlineMode: PrefillDeadlineMode? = nil,
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
            prefillDeadlineMode: prefillDeadlineMode,
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
        activationReserveBytes: UInt64? = nil,
        kvBackendConfig: String = "auto",
        kvBackendConfigByModel: [String: String] = [:],
        prefillDeadlineMode: PrefillDeadlineMode? = nil,
        weightHash: String? = nil,
        specDecPreparation: SpecDecPreparation,
        preparedModel: EngineV2PreparedModel? = nil,
        assemblyOverrides: AssemblyOverrides = AssemblyOverrides(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        persistentTestNamespace: SSDPersistentTestKeyNamespace? = nil,
        startServingTelemetry: Bool = true,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        makeEngineOverride: (@Sendable (String, Int) throws -> any CBv2Engine)? = nil,
        assistantLoader: any ProviderMTPAssistantLoading = ProductionProviderMTPAssistantLoader(),
        logInfo: @escaping @Sendable (String) -> Void = { _ in },
        logWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> ProviderEngineBundle {
        try persistentTestNamespace?.validate(environment: environment)
        // Per-model selection wins. Apply multimodal vetoes before allocation;
        // prepareProductionBackend then resolves auto, the fleet kill switch,
        // and degrade-or-refuse policy. Cache construction uses that final kind.
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
        } else {
            // Scripted engines retain the configured status but never load an assistant.
            let preparation = makeEngineOverride == nil ? specDecPreparation
                : SpecDecPreparation(artifact: nil, status: specDecPreparation.status)
            prepared = try await prepareProductionModel(
                modelId: modelId,
                isVLM: isVLM,
                modelDirectory: modelDirectory,
                container: container,
                specDecPreparation: preparation,
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
        let draftDepth = MTPAutomaticVerificationPolicy.draftDepthPolicy(
            usesRequestStatefulDrafter:
                assistantHandle?.drafter is any CBv2MTPRequestStatefulDrafter,
            modelID: modelId,
            hasBenchmarkVerificationOverride: assemblyOverrides.gemmaMTPVerification != nil)
        var mtpConfig = CBv2MTPConfig(
            enabled: assistantHandle != nil,
            maxDraftTokens: draftDepth.maximum,
            fixedDraftTokens: draftDepth.fixed,
            verificationMode: mtpVerification.mode,
            maxAutomaticRectangularTokens: mtpVerification.automaticRectangularTokens)
        if let verification = assemblyOverrides.gemmaMTPVerification {
            mtpConfig = try verification.applying(
                to: mtpConfig, target: servingModel, drafter: assistantHandle?.drafter)
        }
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
        let hybridPrefixCache = PrefixCachePolicy.hybridConfig(
            modelId: modelId, promptContractID: promptContractID,
            kvBytesCapacity: engineKVBytesCapacity,
            hasMTPDrafter: assistantHandle?.drafter != nil,
            supportsMTPPrefixCheckpoint: assistantHandle?.drafter is any CBv2MTPPrefixCheckpointDrafter,
            environment: environment)
        let preparedBackend: EngineV2Factory.ProductionBackendPreparation?
        if makeEngineOverride == nil {
            do {
                preparedBackend = try EngineV2Factory.prepareProductionBackend(
                    model: servingModel,
                    modelID: modelId,
                    kvBytesCapacity: engineKVBytesCapacity,
                    maxConcurrentRequests: maxConcurrentRequests,
                    kvBackend: kvBackendSelection,
                    maxContextLength: sizing.maxContextLength > 0
                        ? sizing.maxContextLength : nil,
                    environment: environment,
                    residentPrefixCache: residentPrefixCache,
                    hybridPrefixCache: hybridPrefixCache,
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

        // SSD staging reserves transient RAM through GlobalKVCacheBudget;
        // refused staging falls back to recomputation. Complete recurrent
        // checkpoints and attention-only blocks have separate codecs/gates.
        // Resident payloads were prepared above only with the memory opt-in.
        // VLM slots use the resolved serving text tower's layer kinds.
        let completePreparation = await prepareCompletePrefixCache(
            modelId: modelId, model: servingModel, preparedBackend: preparedBackend,
            weightHash: weightHash, promptContractID: promptContractID,
            mtpDrafter: assistantHandle?.drafter, mtpConfig: mtpConfig,
            kvBudget: kvBudget, environment: environment,
            persistentTestNamespace: persistentTestNamespace,
            identityOverride: assemblyOverrides.completeCheckpointIdentity)
        let ssdHybridCheckpointStore = completePreparation?.cache
        let attentionPreparation: AttentionPrefixCachePreparation
        if let completePreparation {
            // A complete-checkpoint target must never fall through to incomplete
            // attention-only storage, including when construction is disabled.
            attentionPreparation = .init(status: completePreparation.status)
        } else {
            attentionPreparation = await prepareAttentionPrefixCache(
                modelId: modelId, preparedBackend: preparedBackend,
                scriptedEngine: makeEngineOverride != nil,
                weightHash: weightHash, promptContractID: promptContractID,
                kvBudget: kvBudget, environment: environment,
                persistentTestNamespace: persistentTestNamespace,
                makePrefixCache: assemblyOverrides.makePrefixCache,
                emitTelemetry: emitTelemetry, logInfo: logInfo, logWarning: logWarning)
        }
        let ssdPrefixCache = attentionPreparation.cache
        let prefixCacheStatus = PrefixCacheModelStatus(
            modelId: modelId,
            backend: preparedBackend.map { PrefixCacheStatusBackend($0.kind) } ?? .unknown,
            replayStrategy: ssdHybridCheckpointStore == nil
                ? PrefixCacheReplayStrategy(attentionPreparation.capability) : .direct,
            state: attentionPreparation.status.state,
            reason: attentionPreparation.status.reason)
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
                    completePrefixCache: ssdHybridCheckpointStore,
                    maxConcurrentRequests: maxConcurrentRequests,
                    mtpDrafter: assistantHandle?.drafter,
                    mtpConfig: mtpConfig,
                    preparedBackend: preparedBackend,
                    kvBudget: kvBudget)
            }
        }

        let targetKVBytesPerToken: Int
        if let preparedBackend {
            targetKVBytesPerToken = slotKVBytesPerToken(
                resolvedKind: preparedBackend.kind,
                pagedPoolDType: preparedBackend.pagedPoolDType,
                pagedLayerDTypes: preparedBackend.pagedLayerDTypes,
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

        let resolvedPartialPrefillCap =
            EngineV2Factory.maxConcurrentPartialPrefills(
                environment: environment)
        if shouldLogPrefillDeadlineProjectionBypass(
            configuredMode: prefillDeadlineMode,
            environment: environment)
        {
            logInfo(
                "engine_v2_prefill_deadline model_id=\(modelId) "
                    + "effective=ordinary_submit "
                    + "reason=partial_prefill_projection_unsupported "
                    + "max_concurrent_partial_prefills="
                    + (resolvedPartialPrefillCap.map(String.init) ?? "unlimited"))
        }

        let residentEvidence = weightHash.flatMap { modelHash in
            promptContractID.flatMap { contract in
                ResidentPrefixCacheEvidence(
                    modelId: modelId, modelAggregateHash: modelHash, promptContractID: contract)
            }
        }
        let bridge = try EngineV2Factory.makeBridge(
            modelId: modelId,
            tokenizer: tokenizer,
            eosTokenIds: eosTokenIds,
            extraEOSTokens: snapshot.extraEOSTokens,
            defaultMaxTokens: sizing.defaultMaxTokens,
            maxConcurrentRequests: maxConcurrentRequests,
            prefillDeadlineMode: prefillDeadlineMode,
            runtimePolicyEnvironment: environment,
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
            ssdHybridCheckpointStore: ssdHybridCheckpointStore,
            residentPrefixCacheEvidence: residentEvidence,
            prefixCacheStatus: prefixCacheStatus,
            emitTelemetry: emitTelemetry,
            makeEngine: makeEngine)

        if startServingTelemetry { await bridge.startSSDPrefixCacheStatsLogger() }
        await bridge.configureMTPStatus(mtpStatus,
            metricsInterval: startServingTelemetry ? .seconds(60) : .zero)
        reportGemmaOptimizations(
            model: servingModel, modelId: modelId,
            emitTelemetry: emitTelemetry, logInfo: logInfo)
        logInfo(
            "engine_v2: \(modelId) prefix cache "
                + prefixCacheStateDescription(
                    residentEnabled:
                        preparedBackend?.residentPrefixCacheEnabled == true,
                    hybridEnabled: preparedBackend?.hybridPrefixCache != nil,
                    ssdCache: ssdPrefixCache,
                    completeCheckpointEnabled: ssdHybridCheckpointStore != nil))

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

    /// Full-attention marginal KV rate used by shared request admission and
    /// token-capacity reporting. Normal paged construction supplies the exact
    /// per-layer table from the pool; shared rows own no storage. The scalar
    /// branch preserves low-level fixed-pool callers. Contiguous GPT-OSS keeps
    /// its existing native full-row adjustment. Window storage and recurrent
    /// fixed charges are separate from this marginal rate.
    static func slotKVBytesPerToken(
        resolvedKind: EngineV2KVBackendKind,
        pagedPoolDType: String?,
        pagedLayerDTypes: [DType]? = nil,
        layerKinds: [CBv2LayerKind],
        nominalFP16BytesPerToken: Int,
        servingModelIsGPTOSS: Bool
    ) -> Int {
        if resolvedKind == .paged, let pagedLayerDTypes {
            return EngineV2Factory.nativeFullKVBytesPerToken(
                layerKinds: layerKinds, dtypes: pagedLayerDTypes)
        }
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
}
