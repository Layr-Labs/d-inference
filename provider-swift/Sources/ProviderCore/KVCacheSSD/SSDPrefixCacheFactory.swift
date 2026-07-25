// Copyright © 2026 Eigen Labs.
//
// Production construction of the default SSD prefix cache for a CBv2-supported
// model slot: Secure-Enclave-rooted KEK (the reviewed legacy key hierarchy,
// unchanged), a per-model directory under `darkbloom/kv3`, environment knob
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

enum SSDPrefixCacheConstructionFailure: String, Sendable {
    case missingWeightHash = "missing_weight_hash"
    case unsupportedPlan = "unsupported_plan"
    case unsafePath = "unsafe_path"
    case keyUnavailable = "key_unavailable"
    case ephemeralKeyUnavailable = "ephemeral_key_unavailable"
    case blockContractMismatch = "block_contract_mismatch"
    case epochUnavailable = "epoch_unavailable"
    case promptContractUnavailable = "prompt_contract_unavailable"
    case layoutUnavailable = "layout_unavailable"
}

enum SSDPrefixCacheFactory {

    #if canImport(os)
    private static let logger = Logger(
        subsystem: "com.darkbloom.provider", category: "ssd_prefix_cache")
    #endif

    /// The SSD tier's OWN root: `~/Library/Caches/darkbloom/kv3/<modelKey>`
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
    static let ssdRootDirectoryName = "darkbloom/kv3"
    /// Testbed-only isolated root. Honored only together with the explicit
    /// ephemeral-key escape hatch, which also forces an in-memory KEK.
    static let testRootEnvironmentKey = "DARKBLOOM_PREFIX_CACHE_TEST_ROOT"

    static func cacheDirectory(
        modelId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let modelKey = SHA256.hash(data: Data(modelId.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(12)
        return cacheRootDirectory(environment: environment)
            .appendingPathComponent(String(modelKey), isDirectory: true)
    }

    static func cacheRootDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let root = isolatedTestRoot(environment: environment) { return root }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(Self.ssdRootDirectoryName, isDirectory: true)
    }

    static func startWholeRootMaintenance(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        intervalSeconds: Int = 60
    ) {
        let root = cacheRootDirectory(environment: environment)
        let ttl = SSDPrefixCachePolicy.ttlSeconds(environment: environment)
        SSDWholeRootMaintainer.shared.startPeriodicMaintenance(
            root: root,
            ttlSeconds: ttl,
            intervalSeconds: intervalSeconds,
            nowSeconds: { Int64(Date().timeIntervalSince1970) },
            budgetBytes: {
                PrefixCachePolicy.ssdDiskBudgetBytes(
                    environment: ProcessInfo.processInfo.environment,
                    freeBytes: PrefixCachePolicy.volumeFreeBytes(at: root))
            })
    }

    static func stopWholeRootMaintenance() {
        SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: cacheRootDirectory())
    }

    private static func ephemeralAllowed(environment: [String: String]) -> Bool {
        let raw = environment["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"]?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }

