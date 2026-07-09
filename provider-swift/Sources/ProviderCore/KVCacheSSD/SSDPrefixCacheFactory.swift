// Copyright © 2026 Eigen Labs.
//
// Production construction of the default SSD prefix cache for a CBv2-supported
// model slot: Secure-Enclave-rooted KEK (the reviewed legacy key hierarchy,
// unchanged), a per-model directory under `darkbloom/kv2`, environment knob
// resolution, startup scan, and periodic TTL sweep. Donation is benefit-gated.
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

    /// The SSD tier's OWN root: `~/Library/Caches/darkbloom/kv2/<modelKey>`
    /// with `modelKey = SHA256(modelId)[:12]` — stable across weight
    /// re-downloads (the metadata weightHash binding invalidates stale
    /// files).
    ///
    /// DELIBERATELY OUTSIDE the legacy `darkbloom/kv` root: the legacy
    /// tier's startup machinery sheds retired-tier ciphertext under `kv/`
    /// on upgrade (v0.7.5 integration: `LegacyKVCacheSweeper` replaces the
    /// old accountant wipe), and this tier's durable restart warmth must
    /// never depend on an exclusion contract with that sweeper — a
    /// separate root is fully self-contained, zero coupling. Survival
    /// after a legacy sweep is pinned by tests.
    static let ssdRootDirectoryName = "darkbloom/kv2"

    static func cacheDirectory(modelId: String) -> URL {
        let modelKey = SHA256.hash(data: Data(modelId.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(12)
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(
            "\(Self.ssdRootDirectoryName)/\(modelKey)", isDirectory: true)
    }

    /// Build the SSD tier for a supported model slot. `weightHash` nil falls
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
