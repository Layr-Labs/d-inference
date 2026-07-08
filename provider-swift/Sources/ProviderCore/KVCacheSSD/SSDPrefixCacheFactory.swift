// Copyright © 2026 Eigen Labs.
//
// Production construction of the SSD prefix cache for a funded v2 model
// slot: Secure-Enclave-rooted KEK (the reviewed legacy key hierarchy,
// unchanged), per-model directory under the legacy-compatible root, env
// knob resolution, startup scan + periodic TTL sweep.
//
// Returns nil — tier disabled, slot serves uncached — when the KEK is
// unavailable (unsigned build without the keychain entitlement), unless
// `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1` (test/stress only: a
// process-random in-memory KEK; files intentionally do NOT survive
// restart, and the HMAC names derived from it are unfindable next run —
// the startup scan's binding checks then delete them).

import CryptoKit
import Foundation
import MLXLMCommon
#if canImport(os)
import os
#endif

enum SSDPrefixCacheFactory {

    #if canImport(os)
    private static let logger = Logger(
        subsystem: "com.darkbloom.provider", category: "ssd_prefix_cache")
    #endif

    /// Legacy-compatible per-model cbv2 subtree:
    /// `~/Library/Caches/darkbloom/kv/<modelKey>/cbv2` with
    /// `modelKey = SHA256(modelId)[:12]` — stable across weight
    /// re-downloads (the metadata weightHash binding invalidates stale
    /// files); preserved by the disk accountant's init sweep.
    static func cacheDirectory(modelId: String) -> URL {
        let modelKey = SHA256.hash(data: Data(modelId.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(12)
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(
            "darkbloom/kv/\(modelKey)/cbv2", isDirectory: true)
    }

    /// Build the SSD tier for a funded model slot. `weightHash` nil falls
    /// back to the model id (same binding degradation as the legacy tier).
    static func make(
        modelId: String,
        weightHash: String?,
        layerKinds: [CBv2LayerKind],
        kvBudget: GlobalKVCacheBudget?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> SSDPrefixCache? {
        // KEK: SE-wrapped + Keychain-persisted (files must survive restart
        // — restart warmth is the feature). Same construction + escape
        // hatch as the legacy tier.
        let kekKey: SymmetricKey
        do {
            let se = try PersistentEnclaveKey.loadOrCreate()
            let kek = KVCacheKEK(
                wrapper: SecureEnclaveKeyWrappingService(enclaveKey: se),
                storage: KeychainWrappedKEKStorage())
            kekKey = try await kek.loadOrCreate()
        } catch {
            let ephEnv = environment["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"]?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let allowEphemeral =
                ephEnv == "1" || ephEnv == "true" || ephEnv == "yes" || ephEnv == "on"
            guard allowEphemeral else {
                #if canImport(os)
                logger.warning(
                    "ssd prefix cache disabled for \(modelId, privacy: .public): KEK unavailable (\(String(describing: error), privacy: .public))")
                #endif
                return nil
            }
            let kek = KVCacheKEK(
                wrapper: InMemoryKeyWrappingService(),
                storage: InMemoryWrappedKEKStorage(identifier: "ephemeral-ssd"))
            guard let ephKey = try? await kek.loadOrCreate() else { return nil }
            #if canImport(os)
            logger.warning(
                "ssd prefix cache (\(modelId, privacy: .public)): EPHEMERAL in-memory KEK (DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL) — files do not survive restart; TEST/STRESS ONLY")
            #endif
            kekKey = ephKey
        }

        let dir = cacheDirectory(modelId: modelId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let blockSize = PrefixCachePolicy.blockSize
        let config = SSDPrefixCache.Config(
            modelId: modelId,
            weightHash: (weightHash?.isEmpty == false) ? weightHash! : modelId,
            blockSize: blockSize,
            adoptionBoundTokens: PrefixCachePolicy.adoptionBoundTokens(layerKinds: layerKinds),
            layoutEpoch: SSDBlockStore.layoutEpoch(blockSize: blockSize, layerKinds: layerKinds),
            root: dir,
            ttlSeconds: SSDPrefixCachePolicy.ttlSeconds(environment: environment),
            minEffectiveTokens: SSDPrefixCachePolicy.minEffectiveTokens(environment: environment),
            maxStageBytes: SSDPrefixCachePolicy.maxStageBytes(environment: environment),
            maxStageMillis: SSDPrefixCachePolicy.maxStageMillis(environment: environment),
            nowSeconds: { Int64(Date().timeIntervalSince1970) })
        let cache = SSDPrefixCache(
            config: config,
            kekKey: kekKey,
            kvBudget: kvBudget,
            maxWriteBytesPerDay: SSDPrefixCachePolicy.maxWriteBytesPerDay(environment: environment),
            strictFsync: SSDPrefixCachePolicy.strictFsync(environment: environment),
            diskBudgetBytes: { [dir] in
                PrefixCachePolicy.ssdDiskBudgetBytes(
                    environment: ProcessInfo.processInfo.environment,
                    freeBytes: PrefixCachePolicy.volumeFreeBytes(at: dir))
            })
        cache.startBackgroundTasks()
        #if canImport(os)
        logger.info(
            "ssd prefix cache active for \(modelId, privacy: .public) at \(dir.path, privacy: .public): ttl \(config.ttlSeconds)s sliding, box-wide disk budget \(PrefixCachePolicy.ssdDiskBudgetBytes(environment: environment, freeBytes: PrefixCachePolicy.volumeFreeBytes(at: dir))) B, adoption bound \(config.adoptionBoundTokens) tok — HMAC-keyed names (T-041 leak #2 closed), no memory carve")
        #endif
        return cache
    }
}
