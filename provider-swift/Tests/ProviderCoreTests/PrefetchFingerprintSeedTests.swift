import Foundation
import Testing

@testable import ProviderCore

/// T4-06 (b): a verified prefetch seeds the reload fingerprint beside the
/// advertised hash, so the first load of that build takes the
/// fingerprint-reuse path instead of recomputing the full hash.
/// Calls `applyVerifiedPrefetch` directly (real actor, real disk, temp HF
/// cache) rather than through the prefetch coordinator, whose background
/// tasks are wall-clock bounded.
@Suite("Prefetch fingerprint seeding", .serialized)
struct PrefetchFingerprintSeedTests {
    private func makeLoop(models: [ModelInfo]) throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: models,
            config: ProviderConfig(
                provider: ProviderSettings(name: "prefetch-fingerprint-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 2),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
        return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
    }

    @Test("applyVerifiedPrefetch records the snapshot fingerprint and the next capture reuses the hash")
    func verifiedPrefetchSeedsTheFingerprint() async throws {
        let modelID = "darkbloom-tests/prefetched-fingerprint-\(UUID().uuidString.prefix(8))"
        let modelDir = try TestHFCache.makeFakeSnapshot(
            modelId: modelID,
            files: [
                "config.json": Data(#"{"model_type":"gpt_oss"}"#.utf8),
                "model.safetensors": Data("prefetched mlx weight bytes".utf8),
            ])
        defer { try? FileManager.default.removeItem(at: modelDir) }
        let snapshot = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
        let expectedFingerprint = try #require(WeightHasher.snapshotFingerprint(snapshotDir: snapshot))
        let expectedHash = try #require(WeightHasher.computeHash(snapshotDir: snapshot))

        let loop = try makeLoop(models: [
            ModelInfo(id: "org/startup", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
        ])
        #expect(await loop.modelHashFingerprintForTesting(modelID) == nil)

        await loop.applyVerifiedPrefetch(modelId: modelID)

        #expect(await loop.isModelAdvertised(modelID))
        #expect(await loop.liveModelHashForTesting(modelID) == expectedHash)
        #expect(await loop.modelHashFingerprintForTesting(modelID) == expectedFingerprint)

        // The first load's capture now reuses the advertised hash: no recompute.
        let capture = try await loop.captureWeightHashForTesting(modelId: modelID, modelPath: snapshot)
        #expect(capture.recomputed == false)
        #expect(capture.hash == expectedHash)
        #expect(capture.fingerprint == expectedFingerprint)
    }
}
