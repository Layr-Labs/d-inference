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

    @Test("matching real artifact hashes publish only after the load bracket closes")
    func matchingArtifactsPublishAfterValidation() async throws {
        let modelID = "test/cache-hash-model"
        let path = try makeSnapshot("matching")
        defer { try? FileManager.default.removeItem(at: path) }
        let loop = try makeLoop()
        let pre = try await loop.captureWeightHashForTesting(
            modelId: modelID,
            modelPath: path,
            requireFreshCryptographicHash: true)
        #expect(await loop.liveModelHashForTesting(modelID) == "stale-observable-hash")
        let post = try await loop.captureWeightHashForTesting(
            modelId: modelID,
            modelPath: path,
            requireFreshCryptographicHash: true)
        let newcomer = makeNewcomer()

        let accepted = try await loop.finalizeReusableSSDLoadForTesting(
            modelId: modelID,
            preLoad: pre,
            postLoad: post,
            newcomer: newcomer)

        #expect(accepted == pre.hash)
        #expect(accepted == post.hash)
        #expect(newcomer.container != nil)
        #expect(await loop.liveModelHashForTesting(modelID) == accepted)
    }

    @Test("real artifact replacement aborts and releases before publication")
    func changedArtifactsAbortLoad() async throws {
        let modelID = "test/cache-hash-model"
        let path = try makeSnapshot("changed", weights: "aaaaaaaaaaaaaa")
        defer { try? FileManager.default.removeItem(at: path) }
        let weights = path.appendingPathComponent("model.safetensors")
        let originalDate = try #require(
            try weights.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate)
        let loop = try makeLoop()
        let pre = try await loop.captureWeightHashForTesting(
            modelId: modelID,
            modelPath: path,
            requireFreshCryptographicHash: true)

        // Keep the path and byte length stable while replacing the bytes.
        try Data("bbbbbbbbbbbbbb".utf8).write(to: weights)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: weights.path)
        let post = try await loop.captureWeightHashForTesting(
            modelId: modelID,
            modelPath: path,
            requireFreshCryptographicHash: true)
        #expect(pre.hash != post.hash)
        let newcomer = makeNewcomer()

        await #expect(throws: InferenceError.self) {
            _ = try await loop.finalizeReusableSSDLoadForTesting(
                modelId: modelID,
                preLoad: pre,
                postLoad: post,
                newcomer: newcomer)
        }
        #expect(newcomer.container == nil)
        #expect(await loop.liveModelHashForTesting(modelID) == "stale-observable-hash")
    }

    @Test("unavailable real post-load hash serves cold without publishing")
    func unavailablePostHashServesCold() async throws {
        let modelID = "test/cache-hash-model"
        let path = try makeSnapshot("missing")
        defer { try? FileManager.default.removeItem(at: path) }
        let loop = try makeLoop()
        let pre = try await loop.captureWeightHashForTesting(
            modelId: modelID,
            modelPath: path,
            requireFreshCryptographicHash: true)
        try FileManager.default.removeItem(at: path)
        let post = try await loop.captureWeightHashForTesting(
            modelId: modelID,
            modelPath: path,
            requireFreshCryptographicHash: true)
        #expect(post.hash == nil)
        let newcomer = makeNewcomer()

        let accepted = try await loop.finalizeReusableSSDLoadForTesting(
            modelId: modelID,
            preLoad: pre,
            postLoad: post,
            newcomer: newcomer)

        #expect(accepted == nil)
        #expect(newcomer.container != nil)
        #expect(await loop.liveModelHashForTesting(modelID) == nil)
        #expect(await loop.modelHashForTesting(modelID) == nil)
        #expect(await loop.isModelAdvertised(modelID))
        #expect(await loop.advertisedModelWeightHashForTesting(modelID) == nil)
        #expect(await loop.loadedModelHashesSnapshotForTesting()[modelID] == nil)

        await loop.installModelSlotForTesting(
            modelId: modelID,
            container: try #require(newcomer.container),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            engineV2: makeInertStubBridge(modelId: modelID).bridge)
        #expect(await loop.loadedModelHashesSnapshotForTesting()[modelID] == "")
    }

    @Test("unavailable real pre-load hash serves cold without publishing")
    func unavailablePreHashServesCold() async throws {
        let modelID = "test/cache-hash-model"
        let path = try makeSnapshot("missing-pre")
        defer { try? FileManager.default.removeItem(at: path) }
        let loop = try makeLoop()
        let pre = ProviderLoop.WeightHashSnapshot(
            fingerprint: nil, hash: nil, recomputed: true)
        let post = try await loop.captureWeightHashForTesting(
            modelId: modelID,
            modelPath: path,
            requireFreshCryptographicHash: true)
        #expect(post.hash != nil)
        let newcomer = makeNewcomer()

        let accepted = try await loop.finalizeReusableSSDLoadForTesting(
            modelId: modelID,
            preLoad: pre,
            postLoad: post,
            newcomer: newcomer)

        #expect(accepted == nil)
        #expect(newcomer.container != nil)
        #expect(await loop.liveModelHashForTesting(modelID) == nil)
        #expect(await loop.modelHashForTesting(modelID) == nil)
        #expect(await loop.isModelAdvertised(modelID))
        #expect(await loop.advertisedModelWeightHashForTesting(modelID) == nil)
    }
}