    private static func isolatedTestRoot(environment: [String: String]) -> URL? {
        guard ephemeralAllowed(environment: environment),
            let raw = environment[testRootEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    /// Build the SSD tier for a supported model slot. Reusable ciphertext is
    /// permitted only when it can be bound to the verified hash of the live
    /// weights. A missing/blank hash disables the tier instead of degrading to
    /// a model-id binding that could survive a weight replacement.
    static func make(
        modelId: String,
        promptContractID: String,
        weightHash: String?,
        layerKinds: [CBv2LayerKind],
        prefixReuseCapability: CBv2PrefixReuseCapability,
        kvBudget: GlobalKVCacheBudget?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onConstructionFailure:
            (@Sendable (SSDPrefixCacheConstructionFailure) -> Void)? = nil
    ) async -> SSDPrefixCache? {
        guard let weightHash = verifiedWeightHash(weightHash) else {
            onConstructionFailure?(.missingWeightHash)
            #if canImport(os)
            logger.warning(
                "ssd prefix cache disabled for \(modelId, privacy: .public): verified live weight hash unavailable")
            #endif
            return nil
        }
        guard prefixReuseCapability.isSupported else {
            onConstructionFailure?(.unsupportedPlan)
            #if canImport(os)
            logger.info(
                "ssd prefix cache disabled for \(modelId, privacy: .public): prefix reuse unsupported (\(prefixReuseCapability.unsupportedReason?.rawValue ?? "unknown", privacy: .public), backend=\(prefixReuseCapability.backend.rawValue, privacy: .public))")
            #endif
            return nil
        }
        let wholeRoot = cacheRootDirectory(environment: environment)
        let dir = cacheDirectory(modelId: modelId, environment: environment)
        do {
            try SSDBlockStore.prepareModelRoot(
                dedicatedRoot: wholeRoot,
                modelRoot: dir)
        } catch {
            onConstructionFailure?(.unsafePath)
            #if canImport(os)
            logger.warning(
                "ssd prefix cache disabled for \(modelId, privacy: .public): unsafe cache path (\(String(describing: error), privacy: .public))")
            #endif
            return nil
        }
        // KEK: SE-wrapped + Keychain-persisted (files must survive restart
        // — restart warmth is the feature). Same construction + escape
        // hatch as the legacy tier.
        let kekKey: SymmetricKey
        var usedEphemeral = false
        let forceEphemeral = isolatedTestRoot(environment: environment) != nil
        if forceEphemeral {
            let kek = KVCacheKEK(
                wrapper: InMemoryKeyWrappingService(),
                storage: InMemoryWrappedKEKStorage(identifier: "ephemeral-ssd"))
            guard let key = try? await kek.loadOrCreate() else {
                onConstructionFailure?(.ephemeralKeyUnavailable)
                return nil
            }
            kekKey = key
            usedEphemeral = true
        } else {
            do {
                let se = try PersistentEnclaveKey.loadOrCreate()
                let kek = KVCacheKEK(
                    wrapper: SecureEnclaveKeyWrappingService(enclaveKey: se),
                    storage: KeychainWrappedKEKStorage())
                kekKey = try await kek.loadOrCreate()
            } catch {
                guard ephemeralAllowed(environment: environment) else {
                    onConstructionFailure?(.keyUnavailable)
                    #if canImport(os)
                    logger.warning(
                        "ssd prefix cache disabled for \(modelId, privacy: .public): KEK unavailable (\(String(describing: error), privacy: .public))")
                    #endif
                    return nil
                }
                let kek = KVCacheKEK(
                    wrapper: InMemoryKeyWrappingService(),
                    storage: InMemoryWrappedKEKStorage(identifier: "ephemeral-ssd"))
                guard let ephKey = try? await kek.loadOrCreate() else {
                    onConstructionFailure?(.ephemeralKeyUnavailable)
                    return nil
                }
                kekKey = ephKey
                usedEphemeral = true
            }
        }
        if usedEphemeral {
            #if canImport(os)
            if forceEphemeral {
                logger.warning(
                    "ssd prefix cache (\(modelId, privacy: .public)): isolated TEST root with ephemeral in-memory KEK — files do not survive process exit")
            } else {
                logger.warning(
                    "ssd prefix cache (\(modelId, privacy: .public)): EPHEMERAL in-memory KEK (DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL) — files do not survive restart; TEST/STRESS ONLY")
            }
            #endif
        }

        let blockSize = PrefixCachePolicy.blockSize
        guard PromptContractIdentity.blockHashVersion == CBv2BlockHasher.version,
            PromptContractIdentity.blockSize == UInt32(blockSize)
        else {
            onConstructionFailure?(.blockContractMismatch)
            #if canImport(os)
            logger.warning(
                "ssd prefix cache disabled for \(modelId, privacy: .public): prompt-contract/block-hasher binary mismatch")
            #endif
            return nil
        }
        let layoutEpoch = SSDBlockStore.layoutEpoch(
            blockSize: blockSize, layerKinds: layerKinds)
        let keyFingerprint = HMAC<SHA256>.authenticationCode(
            for: Data("darkbloom-cache-epoch-key-binding-v1".utf8),
            using: kekKey
        ).map { String(format: "%02x", $0) }.joined()
        let epochStore: SSDCacheEpochStore
        do {
            epochStore = try SSDCacheEpochStore(
                root: dir,
                binding: SSDCacheEpochStore.Binding(
                    modelId: modelId,
                    modelAggregateHash: weightHash,
                    promptContractId: promptContractID,
                    blockHashVersion: CBv2BlockHasher.version,
                    blockSize: blockSize,
                    layoutEpoch: layoutEpoch,
                    keyFingerprint: keyFingerprint))
        } catch {
            onConstructionFailure?(.epochUnavailable)
            #if canImport(os)
            logger.warning(
                "ssd prefix cache disabled for \(modelId, privacy: .public): cache epoch unavailable (\(String(describing: error), privacy: .public))")
            #endif
            return nil
        }
        // WS-4.2. Two INDEPENDENT decisions, deliberately:
        //
        //  * whether this cache has sidecars at all — the operator knob plus a
        //    layout that tiles into whole blocks. This drives the write and
        //    read paths, so the format and the corpus stay exercised;
        //  * whether an adopter's sliding rows are RESTORED — which
        //    additionally requires a row that can install one. Nothing can
        //    today, so this resolves `.replayed` and the replay bound stays
        //    conservative. Tying the geometry to the residency instead would
        //    make the knob a no-op; tying the bound to the geometry (the
        //    original shape) advertised a zero replay that the engine still
        //    performed.
        let backendSelection: EngineV2KVBackendSelection =
            prefixReuseCapability.backend == .pagedFP16 ? .paged : .contiguous
        let windowSidecar =
            SSDPrefixCachePolicy.windowSidecarEnabled(environment: environment)
            ? SSDWindowSidecarGeometry.derive(layerKinds: layerKinds, blockSize: blockSize)
            : nil
        let windowResidency = PrefixCachePolicy.windowResidency(
            layerKinds: layerKinds,
            backendSelection: backendSelection,
            environment: environment)
        // The conservative bound is what this cache charges by default; the
        // restored bound applies per boundary, only where a complete
        // authenticated window is actually present.
        let adoptionBoundTokens = PrefixCachePolicy.adoptionBoundTokens(
            capability: prefixReuseCapability,
            layerKinds: layerKinds,
            windowResidency: .replayed)
        let windowRestoredBoundTokens = PrefixCachePolicy.adoptionBoundTokens(
            capability: prefixReuseCapability,
            layerKinds: layerKinds,
            windowResidency: windowResidency)
        let config = SSDPrefixCache.Config(
            modelId: modelId,
            promptContractID: promptContractID,
            weightHash: weightHash,
            blockSize: blockSize,
            adoptionBoundTokens: adoptionBoundTokens,
            nominalFullKVBytesPerToken: prefixReuseCapability.fullKVBytesPerToken,
            layoutEpoch: layoutEpoch,
            epochStore: epochStore,
            root: dir,
            dedicatedRoot: wholeRoot,
            ttlSeconds: SSDPrefixCachePolicy.ttlSeconds(environment: environment),
            minEffectiveTokens: PrefixCachePolicy.minEffectiveTokens(
                capability: prefixReuseCapability,
                adoptionBoundTokens: adoptionBoundTokens,
                environment: environment),
            maxStageBytes: SSDPrefixCachePolicy.maxStageBytes(environment: environment),
            maxStageMillis: SSDPrefixCachePolicy.maxStageMillis(environment: environment),
            windowSidecar: windowSidecar,
            windowRestoredBoundTokens: windowRestoredBoundTokens,
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
            },
            maintainWholeRoot: { [wholeRoot, dir] in
                _ = SSDWholeRootMaintainer.shared.maintain(
                    root: wholeRoot,
                    ttlSeconds: SSDPrefixCachePolicy.ttlSeconds(
                        environment: ProcessInfo.processInfo.environment),
                    nowSeconds: Int64(Date().timeIntervalSince1970),
                    budgetBytes: PrefixCachePolicy.ssdDiskBudgetBytes(
                        environment: ProcessInfo.processInfo.environment,
                        freeBytes: PrefixCachePolicy.volumeFreeBytes(at: dir)))
            })
        cache.startBackgroundTasks()
        startWholeRootMaintenance(environment: environment)
        #if canImport(os)
        logger.info(
            "ssd prefix cache active for \(modelId, privacy: .public) at \(dir.path, privacy: .public): strategy \(prefixReuseCapability.strategy?.rawValue ?? "none", privacy: .public), backend \(prefixReuseCapability.backend.rawValue, privacy: .public), ttl \(config.ttlSeconds)s sliding, box-wide disk budget \(PrefixCachePolicy.ssdDiskBudgetBytes(environment: environment, freeBytes: PrefixCachePolicy.volumeFreeBytes(at: dir))) B, replay bound \(config.adoptionBoundTokens) tok — HMAC-keyed names (T-041 leak #2 closed), no memory carve")
        #endif
        return cache
    }

    static func verifiedWeightHash(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
