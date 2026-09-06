import CryptoKit
import Foundation
import MLXLMCommon

enum SSDHybridCheckpointStoreFactory {
    static func make(
        modelId: String, identity: CBv2CompleteCheckpointIdentity,
        backendLayout: String = CBv2CompleteCheckpointManifest.layout,
        kvBudget: GlobalKVCacheBudget?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        persistentTestNamespace: SSDPersistentTestKeyNamespace? = nil
    ) async -> SSDHybridCheckpointStore? {
        guard [identity.modelAggregateHash, identity.promptContractID, identity.buildID, identity.numericsFingerprint]
            .allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
            PromptContractIdentity.blockHashVersion == CBv2BlockHasher.version,
            PromptContractIdentity.blockSize == UInt32(PrefixCachePolicy.blockSize),
            backendLayout == CBv2CompleteCheckpointManifest.layout
                || backendLayout == CBv2CompleteCheckpointManifest.pagedLayout
                || backendLayout == CBv2CompleteCheckpointManifest.historicalAttentionLayout
        else { return nil }
        do {
            try persistentTestNamespace?.validate(environment: environment)
        } catch { return nil }
        let wholeRoot = SSDPrefixCacheFactory.cacheRootDirectory(environment: environment)
        // Distinct from attention-only blocks; the existing global maintainer
        // recognizes this same12hex/fanout/.dbk3 hierarchy and accounts all files.
        let key = namespace(modelId: modelId, identity: identity, backendLayout: backendLayout)
        let root = wholeRoot.appendingPathComponent(String(key), isDirectory: true)
        do {
            try SSDBlockStore.prepareModelRoot(dedicatedRoot: wholeRoot, modelRoot: root)
            let material = try await SSDPrefixCacheFactory.loadKeyMaterial(
                environment: environment, persistentTestNamespace: persistentTestNamespace)
            let fingerprint = Data(HMAC<SHA256>.authenticationCode(
                for: Data("darkbloom-cache-epoch-key-binding-v1".utf8), using: material.key)).hexString
            let epoch = try SSDCacheEpochStore(root: root, binding: .init(
                modelId: modelId, modelAggregateHash: identity.modelAggregateHash,
                promptContractId: identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
                blockSize: PrefixCachePolicy.blockSize,
                layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(
                    identity: identity, backendLayout: backendLayout), keyFingerprint: fingerprint))
            let ttl = SSDPrefixCachePolicy.ttlSeconds(environment: environment)
            let budget: @Sendable () -> Int = {
                PrefixCachePolicy.ssdDiskBudgetBytes(environment: environment,
                    freeBytes: PrefixCachePolicy.volumeFreeBytes(at: wholeRoot))
            }
            let maintain: @Sendable () -> Void = {
                _ = SSDWholeRootMaintainer.shared.maintain(root: wholeRoot, ttlSeconds: ttl,
                    nowSeconds: Int64(Date().timeIntervalSince1970), budgetBytes: budget())
            }
            let cache = SSDHybridCheckpointStore(config: .init(
                modelId: modelId, identity: identity, backendLayout: backendLayout,
                root: root, dedicatedRoot: wholeRoot,
                epochStore: epoch, maxReadBytes: SSDPrefixCachePolicy.maxStageBytes(environment: environment),
                maxStageMillis: SSDPrefixCachePolicy.maxStageMillis(environment: environment),
                minEffectiveTokens: SSDPrefixCachePolicy.minEffectiveTokens(environment: environment),
                ttlSeconds: ttl, strictFsync: SSDPrefixCachePolicy.strictFsync(environment: environment),
                nowSeconds: { Int64(Date().timeIntervalSince1970) }, diskBudgetBytes: budget,
                maintainWholeRoot: maintain), kekKey: material.key, kvBudget: kvBudget,
                maxWriteBytesPerDay: SSDPrefixCachePolicy.maxWriteBytesPerDay(environment: environment),
                usesEphemeralKey: material.ephemeral)
            await Task.detached(priority: .utility) {
                cache.scanOnDisk()
                maintain()
            }.value
            SSDPrefixCacheFactory.startWholeRootMaintenance(environment: environment)
            return cache
        } catch {
            return nil
        }
    }

    static func namespace(
        modelId: String, identity: CBv2CompleteCheckpointIdentity, backendLayout: String
    ) -> String {
        let epoch = SSDHybridCheckpointEnvelope.layoutEpoch(identity: identity, backendLayout: backendLayout)
        return String(Data(SHA256.hash(
            data: Data(("complete-checkpoint-v2:" + modelId + ":" + epoch).utf8))).hexString.prefix(12))
    }
}
