// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing

@testable import ProviderCore

@Suite("EngineV2 production wiring: heartbeat and capacity", .serialized)
struct EngineV2ProductionHeartbeatCapacityTests {
    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("heartbeat reads CURRENT grants: budget max tracks the re-sliced ceiling")
    func heartbeatTracksReslicedGrants() async throws {
        let rate = 20_480
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = ProductionGrantRecorder()
        let (bridgeA, _, sizingA) = try await productionBuildAndInstallSlotA(loop, runtime: runtime, recorder: recorder,
        engines: { _, grant in ScriptedCBv2Engine(script: .manual, kvBytesCapacity: grant) })
        await runtime.register(modelId: "gemma-4-26b-qat-4bit", bridge: bridgeA)

        func v2BudgetMax() async throws -> Int64 {
            await loop.updateAggregateCapacity()
            let capacity = try #require(await loop.backendCapacityForTesting())
            let slot = try #require(
                capacity.slots.first(where: { $0.model == "gemma-4-26b-qat-4bit" }))
            return slot.activeTokenBudgetMax
        }

        // Alone on the box: the heartbeat reports the full-budget grant.
        let grantA0 = await bridgeA.engineKVBytesCapacity()
        #expect(try await v2BudgetMax() == Int64(grantA0 / rate))

        // A second v2 slot loads: A's engine grant is RE-SLICED (shrunk);
        // the heartbeat must report the CURRENT grant, not the construction
        // figure.
        let sizingB = productionMakeSizing(weightsGiB: 12, kvRate: 24_576, maxContext: 131_072)
        let bridgeB = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            sizing: sizingB
        )
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            engineV2: bridgeB,
            sizing: sizingB,
            modelType: "gpt_oss")

        let grantA1 = await bridgeA.engineKVBytesCapacity()
        #expect(grantA1 < grantA0)
        #expect(try await v2BudgetMax() == Int64(grantA1 / rate))
        // The heartbeat carries BOTH v2 slots (and nothing else).
        await loop.updateAggregateCapacity()
        let capacity = try #require(await loop.backendCapacityForTesting())
        #expect(Set(capacity.slots.map(\.model)) == ["gemma-4-26b-qat-4bit", "gpt-oss-20b"])
        _ = sizingA
    }
    @Test("capacity + cancellation never consult the runtime without slots")
    func emptySlotsSkipRuntime() async throws {
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)

        #expect(await loop.hasEngineV2SlotsForTesting() == false)
        await loop.updateAggregateCapacity()
        await loop.handleCancellation(requestId: "req-none", receivedFromCoordinator: false)
        #expect(await runtime.consultCount == 0)
    }
    @Test("capacity summary is the ONLY slot source; v2 slot folds into the heartbeat")
    func capacityUsesOnlyTheRuntimeSummary() async throws {
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        let engine = ScriptedCBv2Engine(script: .manual, kvBytesCapacity: 0)
        let bridge = productionMakeBridge(engine: engine)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await runtime.register(modelId: "gemma-4-26b-qat-4bit", bridge: bridge)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            engineV2: bridge,
            modelType: "gemma4"
        )

        #expect(await loop.hasEngineV2SlotsForTesting())
        await loop.updateAggregateCapacity()
        #expect(await runtime.consultCount == 1)
        let capacity = await loop.backendCapacityForTesting()
        let v2Slot = capacity?.slots.first { $0.model == "gemma-4-26b-qat-4bit" }
        #expect(v2Slot != nil)
        // Exactly one heartbeat slot exists — the bridge's. No legacy fold
        // can double-report a model's capacity anymore.
        #expect(capacity?.slots.count == 1)
    }
    @Test("model_load_time_ms rides the slot after recordModelLoadTime")
    func modelLoadTimeRidesTheSlot() async throws {
        let engine = ScriptedCBv2Engine(script: .manual, kvBytesCapacity: 0)
        let bridge = productionMakeBridge(engine: engine)
        await bridge.recordModelLoadTime(ms: 12_345)
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.modelLoadTimeMs == 12_345)
    }
}
