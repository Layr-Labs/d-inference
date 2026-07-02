/// Tests for the persisted loaded-model set (`LoadedModelsStore`) and its
/// `ProviderLoop` write points: every load/non-shutdown-unload rewrites the
/// file, shutdown teardown preserves it. This file is the default startup
/// preload plan, so the round-trip IS the restart-warmup contract.

import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

// MARK: - Store round-trip

@Suite("LoadedModelsStore")
struct LoadedModelsStoreTests {

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-loaded-models-tests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).json")
    }

    @Test("write then read round-trips the model set")
    func roundTrip() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        LoadedModelsStore.write(["gemma-4-26b-it", "qwen3-8b"], to: url)
        #expect(LoadedModelsStore.read(from: url) == ["gemma-4-26b-it", "qwen3-8b"])
    }

    @Test("missing file reads as empty")
    func missingFileReadsEmpty() {
        let url = tempFile()
        #expect(LoadedModelsStore.read(from: url) == [])
    }

    @Test("corrupt file reads as empty, not a crash")
    func corruptFileReadsEmpty() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json {{{".utf8).write(to: url)

        #expect(LoadedModelsStore.read(from: url) == [])
    }

    @Test("schema mismatch reads as empty")
    func schemaMismatchReadsEmpty() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = LoadedModelsStore.State(schema: 99, models: ["m"], updatedAt: 0)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(future).write(to: url)

        #expect(LoadedModelsStore.read(from: url) == [])
    }

    @Test("a later write replaces the set")
    func overwriteReplacesSet() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        LoadedModelsStore.write(["a", "b"], to: url)
        LoadedModelsStore.write(["c"], to: url)
        #expect(LoadedModelsStore.read(from: url) == ["c"])
    }

    @Test("write failure is swallowed (unwritable path)")
    func writeFailureIsSwallowed() {
        // /dev/null/x can never be created; write must not crash.
        let url = URL(fileURLWithPath: "/dev/null/nested/loaded-models.json")
        LoadedModelsStore.write(["m"], to: url)
        #expect(LoadedModelsStore.read(from: url) == [])
    }
}

// MARK: - ProviderLoop write points

/// Stub tokenizer/model/container so a real `ModelSlot` can exist without
/// weights (same pattern as EngineV2ProductionWiringTests).
private struct PersistStubTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [0] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [0] }
}

private final class PersistStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct PersistStubProcessorError: Error {}
private struct PersistStubProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw PersistStubProcessorError()
    }
}

private func makePersistStubContainer() -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/stub-model"),
            model: PersistStubLanguageModel(),
            processor: PersistStubProcessor(),
            tokenizer: PersistStubTokenizer()
        ))
}

private func makePersistLoop() throws -> ProviderLoop {
    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/ignored",
        hardware: HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546
        ),
        models: [],
        config: ProviderConfig(
            provider: ProviderSettings(name: "loaded-models-persist-test", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 2),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
}

@Suite("LoadedModelsStore: ProviderLoop write points")
struct LoadedModelsPersistenceWiringTests {

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-loaded-models-tests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).json")
    }

    @Test("persisting after a slot install writes the loaded set")
    func persistWritesLoadedSlots() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let loop = try makePersistLoop()
        await loop.setLoadedModelsFileForTesting(url)

        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-it",
            scheduler: BatchScheduler(maxConcurrentRequests: 2, defaultMaxTokens: 64),
            container: makePersistStubContainer(),
            tokenizer: TokenizerHandle(PersistStubTokenizer())
        )
        await loop.persistLoadedModelSetForTesting()

        #expect(LoadedModelsStore.read(from: url) == ["gemma-4-26b-it"])
    }

    @Test("a normal unload removes the model from the persisted set")
    func unloadRemovesFromPersistedSet() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let loop = try makePersistLoop()
        await loop.setLoadedModelsFileForTesting(url)

        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-it",
            scheduler: BatchScheduler(maxConcurrentRequests: 2, defaultMaxTokens: 64),
            container: makePersistStubContainer(),
            tokenizer: TokenizerHandle(PersistStubTokenizer())
        )
        await loop.persistLoadedModelSetForTesting()
        #expect(LoadedModelsStore.read(from: url) == ["gemma-4-26b-it"])

        await loop.unloadModel("gemma-4-26b-it")

        #expect(LoadedModelsStore.read(from: url) == [])
    }

    @Test("shutdown teardown preserves the persisted set for the next boot")
    func shutdownUnloadPreservesPersistedSet() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let loop = try makePersistLoop()
        await loop.setLoadedModelsFileForTesting(url)

        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-it",
            scheduler: BatchScheduler(maxConcurrentRequests: 2, defaultMaxTokens: 64),
            container: makePersistStubContainer(),
            tokenizer: TokenizerHandle(PersistStubTokenizer())
        )
        await loop.persistLoadedModelSetForTesting()

        // The run() epilogue unloads with isShuttingDown = true — the whole
        // point of the file is remembering this set across the restart.
        await loop.beginShutdownForTesting()
        await loop.unloadModel("gemma-4-26b-it")

        #expect(LoadedModelsStore.read(from: url) == ["gemma-4-26b-it"])
    }
}
