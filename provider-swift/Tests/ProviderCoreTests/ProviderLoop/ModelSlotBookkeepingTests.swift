import Foundation
import Testing

@testable import ProviderCore

/// Slot bookkeeping around model unload, warm-model state, and the weight
/// hash records the loader keeps. Stub slots only; no model weights.
@Suite("Model slot bookkeeping")
struct ModelSlotBookkeepingTests {

    // MARK: - unloadModel

    @Test("unloading a model that is not loaded returns false")
    func unloadOfAbsentModelReturnsFalse() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)

        #expect(await loop.unloadModel("test/never-loaded") == false)
        #expect(await loop.unloadModel("test/never-loaded", forEviction: true) == false)
    }

    @Test("eviction skips a model with a live request and keeps its slot")
    func evictionSkipsBusyModel() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/busy-model"
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        let stub = makeInertStubBridge(modelId: id)
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge)
        await loop.modelLoadingSetRequest("request-1", model: id)

        #expect(await loop.unloadModel(id, forEviction: true) == false)
        #expect(await loop.modelLoadingResidentIDs() == [id])
        #expect(stub.engine.shutdownCalls == 0)
    }

    @Test("a model that is already unloading is not unloaded twice")
    func unloadInProgressReturnsFalse() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/already-unloading"
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        let stub = makeInertStubBridge(modelId: id)
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge)
        await loop.modelLoadingMarkUnloading(id)

        #expect(await loop.unloadModel(id) == false)
        #expect(await loop.modelLoadingResidentIDs() == [id])
        #expect(stub.engine.shutdownCalls == 0)
        await loop.modelLoadingFinishUnloading(id)
    }

    @Test("unload stops the engine, drops the slot, and persists the remaining set")
    func unloadDropsSlotAndPersists() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        await loop.setLoadedModelsFileForTesting(sandbox.loadedModelsFile)
        let first = makeInertStubBridge(modelId: "test/unload-a")
        let second = makeInertStubBridge(modelId: "test/unload-b")
        await loop.modelLoadingInstallSlot("test/unload-a", bridge: first.bridge)
        await loop.modelLoadingInstallSlot("test/unload-b", bridge: second.bridge)

        #expect(await loop.unloadModel("test/unload-a") == true)

        #expect(first.engine.shutdownCalls == 1)
        #expect(second.engine.shutdownCalls == 0)
        #expect(await loop.modelLoadingResidentIDs() == ["test/unload-b"])
        #expect(await loop.modelLoadingWarmState().warmModels == ["test/unload-b"])
        #expect(LoadedModelsStore.read(from: sandbox.loadedModelsFile) == ["test/unload-b"])
        #expect(await loop.modelLoadingHasQwen4RetirementWindow() == false)
    }

    @Test("an unload during shutdown keeps the persisted serving set")
    func shutdownUnloadKeepsPersistedSet() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        await loop.setLoadedModelsFileForTesting(sandbox.loadedModelsFile)
        let first = makeInertStubBridge(modelId: "test/keep-a")
        let second = makeInertStubBridge(modelId: "test/keep-b")
        await loop.modelLoadingInstallSlot("test/keep-a", bridge: first.bridge)
        await loop.modelLoadingInstallSlot("test/keep-b", bridge: second.bridge)
        await loop.persistLoadedModelSetForTesting()
        await loop.beginShutdownForTesting()

        #expect(await loop.unloadModel("test/keep-a") == true)

        #expect(first.engine.shutdownCalls == 1)
        #expect(await loop.modelLoadingResidentIDs() == ["test/keep-b"])
        #expect(LoadedModelsStore.read(from: sandbox.loadedModelsFile) == ["test/keep-a", "test/keep-b"])
    }

    @Test("unloading a native Qwen4 model opens the memory retirement window")
    func qwen4UnloadOpensRetirementWindow() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/qwen4-unload"
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        await loop.modelLoadingAdvertise(ModelLoadingFixtures.model(id, modelType: "qwen4_exp"))
        let stub = makeInertStubBridge(modelId: id)
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge, modelType: "qwen4_exp")
        #expect(await loop.modelLoadingHasQwen4RetirementWindow() == false)

        #expect(await loop.unloadModel(id) == true)

        #expect(await loop.modelLoadingHasQwen4RetirementWindow())
        #expect(stub.engine.shutdownCalls == 1)
        #expect(await loop.modelLoadingResidentIDs().isEmpty)
    }

    // MARK: - Warm-model state

    @Test("the current model is the one with a live request, else the most recently used")
    func currentModelPrefersLiveRequest() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        let older = makeInertStubBridge(modelId: "test/warm-older")
        let newer = makeInertStubBridge(modelId: "test/warm-newer")
        await loop.modelLoadingInstallSlot(
            "test/warm-older", bridge: older.bridge,
            lastInferenceAt: ContinuousClock.now.advanced(by: .seconds(-60)))
        await loop.modelLoadingInstallSlot("test/warm-newer", bridge: newer.bridge)
        await loop.modelLoadingSetLiveHash("test/warm-older", "hash-older")

        await loop.syncWarmModelState()
        #expect(await loop.modelLoadingWarmState() == ModelLoadingWarmState(
            warmModels: ["test/warm-newer", "test/warm-older"],
            currentModel: "test/warm-newer",
            currentModelHash: nil))

        await loop.modelLoadingSetRequest("request-older", model: "test/warm-older")
        await loop.syncWarmModelState()
        #expect(await loop.modelLoadingWarmState() == ModelLoadingWarmState(
            warmModels: ["test/warm-newer", "test/warm-older"],
            currentModel: "test/warm-older",
            currentModelHash: "hash-older"))
    }

    @Test("warm state is empty when no slot is loaded or the only slot is unloading")
    func warmStateClearsWithoutSlots() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/warm-unloading"
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)

        await loop.syncWarmModelState()
        #expect(await loop.modelLoadingWarmState() == ModelLoadingWarmState(
            warmModels: [], currentModel: nil, currentModelHash: nil))

        let stub = makeInertStubBridge(modelId: id)
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge)
        await loop.modelLoadingSetLiveHash(id, "hash-unloading")
        await loop.syncWarmModelState()
        #expect(await loop.modelLoadingWarmState().currentModel == id)

        await loop.modelLoadingMarkUnloading(id)
        await loop.syncWarmModelState()
        #expect(await loop.modelLoadingWarmState() == ModelLoadingWarmState(
            warmModels: [], currentModel: nil, currentModelHash: nil))
        await loop.modelLoadingFinishUnloading(id)
    }

    @Test("the loaded hash snapshot skips unloading slots and sends empty for unknown hashes")
    func loadedHashSnapshotSkipsUnloadingSlots() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        for id in ["test/hash-known", "test/hash-unknown", "test/hash-unloading"] {
            await loop.modelLoadingInstallSlot(id, bridge: makeInertStubBridge(modelId: id).bridge)
        }
        await loop.modelLoadingSetLiveHash("test/hash-known", "hash-known")
        await loop.modelLoadingSetLiveHash("test/hash-unloading", "hash-unloading")
        await loop.modelLoadingMarkUnloading("test/hash-unloading")

        #expect(await loop.loadedModelHashesSnapshot() == [
            "test/hash-known": "hash-known",
            "test/hash-unknown": "",
        ])
        await loop.modelLoadingFinishUnloading("test/hash-unloading")
    }

    // MARK: - Weight hash records

    @Test("publishing a new hash updates the live hash and the fingerprint")
    func publishNewHash() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/publish-hash"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)],
            modelHashes: [id: "hash-old"], modelHashFingerprints: [id: "fingerprint-old"])

        await loop.publishWeightHash(
            modelId: id,
            snapshot: ProviderLoop.WeightHashSnapshot(
                fingerprint: "fingerprint-new", hash: "hash-new", recomputed: true))

        #expect(await loop.liveModelHashForTesting(id) == "hash-new")
        #expect(await loop.modelLoadingFingerprint(id) == "fingerprint-new")
        // The startup record is separate from the live record.
        #expect(await loop.modelHashForTesting(id) == "hash-old")
    }

    @Test("a failed hash observation never replaces the last known hash")
    func failedObservationKeepsHash() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/publish-failed"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)],
            modelHashes: [id: "hash-old"], modelHashFingerprints: [id: "fingerprint-old"])

        for recomputed in [true, false] {
            await loop.publishWeightHash(
                modelId: id,
                snapshot: ProviderLoop.WeightHashSnapshot(
                    fingerprint: "fingerprint-other", hash: nil, recomputed: recomputed))
            #expect(await loop.liveModelHashForTesting(id) == "hash-old")
            #expect(await loop.modelLoadingFingerprint(id) == "fingerprint-old")
        }
    }

    @Test("publishing the same hash with a new fingerprint updates only the fingerprint")
    func sameHashUpdatesFingerprintOnly() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/publish-same"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)],
            modelHashes: [id: "hash-same"], modelHashFingerprints: [id: "fingerprint-old"])

        await loop.publishWeightHash(
            modelId: id,
            snapshot: ProviderLoop.WeightHashSnapshot(
                fingerprint: "fingerprint-new", hash: "hash-same", recomputed: false))

        #expect(await loop.liveModelHashForTesting(id) == "hash-same")
        #expect(await loop.modelLoadingFingerprint(id) == "fingerprint-new")
    }

    @Test("marking a hash unavailable clears every record and stays cleared on repeat")
    func markHashUnavailableClearsRecords() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/hash-unavailable"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id, weightHash: "hash-old")],
            modelHashes: [id: "hash-old"], modelHashFingerprints: [id: "fingerprint-old"])
        #expect(await loop.advertisedModelWeightHashForTesting(id) == "hash-old")

        await loop.markWeightHashUnavailable(modelId: id)
        #expect(await loop.liveModelHashForTesting(id) == nil)
        #expect(await loop.modelHashForTesting(id) == nil)
        #expect(await loop.modelLoadingFingerprint(id) == nil)
        #expect(await loop.advertisedModelWeightHashForTesting(id) == nil)
        #expect(await loop.isModelAdvertised(id))

        // No previous value: the second call takes the "nothing to remove" path.
        await loop.markWeightHashUnavailable(modelId: id)
        #expect(await loop.liveModelHashForTesting(id) == nil)
        #expect(await loop.isModelAdvertised(id))
    }

    @Test("a hash capture that ends during shutdown throws CancellationError", arguments: [false, true])
    func hashCaptureDuringShutdownCancels(fresh: Bool) async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/hash-shutdown"
        let directory = try sandbox.makeSnapshot("hash-shutdown")
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])
        await loop.beginShutdownForTesting()

        await #expect(throws: CancellationError.self) {
            _ = try await loop.captureWeightHashForTesting(
                modelId: id, modelPath: directory, requireFreshCryptographicHash: fresh)
        }
        #expect(await loop.liveModelHashForTesting(id) == nil)
    }

    @Test("reusable SSD hash decision: equal, different and missing observations")
    func reusableSSDHashDecision() {
        #expect(ProviderLoop.reusableSSDWeightHashDecision(
            preLoadHash: "abc", postLoadHash: "abc") == .eligible("abc"))
        #expect(ProviderLoop.reusableSSDWeightHashDecision(
            preLoadHash: " abc\n", postLoadHash: "abc") == .eligible("abc"))
        #expect(ProviderLoop.reusableSSDWeightHashDecision(
            preLoadHash: "abc", postLoadHash: "def") == .changed)
        #expect(ProviderLoop.reusableSSDWeightHashDecision(
            preLoadHash: nil, postLoadHash: "abc") == .unavailable)
        #expect(ProviderLoop.reusableSSDWeightHashDecision(
            preLoadHash: "abc", postLoadHash: nil) == .unavailable)
        #expect(ProviderLoop.reusableSSDWeightHashDecision(
            preLoadHash: "abc", postLoadHash: "   ") == .unavailable)
    }
}
