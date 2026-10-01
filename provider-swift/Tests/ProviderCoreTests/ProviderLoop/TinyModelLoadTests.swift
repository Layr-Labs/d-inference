import Foundation
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

// The provider loop loads a tiny synthetic model through the real loader:
// path lookup in the model cache, weight hash, config and weights, tokenizer,
// sizing, the real CBv2 engine and slot install. The load-admission budget is
// scripted (ScriptedProviderMemory). The two measured headroom checks after
// the load read the real machine; the tiny model leaves that headroom as it
// was.

extension TinyModelLoadTests {
    @Suite("Provider loop")
    struct ProviderLoopCases {
        @Test("Load, reuse, serve one request and unload a tiny model")
        func loadServeAndUnload() async throws {
            _ = LiveInferenceFixtures.ensureMetallibColocated()
            let checkpoint = try TinyModelCheckpoint()
            defer { checkpoint.remove() }
            let sandbox = try ModelLoadingSandbox()
            defer { sandbox.remove() }

            try await checkpoint.withModelCache {
                let modelID = checkpoint.modelID
                let snapshot = try checkpoint.resolvedSnapshot()
                let info = try checkpoint.scannedModelInfo()
                #expect(info.modelType == TinyModelCheckpoint.modelType)
                let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox, models: [info])
                await loop.setLoadedModelsFileForTesting(sandbox.loadedModelsFile)
                #expect(await loop.isModelAdvertised(modelID))
                #expect(await loop.modelLoadingResidentIDs().isEmpty)
                #expect(await loop.liveModelHashForTesting(modelID) == nil)

                try await loop.ensureModelLoaded(modelId: modelID)

                // Slot state.
                #expect(await loop.modelLoadingResidentIDs() == [modelID])
                let bridge = try #require(await loop.slotBridgeForTesting(modelId: modelID))
                let sizing = try #require(await loop.slotSizingForTesting(modelId: modelID))
                #expect(sizing.weightsBytes == checkpoint.weightBytes)
                #expect(sizing.maxContextLength == TinyModelCheckpoint.maxContextLength)
                #expect(sizing.fp16KVBytesPerToken > 0)
                let facts = try #require(await loop.tinyModelSlotFacts(modelID))
                #expect(facts.modelType == TinyModelCheckpoint.modelType)
                #expect(!facts.isVLM)
                #expect(facts.tokenizer.inner.encode(text: TinyGeneration.prompt, addSpecialTokens: false)
                    == TinyGeneration.promptTokenIDs)

                // The advertised model list does not change.
                #expect(await loop.advertisedModelCount() == 1)
                #expect(await loop.isModelAdvertised(modelID))

