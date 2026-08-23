import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

private final class CacheHashStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }

    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct CacheHashStubProcessorError: Error {}

private struct CacheHashStubProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw CacheHashStubProcessorError()
    }
}

@Suite("SSD cache publication and load refusal")
struct WeightHashCacheEligibilityTests {
    private func makeHarness() async throws -> (
        loop: ProviderLoop, client: CoordinatorClient
    ) {
        let modelID = "test/cache-hash-model"
        let hardware = HardwareInfo(
            machineModel: "Mac16,5",
            chipName: "Apple M4 Max",
            chipFamily: .m4,
            chipTier: .max,
            memoryGb: 128,
            memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40,
            memoryBandwidthGbs: 546)
        let model = ModelInfo(
            id: modelID,
            modelType: "gpt_oss",
            sizeBytes: 1,
            estimatedMemoryGb: 1,
            weightHash: "stale-observable-hash")
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: hardware,
            models: [model],
            config: ProviderConfig(
                provider: ProviderSettings(name: "cache-hash-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)),
            modelHashes: [modelID: "stale-observable-hash"],
            modelHashFingerprints: [modelID: "old-fingerprint"])
        let loop = try ProviderLoop(
            config: config,
            purgeLegacyFiles: false,
            attestationSigner: nil)
        let client = CoordinatorClient(
            config: CoordinatorClientConfig(
                url: config.coordinatorURL,
                hardware: hardware,
                models: [model],
                backendName: "mlx-swift"),
            stats: AtomicProviderStats(),
            state: ProviderState())
        let prefetchCoordinator = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(),
            preCheck: { _ in .alreadyAvailable },
            onVerified: { _ in })
        await loop.installPrefetchCoordinatorForTesting(
            prefetchCoordinator,
            client: client)
        return (loop, client)
    }

    private func nextRegistrationModel(
        _ modelID: String,
        client: CoordinatorClient
    ) async throws -> ModelInfo {
        guard case .register(let registration) = await client.registrationMessage() else {
            throw CacheHashStubProcessorError()
        }
        return try #require(registration.models.first { $0.id == modelID })
    }

