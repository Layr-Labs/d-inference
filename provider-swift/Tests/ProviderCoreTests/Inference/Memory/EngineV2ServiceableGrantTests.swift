import Foundation
import MLX
import MLXLLM
import Testing
@testable import MLXLMCommon
@testable import ProviderCore

@Suite("Ordinary fixed-workspace grant serviceability", .serialized)
struct EngineV2ServiceableGrantTests {
    private let gib = 1 << 30

    init() { _ = LiveInferenceFixtures.ensureMetallibColocated() }

    @Test("the former 1 GiB floor cannot strand a real ordinary Qwen bridge")
    func resliceRefusesFormerMinimum() async throws {
        let fixture = try ServiceableGrantFixture()
        #expect(fixture.engine.nativeShutdownExecutionContractID == nil)
        #expect(fixture.engine.resolvedFixedBytesPerRequest > 0)
        let floor = await fixture.bridge.minimumServiceableGrantBytes()
        let oldGrant = gib + 1
        #expect(floor > oldGrant)
        #expect(!EngineV2KVSizing.resliceMeetsServiceabilityFloor(
            [fixture.modelID: oldGrant], minimumGrantBytes: [fixture.modelID: floor]))
        #expect(await fixture.bridge.effectiveServingConcurrency(allowExpansion: true) > 0)
        await fixture.bridge.shutdown()
    }

    @Test("an accepted minimum grant retains one fixed workspace and 1 GiB usable KV")
    func acceptedFloorRetainsServingCapacity() async throws {
        let fixture = try ServiceableGrantFixture()
        let floor = await fixture.bridge.minimumServiceableGrantBytes()
        #expect(floor < 2 * gib)
        #expect(EngineV2KVSizing.resliceMeetsServiceabilityFloor(
            [fixture.modelID: floor], minimumGrantBytes: [fixture.modelID: floor]))
        await fixture.bridge.updateKVBytesCapacity(floor)
        #expect(await fixture.bridge.effectiveServingConcurrency(allowExpansion: true) >= 1)
        #expect(fixture.engine.admissibleKVBytesCapacity
            >= gib + fixture.engine.resolvedFixedBytesPerRequest)
        let heartbeat = await fixture.bridge.backendSlotCapacity()
        #expect(heartbeat.maxConcurrency >= 1)
        #expect(heartbeat.activeTokenBudgetMax > 0)
        await fixture.bridge.shutdown()
    }

    @Test("the prefix carve belongs to the total grant exactly once, including rollback")
    func prefixCarveAndRollbackStayConsistent() async throws {
        let bank = 256 << 20
        let plain = try ServiceableGrantFixture()
        let cached = try ServiceableGrantFixture(bankBytes: bank)
        let plainFloor = await plain.bridge.minimumServiceableGrantBytes()
        let cachedFloor = await cached.bridge.minimumServiceableGrantBytes()
        let original = await cached.bridge.resliceAdmissionBytesClaim()
        #expect(original == 4 * gib)
        #expect(await cached.bridge.slotKVBytesClaim() == original)
        #expect(cached.engine.hybridPrefixCache?.config.maximumBytes == bank)
        #expect(cached.engine.capacity().kvBytesCapacity == 4 * gib - bank)
        #expect(cachedFloor == plainFloor + bank)

        await cached.bridge.updateKVBytesCapacity(cachedFloor)
        #expect(cached.engine.capacity().kvBytesCapacity == cachedFloor - bank)
        #expect(await cached.bridge.resliceAdmissionBytesClaim() == cachedFloor)
        #expect(await cached.bridge.slotKVBytesClaim() == cachedFloor)
        #expect(await cached.bridge.effectiveServingConcurrency(allowExpansion: true) >= 1)
        await cached.bridge.updateKVBytesCapacity(original)
        #expect(cached.engine.capacity().kvBytesCapacity == 4 * gib - bank)
        #expect(await cached.bridge.resliceAdmissionBytesClaim() == original)
        #expect(cached.engine.hybridPrefixCache?.stats.entries == 0)
        await plain.bridge.shutdown()
        await cached.bridge.shutdown()
    }

    @Test("unknown or overflowing floors cannot be satisfied by Int.max")
    func unattainableFloorFailsClosed() {
        #expect(!EngineV2KVSizing.resliceMeetsServiceabilityFloor(
            ["unattainable": Int.max], minimumGrantBytes: ["unattainable": Int.max]))
        #expect(!EngineV2KVSizing.resliceMeetsServiceabilityFloor(["zero": 0]))
        #expect(!EngineV2KVSizing.resliceMeetsServiceabilityFloor(["negative": -1]))
    }

    @Test("stateless bridges retain the existing one-GiB floor")
    func statelessFloorIsUnchanged() async {
        let model = DeadlineAdmissionFixtureModel()
        let engine = EngineV2(model: model, layerKinds: model.kinds,
            backend: CBv2ContiguousKVBackend(config: .init(bytesCapacity: 4 * gib)),
            cacheProvider: CBv2LayerCacheBank(layerKinds: model.kinds))
        let bridge = EngineV2Bridge(engine: engine, modelId: "stateless-floor",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        #expect(await bridge.minimumServiceableGrantBytes() == gib)
        await bridge.updateKVBytesCapacity(0)
        #expect(await bridge.minimumServiceableGrantBytes() == gib)
        await bridge.shutdown()
    }

    @Test("shared slot assembly refuses an ordinary newcomer before it can publish zero capacity")
    func newcomerMustBeServiceableBeforePublication() async throws {
        var wronglyPublished: ProviderEngineBundle?
        do {
            wronglyPublished = try await ServiceableGrantFixture.bundle(grant: gib + 1)
        } catch {
            #expect(error is EngineV2ProductionError)
        }
        #expect(wronglyPublished == nil)
        if let wronglyPublished { await wronglyPublished.bridge.shutdown() }

        let serviceable = try await ServiceableGrantFixture.bundle(grant: 2 * gib)
        #expect(await serviceable.bridge.effectiveServingConcurrency(allowExpansion: true) >= 1)
        #expect(await serviceable.bridge.backendSlotCapacity().activeTokenBudgetMax > 0)
        await serviceable.bridge.shutdown()
    }
}

