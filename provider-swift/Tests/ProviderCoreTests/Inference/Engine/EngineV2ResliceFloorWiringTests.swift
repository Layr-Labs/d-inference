// Copyright © 2026 Eigen Labs.
//
// Re-slice orchestration against slots whose floors include real fixed
// request workspace (`ResliceFloorScenario`). Residents are real EngineV2
// instances over a contiguous backend, so `minimumServiceableGrantBytes`
// and serving width come from production code; the newcomer is built by
// the scripted hook engine. No weights, requests or GPU work.

import Foundation
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

private final class FloorStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters) throws
        -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct FloorStubProcessor: UserInputProcessor {
    struct Unsupported: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw Unsupported() }
}

private func makeFloorContainer() -> ModelContainer {
    ModelContainer(context: ModelContext(
        configuration: ModelConfiguration(id: "test/reslice-floor"),
        model: FloorStubLanguageModel(), processor: FloorStubProcessor(),
        tokenizer: StubBridgeTokenizer()))
}

/// The production default `memory_reserve_gb`; it does not bind on 150+ GB.
private let floorConfigReserveBytes: UInt64 = 4 << 30

private func makeFloorLoop(physicalBytes: UInt64) throws -> ProviderLoop {
    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/ignored",
        hardware: HardwareInfo(
            machineModel: "Mac14,14", chipName: "Apple M2 Ultra", chipFamily: .m2, chipTier: .ultra,
            memoryGb: physicalBytes >> 30, memoryAvailableGb: (physicalBytes >> 30) - 8,
            cpuCores: CpuCores(total: 24, performance: 16, efficiency: 8),
            gpuCores: 76, memoryBandwidthGbs: 800),
        models: [],
        config: ProviderConfig(
            provider: ProviderSettings(name: "reslice-floor-test", memoryReserveGB: 4),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 8),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
    return try ProviderLoop(config: config, attestationSigner: nil,
        kvBudgetForTesting: ScriptedProviderMemory.budget(
            physicalBytes: physicalBytes, configReserveBytes: floorConfigReserveBytes))
}

/// Each newcomer's GLM rows reference, as the re-slice passed it to the engine build.
private final class RowsReferenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var references: [String: Int?] = [:]
    func record(_ modelID: String, _ reference: Int?) { lock.withLock { references[modelID] = .some(reference) } }
    func built(_ modelID: String) -> Bool { lock.withLock { references[modelID] != nil } }
    func reference(_ modelID: String) -> Int? { lock.withLock { references[modelID] ?? nil } }
}

private let rowsReferenceGLMSizing = SlotSizingSnapshot(weightsBytes: 20 << 30, fp16KVBytesPerToken: 1024,
    maxContextLength: 4096, defaultMaxTokens: 8)
private let rowsReferenceGemmaSizing = SlotSizingSnapshot(weightsBytes: 2 << 30, fp16KVBytesPerToken: 1024,
    maxContextLength: 4096, defaultMaxTokens: 8)

/// Loads GLM (beside Gemma when `besideGemma`) three times on a 64 GiB machine: with no GPU limit read, with a
/// 40 GiB limit, and with that limit and `DARKBLOOM_GLM_GPU_LIMIT_KV=0`. `load` builds the set with the given
/// limit and returns GLM's grant. The reference must be the grant the same set gets without the hold, in all
/// three; the limit must lower the grant only while the switch is on.
private func expectUnheldRowsReference(
    besideGemma: Bool,
    load: (GLM5NextGPULimitKVBudget.GPULimit?, RowsReferenceRecorder) async throws -> Int
) async throws {
    func run(_ limit: GLM5NextGPULimitKVBudget.GPULimit?, switchOff: Bool = false) async throws
        -> (grant: Int, references: RowsReferenceRecorder) {
        let references = RowsReferenceRecorder()
        let environment = switchOff ? [GLM5NextGPULimitKVBudget.environmentName: "0"] : [:]
        let grant = try await GLM5NextGPULimitKVBudget.$environmentForTesting.withValue(environment) {
            try await load(limit, references)
        }
        return (grant, references)
    }
    let limit = GLM5NextGPULimitKVBudget.GPULimit(limitBytes: 40 << 30)
    let unheld = try await run(nil)
    let held = try await run(limit)
    let off = try await run(limit, switchOff: true)
    #expect(unheld.references.reference("glm") == unheld.grant)
    #expect(held.grant < unheld.grant)
    #expect(held.references.reference("glm") == unheld.grant)
    #expect(off.grant == unheld.grant)
    #expect(off.references.reference("glm") == unheld.grant)
    if besideGemma {
        for result in [unheld, held, off] {
            #expect(result.references.built("gemma"))
            #expect(result.references.reference("gemma") == nil, "another family gets no rows reference")
        }
    }
}

