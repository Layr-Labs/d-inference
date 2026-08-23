// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing

@testable import ProviderCore

@Suite("EngineV2 production wiring: failure unwind", .serialized)
struct EngineV2ProductionFailureUnwindTests {
    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("engine construction failure THROWS + ERROR engine_v2_refusal; nothing registered")
    func constructionFailureRefusesLoudly() async throws {
        struct InitFailure: Error {}
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        let telemetry = ProductionWiringTelemetrySink()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                emitTelemetry: telemetry.callback(),
                physicalMemoryBytes: productionWiringPhysicalBytes,
                makeEngine: { _, _ in throw InitFailure() }))

        await #expect(throws: InitFailure.self) {
            _ = try await loop.resliceAndBuildEngineV2SlotForTesting(
                modelId: "gpt-oss-20b",
                modelType: "gpt_oss",
                container: productionMakeStubContainer(),
                tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                sizing: productionMakeSizing(weightsGiB: 12, kvRate: 24_576)
            )
        }
        // Nothing registered — the load fails; there is no legacy fallback.
        #expect(await runtime.bridge(forModel: "gpt-oss-20b") == nil)
        let events = telemetry.events
        #expect(events.count == 1)
        #expect(events.first?.kind == .engineHealth)
        #expect(events.first?.severity == .error)
        #expect(events.first?.fields?["operation"]?.description == "engine_v2_refusal")
        #expect(events.first?.fields?["reason"]?.description == "engine_init_failed")
        #expect(events.first?.fields?["model"]?.description == "gpt-oss-20b")
        #expect(events.first?.fields?["error_class"]?.description.contains("InitFailure") == true)
    }
    @Test("restore-on-throw: B's construction failure restores A's grant EXACTLY")
    func constructionFailureRestoresGrants() async throws {
        struct BFailure: Error {}
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = ProductionGrantRecorder()
        let (bridgeA, engineA, _) = try await productionBuildAndInstallSlotA(loop, runtime: runtime, recorder: recorder,
        engines: { _, grant in ProductionWiringScriptedEngine(script: .manual, kvBytesCapacity: grant) })
        let grantA0 = await bridgeA.engineKVBytesCapacity()

        // Swap the hooks: B's builder throws AFTER A has been shrunk.
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                physicalMemoryBytes: productionWiringPhysicalBytes,
                makeEngine: { _, _ in throw BFailure() }))

        await #expect(throws: BFailure.self) {
            _ = try await loop.resliceAndBuildEngineV2SlotForTesting(
                modelId: "gpt-oss-20b",
                modelType: "gpt_oss",
                container: productionMakeStubContainer(),
                tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                sizing: productionMakeSizing(weightsGiB: 12, kvRate: 24_576, maxContext: 131_072)
            )
        }

        // A was shrunk for the attempt, then restored to the EXACT prior
        // grant — the capacityUpdates trail shows shrink → restore.
        #expect(await bridgeA.engineKVBytesCapacity() == grantA0)
        let updates = engineA.capacityUpdates
        #expect(updates.count == 2)
        #expect(updates.first ?? 0 < grantA0)
        #expect(updates.last == grantA0)
        // B never registered.
        #expect(await runtime.bridge(forModel: "gpt-oss-20b") == nil)
    }
    @Test("serviceability floor: a slice below 1 GiB per slot REFUSES the load (reslice_floor)")
    func resliceFloorRefusesLoad() async throws {
        // A 16 GiB "machine": cap = min(0.9×16, 16−2) = 14 GiB. After slot
        // A's 6 GiB of weights the budget is 14 − 6 − 5.5 (activation
        // reserve) = 2.5 GiB — A loads. Adding B's 6 GiB zeroes it
        // (14 − 12 − 5.5 < 0), so any two-way slice lands below the 1 GiB
        // floor. (An 8 GiB machine no longer works as this fixture: its
        // 6 GiB cap minus the 5.5 GiB reserve cannot clear the floor for
        // even ONE slot — the deliberate consequence of the v0.8.0 reserve
        // raise for the smallest boxes.)
        let tinyPhysical: UInt64 = 16 * productionWiringGiB
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        let telemetry = ProductionWiringTelemetrySink()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                emitTelemetry: telemetry.callback(),
                physicalMemoryBytes: tinyPhysical,
                makeEngine: { _, grant in
                    ProductionWiringScriptedEngine(script: .manual, kvBytesCapacity: grant)
                }))

        // Slot A exists with a small grant already.
        let sizingA = productionMakeSizing(weightsGiB: 6, kvRate: 20_480)
        let bridgeA = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            modelType: "gemma4",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
            sizing: sizingA
        )
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
            engineV2: bridgeA,
            sizing: sizingA,
            modelType: "gemma4")
        let grantA0 = await bridgeA.engineKVBytesCapacity()

        // Loading B would slice both below the serviceability floor →
        // REFUSED (503-shaped modelLoadFailed), A untouched, ERROR telemetry
        // with reason reslice_floor.
        await #expect(throws: InferenceError.self) {
            _ = try await loop.resliceAndBuildEngineV2SlotForTesting(
                modelId: "gpt-oss-20b",
                modelType: "gpt_oss",
                container: productionMakeStubContainer(),
                tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                sizing: productionMakeSizing(weightsGiB: 6, kvRate: 24_576)
            )
        }
        #expect(await bridgeA.engineKVBytesCapacity() == grantA0)
        let refusal = telemetry.events.first {
            $0.fields?["operation"]?.description == "engine_v2_refusal"
        }
        #expect(refusal?.severity == .error)
        #expect(refusal?.fields?["reason"]?.description == "reslice_floor")
        #expect(await runtime.bridge(forModel: "gpt-oss-20b") == nil)
    }
    @Test("cancellation fans out through the runtime to the owning bridge")
    func cancellationFansOutToBridge() async throws {
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        let engine = ProductionWiringScriptedEngine(script: .manual)
        let bridge = productionMakeBridge(engine: engine)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await runtime.register(modelId: "gemma-4-26b-qat-4bit", bridge: bridge)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
            engineV2: bridge,
            modelType: "gemma4"
        )

        // Submit under the coordinator request-id (held open by the manual
        // script) so the runtime fan-out has an owner to find.
        let stream = await bridge.submit(
            request: ChatCompletionRequest(
                model: "gemma-4-26b-qat-4bit",
                messages: [ChatMessage(role: "user", content: "hi")]),
            requestId: "req-coord-1")
        let engineId = await bridge._testEngineRequestId(for: "req-coord-1")

        await loop.handleCancellation(requestId: "req-coord-1", receivedFromCoordinator: false)
        #expect(await runtime.consultCount >= 1)
        #expect(engine.cancelled.first == engineId)
        withExtendedLifetime(stream) {}
    }
    @Test("unloading a v2 slot unregisters the bridge and drains the engine")
    func unloadRetiresBridge() async throws {
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        let engine = ProductionWiringScriptedEngine(script: .manual)
        let bridge = productionMakeBridge(engine: engine)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await runtime.register(modelId: "gemma-4-26b-qat-4bit", bridge: bridge)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
            engineV2: bridge,
            modelType: "gemma4"
        )

        await loop.unloadModel("gemma-4-26b-qat-4bit")
        #expect(await runtime.bridge(forModel: "gemma-4-26b-qat-4bit") == nil)
        #expect(engine.shutdownCalls == 1)
        #expect(await loop.hasEngineV2SlotsForTesting() == false)
    }
}