@Suite("Fixed-workspace load and reserve-raise preflight", .serialized)
struct EngineV2ServiceableLoadTests {
    private let gib: UInt64 = 1 << 30
    private let physical: UInt64 = 32 << 30

    init() { _ = LiveInferenceFixtures.ensureMetallibColocated() }

    @Test("provider and standalone reserve raises preserve an ordinary resident grant")
    func reserveRaisesCannotStrandOrdinaryResident() async throws {
        let providerFixture = try ServiceableGrantFixture()
        let loop = try makeLoop()
        await loop.setEngineV2SlotHooksForTesting(.init(
            physicalMemoryBytes: physical,
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        await loop.installModelSlotForTesting(modelId: providerFixture.modelID,
            container: providerFixture.container(), tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            engineV2: providerFixture.bridge, sizing: ServiceableGrantFixture.sizing(), modelType: "qwen3_5")
        let noReserve = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physical, residentWeightBytes: 0,
            activationReserveBytes: 0, configReserveBytes: 0)
        let raisedReserve = noReserve - (gib + 1)
        #expect(raisedReserve > UnifiedMemoryCap.defaultActivationReserveBytes)
        await loop.acquireResliceGate()
        let providerAllowed = await loop.reserveRaiseKeepsSurvivorsServiceable(reserveBytes: raisedReserve)
        await loop.releaseResliceGate()
        #expect(!providerAllowed)
        #expect(await providerFixture.bridge.engineKVBytesCapacity() == 4 * Int(gib))
        #expect(await providerFixture.bridge.effectiveServingConcurrency(allowExpansion: true) >= 1)
        await providerFixture.bridge.shutdown()
        await loop.removeModelSlotForTesting(modelId: providerFixture.modelID)

        let localFixture = try ServiceableGrantFixture()
        let server = StandaloneServer()
        await server.setV2TestHooksForTesting(.init(
            physicalMemoryBytes: physical,
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        await server.installSlotForTesting(modelId: localFixture.modelID,
            bridge: localFixture.bridge, container: localFixture.container(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), sizing: ServiceableGrantFixture.sizing())
        #expect(await !server.reserveKeepsSurvivorsServiceable(reserveBytes: raisedReserve))
        #expect(await localFixture.bridge.engineKVBytesCapacity() == 4 * Int(gib))
        #expect(await localFixture.bridge.effectiveServingConcurrency(allowExpansion: true) >= 1)
        await localFixture.bridge.shutdown()
    }

    @Test("provider refuses a newcomer before shrinking an ordinary survivor below its workspace floor")
    func providerLoadRefusesBeforeGrantMutation() async throws {
        let fixture = try ServiceableGrantFixture()
        let loop = try makeLoop()
        let runtime = EngineV2Runtime()
        let builds = ServiceabilityBuildProbe()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(.init(
            physicalMemoryBytes: physical,
            makeEngine: { _, grant in builds.record(); return InertStubEngine(kvBytesCapacity: grant) }))
        await loop.installModelSlotForTesting(modelId: fixture.modelID,
            container: fixture.container(), tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            engineV2: fixture.bridge, sizing: ServiceableGrantFixture.sizing(), modelType: "qwen3_5")
        let box = EngineV2NewcomerBox(try ServiceableGrantFixture.container(modelID: "newcomer"))
        let weights = newcomerWeights()
        var built: EngineV2Bridge?
        await loop.acquireResliceGate()
        do {
            built = try await loop.resliceAndBuildEngineV2SlotForTesting(
                modelId: "newcomer", modelType: "qwen3_5", newcomer: box,
                tokenizer: TokenizerHandle(StubBridgeTokenizer()),
                sizing: ServiceableGrantFixture.sizing(weights: weights))
        } catch {
            #expect(error is InferenceError)
        }
        await loop.releaseResliceGate()
        #expect(built == nil)
        #expect(builds.count == 0)
        #expect(box.container == nil)
        #expect(await runtime.bridge(forModel: "newcomer") == nil)
        #expect(await fixture.bridge.engineKVBytesCapacity() == 4 * Int(gib))
        #expect(await fixture.bridge.effectiveServingConcurrency(allowExpansion: true) >= 1)
        if let built { await built.shutdown() }
        await runtime.unregister(modelId: "newcomer")
        await box.releaseAfterExternalResources()
        await fixture.bridge.shutdown()
        await loop.removeModelSlotForTesting(modelId: fixture.modelID)
    }

    @Test("standalone refuses the same invalid reslice without touching the resident grant")
    func standaloneLoadRefusesBeforeGrantMutation() async throws {
        let fixture = try ServiceableGrantFixture()
        let server = StandaloneServer()
        let builds = ServiceabilityBuildProbe()
        await server.setV2TestHooksForTesting(.init(
            physicalMemoryBytes: physical,
            makeEngine: { _, grant in builds.record(); return InertStubEngine(kvBytesCapacity: grant) }))
        await server.installSlotForTesting(modelId: fixture.modelID,
            bridge: fixture.bridge, container: fixture.container(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), sizing: ServiceableGrantFixture.sizing())
        let box = EngineV2NewcomerBox(try ServiceableGrantFixture.container(modelID: "newcomer"))
        var built: EngineV2Bridge?
        do {
            built = try await server.resliceAndBuildSlotForTesting(
                modelId: "newcomer", modelType: "qwen3_5", newcomer: box,
                tokenizer: TokenizerHandle(StubBridgeTokenizer()),
                sizing: ServiceableGrantFixture.sizing(weights: newcomerWeights()))
        } catch {
            #expect(error is StandaloneServerError)
        }
        #expect(built == nil)
        #expect(builds.count == 0)
        #expect(box.container == nil)
        #expect(await fixture.bridge.engineKVBytesCapacity() == 4 * Int(gib))
        #expect(await fixture.bridge.effectiveServingConcurrency(allowExpansion: true) >= 1)
        if let built { await built.shutdown() }
        await box.releaseAfterExternalResources()
        await fixture.bridge.shutdown()
    }

    private func newcomerWeights() -> Int {
        // Only the residency quotation is large; both models have tiny tensors.
        // Equal rates/contexts produce two grants of exactly 1 GiB + 1 byte.
        let budget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physical, residentWeightBytes: 0,
            activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes,
            configReserveBytes: 0)
        return Int(budget - 2 * (gib + 1))
    }

    private func makeLoop() throws -> ProviderLoop {
        try ProviderLoop(config: .init(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: .init(machineModel: "Mac16,5", chipName: "Apple M4 Max",
                chipFamily: .m4, chipTier: .max, memoryGb: 32, memoryAvailableGb: 30,
                cpuCores: .init(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [], config: .init(
                provider: .init(name: "serviceability-test", memoryReserveGB: 0),
                backend: .init(idleTimeoutMins: 0, maxModelSlots: 2),
                coordinator: .init(heartbeatIntervalSecs: 60))), attestationSigner: nil)
    }
}

private struct ServiceableGrantFixture {
    let modelID = "ordinary-serviceability"
    let model: Qwen35Model
    let engine: EngineV2
    let bridge: EngineV2Bridge

    init(grant: Int = 4 << 30, bankBytes: Int = 0) throws {
        model = try Self.makeModel()
        let cache = bankBytes > 0 ? CBv2HybridPrefixCacheConfig(
            maximumBytes: bankBytes, modelID: modelID,
            promptContractID: "fixture-contract", buildID: "fixture-build") : nil
        let build = try EngineV2Factory.makeProductionBuild(
            model: model, modelID: modelID, tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: grant, maxConcurrentRequests: 2,
            hybridPrefixCache: cache, mtpConfig: .init(enabled: false),
            kvBackend: .contiguous, maxContextLength: 2_048,
            environment: [KVBackendGuardStore.pathEnvKey: "/dev/null"])
        engine = try #require(build.engine as? EngineV2)
        bridge = try EngineV2Factory.makeBridge(modelId: modelID,
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [],
            maxConcurrentRequests: 2, kvBytesPerToken: 256,
            emitTelemetry: { _ in }, makeEngine: { build })
    }

    func container() -> ModelContainer {
        ModelContainer(context: .init(configuration: .init(id: modelID),
            model: model, processor: ServiceabilityProcessor(), tokenizer: StubBridgeTokenizer()))
    }

    static func container(modelID: String) throws -> ModelContainer {
        ModelContainer(context: .init(configuration: .init(id: modelID),
            model: try makeModel(), processor: ServiceabilityProcessor(), tokenizer: StubBridgeTokenizer()))
    }

    static func sizing(weights: Int = 0) -> SlotSizingSnapshot {
        .init(weightsBytes: weights, fp16KVBytesPerToken: 256,
            maxContextLength: 2_048, defaultMaxTokens: 1)
    }

    static func bundle(grant: Int) async throws -> ProviderEngineBundle {
        let model = try makeModel()
        let container = ModelContainer(context: .init(configuration: .init(id: "newcomer"),
            model: model, processor: ServiceabilityProcessor(), tokenizer: StubBridgeTokenizer()))
        return try await EngineV2SlotFactory.makeProductionBundle(
            modelId: "newcomer", modelType: "qwen3_5", isVLM: false,
            modelDirectory: nil, container: container,
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), sizing: sizing(),
            kvBytesCapacity: grant, maxConcurrentRequests: 2, kvBudget: nil,
            kvBackendConfig: "contiguous", weightHash: nil,
            specDecPreparation: .init(artifact: nil, status: .disabled(.configDisabled, configured: false)),
            preparedModel: .init(snapshot: .init(model: model, eosTokenIds: [], extraEOSTokens: []),
                servingModel: model, assistant: nil,
                mtpStatus: .disabled(.configDisabled, configured: false), mtpArtifact: nil),
            environment: ["DARKBLOOM_PREFIX_CACHE": "0", KVBackendGuardStore.pathEnvKey: "/dev/null"],
            startServingTelemetry: false, emitTelemetry: { _ in })
    }

    private static func makeModel() throws -> Qwen35Model {
        let json = """
        {"model_type":"qwen3_5","hidden_size":64,"num_hidden_layers":2,
         "intermediate_size":128,"num_attention_heads":1,"num_key_value_heads":1,
         "head_dim":64,"linear_num_value_heads":1,"linear_num_key_heads":1,
         "linear_key_head_dim":64,"linear_value_head_dim":64,"linear_conv_kernel_dim":4,
         "vocab_size":64,"full_attention_interval":2,"num_experts":0,"num_experts_per_tok":0,
         "mtp_num_hidden_layers":0}
        """
        return Qwen35Model(try EngineV2VLMTextExtraction.decodeQwenConfiguration(configData: Data(json.utf8)))
    }
}

private struct ServiceabilityProcessor: UserInputProcessor {
    struct NotUsed: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw NotUsed() }
}

private final class ServiceabilityBuildProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
