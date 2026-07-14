import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("SSD cache weight-hash eligibility")
struct WeightHashCacheEligibilityTests {
    private func makeLoop() throws -> ProviderLoop {
        let modelID = "test/cache-hash-model"
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5",
                chipName: "Apple M4 Max",
                chipFamily: .m4,
                chipTier: .max,
                memoryGb: 128,
                memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40,
                memoryBandwidthGbs: 546),
            models: [ModelInfo(
                id: modelID,
                modelType: "gpt_oss",
                sizeBytes: 1,
                estimatedMemoryGb: 1,
                weightHash: "stale-observable-hash")],
            config: ProviderConfig(
                provider: ProviderSettings(name: "cache-hash-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)),
            modelHashes: [modelID: "stale-observable-hash"],
            modelHashFingerprints: [modelID: "old-fingerprint"])
        return try ProviderLoop(
            config: config,
            purgeLegacyFiles: false,
            attestationSigner: nil)
    }

    @Test("changed fingerprint plus both failed rehashes keeps stale observable hash but disables SSD")
    func failedRehashesDisableReusableCache() async throws {
        let modelID = "test/cache-hash-model"
        let loop = try makeLoop()
        await loop.setWeightHashOperationsForTesting(
            fingerprint: { _ in "new-fingerprint" },
            computeHash: { _, _ in nil })
        let modelPath = URL(fileURLWithPath: "/nonexistent/cache-hash-fixture")

        let preLoad = try await loop.refreshWeightHashForTesting(
            modelId: modelID,
            modelPath: modelPath,
            requireFreshCryptographicHash: true)
        let postLoad = try await loop.refreshWeightHashForTesting(
            modelId: modelID,
            modelPath: modelPath,
            requireFreshCryptographicHash: true)
        let eligible = ProviderLoop.cryptographicallyBracketedCacheHash(
            preLoadHash: preLoad.cacheEligibleWeightHash,
            postLoadHash: postLoad.cacheEligibleWeightHash)

        #expect(preLoad.effectiveFingerprint == nil)
        #expect(postLoad.effectiveFingerprint == nil)
        #expect(eligible == nil)
        #expect(await loop.liveModelHashForTesting(modelID) == "stale-observable-hash")

        let cache = await SSDPrefixCacheFactory.make(
            modelId: modelID,
            weightHash: eligible,
            layerKinds: [CBv2LayerKind(
                attention: .full,
                headDim: 8,
                kvHeads: 1,
                queryHeads: 1)],
            kvBudget: nil,
            environment: ["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1"])
        #expect(cache == nil)
    }

    @Test("fingerprint drift across load disables cache even after a successful post-load hash")
    func loadWindowDriftDisablesCache() {
        let pre = ProviderLoop.WeightHashRefreshResult(
            observedFingerprint: "before",
            effectiveFingerprint: "before",
            cacheEligibleWeightHash: "before-hash")
        let post = ProviderLoop.WeightHashRefreshResult(
            observedFingerprint: "after",
            effectiveFingerprint: "after",
            cacheEligibleWeightHash: "after-hash")
        #expect(ProviderLoop.cacheEligibleWeightHash(
            preLoad: pre,
            postLoadFingerprint: "after",
            postLoadRefresh: post) == nil)
    }

    @Test("same fingerprint with changed cryptographic hash disables SSD")
    func preservedMetadataReplacementIsDetected() async throws {
        final class HashSequence: @unchecked Sendable {
            private let lock = NSLock()
            private var hashes = ["hash-before", "hash-after"]
            func next() -> String? {
                lock.withLock { hashes.isEmpty ? nil : hashes.removeFirst() }
            }
        }
        let sequence = HashSequence()
        let loop = try makeLoop()
        await loop.setWeightHashOperationsForTesting(
            fingerprint: { _ in "same-size-same-mtime" },
            computeHash: { _, _ in sequence.next() })
        let path = URL(fileURLWithPath: "/nonexistent/preserved-metadata-fixture")
        let pre = try await loop.refreshWeightHashForTesting(
            modelId: "test/cache-hash-model",
            modelPath: path,
            requireFreshCryptographicHash: true)
        let post = try await loop.refreshWeightHashForTesting(
            modelId: "test/cache-hash-model",
            modelPath: path,
            requireFreshCryptographicHash: true)

        #expect(pre.observedFingerprint == post.observedFingerprint)
        #expect(pre.cacheEligibleWeightHash == "hash-before")
        #expect(post.cacheEligibleWeightHash == "hash-after")
        #expect(ProviderLoop.cryptographicallyBracketedCacheHash(
            preLoadHash: pre.cacheEligibleWeightHash,
            postLoadHash: post.cacheEligibleWeightHash) == nil)
    }

    @Test("missing either cryptographic bracket disables SSD")
    func missingHashDisablesCache() {
        #expect(ProviderLoop.cryptographicallyBracketedCacheHash(
            preLoadHash: nil, postLoadHash: "hash") == nil)
        #expect(ProviderLoop.cryptographicallyBracketedCacheHash(
            preLoadHash: "hash", postLoadHash: nil) == nil)
        #expect(ProviderLoop.cryptographicallyBracketedCacheHash(
            preLoadHash: "hash", postLoadHash: "hash") == "hash")
    }
}