/// Fleet KV budget for `models` resident on the scenario machine.
private func floorBudget(_ models: [ResliceFloorScenario.Model], physicalBytes: UInt64) -> UInt64 {
    UnifiedMemoryCap.kvBudgetBytes(physicalBytes: physicalBytes,
        residentWeightBytes: UInt64(models.reduce(0) { $0 + $1.weightsBytes }),
        configReserveBytes: floorConfigReserveBytes)
}

/// Residents at the shares the six-slot re-slice gave them, installed on
/// `install`. Each bridge must report the scenario's floor.
private func installResidents(
    physicalBytes: UInt64,
    install: (ResliceFloorScenario.Model, EngineV2Bridge) async -> Void
) async throws -> [String: EngineV2Bridge] {
    let residents = try ResliceFloorScenario.residents()
    let shares = EngineV2KVSizing.resliceGrants(existing: residents.map(\.resliceSlot), newcomer: nil,
        fleetKVBudgetBytes: floorBudget(residents, physicalBytes: physicalBytes))
    var bridges: [String: EngineV2Bridge] = [:]
    for resident in residents {
        let bridge = ResliceFloorScenario.makeBridge(modelId: resident.id,
            fixedRequestBytes: resident.fixedRequestBytes, grant: try #require(shares[resident.id]),
            kvBytesPerToken: resident.fp16KVBytesPerToken)
        #expect(await bridge.minimumServiceableGrantBytes() == resident.minimumGrantBytes, "\(resident.id)")
        await install(resident, bridge)
        bridges[resident.id] = bridge
    }
    return bridges
}

/// Every resident keeps at least its floor and can still serve a request.
private func expectResidentsServiceable(_ bridges: [String: EngineV2Bridge]) async {
    for (id, bridge) in bridges {
        let grant = await bridge.engineKVBytesCapacity()
        #expect(grant >= (await bridge.minimumServiceableGrantBytes()), "\(id) grant \(grant)")
        #expect(await bridge.effectiveServingConcurrency(allowExpansion: true) >= 1, "\(id)")
    }
}

@Suite("KV re-slice keeps every slot's floor (orchestration)", .serialized)
struct EngineV2ResliceFloorWiringTests {
    private static let physical = ResliceFloorScenario.physicalBytes

