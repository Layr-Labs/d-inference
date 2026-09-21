import Foundation
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

private final class EvictionWeakContainer: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: AnyObject?

    init(_ value: AnyObject) { self.value = value }
    var isAlive: Bool { lock.withLock { value != nil } }
}

private final class EvictionObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var releasedAfterDrain: [Bool] = []
    private var aliveAtPurge: [Bool] = []

    func recordRelease(drained: Bool) { lock.withLock { releasedAfterDrain.append(drained) } }
    func recordPurge(alive: Bool) { lock.withLock { aliveAtPurge.append(alive) } }
    var releases: [Bool] { lock.withLock { releasedAfterDrain } }
    var purges: [Bool] { lock.withLock { aliveAtPurge } }
}

/// Empty model with the same external-resource release seam as Qwen4.
/// The fixture allocates no weights and performs no inference.
private final class EvictionStubModel: Module, LanguageModel, Qwen4ExpExternalPLEReleasing {
    private let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
    func releaseExternalPLEResources() { onRelease() }
}

private struct EvictionUnusedProcessor: UserInputProcessor {
    private struct NotUsed: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw NotUsed() }
}

/// Ownership ends when this helper returns; tests keep only a weak observer.
private func installEvictionFixture(
    server: StandaloneServer,
    bridge: EngineV2Bridge,
    onRelease: @escaping @Sendable () -> Void = {}
) async -> EvictionWeakContainer {
    let container = ModelContainer(context: ModelContext(
        configuration: ModelConfiguration(id: "test/eviction-empty-model"),
        model: EvictionStubModel(onRelease: onRelease),
        processor: EvictionUnusedProcessor(),
        tokenizer: StubBridgeTokenizer()))
    let observer = EvictionWeakContainer(container)
    await server.installSlotForTesting(
        modelId: "gpt-oss-20b", bridge: bridge, container: container,
        tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        sizing: SlotSizingSnapshot(
            weightsBytes: 1 << 20, fp16KVBytesPerToken: 1024,
            maxContextLength: 128, defaultMaxTokens: 8),
        modelType: "gpt_oss")
    return observer
}

private func evictionBridge(_ engine: any CBv2Engine) -> EngineV2Bridge {
    EngineV2Bridge(
        engine: engine, modelId: "gpt-oss-20b",
        tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
}

private actor EvictionDrainGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class EvictionGatedEngine: CBv2Engine, @unchecked Sendable {
    private let gate: EvictionDrainGate
    private let base = InertStubEngine(kvBytesCapacity: 3)

    init(gate: EvictionDrainGate) { self.gate = gate }
    var shutdownCalls: Int { base.shutdownCalls }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> { try base.submit(request) }
    func cancel(_ id: CBv2RequestID) { base.cancel(id) }
    func capacity() -> CBv2CapacitySnapshot { base.capacity() }
    func shutdown() async {
        await gate.enterAndWait()
        await base.shutdown()
    }
}

@Suite("Standalone eviction container ownership")
struct StandaloneEvictionOwnershipTests {
    @Test func externalReleaseFollowsDrainAndContainerDiesBeforePurge() async {
        // Regression inherited from the 7c394fa base: full CachedSlot copies
        // in the LRU snapshot/local kept weights alive across purge/regrow.
        let server = StandaloneServer()
        let engine = InertStubEngine()
        let observations = EvictionObservations()
        let observer = await installEvictionFixture(
            server: server, bridge: evictionBridge(engine),
            onRelease: { observations.recordRelease(drained: engine.shutdownCalls == 1) })
        #expect(observer.isAlive)
        await server.setV2TestHooksForTesting(.init(
            clearMemoryCache: { observations.recordPurge(alive: observer.isAlive) },
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))

        #expect(await server.evictLRUIdleSlotForTesting())
        #expect(engine.shutdownCalls == 1)
        #expect(observations.releases == [true])
        #expect(observations.purges == [false])
        #expect(!observer.isAlive)
        #expect(await server.loadedModelIds().isEmpty)
    }

    @Test func reservationAfterActivityProbePreventsEviction() async {
        let server = StandaloneServer()
        let engine = InertStubEngine(kvBytesCapacity: 7)
        _ = await installEvictionFixture(server: server, bridge: evictionBridge(engine))
        let observations = EvictionObservations()
        await server.setV2TestHooksForTesting(.init(
            clearMemoryCache: { observations.recordPurge(alive: false) },
            afterEvictionActivityProbe: { modelId in await server.reserveSlot(modelId) },
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))

        #expect(!(await server.evictLRUIdleSlotForTesting()))
        #expect(engine.shutdownCalls == 0)
        #expect(await server.debugSlotReservationCount(modelId: "gpt-oss-20b") == 1)
        #expect(await server.debugEngineKVGrant(modelId: "gpt-oss-20b") == 7)
        #expect(observations.purges.isEmpty)
        await server.releaseSlot("gpt-oss-20b")
        await server.setV2TestHooksForTesting(nil)
    }

    @Test func replacementAfterActivityProbeIsNotSelectedFromStaleSnapshot() async {
        let server = StandaloneServer()
        let oldEngine = InertStubEngine(kvBytesCapacity: 3)
        let replacementEngine = InertStubEngine(kvBytesCapacity: 17)
        let replacementBridge = evictionBridge(replacementEngine)
        _ = await installEvictionFixture(server: server, bridge: evictionBridge(oldEngine))
        let observations = EvictionObservations()
        await server.setV2TestHooksForTesting(.init(
            clearMemoryCache: { observations.recordPurge(alive: false) },
            afterEvictionActivityProbe: { _ in
                _ = await installEvictionFixture(server: server, bridge: replacementBridge)
            },
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))

        #expect(!(await server.evictLRUIdleSlotForTesting()))
        #expect(oldEngine.shutdownCalls == 0)
        #expect(replacementEngine.shutdownCalls == 0)
        #expect(await server.debugEngineKVGrant(modelId: "gpt-oss-20b") == 17)
        #expect(observations.purges.isEmpty)
        await server.setV2TestHooksForTesting(nil)
    }

    @Test func replacementDuringDrainIsNeitherClosedNorRemoved() async {
        let server = StandaloneServer()
        let gate = EvictionDrainGate()
        let oldEngine = EvictionGatedEngine(gate: gate)
        _ = await installEvictionFixture(server: server, bridge: evictionBridge(oldEngine))
        let observations = EvictionObservations()
        await server.setV2TestHooksForTesting(.init(
            clearMemoryCache: { observations.recordPurge(alive: false) },
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))

        let eviction = Task { await server.evictLRUIdleSlotForTesting() }
        await gate.waitUntilEntered()
        let replacementEngine = InertStubEngine(kvBytesCapacity: 17)
        _ = await installEvictionFixture(
            server: server, bridge: evictionBridge(replacementEngine),
            onRelease: { observations.recordRelease(drained: false) })
        await gate.release()
        #expect(!(await eviction.value))
        #expect(oldEngine.shutdownCalls == 1)
        #expect(replacementEngine.shutdownCalls == 0)
        #expect(observations.releases.isEmpty)
        #expect(observations.purges.isEmpty)
        #expect(await server.debugEngineKVGrant(modelId: "gpt-oss-20b") == 17)
    }
}
