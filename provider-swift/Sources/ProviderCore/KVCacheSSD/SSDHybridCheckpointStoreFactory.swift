import CryptoKit
import Foundation
import MLXLMCommon
#if canImport(os)
import os
#endif

enum SSDHybridCheckpointStoreFactory {
    /// Why a complete-checkpoint store was not built. `detail` is the
    /// underlying error's description (fixed messages and status codes); it
    /// never carries key bytes or cache file contents.
    struct ConstructionFailure: Error, Equatable {
        let reason: SSDPrefixCacheConstructionFailure
        let detail: String?
    }

    #if canImport(os)
    private static let logger = Logger(
        subsystem: BuildEnvironment.current.logSubsystem, category: "ssd_prefix_cache")
    #endif

    static func make(
        modelId: String, identity: CBv2CompleteCheckpointIdentity,
        backendLayout: String = CBv2CompleteCheckpointManifest.layout,
        nativePrefillChunkSize: Int? = nil,
        kvBudget: GlobalKVCacheBudget?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        persistentTestNamespace: SSDPersistentTestKeyNamespace? = nil
    ) async -> SSDHybridCheckpointStore? {
        try? await build(
            modelId: modelId, identity: identity, backendLayout: backendLayout,
            nativePrefillChunkSize: nativePrefillChunkSize, kvBudget: kvBudget,
            environment: environment, persistentTestNamespace: persistentTestNamespace
        ).get()
    }

