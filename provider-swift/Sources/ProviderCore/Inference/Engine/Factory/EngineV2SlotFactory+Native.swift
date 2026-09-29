import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

enum EngineV2ServingPreparation: Sendable {
    case autoregressive(EngineV2PreparedModel)
    case nativeMiMo(MiMoV26ServingPreparation)
    case diffusion
    var autoregressive: EngineV2PreparedModel? {
        if case .autoregressive(let value) = self { value } else { nil }
    }
    var assistant: ProviderMTPAssistantHandle? {
        if case .nativeMiMo = self { return nil } // Native preparation is metadata-only.
        return autoregressive?.assistant
    }
    var assistantBytes: UInt64 { autoregressive?.assistantBytes ?? 0 }
    var mtpStatus: MTPActivationStatus {
        if case .nativeMiMo(let value) = self { return value.status }
        return autoregressive?.mtpStatus ?? .disabled(.targetUnsupported, configured: false)
    }
    var mtpArtifact: SpecDecArtifact? { autoregressive?.mtpArtifact }
    func fallingBack(_ reason: MTPFallbackReason) -> Self {
        if case .nativeMiMo(let value) = self {
            return .nativeMiMo(.init(container: value.container, load: value.load,
                transaction: value.transaction, status: value.status.fallingBack(reason)))
        }
        if let autoregressive { return .autoregressive(autoregressive.fallingBack(reason)) }
        return .diffusion
    }
}

/// Honest pre-build intent. No native model/binding/assistant escapes the SDK
/// container. Actual activation is reported only by the completed real bundle.
struct MiMoV26ServingPreparation: Sendable {
    let container: ModelContainer
    let load: MiMoV26ServingLoad
    let transaction: MiMoV26NativeLoadTransaction
    let status: MTPActivationStatus
}

/// Existing synchronized handles and metadata only. In particular this value
/// has NO deinit that releases the assistant if the enclosing SDK fence fails.
private struct MiMoV26NativeSlotAssembly: Sendable {
    let engine: EngineV2
    let bridge: EngineV2Bridge
    let assistant: ProviderMTPAssistantHandle?
    let status: MTPActivationStatus
}

