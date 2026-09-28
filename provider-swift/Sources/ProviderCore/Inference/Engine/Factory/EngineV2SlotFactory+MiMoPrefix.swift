// Copyright © 2026 Eigen Labs.
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation

extension EngineV2SlotFactory {
    struct MiMoNativePrefixPreparation: Sendable {
        let metadata: MiMoV26NativeCompletePrefixMetadata?
        let resources: MiMoV26NativePrefixResources?
        let status: PrefixCacheConstructionStatus
        var store: SSDHybridCheckpointStore? { resources?.store }
        static func disabled(_ reason: PrefixCacheStatusReason) -> Self {
            .init(metadata: nil, resources: nil, status: .init(state: .disabled, reason: reason))
        }
    }

    /// Separate experiment opt-in, never a catalog/capability advertisement.
    /// Media remains on its genuine existing owner/profile; combined media
    /// prefix is not supported by this text-only complete-checkpoint contract.
    static func nativeMiMoPrefixRefusal(modelId: String, hasMedia: Bool,
        environment: [String: String]) -> PrefixCacheStatusReason? {
        guard environment["DARKBLOOM_MIMO_COMPLETE_PREFIX"] == "1",
              PrefixCachePolicy.isEnabled(modelId: modelId, environment: environment) else {
            return .configDisabled
        }
        return hasMedia ? .unsupportedLayout : nil
    }

    /// Stable source facts only. Sessions, loaded-generation UUIDs, binding
    /// fingerprints, paths and inode/mtime snapshots are two-scope validators,
    /// NOT persistent identity. The aggregate payload hash comes from the
    /// existing load-hash bracket, not from these metadata digests.
    static func nativeMiMoSourceNumerics(_ binding: MiMoV26SerialLoadBinding) -> [String: String] {
        var values = [
            "modelType": "mimo_v2", "configSHA256": binding.configSHA256,
            "indexSHA256": binding.indexSHA256, "descriptorSHA256": binding.descriptorSHA256,
            "sourceRepository": binding.sourceRepository, "sourceRevision": binding.sourceRevision,
            "conversionManifestSHA256": binding.conversionManifestSHA256,
        ]
        if let receipt = binding.payloadVerificationReceiptSHA256 {
            values["payloadVerificationReceiptSHA256"] = receipt
        }
        return values
    }

    /// Only Sendable scalar metadata enters this host/IO phase. The protected
    /// loaded wrapper still owns the first binding/probe; the second scope must
    /// rederive exactly the same DTO before issuing a native execution ticket.
    static func prepareNativeMiMoPrefix(modelId: String, modelDirectory: URL?, weightHash: String?,
        prepared: MiMoV26ServingPreparation, metadata: MiMoV26NativeCompletePrefixMetadata,
        mtpConfig: CBv2MTPConfig, environment: [String: String],
        persistentTestNamespace: SSDPersistentTestKeyNamespace?) async throws -> MiMoNativePrefixPreparation {
        try prepared.load.recheck()
        let binding = prepared.load.request.binding
        guard metadata.modelType == "mimo_v2", metadata.loadSessionID == prepared.load.request.sessionID,
              metadata.loadBindingFingerprint == (try binding.fingerprint()),
              metadata.verificationMode == mtpConfig.verificationMode,
              (metadata.assistantCodecID != nil) == mtpConfig.enabled,
              let storage = CompleteCheckpointStorageIdentity(kind: .contiguous,
                layerDTypes: metadata.layerDTypes, pagedConfig: nil,
                target: .historicalAttention(metadata.layerKinds)),
              metadata.backendLayout == (mtpConfig.enabled
                ? CBv2CompleteCheckpointManifest.contiguousAsymmetricMTPLayout
                : CBv2CompleteCheckpointManifest.contiguousAsymmetricLayout) else {
            throw MiMoV26ServingLoadError.nativeOwnerMismatch
        }
        guard PrefixCachePolicy.checkpointIdentityHash(weightHash) != nil else {
            return .disabled(.weightHashUnavailable)
        }
        let root = URL(fileURLWithPath: binding.canonicalRoot, isDirectory: true)
        guard modelDirectory == nil || modelDirectory?.standardizedFileURL == root.standardizedFileURL,
              let prompt = try? PromptContractIdentity.compute(modelDirectory: root) else {
            return .disabled(.runtimeIdentityUnavailable)
        }
        var numerics = nativeMiMoSourceNumerics(binding)
        numerics["maximumContextTokens"] = String(metadata.maximumContextTokens)
        numerics["completeLayout"] = metadata.backendLayout
        guard let identity = PrefixCachePolicy.completeCheckpointIdentity(
            modelAggregateHash: weightHash, promptContractID: prompt,
            binaryHash: PrefixCachePolicy.checkpointBinaryHash, loadedMetallibHash: metallibHash(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            mtpConfig: mtpConfig, assistantCodecID: metadata.assistantCodecID,
            environment: environment, processEnvironment: ProcessInfo.processInfo.environment,
            storage: storage, additionalNumerics: numerics, nativeModelType: "mimo_v2") else {
            return .disabled(.runtimeIdentityUnavailable)
        }
        try prepared.load.recheck() // closes prompt/config read race before store creation
        let owner = MiMoV26NativePrefixResources(transactionID: prepared.transaction.id,
            sessionID: prepared.load.request.sessionID, budget: prepared.transaction.budget,
            identity: identity, backendLayout: metadata.backendLayout)
        // This capture accepts a late cancellation while performSetup is live.
        do { try prepared.transaction.registerNativeCompletePrefixResources(owner) }
        catch {
            // This is our newly created, never-bound zero-charge owner only.
            // No foreign transaction/store is disposed by a registration refusal.
            let failure = error
            await owner.closeAndWait()
            try owner.retireUnusedOwner()
            throw failure
        }
        let store = await SSDHybridCheckpointStoreFactory.make(modelId: modelId, identity: identity,
            backendLayout: metadata.backendLayout, kvBudget: prepared.transaction.budget,
            environment: environment, persistentTestNamespace: persistentTestNamespace)
        if let store {
            // Capture the actual returned store BEFORE any cancellation or
            // source recheck; the in-flight setup operation cannot retire early.
            do { try owner.install(store) }
            catch {
                // Factory.make returned this newly owned unbound store. A
                // mismatch cannot orphan its actual read/write workers.
                let failure = error
                await store.closeAndWait()
                throw failure
            }
        } else {
            await owner.closeAndWait()
            try owner.retireUnusedOwner()
            return .init(metadata: nil, resources: nil,
                status: .init(state: .error, reason: .cacheInitFailed))
        }
        try prepared.load.recheck()
        try prepared.transaction.recheckSetup()
        return .init(metadata: metadata, resources: owner, status: .scanPending)
    }
}