                // Weight hash capture: the hash of the bytes on disk, published
                // as the live hash, the slot identity and the warm state.
                let expectedHash = try #require(WeightHasher.computeHash(snapshotDir: snapshot, modelID: modelID))
                #expect(await loop.liveModelHashForTesting(modelID) == expectedHash)
                #expect(await loop.modelLoadingFingerprint(modelID)
                    == WeightHasher.snapshotFingerprint(snapshotDir: snapshot))
                #expect(facts.modelArtifactSHA256 == expectedHash)
                #expect(facts.cacheEligibleWeightHash == nil)
                #expect(await loop.loadedModelHashesSnapshotForTesting() == [modelID: expectedHash])
                #expect(await loop.modelLoadingWarmState() == ModelLoadingWarmState(
                    warmModels: [modelID], currentModel: modelID, currentModelHash: expectedHash))

                // Load bookkeeping: the gate is open, no load is in flight, the
                // pending-load reservation is gone, the serving set is saved and
                // the heartbeat capacity lists the idle slot.
                #expect(!(await loop.modelLoadingIsLoadingAny()))
                #expect(await loop.modelLoadingInFlightIDs().isEmpty)
                #expect(await loop.modelLoadingLoadGateWaiterCount() == 0)
                #expect(await loop.modelLoadingLastLoadError() == nil)
                #expect(await loop.outstandingKVReservationBytesForTesting() == 0)
                #expect(LoadedModelsStore.read(from: sandbox.loadedModelsFile) == [modelID])
                let capacity = try #require(await loop.backendCapacityForTesting())
                #expect(capacity.slots.map(\.model) == [modelID])
                #expect(capacity.slots.first?.state == "idle")

                // A second load of the same model returns the resident slot.
                try await loop.ensureModelLoaded(modelId: modelID)
                #expect(await loop.slotBridgeForTesting(modelId: modelID) === bridge)
                #expect(await loop.modelLoadingResidentIDs() == [modelID])

                // One short request runs through the real engine.
                let generation = await TinyGeneration.run(bridge: bridge, modelID: modelID)
                generation.check()
                // The request gives its KV reservation back when it ends.
                #expect(await modelLoadingWaitUntil {
                    await loop.outstandingKVReservationBytesForTesting() == 0
                })

                // Unload removes the slot, the warm state and the saved entry,
                // and keeps the model advertised.
                #expect(await loop.unloadModel(modelID))
                #expect(await loop.modelLoadingResidentIDs().isEmpty)
                #expect(await loop.slotBridgeForTesting(modelId: modelID) == nil)
                #expect(await loop.modelLoadingWarmState() == ModelLoadingWarmState(
                    warmModels: [], currentModel: nil, currentModelHash: nil))
                #expect(await loop.loadedModelHashesSnapshotForTesting().isEmpty)
                #expect(LoadedModelsStore.read(from: sandbox.loadedModelsFile).isEmpty)
                #expect(await loop.isModelAdvertised(modelID))
                #expect(!(await loop.unloadModel(modelID)))
            }
        }

        @Test("A reload after unload reuses the unchanged weight hash")
        func reloadReusesUnchangedHash() async throws {
            _ = LiveInferenceFixtures.ensureMetallibColocated()
            let checkpoint = try TinyModelCheckpoint(seed: 11)
            defer { checkpoint.remove() }
            let sandbox = try ModelLoadingSandbox()
            defer { sandbox.remove() }

            try await checkpoint.withModelCache {
                let modelID = checkpoint.modelID
                let snapshot = try checkpoint.resolvedSnapshot()
                let loop = try await ModelLoadingFixtures.makeLoop(
                    sandbox: sandbox, models: [try checkpoint.scannedModelInfo()])
                let expectedHash = try #require(WeightHasher.computeHash(snapshotDir: snapshot, modelID: modelID))

                try await loop.ensureModelLoaded(modelId: modelID)
                let firstBridge = try #require(await loop.slotBridgeForTesting(modelId: modelID))
                #expect(await loop.unloadModel(modelID))

                // The files did not change, so the fingerprint matches and the
                // second load keeps the same hash. The new slot has a new engine.
                try await loop.ensureModelLoaded(modelId: modelID)
                let secondBridge = try #require(await loop.slotBridgeForTesting(modelId: modelID))
                #expect(secondBridge !== firstBridge)
                #expect(await loop.liveModelHashForTesting(modelID) == expectedHash)
                let facts = try #require(await loop.tinyModelSlotFacts(modelID))
                #expect(facts.modelArtifactSHA256 == expectedHash)
                #expect(await loop.modelLoadingResidentIDs() == [modelID])

                #expect(await loop.unloadModel(modelID))
                #expect(await loop.modelLoadingResidentIDs().isEmpty)
            }
        }
    }
}

struct TinyModelSlotFacts: Sendable {
    let modelType: String?
    let isVLM: Bool
    let tokenizer: TokenizerHandle
    let modelArtifactSHA256: String?
    let cacheEligibleWeightHash: String?
}

extension ProviderLoop {
    func tinyModelSlotFacts(_ modelId: String) -> TinyModelSlotFacts? {
        guard let slot = modelSlots[modelId] else { return nil }
        return TinyModelSlotFacts(
            modelType: slot.modelType, isVLM: slot.isVLM, tokenizer: slot.tokenizer,
            modelArtifactSHA256: slot.modelArtifactSHA256,
            cacheEligibleWeightHash: slot.cacheEligibleWeightHash)
    }
}
