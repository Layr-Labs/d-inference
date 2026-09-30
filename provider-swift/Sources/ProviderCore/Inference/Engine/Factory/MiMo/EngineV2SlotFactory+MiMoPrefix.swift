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

    /// Construction intent only, not capability or ownership authority. The
    /// factory must issue the corresponding genuine SDK tuple; it may never
    /// turn a media load into a text-only profile to obtain prefix support.
    enum MiMoNativeServingProfile: Sendable, Equatable { case text, decodedVisual, decodedAudio }
    static func nativeMiMoServingProfile(hasVisual: Bool, hasAudio: Bool) -> MiMoNativeServingProfile {
        hasAudio ? .decodedAudio : hasVisual ? .decodedVisual : .text
    }

    /// Existing opt-in/cache policy only. Joint media authority is checked by
    /// the protected SDK issuer, not inferred from this successful policy gate.
    static func nativeMiMoPrefixRefusal(modelId: String,
        environment: [String: String]) -> PrefixCacheStatusReason? {
        guard environment["DARKBLOOM_MIMO_COMPLETE_PREFIX"] == "1",
              PrefixCachePolicy.isEnabled(modelId: modelId, environment: environment) else {
            return .configDisabled
        }
        return nil
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

extension EngineV2SlotFactory {
    struct MiMoNativePagedPrefixPreparation: Sendable {
        let metadata: MiMoV26NativePagedPrefixMetadata?
        let status: PrefixCacheConstructionStatus
        static func disabled(_ reason: PrefixCacheStatusReason) -> Self {
            .init(metadata: nil, status: .init(state: .disabled, reason: reason))
        }
    }

    /// Scalar first-scope facts only. The already registered PAGED host owner
    /// receives the actual store; never create a second process ledger owner.
    static func prepareNativeMiMoPagedPrefix(modelId: String, modelDirectory: URL?, weightHash: String?,
        prepared: MiMoV26ServingPreparation, metadata: MiMoV26NativePagedPrefixMetadata,
        paging: MiMoV26NativePagedResources, mtpConfig: CBv2MTPConfig, environment: [String: String],
        persistentTestNamespace: SSDPersistentTestKeyNamespace?) async throws -> MiMoNativePagedPrefixPreparation {
        try prepared.load.recheck()
        let native = metadata.prefix, binding = prepared.load.request.binding
        guard paging.transactionID == prepared.transaction.id, paging.sessionID == prepared.load.request.sessionID,
              paging.budget === prepared.transaction.budget,
              native.modelType == "mimo_v2", native.loadSessionID == prepared.load.request.sessionID,
              native.loadBindingFingerprint == (try binding.fingerprint()),
              native.verificationMode == .serialTarget, mtpConfig.verificationMode == .serialTarget,
              (native.assistantCodecID != nil) == mtpConfig.enabled,
              metadata.pagedConfiguration.layerDTypes == native.layerDTypes,
              metadata.pagedConfiguration.gatheredAttention?.maximumContextTokens == native.maximumContextTokens,
              native.backendLayout == (mtpConfig.enabled ? CBv2CompleteCheckpointManifest.pagedAsymmetricMTPLayout
                : CBv2CompleteCheckpointManifest.pagedAsymmetricLayout),
              let storage = CompleteCheckpointStorageIdentity(kind: .paged,
                layerDTypes: native.layerDTypes, pagedConfig: metadata.pagedConfiguration,
                target: .historicalAttention(native.layerKinds)) else {
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
        numerics["maximumContextTokens"] = String(native.maximumContextTokens)
        numerics["completeLayout"] = native.backendLayout
        guard let identity = PrefixCachePolicy.completeCheckpointIdentity(
            modelAggregateHash: weightHash, promptContractID: prompt,
            binaryHash: PrefixCachePolicy.checkpointBinaryHash, loadedMetallibHash: metallibHash(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            mtpConfig: mtpConfig, assistantCodecID: native.assistantCodecID,
            environment: environment, processEnvironment: ProcessInfo.processInfo.environment,
            storage: storage, additionalNumerics: numerics, nativeModelType: "mimo_v2") else {
            return .disabled(.runtimeIdentityUnavailable)
        }
        try prepared.load.recheck()
        try prepared.transaction.recheckSetup()
        try paging.preparePrefix(identity: identity, backendLayout: native.backendLayout)
        let store = await SSDHybridCheckpointStoreFactory.make(modelId: modelId, identity: identity,
            backendLayout: native.backendLayout, kvBudget: paging.budget,
            environment: environment, persistentTestNamespace: persistentTestNamespace)
        if let store {
            do { try paging.installPrefix(store) }
            catch {
                let failure = error
                await store.closeAndWait() // this newly created, unbound store only
                throw failure
            }
        } else {
            await paging.closeAndWait()
            // The SAME zero-charge paging owner remains available for the
            // honest uncached profile; do not retire/recreate a process owner.
            return .init(metadata: nil, status: .init(state: .error, reason: .cacheInitFailed))
        }
        try prepared.load.recheck()
        try prepared.transaction.recheckSetup()
        return .init(metadata: metadata, status: .scanPending)
    }
}
