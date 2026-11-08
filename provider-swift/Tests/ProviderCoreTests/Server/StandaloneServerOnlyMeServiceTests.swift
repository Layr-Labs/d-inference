import Foundation
import Hummingbird
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

/// An empty model: no weights, no inference (the eviction tests' fixture).
private final class IdleStubModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters) throws
        -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct IdleUnusedProcessor: UserInputProcessor {
    private struct NotUsed: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw NotUsed() }
}

/// Installs `modelId` on `server` as a resident slot over an inert engine.
private func installIdleSlot(_ server: StandaloneServer, modelId: String) async -> InertStubEngine {
    let engine = InertStubEngine(kvBytesCapacity: 3)
    let container = ModelContainer(context: ModelContext(
        configuration: ModelConfiguration(id: modelId), model: IdleStubModel(), processor: IdleUnusedProcessor(),
        tokenizer: StubBridgeTokenizer()))
    await server.installSlotForTesting(
        modelId: modelId,
        bridge: EngineV2Bridge(engine: engine, modelId: modelId, tokenizer: TokenizerHandle(StubBridgeTokenizer()),
                               eosTokenIds: []),
        container: container, tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        sizing: SlotSizingSnapshot(weightsBytes: 1 << 20, fp16KVBytesPerToken: 1024, maxContextLength: 128,
                                   defaultMaxTokens: 8),
        modelType: "gpt_oss")
    return engine
}

/// Only me's background service on the standalone server: models idle past the memory setting are unloaded, and an
/// update closes admission only while it waits for the owner's requests, then reopens it. No weights, no GPU work.
@Suite("Only me's background service: idle unload and the update drain", .serialized)
struct StandaloneServerOnlyMeServiceTests {
    @Test("a model unused past the memory setting is unloaded; one used since, reserved or under a load is not")
    func idleUnload() async {
        let server = StandaloneServer(config: .init(port: 0))
        await server.setV2TestHooksForTesting(.init(clearMemoryCache: {},
                                                    makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        let engine = await installIdleSlot(server, modelId: "gpt-oss-20b")
        // Used within the last hour: kept.
        #expect(await server.unloadIdleModels(idleFor: .seconds(3_600)) == 0)
        // Reserved by a request: kept, however long ago it was used.
        await server.reserveSlot("gpt-oss-20b")
        #expect(await server.unloadIdleModels(idleFor: .seconds(60), now: .now + .seconds(7_200)) == 0)
        await server.releaseSlot("gpt-oss-20b")
        // Unused for longer than the setting: unloaded.
        #expect(await server.unloadIdleModels(idleFor: .seconds(60), now: .now + .seconds(7_200)) == 1)
        #expect(engine.shutdownCalls == 1)
        #expect(await server.loadedModelIds().isEmpty)
        await server.setV2TestHooksForTesting(nil)
    }

    @Test("idle unload is off for 0 minutes (always ready), and starts once")
    func idleUnloadOff() async {
        let server = StandaloneServer(config: .init(port: 0))
        await server.startIdleUnload(minutes: 0)
        #expect(await server.idleUnloadTask == nil)
        await server.startIdleUnload(minutes: 60, every: .seconds(3_600))
        let first = await server.idleUnloadTask
        await server.startIdleUnload(minutes: 60, every: .seconds(3_600))
        #expect(first != nil)
        await server.stop()
        #expect(await server.idleUnloadTask == nil)
    }

    @Test("an update closes admission while it waits for the owner's requests, and reopens it when it doesn't restart")
    func updateDrainReopens() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        await server.reserveSlot("held-model")
        await server.beginUpdateDrain()
        #expect(throws: HTTPError.self) { try server.responseTracker.admit().release() }
        #expect(await !server.waitForUpdateDrain(.milliseconds(200)), "a request still runs")
        await server.releaseSlot("held-model")
        #expect(await server.waitForUpdateDrain(.seconds(5)))
        await server.resumeAfterUpdate()
        let lease = try server.responseTracker.admit()
        lease.release()
        #expect(await !server.lifecycleDraining)
    }

    @Test("the update cycle is off with auto_update = false or DARKBLOOM_NO_UPDATE_CHECK, and starts once")
    func updateMonitorSwitches() async {
        let server = StandaloneServer(config: .init(port: 0))
        await server.startAutoUpdateMonitor(coordinatorURL: "wss://coordinator.invalid/ws/provider", enabled: false,
                                            environment: [:])
        #expect(await server.autoUpdateTask == nil)
        await server.startAutoUpdateMonitor(coordinatorURL: "wss://coordinator.invalid/ws/provider", enabled: true,
                                            environment: ["DARKBLOOM_NO_UPDATE_CHECK": "1"])
        #expect(await server.autoUpdateTask == nil)
        await server.startAutoUpdateMonitor(coordinatorURL: "wss://coordinator.invalid/ws/provider", enabled: true,
                                            environment: [:])
        #expect(await server.autoUpdateTask != nil)
        await server.stop()
        #expect(await server.autoUpdateTask == nil)
    }
}