    private func makeSnapshot(_ label: String, weights: String = "weights-before") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-hash-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"model_type":"gpt_oss"}"#.utf8)
            .write(to: root.appendingPathComponent("config.json"))
        try Data(weights.utf8)
            .write(to: root.appendingPathComponent("model.safetensors"))
        return root
    }

    private func makeNewcomer() -> EngineV2NewcomerBox {
        EngineV2NewcomerBox(ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: "test/cache-hash-model"),
                model: CacheHashStubLanguageModel(),
                processor: CacheHashStubProcessor(),
                tokenizer: StubBridgeTokenizer()
            )))
    }

    @Test("matching artifacts bind reusable cache before the next registration advertises their hash")
    func matchingArtifactsPublishAfterValidation() async throws {
        let modelID = "test/cache-hash-model"
        let path = try makeSnapshot("matching")
        defer { try? FileManager.default.removeItem(at: path) }
        let harness = try await makeHarness()
        let pre = try await harness.loop.captureWeightHashForTesting(
            modelId: modelID,
            modelPath: path,
            requireFreshCryptographicHash: true)
        let post = try await harness.loop.captureWeightHashForTesting(
            modelId: modelID,
            modelPath: path,
            requireFreshCryptographicHash: true)
        #expect(
            try await nextRegistrationModel(modelID, client: harness.client).weightHash
                == "stale-observable-hash")
        let newcomer = makeNewcomer()

        let cacheBinding = try await harness.loop.finalizeReusableSSDLoadForTesting(
            modelId: modelID,
            preLoad: pre,
            postLoad: post,
            newcomer: newcomer)

        #expect(cacheBinding == pre.hash)
        #expect(cacheBinding == post.hash)
        #expect(newcomer.container != nil)
        #expect(
            try await nextRegistrationModel(modelID, client: harness.client).weightHash
                == cacheBinding)
    }

    @Test("artifact replacement refuses the load and clears the stale advertised hash")
    func changedArtifactsAbortLoad() async throws {
        let modelID = "test/cache-hash-model"
        let path = try makeSnapshot("changed", weights: "aaaaaaaaaaaaaa")
        defer { try? FileManager.default.removeItem(at: path) }
        let weights = path.appendingPathComponent("model.safetensors")
        let originalDate = try #require(
            try weights.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate)
        let harness = try await makeHarness()
        let pre = try await harness.loop.captureWeightHashForTesting(
            modelId: modelID,
            modelPath: path,
            requireFreshCryptographicHash: true)

        // Keep the path and byte length stable while replacing the bytes.
        try Data("bbbbbbbbbbbbbb".utf8).write(to: weights)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: weights.path)
        let post = try await harness.loop.captureWeightHashForTesting(
            modelId: modelID,
            modelPath: path,
            requireFreshCryptographicHash: true)
        #expect(pre.hash != post.hash)
        let newcomer = makeNewcomer()

        await #expect(throws: InferenceError.self) {
            _ = try await harness.loop.finalizeReusableSSDLoadForTesting(
                modelId: modelID,
                preLoad: pre,
                postLoad: post,
                newcomer: newcomer)
        }
        #expect(newcomer.container == nil)
        #expect(
            try await nextRegistrationModel(modelID, client: harness.client).weightHash
                == nil)
    }

    @Test("unavailable real post-load hash serves cold without advertising a binding")
    func unavailablePostHashServesCold() async throws {
        let modelID = "test/cache-hash-model"
        let path = try makeSnapshot("missing")
        defer { try? FileManager.default.removeItem(at: path) }
        let harness = try await makeHarness()
        let pre = try await harness.loop.captureWeightHashForTesting(
            modelId: modelID,
            modelPath: path,
            requireFreshCryptographicHash: true)
        try FileManager.default.removeItem(at: path)
        let post = try await harness.loop.captureWeightHashForTesting(
            modelId: modelID,
            modelPath: path,
            requireFreshCryptographicHash: true)
        #expect(post.hash == nil)
        let newcomer = makeNewcomer()

        let cacheBinding = try await harness.loop.finalizeReusableSSDLoadForTesting(
            modelId: modelID,
            preLoad: pre,
            postLoad: post,
            newcomer: newcomer)

        #expect(cacheBinding == nil)
        #expect(newcomer.container != nil)
        #expect(
            try await nextRegistrationModel(modelID, client: harness.client).weightHash
                == nil)
        #expect(await harness.loop.loadedModelHashesSnapshotForTesting()[modelID] == nil)

        await harness.loop.installModelSlotForTesting(
            modelId: modelID,
            container: try #require(newcomer.container),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            engineV2: makeInertStubBridge(modelId: modelID).bridge)
        #expect(await harness.loop.loadedModelHashesSnapshotForTesting()[modelID] == "")
    }

    @Test("unavailable real pre-load hash serves cold without advertising a binding")
    func unavailablePreHashServesCold() async throws {
        let modelID = "test/cache-hash-model"
        let path = try makeSnapshot("missing-pre")
        defer { try? FileManager.default.removeItem(at: path) }
        let harness = try await makeHarness()
        let pre = ProviderLoop.WeightHashSnapshot(
            fingerprint: nil, hash: nil, recomputed: true)
        let post = try await harness.loop.captureWeightHashForTesting(
            modelId: modelID,
            modelPath: path,
            requireFreshCryptographicHash: true)
        #expect(post.hash != nil)
        let newcomer = makeNewcomer()

        let cacheBinding = try await harness.loop.finalizeReusableSSDLoadForTesting(
            modelId: modelID,
            preLoad: pre,
            postLoad: post,
            newcomer: newcomer)

        #expect(cacheBinding == nil)
        #expect(newcomer.container != nil)
        #expect(
            try await nextRegistrationModel(modelID, client: harness.client).weightHash
                == nil)
    }
}