    @Test("ProviderLoop admits a seventh model when Σ floors fits the fleet budget",
          arguments: [ResliceFloorScenario.gemmaQAT.id, ResliceFloorScenario.gptOSS.id])
    func providerLoopAdmitsSeventhModel(newcomerID: String) async throws {
        let newcomer = newcomerID == ResliceFloorScenario.gptOSS.id
            ? ResliceFloorScenario.gptOSS : ResliceFloorScenario.gemmaQAT
        let loop = try makeFloorLoop(physicalBytes: Self.physical)
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(.init(physicalMemoryBytes: Self.physical, retainedResidentBytes: 0,
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        let residents = try await installResidents(physicalBytes: Self.physical) { model, bridge in
            await loop.installModelSlotForTesting(modelId: model.id, container: makeFloorContainer(),
                tokenizer: TokenizerHandle(StubBridgeTokenizer()), engineV2: bridge,
                sizing: model.sizing, modelType: model.modelType)
        }
        let all = try ResliceFloorScenario.residents() + [newcomer]
        let budget = floorBudget(all, physicalBytes: Self.physical)
        // The proportional share alone would leave Lightning below its floor.
        let lightning = try #require(all.first { $0.id == ResliceFloorScenario.lightningID })
        let proportional = EngineV2KVSizing.resliceGrants(existing: all.map(\.resliceSlot), newcomer: nil,
            fleetKVBudgetBytes: budget)
        let lightningShare = try #require(proportional[lightning.id])
        #expect(lightningShare < lightning.minimumGrantBytes)
        #expect(UInt64(all.reduce(0) { $0 + $1.minimumGrantBytes }) <= budget)

        let bridge = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: newcomer.id, modelType: newcomer.modelType, container: makeFloorContainer(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), sizing: newcomer.sizing)

        await expectResidentsServiceable(residents)
        let newcomerGrant = await bridge.engineKVBytesCapacity()
        #expect(newcomerGrant >= Int(EngineV2KVSizing.minimumServiceableGrantBytes))
        var total = UInt64(newcomerGrant)
        for resident in residents.values { total += UInt64(await resident.engineKVBytesCapacity()) }
        #expect(total <= budget)
        await bridge.shutdown()
        for resident in residents.values { await resident.shutdown() }
    }

    @Test("ProviderLoop holds a GLM set's grants to the GPU limit")
    func providerLoopHoldsGLMGrantsToTheGPULimit() async throws {
        let physical: UInt64 = 64 << 30
        let loop = try makeFloorLoop(physicalBytes: physical)
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        await loop.setEngineV2SlotHooksForTesting(.init(physicalMemoryBytes: physical, retainedResidentBytes: 0,
            gpuLimit: .init(limitBytes: 40 << 30),
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        let (glm, _) = makeInertStubBridge(modelId: "glm", kvBytesCapacity: 1 << 30)
        await loop.installModelSlotForTesting(modelId: "glm", container: makeFloorContainer(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), engineV2: glm,
            sizing: SlotSizingSnapshot(weightsBytes: 20 << 30, fp16KVBytesPerToken: 1024,
                maxContextLength: 4096, defaultMaxTokens: 8),
            modelType: "glm5_next")
        let bridge = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gemma", modelType: "gemma4", container: makeFloorContainer(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            sizing: SlotSizingSnapshot(weightsBytes: 2 << 30, fp16KVBytesPerToken: 1024,
                maxContextLength: 4096, defaultMaxTokens: 8))
        // The cap alone would grant 57.6 − 22 − 5.5 = 30.1 GiB across the two.
        let total = UInt64(await bridge.engineKVBytesCapacity()) + UInt64(await glm.engineKVBytesCapacity())
        #expect(total > 0)
        #expect(total <= (40 << 30) - (22 << 30) - UnifiedMemoryCap.defaultActivationReserveBytes)
        await bridge.shutdown()
        await glm.shutdown()
    }

    @Test("ProviderLoop's GLM estimate without the other models keeps the GPU limit")
    func providerLoopSoloEstimateKeepsTheGPULimit() async throws {
        let physical: UInt64 = 64 << 30
        let loop = try makeFloorLoop(physicalBytes: physical)
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        await loop.setEngineV2SlotHooksForTesting(.init(physicalMemoryBytes: physical, retainedResidentBytes: 0,
            gpuLimit: .init(limitBytes: 40 << 30),
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        var bridges: [EngineV2Bridge] = []
        for (id, type, weights) in [("glm", "glm5_next", 20 << 30), ("gemma", "gemma4", 2 << 30)] {
            let (bridge, _) = makeInertStubBridge(modelId: id, kvBytesCapacity: 1 << 30)
            bridges.append(bridge)
            await loop.installModelSlotForTesting(modelId: id, container: makeFloorContainer(),
                tokenizer: TokenizerHandle(StubBridgeTokenizer()), engineV2: bridge,
                sizing: SlotSizingSnapshot(weightsBytes: weights, fp16KVBytesPerToken: 1024,
                    maxContextLength: 4096, defaultMaxTokens: 8),
                modelType: type)
        }
        let reserve = await loop.resolvedActivationReserveBytes
        // Without Gemma the cap would leave 57.6 − 20 GiB less the reserve; the GPU limit leaves 40 − 20 GiB less it.
        #expect(await loop.glmSoloGrant(for: "glm") == (40 << 30) - (20 << 30) - reserve)
        // Leaving out GLM itself leaves a set the limit doesn't hold.
        #expect(await loop.fleetKVBudgetBytes(extraWeightBytes: 0, excludingModelIDs: ["glm"])
            > (40 << 30) - (2 << 30) - reserve)
        for bridge in bridges { await bridge.shutdown() }
    }

    @Test("ProviderLoop gives a GLM newcomer its grant without the GPU-limit hold as its rows reference",
        arguments: [false, true])
    func providerLoopPassesTheUnheldRowsReference(besideGemma: Bool) async throws {
        try await expectUnheldRowsReference(besideGemma: besideGemma) { limit, references in
            let physical: UInt64 = 64 << 30
            let loop = try makeFloorLoop(physicalBytes: physical)
            await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
            await loop.setEngineV2SlotHooksForTesting(.init(physicalMemoryBytes: physical, retainedResidentBytes: 0,
                gpuLimit: limit, onGLMRowsReference: references.record,
                makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
            var bridges: [EngineV2Bridge] = []
            if besideGemma {
                bridges.append(try await loop.loadV2SlotForTesting(modelId: "gemma", modelType: "gemma4",
                    container: makeFloorContainer(), tokenizer: TokenizerHandle(StubBridgeTokenizer()),
                    sizing: rowsReferenceGemmaSizing))
            }
            let glm = try await loop.loadV2SlotForTesting(modelId: "glm", modelType: "glm5_next",
                container: makeFloorContainer(), tokenizer: TokenizerHandle(StubBridgeTokenizer()),
                sizing: rowsReferenceGLMSizing)
            bridges.append(glm)
            let grant = await glm.engineKVBytesCapacity()
            for bridge in bridges { await bridge.shutdown() }
            return grant
        }
    }

    @Test("StandaloneServer gives a GLM newcomer its grant without the GPU-limit hold as its rows reference",
        arguments: [false, true])
    func standalonePassesTheUnheldRowsReference(besideGemma: Bool) async throws {
        try await expectUnheldRowsReference(besideGemma: besideGemma) { limit, references in
            let server = StandaloneServer(models: [])
            await server.setV2TestHooksForTesting(.init(physicalMemoryBytes: 64 << 30, retainedResidentBytes: 0,
                gpuLimit: limit, onGLMRowsReference: references.record,
                makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
            var bridges: [EngineV2Bridge] = []
            if besideGemma {
                bridges.append(try await server.buildSlotForTesting(modelId: "gemma", modelType: "gemma4",
                    container: makeFloorContainer(), tokenizer: TokenizerHandle(StubBridgeTokenizer()),
                    sizing: rowsReferenceGemmaSizing))
            }
            let glm = try await server.buildSlotForTesting(modelId: "glm", modelType: "glm5_next",
                container: makeFloorContainer(), tokenizer: TokenizerHandle(StubBridgeTokenizer()),
                sizing: rowsReferenceGLMSizing)
            bridges.append(glm)
            let grant = await glm.engineKVBytesCapacity()
            for bridge in bridges { await bridge.shutdown() }
            return grant
        }
    }

    @Test("StandaloneServer admits a seventh model when Σ floors fits the fleet budget")
    func standaloneAdmitsSeventhModel() async throws {
        try await Self.runStandaloneSeventhModel()
    }

    /// CI (SDK 27 lane, 11-16): this scenario once refused Lightning below its floor. The fleet budget also subtracts
    /// GLM memory retained after a load fault, a charge held by the whole test process; another test in the same
    /// process (`EngineV2ProductionWiringTests`, `GLM5NextLocalLoadPolicyTests`) can leave 12 GiB or more of it. In a
    /// child process holding such a charge, the scenario must still admit the seventh model.
    @Test("a GLM charge another test left retained doesn't shrink the scenario's budget")
    func retainedGLMChargeOfAnotherTestDoesNotShrinkTheBudget() async {
        await #expect(processExitsWith: .success) {
            final class OtherTestsFault {}
            let fault = OtherTestsFault()
            GLM5NextLoadFaultState.retain([fault], charging: fault, residentBytes: 48 << 30)
            #expect(GLM5NextLoadFaultState.retainedResidentBytes >= 48 << 30)
            try await EngineV2ResliceFloorWiringTests.runStandaloneSeventhModel()
            withExtendedLifetime(fault) {}
        }
    }

    static func runStandaloneSeventhModel() async throws {
        let newcomer = ResliceFloorScenario.gemmaQAT
        let server = StandaloneServer(models: [])
        await server.setV2TestHooksForTesting(.init(physicalMemoryBytes: Self.physical, retainedResidentBytes: 0,
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        let residents = try await installResidents(physicalBytes: Self.physical) { model, bridge in
            await server.installSlotForTesting(modelId: model.id, bridge: bridge,
                container: makeFloorContainer(), tokenizer: TokenizerHandle(StubBridgeTokenizer()),
                sizing: model.sizing, modelType: model.modelType)
        }

        let bridge = try await server.buildSlotForTesting(
            modelId: newcomer.id, modelType: newcomer.modelType, container: makeFloorContainer(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), sizing: newcomer.sizing)

        await expectResidentsServiceable(residents)
        #expect(await bridge.engineKVBytesCapacity() >= Int(EngineV2KVSizing.minimumServiceableGrantBytes))
        await bridge.shutdown()
        for resident in residents.values { await resident.shutdown() }
    }

    @Test("a seventh model whose floors exceed the fleet budget is still refused")
    func infeasibleSeventhModelIsRefused() async throws {
        let physical: UInt64 = 150 << 30
        let newcomer = ResliceFloorScenario.gemmaQAT
        let all = try ResliceFloorScenario.residents() + [newcomer]
        #expect(UInt64(all.reduce(0) { $0 + $1.minimumGrantBytes }) > floorBudget(all, physicalBytes: physical))
        let loop = try makeFloorLoop(physicalBytes: physical)
        await loop.setEngineV2SlotHooksForTesting(.init(physicalMemoryBytes: physical, retainedResidentBytes: 0,
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        let residents = try await installResidents(physicalBytes: physical) { model, bridge in
            await loop.installModelSlotForTesting(modelId: model.id, container: makeFloorContainer(),
                tokenizer: TokenizerHandle(StubBridgeTokenizer()), engineV2: bridge,
                sizing: model.sizing, modelType: model.modelType)
        }
        var before: [String: Int] = [:]
        for (id, bridge) in residents { before[id] = await bridge.engineKVBytesCapacity() }

        do {
            _ = try await loop.resliceAndBuildEngineV2SlotForTesting(
                modelId: newcomer.id, modelType: newcomer.modelType, container: makeFloorContainer(),
                tokenizer: TokenizerHandle(StubBridgeTokenizer()), sizing: newcomer.sizing)
            Issue.record("an infeasible re-slice was admitted")
        } catch InferenceError.modelLoadFailed(let message) {
            #expect(message.contains("would leave a model without its fixed request workspace"))
            #expect(message.contains("across 7 slots"))
        }
        for (id, bridge) in residents {
            #expect(await bridge.engineKVBytesCapacity() == before[id], "\(id)")
            await bridge.shutdown()
        }
    }

    @Test("regrow and the reserve preflight keep a starved slot at its floor")
    func regrowAndPreflightKeepFloors() async throws {
        let newcomer = ResliceFloorScenario.gemmaQAT
        let loop = try makeFloorLoop(physicalBytes: Self.physical)
        await loop.setEngineV2SlotHooksForTesting(.init(physicalMemoryBytes: Self.physical, retainedResidentBytes: 0,
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        let residents = try await installResidents(physicalBytes: Self.physical) { model, bridge in
            await loop.installModelSlotForTesting(modelId: model.id, container: makeFloorContainer(),
                tokenizer: TokenizerHandle(StubBridgeTokenizer()), engineV2: bridge,
                sizing: model.sizing, modelType: model.modelType)
        }
        let newcomerBridge = EngineV2Bridge(engine: InertStubEngine(kvBytesCapacity: 4 << 30),
            modelId: newcomer.id, tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        await loop.installModelSlotForTesting(modelId: newcomer.id, container: makeFloorContainer(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), engineV2: newcomerBridge,
            sizing: newcomer.sizing, modelType: newcomer.modelType)

        #expect(await loop.reserveRaiseKeepsSurvivorsServiceable(
            reserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes))
        await loop.resliceGrowSurvivorsForTesting()

        await expectResidentsServiceable(residents)
        let all = try ResliceFloorScenario.residents() + [newcomer]
        var total = UInt64(await newcomerBridge.engineKVBytesCapacity())
        for resident in residents.values { total += UInt64(await resident.engineKVBytesCapacity()) }
        #expect(total <= floorBudget(all, physicalBytes: Self.physical))
        await newcomerBridge.shutdown()
        for resident in residents.values { await resident.shutdown() }
    }

    @Test("StandaloneServer regrow and the reserve check keep a starved slot at its floor")
    func standaloneRegrowAndReserveKeepFloors() async throws {
        let newcomer = ResliceFloorScenario.gemmaQAT
        let server = StandaloneServer(models: [])
        await server.setV2TestHooksForTesting(.init(physicalMemoryBytes: Self.physical, retainedResidentBytes: 0,
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        let residents = try await installResidents(physicalBytes: Self.physical) { model, bridge in
            await server.installSlotForTesting(modelId: model.id, bridge: bridge,
                container: makeFloorContainer(), tokenizer: TokenizerHandle(StubBridgeTokenizer()),
                sizing: model.sizing, modelType: model.modelType)
        }
        let newcomerBridge = EngineV2Bridge(engine: InertStubEngine(kvBytesCapacity: 4 << 30),
            modelId: newcomer.id, tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        await server.installSlotForTesting(modelId: newcomer.id, bridge: newcomerBridge,
            container: makeFloorContainer(), tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            sizing: newcomer.sizing, modelType: newcomer.modelType)
        // The server's own budget: its proportional share alone starves Lightning.
        let budget = await server.fleetKVBudgetBytes(extraWeightBytes: 0)
        let all = try ResliceFloorScenario.residents() + [newcomer]
        let lightning = try #require(all.first { $0.id == ResliceFloorScenario.lightningID })
        let proportional = EngineV2KVSizing.resliceGrants(existing: all.map(\.resliceSlot), newcomer: nil,
            fleetKVBudgetBytes: budget)
        #expect(try #require(proportional[lightning.id]) < lightning.minimumGrantBytes)

        #expect(await server.reserveKeepsSurvivorsServiceable(
            reserveBytes: await server.resolvedActivationReserveBytes))
        await server.resliceGrowSurvivors()

        await expectResidentsServiceable(residents)
        var total = UInt64(await newcomerBridge.engineKVBytesCapacity())
        for resident in residents.values { total += UInt64(await resident.engineKVBytesCapacity()) }
        #expect(total <= budget)
        await newcomerBridge.shutdown()
        for resident in residents.values { await resident.shutdown() }
    }
}
