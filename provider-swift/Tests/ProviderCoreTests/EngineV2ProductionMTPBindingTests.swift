// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing

@testable import ProviderCore

@Suite("EngineV2 production wiring: MTP binding", .serialized)
struct EngineV2ProductionMTPBindingTests {
    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("the daemon state file carries each slot's resolved KV backend and MTP posture")
    func daemonStateCarriesSlotPosture() async throws {
        // §16.5: `darkbloom status` / `doctor` read the state file, not the
        // live engine. If the resolved backend never reaches that file the
        // operator cannot answer "is this box on paged?" at all.
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)

        let pagedBridge = productionMakeBridge(engine: ScriptedCBv2Engine(script: .manual, kvBytesCapacity: 0),
        modelId: "gemma-4-26b-qat-4bit",
        kvBackendKind: .paged)
        // `.zero` disables the posture sampler; this test is about the state
        // file, not the telemetry producer.
        await pagedBridge.configureMTPStatus(
            MTPActivationStatus(
                configured: true, active: true, reason: nil, source: nil, revision: nil,
                artifactBytes: 0, assistantBytes: 0),
            metricsInterval: .zero)
        let contiguousBridge = productionMakeBridge(engine: ScriptedCBv2Engine(script: .manual, kvBytesCapacity: 0),
        modelId: "gpt-oss-20b",
        kvBackendKind: .contiguous)

        for (modelId, bridge) in [
            ("gemma-4-26b-qat-4bit", pagedBridge), ("gpt-oss-20b", contiguousBridge),
        ] {
            await runtime.register(modelId: modelId, bridge: bridge)
            await loop.installModelSlotForTesting(
                modelId: modelId,
                container: productionMakeStubContainer(),
                tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
                engineV2: bridge,
                modelType: "gemma4")
        }

        await loop.updateAggregateCapacity()
        let slots = try #require(await loop.currentDaemonState().slots)
        #expect(slots.map(\.model) == ["gemma-4-26b-qat-4bit", "gpt-oss-20b"])
        #expect(slots[0].kvBackend == "paged")
        #expect(slots[1].kvBackend == "contiguous")
        // A scripted engine is not a concrete EngineV2 and reports no MTP
        // metrics, so a configured-and-activated slot resolves to
        // enabled-but-not-producing. That is precisely the distinction the
        // operator surface exists to make: enabled != producing drafts, and
        // the reason must always be named.
        #expect(slots[0].mtpEnabled == true)
        #expect(slots[0].mtpActive == false)
        #expect(slots[0].mtpInactiveReason == MTPFallbackReason.engineInactive.rawValue)
        #expect(slots[1].mtpEnabled == false)
        #expect(slots.allSatisfy { $0.loadError == nil })
    }
}
