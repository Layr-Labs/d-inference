import Foundation
import MLXLMCommon
import MLXNN
import Testing
@testable import ProviderCore

private final class PreflightEmptyModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult { .tokens(input.text) }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}
private struct PreflightEmptyProcessor: UserInputProcessor {
    struct Unused: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw Unused() }
}
private func preflightEmptyContainer() -> ModelContainer {
    .init(context: ModelContext(configuration: ModelConfiguration(id: "test/autopilot"),
        model: PreflightEmptyModel(), processor: PreflightEmptyProcessor(), tokenizer: StubBridgeTokenizer()))
}

private extension ProviderLoop {
    func preflightLoadedIDs() -> [String] { modelSlots.keys.sorted() }
    func markPreflightResidentOld(_ model: String) {
        autopilotResidentSince[model] = .now.advanced(by: .seconds(-3_600))
        modelSlots[model]?.lastInferenceAt = .now.advanced(by: .seconds(-3_600))
        publishModelAutopilotSnapshot()
    }
    func recordFailedSelfTestForTest(_ model: String, hash: String = "") {
        failedSelfTestHashes[model] = hash
    }
    func setInventoryWeightHashForTest(_ model: String, hash: String?) {
        autopilotInventoryModels[model]?.weightHash = hash
    }
    func removeInventoryModelForTest(_ model: String) {
        autopilotInventoryModels.removeValue(forKey: model)
    }
    /// Deterministic admission sample so the memory-feasibility gate passes
    /// regardless of the test host's real free memory.
    func setPlentyOfMemoryForTest() {
        engineV2SlotHooks = .init(availableMemoryGb: 100, makeEngine: { _, _ in
            throw NSError(domain: "unexpected-preflight-fixture-engine", code: 1)
        })
    }
    func preflightAdvertisedIDs() -> [String] { advertisedModels.keys.sorted() }
}

private final class PreflightRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ModelAutopilotStatus] = []
    func send(_ message: OutboundMessage) {
        if case .modelAutopilotStatus(let status) = message { lock.withLock { states.append(status) } }
    }
    var last: ModelAutopilotStatus? { lock.withLock { states.last } }
}

/// Creates a fake HF cache snapshot so the target resolves locally, removed on teardown.
private struct PreflightCachedModel {
    let id: String
    let dir: URL
    init() throws {
        id = "darkbloom-tests/preflight-\(UUID().uuidString)"
        dir = ModelScanner.cacheDirectory()
            .appendingPathComponent(ModelScanner.cacheDirectoryName(for: id), isDirectory: true)
        let snapshot = dir.appendingPathComponent("snapshots/abc123", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
    }
    func remove() { try? FileManager.default.removeItem(at: dir) }
}

@Suite("ModelAutopilot target preflight before victim unload", .serialized)
struct ModelAutopilotTargetPreflightTests {
    private let hash = String(repeating: "b", count: 64)

    private func info(_ id: String, hash: String?) -> ModelInfo {
        ModelInfo(id: id, modelType: "gemma4", sizeBytes: 1024, estimatedMemoryGb: 0.001, weightHash: hash)
    }

    private func fixture(target: String, healthy: String = "healthy") async throws -> (ProviderLoop, InertStubEngine) {
        let loop = try ProviderLoop(config: ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124, cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [info("old", hash: nil)],
            config: ProviderConfig(provider: ProviderSettings(name: "autopilot-preflight-test"),
                backend: BackendSettings(modelAutopilot: .init(enabled: true, pinnedModels: [], consentRecorded: true,
                    selectedModels: ["old", target, healthy], revision: "test"))),
            autopilotInventory: [info(target, hash: hash), info(healthy, hash: hash)]),
            attestationSigner: nil)
        await loop.activateAutopilotForTesting()
        await loop.setLoadedModelsPersistenceEnabledForTesting(false)
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        let engine = InertStubEngine(onShutdown: { @Sendable in })
        let bridge = EngineV2Bridge(engine: engine, modelId: "old",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        await runtime.register(modelId: "old", bridge: bridge)
        await loop.installModelSlotForTesting(modelId: "old", container: preflightEmptyContainer(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), engineV2: bridge)
        await loop.markPreflightResidentOld("old")
        await loop.setPlentyOfMemoryForTest()
        return (loop, engine)
    }

    private func runLoad(_ loop: ProviderLoop, target: String) async -> ModelAutopilotStatus? {
        let recorder = PreflightRecorder()
        await loop.handleModelAutopilot(.init(commandId: "preflight", loadModelId: target,
            unloadModelIds: ["old"], expectedResidentModels: ["old"],
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000,
            sessionId: "session", revision: "test"), send: SendHandle(recorder.send))
        let task = await loop.autopilotTask
        await task?.value
        return recorder.last
    }

    private func expectVictimSurvived(_ loop: ProviderLoop, _ engine: InertStubEngine,
                                      _ status: ModelAutopilotStatus?) async {
        #expect(status?.status == .failed)
        #expect(status?.error == "model_not_cached")
        #expect(engine.shutdownCalls == 0)
        #expect(await loop.preflightLoadedIDs() == ["old"])
        #expect(await loop.preflightAdvertisedIDs().contains("old"))
    }

    @Test func a1FailedSelfTestTargetRejectedBeforeVictimUnload() async throws {
        let cached = try PreflightCachedModel(); defer { cached.remove() }
        let (loop, engine) = try await fixture(target: cached.id)
        await loop.recordFailedSelfTestForTest(cached.id)
        await expectVictimSurvived(loop, engine, await runLoad(loop, target: cached.id))
    }

    @Test func a2EmptyWeightHashTargetRejectedBeforeVictimUnload() async throws {
        let cached = try PreflightCachedModel(); defer { cached.remove() }
        let (loop, engine) = try await fixture(target: cached.id)
        await loop.setInventoryWeightHashForTest(cached.id, hash: "")
        await expectVictimSurvived(loop, engine, await runLoad(loop, target: cached.id))
    }

    // Positive control: a healthy inventory target (hash, no failed self-test,
    // not retiring) must get past the early check. Its fake snapshot cannot
    // actually load, so the command still fails later, but not as
    // model_not_cached and not before the victim is released.
    @Test func healthyTargetPassesEarlyCheck() async throws {
        let cached = try PreflightCachedModel(); defer { cached.remove() }
        let (loop, engine) = try await fixture(target: cached.id)
        let status = await runLoad(loop, target: cached.id)
        #expect(status != nil)
        #expect(status?.error != "model_not_cached")
        #expect(engine.shutdownCalls == 1)
    }

    @Test func a3TargetMissingFromInventoryRejectedBeforeVictimUnload() async throws {
        // With the target absent from the inventory, autopilotRejection's
        // autopilotModelInfo check may already reject on current code.
        let cached = try PreflightCachedModel(); defer { cached.remove() }
        let (loop, engine) = try await fixture(target: cached.id)
        await loop.removeInventoryModelForTest(cached.id)
        await expectVictimSurvived(loop, engine, await runLoad(loop, target: cached.id))
    }
}