    /// Builds the store, or returns the typed reason it was refused. Every
    /// refusal logs one public line naming the model and reason; the slot
    /// still loads and serves uncached.
    static func build(
        modelId: String, identity: CBv2CompleteCheckpointIdentity,
        backendLayout: String = CBv2CompleteCheckpointManifest.layout,
        nativePrefillChunkSize: Int? = nil,
        kvBudget: GlobalKVCacheBudget?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        persistentTestNamespace: SSDPersistentTestKeyNamespace? = nil,
        persistentKeyLoader: SSDCacheKeyMaterial.PersistentLoader? = nil
    ) async -> Result<SSDHybridCheckpointStore, ConstructionFailure> {
        func refuse(_ reason: SSDPrefixCacheConstructionFailure, _ error: (any Error)? = nil)
            -> Result<SSDHybridCheckpointStore, ConstructionFailure>
        {
            let failure = ConstructionFailure(reason: reason, detail: error.map { String(describing: $0) })
            #if canImport(os)
            let detail = failure.detail.map { " (\($0))" } ?? ""
            logger.warning(
                "complete prefix cache disabled for \(modelId, privacy: .public): \(reason.rawValue, privacy: .public)\(detail, privacy: .public)")
            #endif
            return .failure(failure)
        }
        guard [identity.modelAggregateHash, identity.promptContractID, identity.buildID, identity.numericsFingerprint]
            .allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 })
        else { return refuse(.identityUnavailable) }
        guard PromptContractIdentity.blockHashVersion == CBv2BlockHasher.version,
            PromptContractIdentity.blockSize == UInt32(PrefixCachePolicy.blockSize)
        else { return refuse(.blockContractMismatch) }
        guard backendLayout == CBv2CompleteCheckpointManifest.layout
                || backendLayout == CBv2CompleteCheckpointManifest.pagedLayout
                || backendLayout == CBv2CompleteCheckpointManifest.quantizedPagedLayout
                 || backendLayout == CBv2CompleteCheckpointManifest.quantizedHistoricalLayout
                 || backendLayout == CBv2CompleteCheckpointManifest.nativeQuantizedPagedLayout
                 || backendLayout == CBv2CompleteCheckpointManifest.nativeQuantizedHistoricalLayout
                 || backendLayout == CBv2CompleteCheckpointManifest.nativeQuantizedContiguousLayout
                 || backendLayout == CBv2CompleteCheckpointManifest.nativeQuantizedContiguousHistoricalLayout
                 || backendLayout == CBv2CompleteCheckpointManifest.historicalAttentionLayout
                 || backendLayout == CBv2CompleteCheckpointManifest.nativeContiguousHistoricalLayout
                || backendLayout == CBv2CompleteCheckpointManifest.contiguousAsymmetricLayout
                || backendLayout == CBv2CompleteCheckpointManifest.contiguousAsymmetricMTPLayout
                || backendLayout == CBv2CompleteCheckpointManifest.pagedAsymmetricLayout
                || backendLayout == CBv2CompleteCheckpointManifest.pagedAsymmetricMTPLayout
                || backendLayout == CBv2CompleteCheckpointManifest.glm5NextPagedLayout
                || backendLayout == CBv2CompleteCheckpointManifest.diffusionBlockLayout
        else { return refuse(.layoutUnavailable) }
        guard backendLayout != CBv2CompleteCheckpointManifest.diffusionBlockLayout
            || (kvBudget != nil && (nativePrefillChunkSize ?? 0) > 0) else { return refuse(.layoutUnavailable) }
        do {
            try persistentTestNamespace?.validate(environment: environment)
        } catch { return refuse(.keyUnavailable, error) }
        let wholeRoot = SSDPrefixCacheFactory.cacheRootDirectory(environment: environment)
        // Distinct from attention-only blocks; the existing global maintainer
        // recognizes this same12hex/fanout/.dbk3 hierarchy and accounts all files.
        let key = namespace(modelId: modelId, identity: identity, backendLayout: backendLayout)
        let root = wholeRoot.appendingPathComponent(String(key), isDirectory: true)
        do {
            if SSDPrefixCacheFactory.isolatedTestRoot(environment: environment) == nil {
                try CacheStorage.validateSelection()
            }
            try SSDBlockStore.prepareModelRoot(dedicatedRoot: wholeRoot, modelRoot: root)
        } catch { return refuse(.unsafePath, error) }
        let material: SSDCacheKeyMaterial
        do {
            material = try await SSDPrefixCacheFactory.loadKeyMaterial(
                environment: environment, persistentTestNamespace: persistentTestNamespace,
                persistentLoader: persistentKeyLoader)
        } catch SSDCacheKeyMaterial.Failure.ephemeralKeyUnavailable {
            return refuse(.ephemeralKeyUnavailable)
        } catch { return refuse(.keyUnavailable, error) }
        let fingerprint = Data(HMAC<SHA256>.authenticationCode(
            for: Data("darkbloom-cache-epoch-key-binding-v1".utf8), using: material.key)).hexString
        let epoch: SSDCacheEpochStore
        do {
            epoch = try SSDCacheEpochStore(root: root, binding: .init(
                modelId: modelId, modelAggregateHash: identity.modelAggregateHash,
                promptContractId: identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
                blockSize: PrefixCachePolicy.blockSize,
                layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(
                    identity: identity, backendLayout: backendLayout), keyFingerprint: fingerprint))
        } catch { return refuse(.epochUnavailable, error) }
        let ttl = SSDPrefixCachePolicy.ttlSeconds(environment: environment)
        let budget: @Sendable () -> Int = {
            PrefixCachePolicy.ssdDiskBudgetBytes(environment: environment,
                freeBytes: PrefixCachePolicy.volumeFreeBytes(at: wholeRoot))
        }
        let maintain: @Sendable () -> Void = {
            _ = SSDWholeRootMaintainer.shared.maintain(root: wholeRoot, ttlSeconds: ttl,
                nowSeconds: Int64(Date().timeIntervalSince1970), budgetBytes: budget())
        }
        let maxWriteBytesPerDay = SSDPrefixCachePolicy.maxWriteBytesPerDay(environment: environment)
        let writeBudget: SSDWriteBudget?
        do {
            writeBudget = try CacheStorage.makeWriteBudget(
                maxWriteBytesPerDay: maxWriteBytesPerDay,
                payloadRoot: wholeRoot,
                isolated: SSDPrefixCacheFactory.isolatedTestRoot(environment: environment) != nil)
        } catch { return refuse(.writeBudgetUnavailable, error) }
        let cache = SSDHybridCheckpointStore(config: .init(
            modelId: modelId, identity: identity, backendLayout: backendLayout,
            nativePrefillChunkSize: nativePrefillChunkSize,
            root: root, dedicatedRoot: wholeRoot,
            epochStore: epoch,
            maxReadBytes: SSDPrefixCachePolicy.completeCheckpointMaxStageBytes(environment: environment),
            maxStageMillis: SSDPrefixCachePolicy.completeCheckpointMaxStageMillis(environment: environment),
            minEffectiveTokens: SSDPrefixCachePolicy.minEffectiveTokens(environment: environment),
            ttlSeconds: ttl, strictFsync: SSDPrefixCachePolicy.strictFsync(environment: environment),
            nowSeconds: { Int64(Date().timeIntervalSince1970) }, diskBudgetBytes: budget,
            maintainWholeRoot: maintain), kekKey: material.key, kvBudget: kvBudget,
            maxWriteBytesPerDay: maxWriteBytesPerDay,
            usesEphemeralKey: material.ephemeral,
            writeBudget: writeBudget)
        await Task.detached(priority: .utility) {
            cache.scanOnDisk()
            maintain()
        }.value
        SSDPrefixCacheFactory.startWholeRootMaintenance(environment: environment)
        return .success(cache)
    }

    static func namespace(
        modelId: String, identity: CBv2CompleteCheckpointIdentity, backendLayout: String
    ) -> String {
        let epoch = SSDHybridCheckpointEnvelope.layoutEpoch(identity: identity, backendLayout: backendLayout)
        return String(Data(SHA256.hash(
            data: Data(("complete-checkpoint-v2:" + modelId + ":" + epoch).utf8))).hexString.prefix(12))
    }
}
