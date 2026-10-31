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
        await loop.setEngineV2SlotHooksForTesting(.init(physicalMemoryBytes: Self.physical,
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

    @Test("StandaloneServer admits a seventh model when Σ floors fits the fleet budget")
    func standaloneAdmitsSeventhModel() async throws {
        let newcomer = ResliceFloorScenario.gemmaQAT
        let server = StandaloneServer(models: [])
        await server.setV2TestHooksForTesting(.init(physicalMemoryBytes: Self.physical,
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
        await loop.setEngineV2SlotHooksForTesting(.init(physicalMemoryBytes: physical,
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
        await loop.setEngineV2SlotHooksForTesting(.init(physicalMemoryBytes: Self.physical,
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
}