// MARK: - T4-01: contiguous slots take the fingerprint path; the self-test record stays honest

/// Cancels the load from inside `beforeModelLoad`, which runs AFTER the
/// pre-load hash capture/publish and BEFORE the container load — the
/// observable is what was published up to that point.
@Suite("Contiguous load path weight hash (T4-01)", .serialized)
struct ContiguousLoadWeightHashTests {
    private let modelID = "darkbloom-tests/contiguous-hash-\(UUID().uuidString.prefix(8))"

    private func makeLoop(kvBackend: String) throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [ModelInfo(
                id: modelID, modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 0.1,
                weightHash: "stale-observable-hash")],
            config: ProviderConfig(
                provider: ProviderSettings(name: "contiguous-hash-test", memoryReserveGB: 1),
                backend: BackendSettings(
                    idleTimeoutMins: 0, maxModelSlots: 1, engineV2KVBackend: kvBackend),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)),
            modelHashes: [modelID: "stale-observable-hash"],
            modelHashFingerprints: [modelID: "old-fingerprint"])
        return try ProviderLoop(
            config: config,
            purgeLegacyFiles: false,
            attestationSigner: nil,
            beforeModelLoad: { _ in
                // Stop before any weights are read: `ensureModelLoaded`
                // checks cancellation right after this hook.
                withUnsafeCurrentTask { $0?.cancel() }
            })
    }

    private func seedSnapshot(weights: String) throws -> (modelDir: URL, snapshot: URL) {
        let modelDir = try TestHFCache.makeFakeSnapshot(
            modelId: modelID,
            files: [
                "config.json": Data(#"{"model_type":"gpt_oss"}"#.utf8),
                "model.safetensors": Data(weights.utf8),
            ])
        let snapshot = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
        return (modelDir, snapshot)
    }

    @Test("a contiguous (`auto`) slot with a drifted fingerprint publishes ONE recomputed hash before the container load")
    func contiguousPublishesPreLoadHash() async throws {
        let (modelDir, snapshot) = try seedSnapshot(weights: "contiguous-weights-v1")
        defer { try? FileManager.default.removeItem(at: modelDir) }
        let expected = try #require(WeightHasher.computeHash(snapshotDir: snapshot))
        let loop = try makeLoop(kvBackend: "auto")

        let task = Task { try await loop.ensureModelLoaded(modelId: modelID) }
        await #expect(throws: CancellationError.self) { try await task.value }

        // Fingerprint path: the drifted seed forced one recompute, and the
        // result was published BEFORE the load (the bracket used to publish
        // nothing until both fresh reads agreed).
        #expect(await loop.liveModelHashForTesting(modelID) == expected)
    }

    @Test("an explicit paged slot keeps the bracket: nothing is published before the post-load read")
    func pagedKeepsTheBracket() async throws {
        let (modelDir, _) = try seedSnapshot(weights: "paged-weights-v1")
        defer { try? FileManager.default.removeItem(at: modelDir) }
        let loop = try makeLoop(kvBackend: "paged")

        let task = Task { try await loop.ensureModelLoaded(modelId: modelID) }
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(await loop.liveModelHashForTesting(modelID) == "stale-observable-hash")
    }

    @Test("a failed startup self-test records the slot's loaded hash, never the \"\" sentinel, on a contiguous slot")
    func selfTestRecordUsesLoadedHash() async throws {
        let loop = try makeLoop(kvBackend: "auto")
        let container = ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: modelID),
                model: CacheHashStubLanguageModel(),
                processor: CacheHashStubProcessor(),
                tokenizer: StubBridgeTokenizer()))
        await loop.installModelSlotForTesting(
            modelId: modelID,
            container: container,
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            engineV2: makeInertStubBridge(modelId: modelID).bridge,
            loadedWeightHash: "h-loaded-contiguous")
        #expect(await loop.loadedWeightHashForTesting(modelId: modelID) == "h-loaded-contiguous")

        await loop.retireModelAfterFailedSelfTest(modelId: modelID)

        // Keyed on the bytes that failed: a same-hash prefetch is refused,
        // a different-hash build of the same id is still advertisable.
        #expect(await loop.failedSelfTestHashForTesting(modelId: modelID) == "h-loaded-contiguous")
        #expect(await loop.isModelAdvertised(modelID) == false)
    }

    @Test("a slot with no trustworthy observation still records the fail-closed sentinel")
    func selfTestRecordFallsBackToSentinel() async throws {
        let loop = try makeLoop(kvBackend: "auto")
        let container = ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: modelID),
                model: CacheHashStubLanguageModel(),
                processor: CacheHashStubProcessor(),
                tokenizer: StubBridgeTokenizer()))
        await loop.installModelSlotForTesting(
            modelId: modelID,
            container: container,
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            engineV2: makeInertStubBridge(modelId: modelID).bridge)

        await loop.retireModelAfterFailedSelfTest(modelId: modelID)

        #expect(await loop.failedSelfTestHashForTesting(modelId: modelID) == "")
    }
}
