import Foundation
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation

extension EngineV2SlotFactory {
    static let diffusionPrefillChunkSize = 512

    struct DiffusionPrefixPreparation: Sendable {
        let snapshots: DiffusionGemmaResidentPrefixConfiguration?
        let store: SSDHybridCheckpointStore?
        let retainMemory: Bool
        let status: PrefixCacheConstructionStatus
    }

    static func prepareDiffusionPrefixCache(
        modelId: String, modelDirectory: URL?, weightHash: String?, kvBytesCapacity: Int,
        kvBudget: GlobalKVCacheBudget?, environment: [String: String],
        persistentTestNamespace: SSDPersistentTestKeyNamespace?, pageBacked: Bool = false
    ) async throws -> DiffusionPrefixPreparation {
        let resident = try PrefixCachePolicy.diffusionResidentConfig(modelDirectory: modelDirectory,
            weightHash: weightHash, kvBytesCapacity: kvBytesCapacity, environment: environment)
        func fallback(_ reason: PrefixCacheStatusReason, state: PrefixCacheStatusState = .disabled) -> DiffusionPrefixPreparation {
            .init(snapshots: resident, store: nil, retainMemory: resident != nil, status: .init(state: state, reason: reason))
        }
        guard PrefixCachePolicy.isEnabled(modelId: modelId, environment: environment) else { return fallback(.configDisabled) }
        guard kvBudget != nil else { return fallback(.runtimeIdentityUnavailable) }
        guard PrefixCachePolicy.checkpointIdentityHash(weightHash) != nil else { return fallback(.weightHashUnavailable) }
        guard let modelDirectory, let prompt = try? PromptContractIdentity.compute(modelDirectory: modelDirectory),
            let identity = PrefixCachePolicy.completeCheckpointIdentity(
                modelAggregateHash: weightHash, promptContractID: prompt,
                binaryHash: PrefixCachePolicy.checkpointBinaryHash, loadedMetallibHash: metallibHash(),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                mtpConfig: .init(enabled: false), assistantCodecID: nil,
                environment: environment, processEnvironment: ProcessInfo.processInfo.environment,
                additionalNumerics: ["layout": CBv2CompleteCheckpointManifest.diffusionBlockLayout,
                                     "attentionStorage": pageBacked ? "segmented-pages-native-sdpa-v1" : "contiguous-native-sdpa-v1",
                                     "prefillChunkSize": String(diffusionPrefillChunkSize)])
        else { return fallback(.runtimeIdentityUnavailable) }
        let bytes = min(1 << 30, max(0, kvBytesCapacity / 8))
        guard bytes > 0, bytes < kvBytesCapacity else { return fallback(.unsupportedLayout) }
        guard let store = await SSDHybridCheckpointStoreFactory.make(modelId: modelId, identity: identity,
            backendLayout: CBv2CompleteCheckpointManifest.diffusionBlockLayout,
            nativePrefillChunkSize: diffusionPrefillChunkSize, kvBudget: kvBudget,
            environment: environment, persistentTestNamespace: persistentTestNamespace)
        else { return fallback(.cacheInitFailed, state: .error) }
        let snapshots = try DiffusionGemmaResidentPrefixConfiguration(maximumBytes: bytes,
            artifactIdentity: identity.modelAggregateHash, templateIdentity: identity.promptContractID,
            numericalProfile: identity.numericsFingerprint)
        return .init(snapshots: snapshots, store: store,
            retainMemory: PrefixCachePolicy.isMemoryEnabled(environment: environment), status: .scanPending)
    }
}
