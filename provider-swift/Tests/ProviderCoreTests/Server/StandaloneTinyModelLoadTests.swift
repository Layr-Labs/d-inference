import Foundation
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

// The standalone (local mode) server loads a tiny synthetic model through the
// real loader and the real CBv2 engine. The load-admission budget is scripted
// (ScriptedProviderMemory). No test hooks replace the engine, and the two
// measured headroom checks after the load read the real machine; the tiny
// model leaves that headroom as it was.

extension TinyModelLoadTests {
    @Suite("Standalone server")
    struct StandaloneServerCases {
        @Test("Load, reuse, serve one request and evict a tiny model")
        func loadServeAndEvict() async throws {
            _ = LiveInferenceFixtures.ensureMetallibColocated()
            let checkpoint = try TinyModelCheckpoint(seed: 13)
            defer { checkpoint.remove() }

            try await checkpoint.withModelCache {
                let modelID = checkpoint.modelID
                let info = try checkpoint.scannedModelInfo()
                let server = StandaloneServer(
                    config: StandaloneServerConfig(mtpMode: .off),
                    models: [info],
                    kvBudgetForTesting: ScriptedProviderMemory.budget(modelIDs: [modelID]))
                #expect(await server.advertisedModelIds() == [modelID])
                #expect(await server.loadedModelIds().isEmpty)

                try await server.ensureModelLoaded(modelID)

                // Slot state.
                #expect(await server.loadedModelIds() == [modelID])
                let slot = try #require(await server.slots[modelID])
                #expect(slot.modelType == TinyModelCheckpoint.modelType)
                #expect(!slot.isVLM)
                #expect(slot.sizing.weightsBytes == checkpoint.weightBytes)
                #expect(slot.sizing.maxContextLength == TinyModelCheckpoint.maxContextLength)
                #expect(slot.tokenizer.inner.encode(text: TinyGeneration.prompt, addSpecialTokens: false)
                    == TinyGeneration.promptTokenIDs)
                let grant = try #require(await server.debugEngineKVGrant(modelId: modelID))
                #expect(grant > 0)

                // No artifact profile asks for the weight hash, so the server
                // does not read the weights twice and records no hash.
                #expect(slot.modelArtifactSHA256 == nil)
                #expect(slot.cacheEligibleWeightHash == nil)

                // Load bookkeeping and the advertised list.
                #expect(!(await server.isLoadingAny))
                #expect(await server.modelsLoading.isEmpty)
                #expect(await server.debugOutstandingKVReservationBytes() == 0)
                #expect(await server.advertisedModelIds() == [modelID])

                // A second load of the same model returns the resident slot.
                try await server.ensureModelLoaded(modelID)
                #expect(await server.slots[modelID]?.bridge === slot.bridge)

                // One short request runs through the acquired engine.
                let acquired = try await server.acquireModel(modelID)
                #expect(await server.debugSlotReservationCount(modelId: modelID) == 1)
                let bridge = try #require(acquired.engineV2Bridge)
                #expect(bridge === slot.bridge)
                let generation = await TinyGeneration.run(bridge: bridge, modelID: modelID)
                await acquired.releaseToken.fire()
                generation.check()
                #expect(await server.debugSlotReservationCount(modelId: modelID) == 0)
                #expect(await modelLoadingWaitUntil {
                    await server.debugOutstandingKVReservationBytes() == 0
                })

                // Eviction unloads the idle slot. The model stays advertised.
                #expect(await server.evictLRUIdleSlotForTesting())
                #expect(await server.loadedModelIds().isEmpty)
                #expect(await server.slots[modelID] == nil)
                #expect(await server.advertisedModelIds() == [modelID])
                #expect(!(await server.evictLRUIdleSlotForTesting()))
            }
        }
    }
}
