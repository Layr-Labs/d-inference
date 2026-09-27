import Foundation
import MLXLMCommon
import MLXVLM

enum EngineV2ServingPreparation {
    case autoregressive(EngineV2PreparedModel)
    case diffusion
    var autoregressive: EngineV2PreparedModel? {
        if case .autoregressive(let value) = self { value } else { nil }
    }
    var assistant: ProviderMTPAssistantHandle? { autoregressive?.assistant }
    var assistantBytes: UInt64 { autoregressive?.assistantBytes ?? 0 }
    var mtpStatus: MTPActivationStatus {
        autoregressive?.mtpStatus ?? .disabled(.targetUnsupported, configured: false)
    }
    var mtpArtifact: SpecDecArtifact? { autoregressive?.mtpArtifact }
    func fallingBack(_ reason: MTPFallbackReason) -> Self {
        if let autoregressive { .autoregressive(autoregressive.fallingBack(reason)) } else { .diffusion }
    }
}

extension EngineV2SlotFactory {
    static func prepareProductionModel(
        modelId: String, isVLM: Bool, modelDirectory: URL? = nil,
        container: ProviderModelContainer, specDecPreparation: SpecDecPreparation,
        assistantLoader: any ProviderMTPAssistantLoading = ProductionProviderMTPAssistantLoader(),
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        logInfo: @escaping @Sendable (String) -> Void = { _ in },
        logWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> EngineV2ServingPreparation {
        switch container {
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
        kvBytesCapacity: Int, maxConcurrentRequests: Int, kvBudget: GlobalKVCacheBudget?,
        activationReserveBytes: UInt64? = nil, kvBackendConfig: String = "auto",
        kvBackendConfigByModel: [String: String] = [:], prefillDeadlineMode: PrefillDeadlineMode? = nil,
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
        case .autoregressive(let target):
            return try await makeProductionBundle(
                modelId: modelId, modelType: modelType, isVLM: isVLM, modelDirectory: modelDirectory,
                container: target, tokenizer: tokenizer, sizing: sizing, kvBytesCapacity: kvBytesCapacity,
                maxConcurrentRequests: maxConcurrentRequests, kvBudget: kvBudget,
                activationReserveBytes: activationReserveBytes, kvBackendConfig: kvBackendConfig,
                kvBackendConfigByModel: kvBackendConfigByModel, prefillDeadlineMode: prefillDeadlineMode,
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
                maxConcurrentRequests: maxConcurrentRequests, sharedBudget: kvBudget,
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
}
