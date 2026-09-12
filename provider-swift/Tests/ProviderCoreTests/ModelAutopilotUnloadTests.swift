import Foundation
import MLXLMCommon
import MLXNN
import Testing
@testable import ProviderCore

private final class AutopilotEmptyModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult { .tokens(input.text) }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}
private struct AutopilotEmptyProcessor: UserInputProcessor {
    struct Unused: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw Unused() }
}
private func autopilotEmptyContainer() -> ModelContainer {
    .init(context: ModelContext(configuration: ModelConfiguration(id: "test/autopilot"),
        model: AutopilotEmptyModel(), processor: AutopilotEmptyProcessor(), tokenizer: StubBridgeTokenizer()))
}
private extension ProviderLoop {
    func markAutopilotResidentOld(_ model: String, local: Bool = false, superseded: Bool = false) {
        autopilotResidentSince[model] = .now.advanced(by: .seconds(-3_600))
        modelSlots[model]?.lastInferenceAt = .now.advanced(by: .seconds(-3_600))
        if local { localReservations.reserve(model) }
        if superseded { autopilotSupersededModels.insert(model); advertisedModels.removeValue(forKey: model) }
        publishModelAutopilotSnapshot()
    }
    func autopilotLoadedIDs() -> [String] { modelSlots.keys.sorted() }
    func unadvertiseWithoutReleaseForTest(_ model: String) { advertisedModels.removeValue(forKey: model) }
}
private final class AutopilotUnloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ModelAutopilotStatus] = []
    func send(_ message: OutboundMessage) {
        if case .modelAutopilotStatus(let status) = message { lock.withLock { states.append(status) } }
    }
    var last: ModelAutopilotStatus? { lock.withLock { states.last } }
}

@Suite("ModelAutopilot actual unload lifecycle", .serialized)
struct ModelAutopilotUnloadTests {
    private func fixture(pins: [String] = []) async throws -> (ProviderLoop, [String: InertStubEngine]) {
        let ids = ["old", "keep", "local"]
        let loop = try ProviderLoop(config: ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124, cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: ids.map { ModelInfo(id: $0, modelType: "gemma4", sizeBytes: 1024, estimatedMemoryGb: 0.001) },
            config: ProviderConfig(provider: ProviderSettings(name: "autopilot-unload-test"),
                backend: BackendSettings(modelAutopilot: .init(enabled: true, pinnedModels: pins)))),
            purgeLegacyFiles: false, attestationSigner: nil)
        await loop.setLoadedModelsPersistenceEnabledForTesting(false)
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        var engines: [String: InertStubEngine] = [:]
        for model in ids {
            let (bridge, engine) = makeInertStubBridge(modelId: model)
            engines[model] = engine
            await runtime.register(modelId: model, bridge: bridge)
            await loop.installModelSlotForTesting(modelId: model, container: autopilotEmptyContainer(),
                tokenizer: TokenizerHandle(StubBridgeTokenizer()), engineV2: bridge)
            await loop.markAutopilotResidentOld(model)
        }
        return (loop, engines)
    }

    @Test func explicitUnloadTouchesOnlyDeclaredVictim() async throws {
        let (loop, engines) = try await fixture()
        let recorder = AutopilotUnloadRecorder()
        await loop.handleModelAutopilot(.init(commandId: "unload", unloadModelIds: ["old"],
            expectedResidentModels: ["old", "keep", "local"],
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000), send: SendHandle(recorder.send))
        let task = await loop.autopilotTask
        await task?.value
        #expect(recorder.last?.status == .succeeded)
        #expect(engines["old"]?.shutdownCalls == 1)
        #expect(engines["keep"]?.shutdownCalls == 0)
        #expect(engines["local"]?.shutdownCalls == 0)
        #expect(await loop.autopilotLoadedIDs() == ["keep", "local"])
    }

    @Test func releaseCleanupPreservesArbitraryUnadvertisedAndSupportedResidents() async throws {
        let (loop, engines) = try await fixture()
        await loop.markAutopilotResidentOld("old", superseded: true)
        await loop.unadvertiseWithoutReleaseForTest("keep")
        await loop.cleanupAutopilotSupersededModels()
        #expect(engines["old"]?.shutdownCalls == 1)
        #expect(engines["keep"]?.shutdownCalls == 0)
        #expect(engines["local"]?.shutdownCalls == 0)
        #expect(await loop.autopilotLoadedIDs() == ["keep", "local"])
    }

    @Test func releaseCleanupOnlyRetiresExplicitInactiveUnpinnedBuilds() async throws {
        let (loop, engines) = try await fixture(pins: ["keep"])
        await loop.markAutopilotResidentOld("old", superseded: true)
        await loop.markAutopilotResidentOld("keep", superseded: true)
        await loop.markAutopilotResidentOld("local", local: true, superseded: true)
        await loop.cleanupAutopilotSupersededModels()
        #expect(engines["old"]?.shutdownCalls == 1)
        #expect(engines["keep"]?.shutdownCalls == 0)
        #expect(engines["local"]?.shutdownCalls == 0)
        #expect(await loop.autopilotLoadedIDs() == ["keep", "local"])
        await loop.releaseLocalReservation("local")
        await loop.cleanupAutopilotSupersededModels()
        #expect(engines["local"]?.shutdownCalls == 1)
        #expect(engines["keep"]?.shutdownCalls == 0)
    }
}