extension EngineV2SlotFactory {
    /// Experimental strategy opt-in for eligible text rounds only. It does
    /// not activate MTP, remove media support, or change any fallback gate.
    static func nativeMiMoVerificationMode(wantsMTP: Bool,
        environment: [String: String]) -> CBv2MTPVerificationMode {
        wantsMTP && environment["DARKBLOOM_MIMO_RECTANGULAR_VERIFY"] == "1"
            ? .rectangular : .serialTarget
    }
    static func prepareProductionModel(
        modelId: String, isVLM: Bool, modelDirectory: URL? = nil,
        container: ProviderModelContainer, specDecPreparation: SpecDecPreparation,
        assistantLoader: any ProviderMTPAssistantLoading = ProductionProviderMTPAssistantLoader(),
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        logInfo: @escaping @Sendable (String) -> Void = { _ in },
        logWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> EngineV2ServingPreparation {
        switch container {
        case .nativeMiMo(let target, let load):
            guard !isVLM, specDecPreparation.artifact == nil else { throw MiMoV26ServingLoadError.nativeOwnerMismatch }
            return .nativeMiMo(try await prepareNativeMiMo(container: target, load: load,
                status: specDecPreparation.status))
        case .autoregressive(let target):
            return .autoregressive(try await prepareProductionModel(
                modelId: modelId, isVLM: isVLM, modelDirectory: modelDirectory, container: target,
                specDecPreparation: specDecPreparation, assistantLoader: assistantLoader,
                emitTelemetry: emitTelemetry, logInfo: logInfo, logWarning: logWarning))
        case .diffusion:
            guard specDecPreparation.artifact == nil else {
                throw CBv2KVError.backendIneligible(reason: "Autoregressive assistant cannot bind to diffusion")
            }
            return .diffusion
        }
    }

    static func prepareRecoveryModel(
        modelId: String, isVLM: Bool, modelDirectory: URL? = nil,
        container: ProviderModelContainer, previousArtifact: SpecDecArtifact?,
        previousStatus: MTPActivationStatus, assistant: ProviderMTPAssistantHandle?,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        logInfo: @escaping @Sendable (String) -> Void = { _ in },
        logWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> EngineV2ServingPreparation {
        switch container {
        case .nativeMiMo:
            // Refuse BEFORE any assistant/engine release. A retired cold permit
            // cannot authorize another setup generation or a hidden OFF rebuild.
            throw MiMoV26NativeTransactionError.warmRebuildUnsupported
        case .autoregressive(let target):
            return .autoregressive(try await prepareRecoveryModel(
                modelId: modelId, isVLM: isVLM, modelDirectory: modelDirectory, container: target,
                previousArtifact: previousArtifact, previousStatus: previousStatus, assistant: assistant,
                emitTelemetry: emitTelemetry, logInfo: logInfo, logWarning: logWarning))
        case .diffusion:
            guard previousArtifact == nil, assistant == nil, !previousStatus.active else {
                throw CBv2KVError.backendIneligible(reason: "Invalid native diffusion recovery ownership")
            }
            return .diffusion
        }
    }

    static func makeProductionBundle(
        modelId: String, modelType: String?, isVLM: Bool, modelDirectory: URL?,
        container: ProviderModelContainer, tokenizer: TokenizerHandle, sizing: SlotSizingSnapshot,
        kvBytesCapacity: Int, maxConcurrentRequests: Int, automaticallySelectConcurrency: Bool = false,
        constructionPurpose: EngineV2Factory.ConstructionPurpose = .serving,
        kvBudget: GlobalKVCacheBudget?,
        activationReserveBytes: UInt64? = nil, kvBackendConfig: String = "auto",
        kvBackendConfigByModel: [String: String] = [:], prefillDeadlineMode: PrefillDeadlineMode? = nil,
        modelArtifactSHA256: String? = nil,
        weightHash: String? = nil, specDecPreparation: SpecDecPreparation,
        preparedModel: EngineV2ServingPreparation? = nil,
        assemblyOverrides: AssemblyOverrides = AssemblyOverrides(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        persistentTestNamespace: SSDPersistentTestKeyNamespace? = nil, startServingTelemetry: Bool = true,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        makeEngineOverride: (@Sendable (String, Int) throws -> any CBv2Engine)? = nil,
        assistantLoader: any ProviderMTPAssistantLoading = ProductionProviderMTPAssistantLoader(),
        logInfo: @escaping @Sendable (String) -> Void = { _ in },
        logWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> ProviderEngineBundle {
        switch container {
        case .nativeMiMo(let target, let load):
            guard modelType == "mimo_v2", !isVLM, specDecPreparation.artifact == nil,
                makeEngineOverride == nil else { throw MiMoV26ServingLoadError.nativeOwnerMismatch }
            let prepared: MiMoV26ServingPreparation
            if case .nativeMiMo(let value)? = preparedModel {
                guard value.load === load, value.container === target,
                      value.transaction === load.transaction,
                      value.status.configured == specDecPreparation.status.configured,
                      !(value.status.configured && value.status.reason == nil)
                        || (specDecPreparation.status.configured && specDecPreparation.status.reason == nil) else {
                    throw MiMoV26ServingLoadError.nativeOwnerMismatch
                }
                prepared = value
            } else {
                prepared = try await prepareNativeMiMo(container: target, load: load,
                    status: specDecPreparation.status)
            }
            return try await makeNativeMiMoBundle(modelId: modelId, tokenizer: tokenizer, sizing: sizing,
                prepared: prepared, kvBytesCapacity: kvBytesCapacity,
                maxConcurrentRequests: maxConcurrentRequests,
                automaticallySelectConcurrency: automaticallySelectConcurrency,
                constructionPurpose: constructionPurpose, kvBudget: kvBudget,
                backend: kvBackendConfigByModel[modelId] ?? kvBackendConfig,
                prefillDeadlineMode: prefillDeadlineMode, environment: environment,
                modelDirectory: modelDirectory, modelArtifactSHA256: modelArtifactSHA256, weightHash: weightHash,
                persistentTestNamespace: persistentTestNamespace,
                startServingTelemetry: startServingTelemetry, emitTelemetry: emitTelemetry)
        case .autoregressive(let target):
            return try await makeProductionBundle(
                modelId: modelId, modelType: modelType, isVLM: isVLM, modelDirectory: modelDirectory,
                container: target, tokenizer: tokenizer, sizing: sizing, kvBytesCapacity: kvBytesCapacity,
                maxConcurrentRequests: maxConcurrentRequests,
                automaticallySelectConcurrency: automaticallySelectConcurrency,
                constructionPurpose: constructionPurpose, kvBudget: kvBudget,
                activationReserveBytes: activationReserveBytes, kvBackendConfig: kvBackendConfig,
                kvBackendConfigByModel: kvBackendConfigByModel, prefillDeadlineMode: prefillDeadlineMode,
                modelArtifactSHA256: modelArtifactSHA256,
                weightHash: weightHash, specDecPreparation: specDecPreparation,
                preparedModel: preparedModel?.autoregressive, assemblyOverrides: assemblyOverrides,
                environment: environment, persistentTestNamespace: persistentTestNamespace,
                startServingTelemetry: startServingTelemetry, emitTelemetry: emitTelemetry,
                makeEngineOverride: makeEngineOverride, assistantLoader: assistantLoader,
                logInfo: logInfo, logWarning: logWarning)
        case .diffusion(let target):
            guard modelType == "diffusion_gemma", specDecPreparation.artifact == nil else {
                throw CBv2KVError.backendIneligible(reason: "Native diffusion slot identity mismatch")
            }
            let backend = kvBackendConfigByModel[modelId] ?? kvBackendConfig
            guard ["auto", "contiguous", "paged"].contains(backend.lowercased()) else {
                throw CBv2KVError.backendIneligible(reason: "Unknown native diffusion storage backend")
            }
            let pageBacked = backend.lowercased() == "paged"
            let prefix = try await prepareDiffusionPrefixCache(modelId: modelId, modelDirectory: modelDirectory,
                weightHash: weightHash, kvBytesCapacity: kvBytesCapacity, kvBudget: kvBudget,
                environment: environment, persistentTestNamespace: persistentTestNamespace, pageBacked: pageBacked)
            let prepared: DiffusionGemmaProviderBridge.Prepared
            do { prepared = try await DiffusionGemmaProviderBridge.make(
                container: target, modelID: modelId, kvBytesCapacity: kvBytesCapacity,
                maxConcurrentRequests: ServingPerformanceProfiles.concurrency(
                    configured: UInt64(max(1, maxConcurrentRequests))), sharedBudget: kvBudget,
                prefixCache: prefix.snapshots, completePrefixCache: prefix.store,
                retainMemoryPrefixes: prefix.retainMemory, prefillChunkSize: diffusionPrefillChunkSize,
                prefixCacheStatus: .init(modelId: modelId, backend: pageBacked ? .paged : .contiguous,
                    replayStrategy: prefix.store == nil ? .none : .direct,
                    state: prefix.status.state, reason: prefix.status.reason), pageBacked: pageBacked)
            } catch { await prefix.store?.closeAndWait(); throw error }
            let status = MTPActivationStatus.disabled(.targetUnsupported, configured: false)
            await prepared.bridge.configureMTPStatus(status, metricsInterval: startServingTelemetry ? .seconds(60) : .zero)
            return ProviderEngineBundle(bridge: prepared.bridge, assistant: nil, assistantBytes: 0,
                mtpArtifact: nil, mtpStatus: status)
        }
    }

    private static func prepareNativeMiMo(container: ModelContainer, load: MiMoV26ServingLoad,
                                          status: MTPActivationStatus) async throws -> MiMoV26ServingPreparation {
        try load.recheck()
        guard let transaction = load.transaction else { throw MiMoV26ServingLoadError.managedLoadRequired }
        try transaction.validateContainerIdentity(container)
        guard !transaction.snapshot().hasEngine else { throw MiMoV26NativeTransactionError.warmRebuildUnsupported }
        // Metadata only: no binding, assistant, cache, projection or native eval.
        try await container.perform { context in
            guard let model = context.model as? MiMoV26LoadedModel,
                  model.loadReceipt.sessionID == load.request.sessionID,
                  model.loadReceipt.binding == load.request.binding else {
                throw MiMoV26ServingLoadError.nativeOwnerMismatch
            }
        }
        try load.recheck()
        try transaction.validateContainerIdentity(container)
        let planned = MTPActivationStatus(configured: status.configured, active: false,
            reason: status.reason, source: status.source, revision: status.revision,
            sourceRevision: status.sourceRevision, artifactBytes: status.artifactBytes,
            assistantBytes: 0)
        return .init(container: container, load: load, transaction: transaction, status: planned)
    }

    private static func makeNativeMiMoBundle(
        modelId: String, tokenizer: TokenizerHandle, sizing: SlotSizingSnapshot,
        prepared: MiMoV26ServingPreparation, kvBytesCapacity: Int, maxConcurrentRequests: Int,
        automaticallySelectConcurrency: Bool, constructionPurpose: EngineV2Factory.ConstructionPurpose,
        kvBudget: GlobalKVCacheBudget?, backend: String, prefillDeadlineMode: PrefillDeadlineMode?,
        environment: [String: String], modelDirectory: URL?, modelArtifactSHA256: String?, weightHash: String?,
        persistentTestNamespace: SSDPersistentTestKeyNamespace?, startServingTelemetry: Bool,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?
    ) async throws -> ProviderEngineBundle {
        // These controls are process-latched by the actual SDK dispatchers.
        // Reject contradictory injected values before routing/claiming any
        // native slot; a width-only rollback would falsely promise disabled kernels.
        try EngineV2Factory.validateNativeMiMoPrefillPolicy(environment: environment)
        if backend.lowercased() == "paged" {
            return try await makeNativeMiMoPagedTargetBundle(modelId: modelId, tokenizer: tokenizer,
                sizing: sizing, prepared: prepared, kvBytesCapacity: kvBytesCapacity,
                maxConcurrentRequests: maxConcurrentRequests,
                automaticallySelectConcurrency: automaticallySelectConcurrency,
                constructionPurpose: constructionPurpose, kvBudget: kvBudget,
                prefillDeadlineMode: prefillDeadlineMode, environment: environment,
                modelDirectory: modelDirectory, modelArtifactSHA256: modelArtifactSHA256, weightHash: weightHash,
                persistentTestNamespace: persistentTestNamespace,
                startServingTelemetry: startServingTelemetry, emitTelemetry: emitTelemetry)
        }
        let transaction = prepared.transaction
        // These refusals are outside owned construction cleanup: a rejected
        // second/warm assembly must not revoke or release the existing pipeline.
        guard ["auto", "contiguous"].contains(backend.lowercased()), kvBytesCapacity > 0,
              maxConcurrentRequests > 0, let kvBudget else {
            throw MiMoV26ServingLoadError.unsupportedBackend
        }
        guard kvBudget === transaction.budget, prepared.load.transaction === transaction else {
            throw MiMoV26ServingLoadError.nativeOwnerMismatch
        }
        try transaction.validateContainerIdentity(prepared.container)
        try prepared.load.recheck()
        try transaction.claimSlotAssembly(prepared.container)
        do {
            let bundle = try await transaction.performSetup {
                let intent = prepared.status.configured && prepared.status.reason == nil
                    && !SpecDecArtifactFunnel.killSwitchEnabled(environment: environment)
                    ? prepared.status.fallingBack(.killSwitchDisabled) : prepared.status
                let wantsMTP = intent.configured && intent.reason == nil
                let verificationMode = nativeMiMoVerificationMode(wantsMTP: wantsMTP, environment: environment)
                let mtpConfig = CBv2MTPConfig(enabled: wantsMTP, maxDraftTokens: 3,
                    maxSpeculativeBatch: 1, verificationMode: verificationMode)
                let servingProfile = nativeMiMoServingProfile(
                    hasVisual: prepared.load.decodedMediaPolicy != nil,
                    hasAudio: prepared.load.decodedAudioPolicy != nil)
                let prefix: MiMoNativePrefixPreparation
                if let reason = nativeMiMoPrefixRefusal(modelId: modelId, environment: environment) {
                    prefix = .disabled(reason)
                } else if PrefixCachePolicy.checkpointIdentityHash(weightHash) == nil {
                    prefix = .disabled(.weightHashUnavailable)
                } else {
                    // Only Sendable scalar metadata escapes this first protected
                    // scope. Its actual probe/binding stays with the loaded owner.
                    let metadata = try await transaction.withNativeConstruction { model, scope in
                        let binding = try model.makeCBv2Binding(enableMTP: wantsMTP,
                            verificationMode: verificationMode)
                        _ = try binding.adapter.probeNativeKVTypes(retaining: scope)
                        return try model.nativeCompletePrefixMetadata(binding: binding, retaining: scope)
                    }
                    prefix = try await prepareNativeMiMoPrefix(modelId: modelId,
                        modelDirectory: modelDirectory, weightHash: weightHash, prepared: prepared,
                        metadata: metadata, mtpConfig: mtpConfig, environment: environment,
                        persistentTestNamespace: persistentTestNamespace)
                }
                let audioInstallation = try prepared.load.takeAudioInstallation()
                let assembled = try await transaction.withNativeConstruction { model, scope in
                    guard model.loadReceipt.sessionID == prepared.load.request.sessionID,
                          model.loadReceipt.binding == prepared.load.request.binding else {
                        throw MiMoV26ServingLoadError.nativeOwnerMismatch
                    }
                    if let audioInstallation {
                        let receipt = try model.installAudioSidecar(session: audioInstallation.session.consume(),
                            reservation: audioInstallation.reservation, retaining: scope,
                            isCancelled: { transaction.isCancellationRequested })
                        try transaction.registerInstalledAudioReceipt(receipt)
                    }
                    let binding = try model.makeCBv2Binding(enableMTP: wantsMTP,
                        verificationMode: verificationMode)
                    guard (binding.assistant != nil) == wantsMTP else {
                        throw MiMoV26ServingLoadError.nativeOwnerMismatch
                    }
                    let assistant = binding.assistant.map { ProviderMTPAssistantHandle(owner: $0, drafter: $0) }
                    if let assistant {
                        // The handle owns the same loaded native assistant/target,
                        // never the facade/transaction (which would form a cycle).
                        assistant.bind(sourceTarget: model, servingTarget: model)
                        try transaction.registerAssistant(assistant)
                    }
                    let probe = try binding.adapter.probeNativeKVTypes(retaining: scope)
                    let config = model.nativeConfiguration
                    let geometry = try MiMoV26AdmissionGeometry(layerKinds: binding.adapter.layerKinds,
                        probedDTypes: probe.layerDTypes, maximumContextTokens: config.maxPositionEmbeddings)
                    let resources: (backend: MiMoV26CBv2Backend,
                                    cacheProvider: any CBv2LayerCacheProvider,
                                    contract: CBv2NativeExecutionContract)
                    if let prefixOwner = prefix.resources, let store = prefixOwner.store,
                       let metadata = prefix.metadata {
                        switch servingProfile {
                        case .decodedAudio:
                            guard let audio = prepared.load.decodedAudioPolicy else {
                                throw MiMoV26ServingLoadError.nativeOwnerMismatch
                            }
                            try transaction.registerDecodedMediaFacade(prepared.load,
                                sampling: MiMoV26EncodedVisualDecoder.Sampling(configuration: config))
                            let joint = try model.makeManagedAudioCompletePrefixExecutionResources(binding: binding,
                                bytesCapacity: kvBytesCapacity, expectedMetadata: metadata,
                                completePrefixCache: store, processMemoryOwner: prefixOwner.processOwner,
                                limits: audio.media.limits, retaining: scope)
                            resources = (joint.backend, joint.cacheProvider, joint.contract)
                        case .decodedVisual:
                            guard let policy = prepared.load.decodedMediaPolicy else {
                                throw MiMoV26ServingLoadError.nativeOwnerMismatch
                            }
                            try transaction.registerDecodedMediaFacade(prepared.load,
                                sampling: MiMoV26EncodedVisualDecoder.Sampling(configuration: config))
                            let joint = try model.makeManagedMediaCompletePrefixExecutionResources(binding: binding,
                                bytesCapacity: kvBytesCapacity, expectedMetadata: metadata,
                                completePrefixCache: store, processMemoryOwner: prefixOwner.processOwner,
                                limits: policy.limits, retaining: scope)
                            resources = (joint.backend, joint.cacheProvider, joint.contract)
                        case .text:
                            let text = try model.makeNativeCompletePrefixExecutionResources(binding: binding,
                                bytesCapacity: kvBytesCapacity, expectedMetadata: metadata,
                                completePrefixCache: store, processMemoryOwner: prefixOwner.processOwner, retaining: scope)
                            resources = (text.backend, text.cacheProvider, text.contract)
                        }
                    } else if let audio = prepared.load.decodedAudioPolicy {
                        try transaction.registerDecodedMediaFacade(prepared.load,
                            sampling: MiMoV26EncodedVisualDecoder.Sampling(configuration: config))
                        let media = try model.makeManagedAudioExecutionResources(binding: binding,
                            bytesCapacity: kvBytesCapacity, limits: audio.media.limits, retaining: scope)
                        resources = (media.backend, media.cacheProvider, media.contract)
                    } else if let policy = prepared.load.decodedMediaPolicy {
                        try transaction.registerDecodedMediaFacade(prepared.load,
                            sampling: MiMoV26EncodedVisualDecoder.Sampling(configuration: config))
                        let media = try model.makeManagedMediaExecutionResources(binding: binding,
                            bytesCapacity: kvBytesCapacity, limits: policy.limits, retaining: scope)
                        resources = (media.backend, media.cacheProvider, media.contract)
                    } else {
                        let text = try binding.adapter.makeNativeExecutionResources(
                            bytesCapacity: kvBytesCapacity, retaining: scope)
                        resources = (text.backend, text.cacheProvider, text.contract)
                    }
                    let policy = EngineV2Factory.productionServingPolicy(
                        model: model, modelID: modelId, modelArtifactSHA256: modelArtifactSHA256,
                        constructionPurpose: constructionPurpose,
                        automaticallySelectConcurrency: automaticallySelectConcurrency,
                        performanceQualificationAllowed: !wantsMTP, backend: .contiguous,
                        maxContextLength: config.maxPositionEmbeddings,
                        maxConcurrentRequests: maxConcurrentRequests, environment: environment)
                    var scheduler = policy.scheduler
                    scheduler.enablePrefixCache = prefix.store != nil
                    let engine = EngineV2(model: binding.adapter, layerKinds: binding.adapter.layerKinds,
                        backend: resources.backend, cacheProvider: resources.cacheProvider,
                        sampler: CBv2DefaultSampler(),
                        detokenizerFactory: CBv2TextDetokenizerFactory(tokenizer: tokenizer.inner),
                        schedulerConfig: scheduler,
                        loopConfig: CBv2EngineLoopConfig(useLegacyRequestTimeout: EngineV2Factory.legacyRequestTimeoutEnabled()),
                        admissionConfig: geometry.internalAdmissionConfig,
                        completePrefixCache: prefix.store,
                        mtpDrafter: binding.assistant, mtpConfig: mtpConfig,
                        processMemoryOwner: prefix.resources?.processOwner,
                        nativeCompletionTracking: true, nativeExecutionContract: resources.contract,
                        automaticMiMoPrefill: EngineV2Factory.nativeMiMoAutomaticPrefill(
                            environment: environment))
                    // Register immediately; every subsequent validation may throw.
                    try transaction.registerEngine(engine, executionContract: resources.contract)
                    if case .unavailable(let reason)? = engine.resolvedMTPAdmission { throw reason }
                    if wantsMTP {
                        guard case .bounded? = engine.resolvedMTPAdmission,
                              engine.mtpInactiveReason == nil,
                              engine.mtpMetricsSnapshot()?.verificationMode == verificationMode,
                              resources.contract.mtpVerificationMode == verificationMode else {
                            throw MiMoV26ServingLoadError.nativeOwnerMismatch
                        }
                    } else {
                        guard engine.mtpMetricsSnapshot() == nil else { throw MiMoV26ServingLoadError.nativeOwnerMismatch }
                    }
                    try prepared.load.recheck()
                    // Internal Admission already owns target SWA rings. Shared
                    // bridge adds them once alongside the engine's real bounded
                    // MTP/auxiliary fixed term, never another target-ring charge.
                    let sharedFixed = try geometry.sharedFixedRequestBytes(
                        resolvedNonTargetFixedBytes: engine.resolvedFixedBytesPerRequest)
                    let bridge = try EngineV2Factory.makeBridge(modelId: modelId, tokenizer: tokenizer,
                        eosTokenIds: binding.stopTokenIDs, defaultMaxTokens: sizing.defaultMaxTokens,
                        maxConcurrentRequests: scheduler.maxConcurrentRequests,
                        performanceProfile: policy.performanceProfile,
                        unqualifiedMaxConcurrentRequests: ServingPerformanceProfiles.concurrency(
                            configured: UInt64(max(1, maxConcurrentRequests))),
                        prefillDeadlineMode: prefillDeadlineMode,
                        advertisedContextTokens: config.maxPositionEmbeddings, runtimePolicyEnvironment: environment,
                        kvBytesPerToken: geometry.fullKVBytesPerToken, kvBudget: kvBudget,
                        ssdHybridCheckpointStore: prefix.store,
                        prefixCacheStatus: .init(modelId: modelId, backend: .contiguous,
                            replayStrategy: prefix.store == nil ? .none : .direct,
                            state: prefix.status.state, reason: prefix.status.reason),
                        emitTelemetry: emitTelemetry) {
                        .init(engine: engine, fixedRequestBytes: sharedFixed,
                            kvBackendKind: .contiguous, kvBackendFallbackReason: nil,
                            mtpAdmissionResolution: engine.resolvedMTPAdmission,
                            effectiveMaxConcurrentRequests: scheduler.maxConcurrentRequests)
                    }
                    try transaction.registerBridge(bridge)
                    let status: MTPActivationStatus
                    if wantsMTP {
                        let headBytes = UInt64(prepared.load.plan.bundlePlan.tensorBytes(for: .mtp))
                        status = .init(configured: true, active: true, reason: nil, source: .inline,
                            revision: prepared.load.request.binding.indexSHA256,
                            sourceRevision: prepared.load.request.binding.sourceRevision,
                            artifactBytes: headBytes, assistantBytes: headBytes)
                    } else {
                        status = intent
                    }
                    return MiMoV26NativeSlotAssembly(engine: engine, bridge: bridge,
                        assistant: assistant, status: status)
                }
                // This await is still owned by performSetup. If its later veto
                // throws, the transaction retains every actual handle.
                try await assembled.bridge.attachNativeTransaction(transaction)
                await assembled.bridge.configureMTPStatus(assembled.status,
                    metricsInterval: startServingTelemetry ? .seconds(60) : .zero)
                if startServingTelemetry { await assembled.bridge.startSSDPrefixCacheStatsLogger() }
                try prepared.load.recheck()
                // No bundle exists before the successful SDK fence. Retain the
                // actual bundle while this operation is still active, before
                // this or an enclosing caller's final setup veto can throw.
                // Its deinit must not release the registered assistant early.
                let bundle = ProviderEngineBundle(bridge: assembled.bridge, assistant: assembled.assistant,
                    assistantBytes: 0, mtpArtifact: nil, mtpStatus: assembled.status)
                try transaction.registerBundle(bundle)
                return bundle
            }
            return bundle
        } catch {
            let failure = error
            prepared.load.revoke()
            // Invoke the real outcome path. An enclosing registered host task
            // or unfinished bridge consumer may legitimately keep this pending.
            // The owning transaction schedules retry; do not use Void shutdown/drop/refund.
            _ = await prepared.load.finishFailureAfterUnwind()
            throw failure
        }
    }
    /// Experimental owned text paging. Actual serial-head and complete-prefix
    /// tuples may compose; rectangular and media remain explicit refusals.
    private static func makeNativeMiMoPagedTargetBundle(
        modelId: String, tokenizer: TokenizerHandle, sizing: SlotSizingSnapshot,
        prepared: MiMoV26ServingPreparation, kvBytesCapacity: Int, maxConcurrentRequests: Int,
        automaticallySelectConcurrency: Bool, constructionPurpose: EngineV2Factory.ConstructionPurpose,
        kvBudget: GlobalKVCacheBudget?, prefillDeadlineMode: PrefillDeadlineMode?,
        environment: [String: String], modelDirectory: URL?, modelArtifactSHA256: String?, weightHash: String?,
        persistentTestNamespace: SSDPersistentTestKeyNamespace?, startServingTelemetry: Bool,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?
    ) async throws -> ProviderEngineBundle {
        let transaction = prepared.transaction
        let intent = prepared.status.configured && prepared.status.reason == nil
            && !SpecDecArtifactFunnel.killSwitchEnabled(environment: environment)
            ? prepared.status.fallingBack(.killSwitchDisabled) : prepared.status
        let wantsMTP = intent.configured && intent.reason == nil
        let verificationMode = nativeMiMoVerificationMode(wantsMTP: wantsMTP, environment: environment)
        guard environment["DARKBLOOM_MIMO_NATIVE_PAGED_TARGET"] == "1",
              prepared.load.decodedMediaPolicy == nil, prepared.load.decodedAudioPolicy == nil,
              verificationMode == .serialTarget,
              kvBytesCapacity > 0, maxConcurrentRequests > 0, let kvBudget else {
            throw MiMoV26ServingLoadError.unsupportedBackend
        }
        guard kvBudget === transaction.budget, prepared.load.transaction === transaction else {
            throw MiMoV26ServingLoadError.nativeOwnerMismatch
        }
        try transaction.validateContainerIdentity(prepared.container)
        try prepared.load.recheck()
        try transaction.claimSlotAssembly(prepared.container) // foreign/warm refusal never disposes live work
        let mtpConfiguration = CBv2MTPConfig(enabled: wantsMTP, maxDraftTokens: 3,
            maxSpeculativeBatch: 1, verificationMode: .serialTarget)
        do {
            return try await transaction.performSetup {
                let paging = MiMoV26NativePagedResources(transactionID: transaction.id,
                    sessionID: prepared.load.request.sessionID, budget: kvBudget)
                do { try transaction.registerNativePagedResources(paging) }
                catch {
                    // This newly created, unbound, zero-charge owner only.
                    let error = error
                    try paging.retireUnusedOwner()
                    throw error
                }
                let prefix: MiMoNativePagedPrefixPreparation
                if let refusal = nativeMiMoPrefixRefusal(modelId: modelId, environment: environment) {
                    prefix = .disabled(refusal)
                } else if PrefixCachePolicy.checkpointIdentityHash(weightHash) == nil {
                    prefix = .disabled(.weightHashUnavailable)
                } else {
                    // Only this immutable scalar DTO crosses the store await.
                    // The genuine first binding/probe stays with LoadedModel.
                    let metadata = try await transaction.withNativeConstruction { model, scope in
                        let binding = try model.makeCBv2Binding(enableMTP: wantsMTP, verificationMode: .serialTarget)
                        _ = try binding.adapter.probeNativeKVTypes(retaining: scope)
                        let scheduler = EngineV2Factory.productionServingPolicy(
                            model: model, modelID: modelId, modelArtifactSHA256: modelArtifactSHA256,
                            constructionPurpose: constructionPurpose,
                            automaticallySelectConcurrency: automaticallySelectConcurrency,
                            performanceQualificationAllowed: !wantsMTP, backend: .paged,
                            maxContextLength: model.nativeConfiguration.maxPositionEmbeddings,
                            maxConcurrentRequests: maxConcurrentRequests, environment: environment).scheduler
                        let maximumQuery = max(scheduler.maxBatchedTokensPerStep,
                            max(scheduler.prefillChunkSize, scheduler.soloPrefillStripeTokens ?? 0))
                        let maximumPrefill = max(scheduler.prefillChunkSize, scheduler.soloPrefillStripeTokens ?? 0)
                        return try model.nativePagedCompletePrefixMetadata(binding: binding,
                            bytesCapacity: kvBytesCapacity, maximumConcurrentRequests: scheduler.maxConcurrentRequests,
                            maximumQueryTokens: maximumQuery, maximumPrefillChunk: maximumPrefill, retaining: scope)
                    }
                    prefix = try await prepareNativeMiMoPagedPrefix(modelId: modelId,
                        modelDirectory: modelDirectory, weightHash: weightHash, prepared: prepared,
                        metadata: metadata, paging: paging, mtpConfig: mtpConfiguration,
                        environment: environment, persistentTestNamespace: persistentTestNamespace)
                }
                let assembled = try await transaction.withNativeConstruction { model, scope in
                    guard model.loadReceipt.sessionID == prepared.load.request.sessionID,
                          model.loadReceipt.binding == prepared.load.request.binding else {
                        throw MiMoV26ServingLoadError.nativeOwnerMismatch
                    }
                    let binding = try model.makeCBv2Binding(enableMTP: wantsMTP, verificationMode: .serialTarget)
                    guard (binding.assistant != nil) == wantsMTP else {
                        throw MiMoV26ServingLoadError.nativeOwnerMismatch
                    }
                    let assistant = binding.assistant.map { ProviderMTPAssistantHandle(owner: $0, drafter: $0) }
                    if let assistant {
                        assistant.bind(sourceTarget: model, servingTarget: model)
                        try transaction.registerAssistant(assistant)
                    }
                    let probe = try binding.adapter.probeNativeKVTypes(retaining: scope)
                    let config = model.nativeConfiguration
                    let geometry = try MiMoV26AdmissionGeometry(layerKinds: binding.adapter.layerKinds,
                        probedDTypes: probe.layerDTypes, maximumContextTokens: config.maxPositionEmbeddings)
                    let policy = EngineV2Factory.productionServingPolicy(
                        model: model, modelID: modelId, modelArtifactSHA256: modelArtifactSHA256,
                        constructionPurpose: constructionPurpose,
                        automaticallySelectConcurrency: automaticallySelectConcurrency,
                        performanceQualificationAllowed: !wantsMTP, backend: .paged,
                        maxContextLength: config.maxPositionEmbeddings,
                        maxConcurrentRequests: maxConcurrentRequests, environment: environment)
                    var scheduler = policy.scheduler
                    scheduler.enablePrefixCache = prefix.metadata != nil && paging.store != nil
                    let maximumQuery = max(scheduler.maxBatchedTokensPerStep,
                        max(scheduler.prefillChunkSize, scheduler.soloPrefillStripeTokens ?? 0))
                    let maximumPrefill = max(scheduler.prefillChunkSize, scheduler.soloPrefillStripeTokens ?? 0)
                    let resources: MiMoV26CBv2NativePagedExecutionResources
                    if let metadata = prefix.metadata, let store = paging.store {
                        resources = try model.makeNativePagedCompletePrefixExecutionResources(binding: binding,
                            bytesCapacity: kvBytesCapacity, maximumConcurrentRequests: scheduler.maxConcurrentRequests,
                            maximumQueryTokens: maximumQuery, maximumPrefillChunk: maximumPrefill,
                            expectedMetadata: metadata, completePrefixCache: store,
                            processMemoryOwner: paging.processOwner, retaining: scope)
                    } else if wantsMTP {
                        resources = try model.makeNativePagedSerialMTPExecutionResources(binding: binding,
                            bytesCapacity: kvBytesCapacity, maximumConcurrentRequests: scheduler.maxConcurrentRequests,
                            maximumQueryTokens: maximumQuery, maximumPrefillChunk: maximumPrefill,
                            processMemoryOwner: paging.processOwner, retaining: scope)
                    } else {
                        resources = try model.makeNativePagedExecutionResources(binding: binding,
                            bytesCapacity: kvBytesCapacity, maximumConcurrentRequests: scheduler.maxConcurrentRequests,
                            maximumQueryTokens: maximumQuery, maximumPrefillChunk: maximumPrefill,
                            processMemoryOwner: paging.processOwner, retaining: scope)
                    }
                    let engine = EngineV2(model: binding.adapter, layerKinds: binding.adapter.layerKinds,
                        backend: resources.backend, cacheProvider: resources.cacheProvider,
                        sampler: CBv2DefaultSampler(),
                        detokenizerFactory: CBv2TextDetokenizerFactory(tokenizer: tokenizer.inner),
                        schedulerConfig: scheduler,
                        loopConfig: .init(useLegacyRequestTimeout: EngineV2Factory.legacyRequestTimeoutEnabled()),
                        admissionConfig: geometry.internalAdmissionConfig,
                        completePrefixCache: paging.store,
                        mtpDrafter: binding.assistant,
                        mtpConfig: mtpConfiguration,
                        processMemoryOwner: paging.processOwner,
                        nativeCompletionTracking: true, nativeExecutionContract: resources.contract)
                    try transaction.registerEngine(engine, executionContract: resources.contract)
                    guard engine.nativeCompletionFault == nil, engine.pagedAttentionWorkInactiveReason == nil else {
                        throw MiMoV26ServingLoadError.nativeOwnerMismatch
                    }
                    if case .unavailable(let reason)? = engine.resolvedMTPAdmission { throw reason }
                    if wantsMTP {
                        guard resources.contract.supportsNativePagedSerialMTP,
                              case .bounded? = engine.resolvedMTPAdmission,
                              engine.mtpInactiveReason == nil,
                              engine.mtpMetricsSnapshot()?.verificationMode == .serialTarget else {
                            throw MiMoV26ServingLoadError.nativeOwnerMismatch
                        }
                    } else {
                        guard !resources.contract.supportsNativePagedSerialMTP,
                              engine.mtpMetricsSnapshot() == nil else {
                            throw MiMoV26ServingLoadError.nativeOwnerMismatch
                        }
                    }
                    try prepared.load.recheck()
                    let bridge = try EngineV2Factory.makeBridge(modelId: modelId, tokenizer: tokenizer,
                        eosTokenIds: binding.stopTokenIDs, defaultMaxTokens: sizing.defaultMaxTokens,
                        maxConcurrentRequests: scheduler.maxConcurrentRequests,
                        performanceProfile: policy.performanceProfile,
                        unqualifiedMaxConcurrentRequests: ServingPerformanceProfiles.concurrency(
                            configured: UInt64(max(1, maxConcurrentRequests))),
                        prefillDeadlineMode: prefillDeadlineMode,
                        advertisedContextTokens: config.maxPositionEmbeddings,
                        runtimePolicyEnvironment: environment, kvBytesPerToken: geometry.fullKVBytesPerToken,
                        kvBudget: kvBudget, ssdHybridCheckpointStore: paging.store,
                        prefixCacheStatus: .init(modelId: modelId, backend: .paged,
                            replayStrategy: paging.store == nil ? .none : .direct,
                            state: prefix.status.state, reason: prefix.status.reason),
                        emitTelemetry: emitTelemetry) {
                        .init(engine: engine, fixedRequestBytes: engine.resolvedFixedBytesPerRequest,
                            kvBackendKind: .paged, kvBackendFallbackReason: nil,
                            mtpAdmissionResolution: engine.resolvedMTPAdmission,
                            effectiveMaxConcurrentRequests: scheduler.maxConcurrentRequests)
                    }
                    try transaction.registerBridge(bridge)
                    let status: MTPActivationStatus
                    if wantsMTP {
                        let headBytes = UInt64(prepared.load.plan.bundlePlan.tensorBytes(for: .mtp))
                        status = .init(configured: true, active: true, reason: nil, source: .inline,
                            revision: prepared.load.request.binding.indexSHA256,
                            sourceRevision: prepared.load.request.binding.sourceRevision,
                            artifactBytes: headBytes, assistantBytes: headBytes)
                    } else { status = intent }
                    return MiMoV26NativeSlotAssembly(engine: engine, bridge: bridge,
                        assistant: assistant, status: status)
                }
                try await assembled.bridge.attachNativeTransaction(transaction)
                await assembled.bridge.configureMTPStatus(assembled.status,
                    metricsInterval: startServingTelemetry ? .seconds(60) : .zero)
                try prepared.load.recheck()
                let bundle = ProviderEngineBundle(bridge: assembled.bridge, assistant: assembled.assistant,
                    // The inline trained heads are already in the strict load's
                    // weight charge, just as for the contiguous native bundle.
                    assistantBytes: 0, mtpArtifact: nil, mtpStatus: assembled.status)
                try transaction.registerBundle(bundle)
                return bundle
            }
        } catch {
            let failure = error
            prepared.load.revoke()
            _ = await prepared.load.finishFailureAfterUnwind()
            throw failure
        }
    }

}
