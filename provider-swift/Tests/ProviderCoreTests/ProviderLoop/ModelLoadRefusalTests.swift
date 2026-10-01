import Foundation
import Testing

@testable import ProviderCore

/// `ensureModelLoaded` paths that end before any weights load: refusals,
/// waits on another load or unload, the load gate, and the failure cleanup.
/// No test here loads a real model.
@Suite("Model load refusals and waits")
struct ModelLoadRefusalTests {

    // MARK: - Early refusals

    @Test("a load during shutdown throws CancellationError and starts nothing")
    func shutdownRefusesLoad() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/load-during-shutdown"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])
        await loop.beginShutdownForTesting()

        await #expect(throws: CancellationError.self) {
            try await loop.ensureModelLoaded(modelId: id)
        }
        #expect(await loop.modelLoadingInFlightIDs().isEmpty)
        #expect(await loop.modelLoadingResidentIDs().isEmpty)
        #expect(await loop.modelLoadingIsLoadingAny() == false)
    }

    @Test("an id with no local snapshot fails as not found and maps to 404")
    func missingSnapshotIsNotFound() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "darkbloom-tests/absent-\(UUID().uuidString)"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])

        do {
            try await loop.ensureModelLoaded(modelId: id)
            Issue.record("expected the load to fail for a missing snapshot")
        } catch let InferenceError.invalidModelDirectory(message) {
            #expect(message == "Model '\(id)' not found in local HuggingFace cache")
            #expect(ProviderLoop.loadErrorStatusCode(
                for: InferenceError.invalidModelDirectory(message)) == 404)
        }
        #expect(await loop.modelLoadingIsLoadingAny() == false)
    }

    @Test("a snapshot on disk that is not advertised fails with the advertised-list error")
    func unadvertisedSnapshotIsRefused() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/unadvertised-model"
        let directory = try sandbox.makeSnapshot("unadvertised")
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)

        do {
            try await loop.ensureModelLoaded(modelId: id, revisionDirectory: directory)
            Issue.record("expected the load to fail for an unadvertised model")
        } catch let InferenceError.invalidModelDirectory(message) {
            #expect(message == "Model '\(id)' not in advertised model list")
            #expect(ProviderLoop.loadErrorStatusCode(
                for: InferenceError.invalidModelDirectory(message)) == 404)
        }
        #expect(await loop.modelLoadingInFlightIDs().isEmpty)
    }

    @Test("a resident model returns at once and keeps its bridge")
    func residentModelReturnsAtOnce() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/resident-model"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])
        let stub = makeInertStubBridge(modelId: id)
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge)

        try await loop.ensureModelLoaded(modelId: id)

        #expect(await loop.slotBridgeForTesting(modelId: id) === stub.bridge)
        #expect(stub.engine.shutdownCalls == 0)
        #expect(await loop.modelLoadingIsLoadingAny() == false)
    }

    // MARK: - Waiting on an unload of the same model

    @Test("a load waits for the same model's unload, then returns the resident slot")
    func loadWaitsForUnload() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/wait-for-unload"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])
        await loop.modelLoadingMarkUnloading(id)

        let load = Task { try await loop.ensureModelLoaded(modelId: id) }
        let parked = await modelLoadingWaitUntil { await loop.modelLoadingUnloadWaiterCount(id) == 1 }
        #expect(parked)

        let stub = makeInertStubBridge(modelId: id)
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge)
        await loop.modelLoadingFinishUnloading(id)
        try await load.value

        #expect(await loop.slotBridgeForTesting(modelId: id) === stub.bridge)
    }

    @Test("shutdown during the unload wait cancels the load")
    func shutdownDuringUnloadWaitCancels() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/unload-wait-shutdown"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])
        await loop.modelLoadingMarkUnloading(id)

        let load = Task { try await loop.ensureModelLoaded(modelId: id) }
        let parked = await modelLoadingWaitUntil { await loop.modelLoadingUnloadWaiterCount(id) == 1 }
        #expect(parked)

        await loop.beginShutdownForTesting()
        await loop.modelLoadingFinishUnloading(id)
        await #expect(throws: CancellationError.self) { try await load.value }
        #expect(await loop.modelLoadingResidentIDs().isEmpty)
    }

    // MARK: - Waiting on another load of the same model

    @Test("a second load waits for the first and returns the slot it installed")
    func secondLoadUsesFirstLoadSlot() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/second-load-joins"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])
        await loop.modelLoadingMarkLoading(id)

        let load = Task { try await loop.ensureModelLoaded(modelId: id) }
        let parked = await modelLoadingWaitUntil { await loop.modelLoadingLoadingWaiterCount(id) == 1 }
        #expect(parked)

        let stub = makeInertStubBridge(modelId: id)
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge)
        await loop.modelLoadingClearLoading(id)
        await loop.modelLoadingResumeLoadingWaiters(id)
        try await load.value

        #expect(await loop.slotBridgeForTesting(modelId: id) === stub.bridge)
    }

    @Test("a second load gets the first load's failure")
    func secondLoadGetsFirstLoadFailure() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/second-load-failure"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])
        await loop.modelLoadingMarkLoading(id)

        let load = Task { try await loop.ensureModelLoaded(modelId: id) }
        let parked = await modelLoadingWaitUntil { await loop.modelLoadingLoadingWaiterCount(id) == 1 }
        #expect(parked)

        await loop.modelLoadingClearLoading(id)
        await loop.modelLoadingResumeLoadingWaiters(id, failure: "first load failed")
        do {
            try await load.value
            Issue.record("expected the waiting load to get the first failure")
        } catch let InferenceError.modelLoadFailed(message) {
            #expect(message == "first load failed")
        }
        #expect(await loop.modelLoadingResidentIDs().isEmpty)
    }

    @Test("shutdown while waiting on the first load cancels the second load")
    func shutdownWhileWaitingOnFirstLoadCancels() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/second-load-shutdown"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])
        await loop.modelLoadingMarkLoading(id)

        let load = Task { try await loop.ensureModelLoaded(modelId: id) }
        let parked = await modelLoadingWaitUntil { await loop.modelLoadingLoadingWaiterCount(id) == 1 }
        #expect(parked)

        await loop.beginShutdownForTesting()
        await loop.modelLoadingResumeLoadingWaiters(id)
        await #expect(throws: CancellationError.self) { try await load.value }
    }

    @Test("a model that starts retiring during the wait is refused with the retiring error")
    func retiringDuringFirstLoadIsRefused() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/second-load-retiring"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])
        await loop.modelLoadingMarkLoading(id)

        let load = Task { try await loop.ensureModelLoaded(modelId: id) }
        let parked = await modelLoadingWaitUntil { await loop.modelLoadingLoadingWaiterCount(id) == 1 }
        #expect(parked)

        await loop.markRetiringForTesting(id)
        let stub = makeInertStubBridge(modelId: id)
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge)
        await loop.modelLoadingClearLoading(id)
        await loop.modelLoadingResumeLoadingWaiters(id)
        do {
            try await load.value
            Issue.record("expected the retiring model to be refused")
        } catch let InferenceError.invalidModelDirectory(message) {
            #expect(message == "Model '\(id)' slot is retiring after a failed self-test")
            #expect(ProviderLoop.loadErrorStatusCode(
                for: InferenceError.invalidModelDirectory(message)) == 503)
        }
    }

    @Test("after the first load ends with no slot, the second load retries and reports not found")
    func secondLoadRetriesWhenNoSlotAppears() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "darkbloom-tests/retry-absent-\(UUID().uuidString)"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])
        await loop.modelLoadingMarkLoading(id)

        let load = Task { try await loop.ensureModelLoaded(modelId: id) }
        let parked = await modelLoadingWaitUntil { await loop.modelLoadingLoadingWaiterCount(id) == 1 }
        #expect(parked)

        await loop.modelLoadingClearLoading(id)
        await loop.modelLoadingResumeLoadingWaiters(id)
        do {
            try await load.value
            Issue.record("expected the retried load to fail for a missing snapshot")
        } catch let InferenceError.invalidModelDirectory(message) {
            #expect(message == "Model '\(id)' not found in local HuggingFace cache")
        }
    }

    // MARK: - Load gate

    @Test("a load parked at the load gate returns the slot another load installed")
    func loadGateWaiterReturnsResidentSlot() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/load-gate-resident"
        let directory = try sandbox.makeSnapshot("load-gate-resident")
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])
        await loop.modelLoadingSetLoadingAny(true)

        let load = Task { try await loop.ensureModelLoaded(modelId: id, revisionDirectory: directory) }
        let parked = await modelLoadingWaitUntil { await loop.modelLoadingLoadGateWaiterCount() == 1 }
        #expect(parked)

        let stub = makeInertStubBridge(modelId: id)
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge)
        await loop.releaseLoadGateWaiters()
        try await load.value

        #expect(await loop.slotBridgeForTesting(modelId: id) === stub.bridge)
        #expect(await loop.modelLoadingLoadGateWaiterCount() == 0)
        // The waiter returned without taking the gate: the flag is still ours.
        #expect(await loop.modelLoadingIsLoadingAny())
        #expect(await loop.modelLoadingInFlightIDs().isEmpty)
        await loop.modelLoadingSetLoadingAny(false)
    }

    @Test("shutdown while parked at the load gate cancels the load")
    func shutdownAtLoadGateCancels() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/load-gate-shutdown"
        let directory = try sandbox.makeSnapshot("load-gate-shutdown")
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])
        await loop.modelLoadingSetLoadingAny(true)

        let load = Task { try await loop.ensureModelLoaded(modelId: id, revisionDirectory: directory) }
        let parked = await modelLoadingWaitUntil { await loop.modelLoadingLoadGateWaiterCount() == 1 }
        #expect(parked)

        await loop.beginShutdownForTesting()
        await loop.releaseLoadGateWaiters()
        await #expect(throws: CancellationError.self) { try await load.value }
        #expect(await loop.modelLoadingResidentIDs().isEmpty)
        #expect(await loop.modelLoadingInFlightIDs().isEmpty)
    }

    // MARK: - Slot cap

    @Test("all slots busy with live requests: the load is refused with a 503 slot error")
    func busySlotsRefuseLoad() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/slot-cap-target"
        let directory = try sandbox.makeSnapshot("slot-cap-target")
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox,
            models: [
                ModelLoadingFixtures.model("test/slot-busy-a"),
                ModelLoadingFixtures.model("test/slot-busy-b"),
                ModelLoadingFixtures.model(id),
            ],
            maxModelSlots: 2)
        let first = makeInertStubBridge(modelId: "test/slot-busy-a")
        let second = makeInertStubBridge(modelId: "test/slot-busy-b")
        await loop.modelLoadingInstallSlot("test/slot-busy-a", bridge: first.bridge)
        await loop.modelLoadingInstallSlot("test/slot-busy-b", bridge: second.bridge)
        await loop.modelLoadingSetRequest("request-a", model: "test/slot-busy-a")
        await loop.modelLoadingSetRequest("request-b", model: "test/slot-busy-b")

        do {
            try await loop.ensureModelLoaded(modelId: id, revisionDirectory: directory)
            Issue.record("expected the load to be refused at the slot cap")
        } catch let InferenceError.invalidModelDirectory(message) {
            #expect(message == "All 2 model slot(s) are active; cannot load '\(id)'")
            #expect(ProviderLoop.loadErrorStatusCode(
                for: InferenceError.invalidModelDirectory(message)) == 503)
        }

        #expect(await loop.modelLoadingResidentIDs() == ["test/slot-busy-a", "test/slot-busy-b"])
        #expect(first.engine.shutdownCalls == 0)
        #expect(second.engine.shutdownCalls == 0)
        #expect(await loop.modelLoadingIsLoadingAny() == false)
    }

    // MARK: - Memory admission and failure cleanup

    @Test("a memory refusal is recorded for doctor and the loop state is reset")
    func memoryRefusalIsRecorded() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/memory-refusal"
        let directory = try sandbox.makeSnapshot("memory-refusal")
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 0)

        do {
            try await loop.ensureModelLoaded(
                modelId: id, allowEviction: false, revisionDirectory: directory)
            Issue.record("expected the memory gate to refuse the load")
        } catch let InferenceError.modelLoadFailed(message) {
            #expect(message.hasPrefix("Insufficient memory (0.0 GB free, need "))
            #expect(message.hasSuffix("to load without evicting resident models"))
            let recorded = await loop.modelLoadingLastLoadError()
            #expect(recorded?.model == id)
            #expect(recorded?.message == message)
        }

        #expect(FileManager.default.fileExists(atPath: sandbox.daemonStateFile.path))
        #expect(await loop.modelLoadingInFlightIDs().isEmpty)
        #expect(await loop.modelLoadingIsLoadingAny() == false)
        #expect(await loop.outstandingKVReservationBytesForTesting() == 0)
    }

    @Test("a load that cannot claim its memory at final admission fails and holds nothing")
    func finalAdmissionRefusal() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/final-admission"
        let directory = try sandbox.makeSnapshot("final-admission")
        // The advisory sample says there is room; the scripted 4 GiB machine
        // cannot hold a 100 GB claim.
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id, memoryGb: 100)],
            physicalBytes: 4 << 30)
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 1_000_000)

        do {
            try await loop.ensureModelLoaded(modelId: id, revisionDirectory: directory)
            Issue.record("expected the final admission to refuse the load")
        } catch let InferenceError.modelLoadFailed(message) {
            #expect(message == "Insufficient memory for '\(id)' at final load admission")
            #expect(ProviderLoop.loadErrorStatusCode(
                for: InferenceError.modelLoadFailed(message)) == 503)
        }

        #expect(await loop.outstandingKVReservationBytesForTesting() == 0)
        #expect(await loop.modelLoadingInFlightIDs().isEmpty)
        #expect(await loop.modelLoadingIsLoadingAny() == false)
        #expect(await loop.modelLoadingResidentIDs().isEmpty)
    }

    @Test("shutdown in the before-load hook cancels the load and releases its claim")
    func shutdownInBeforeLoadHookCancels() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/before-load-shutdown"
        let directory = try sandbox.makeSnapshot("before-load-shutdown")
        let recorder = ModelLoadHookRecorder()
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)],
            beforeModelLoad: { modelId in await recorder.recordAndShutDown(modelId) })
        await recorder.attach(loop)
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 1_000_000)

        await #expect(throws: CancellationError.self) {
            try await loop.ensureModelLoaded(modelId: id, revisionDirectory: directory)
        }

        #expect(await recorder.seen == [id])
        #expect(await loop.outstandingKVReservationBytesForTesting() == 0)
        #expect(await loop.modelLoadingInFlightIDs().isEmpty)
        #expect(await loop.modelLoadingIsLoadingAny() == false)
        #expect(await loop.modelLoadingResidentIDs().isEmpty)
    }

    @Test("a changed native Qwen4 load footprint stops the load before weights load")
    func changedQwen4FootprintStopsLoad() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/footprint-changed"
        let directory = try sandbox.makeSnapshot("footprint-changed")
        // A declared transient size with no offload figure cannot be
        // re-checked, so the footprint counts as changed.
        let info = ModelInfo(
            id: id, modelType: "gpt_oss", sizeBytes: 1 << 20, estimatedMemoryGb: 0.01,
            nativeLoadTransientBytes: 1)
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox, models: [info])
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 1_000_000)

        do {
            try await loop.ensureModelLoaded(modelId: id, revisionDirectory: directory)
            Issue.record("expected the footprint check to stop the load")
        } catch let InferenceError.modelLoadFailed(message) {
            #expect(message == "Native Qwen4 loading footprint changed after admission; rescan the model")
        }

        #expect(await loop.outstandingKVReservationBytesForTesting() == 0)
        #expect(await loop.modelLoadingInFlightIDs().isEmpty)
        #expect(await loop.modelLoadingIsLoadingAny() == false)
    }

    @Test("a container load error from the model config is passed through unchanged")
    func containerLoadErrorPassesThrough() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/container-load-error"
        // The config names a model type that only the managed native path can
        // load, so the generic loader refuses it before any weights are read.
        let directory = try sandbox.makeSnapshot(
            "container-load-error", config: #"{"model_type":"mimo_v2"}"#)
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id)])
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 1_000_000)

        await #expect(throws: MiMoV26ServingLoadError.managedLoadRequired) {
            try await loop.ensureModelLoaded(modelId: id, revisionDirectory: directory)
        }

        #expect(ProviderLoop.loadErrorStatusCode(
            for: MiMoV26ServingLoadError.managedLoadRequired) == 500)
        #expect(await loop.outstandingKVReservationBytesForTesting() == 0)
        #expect(await loop.modelLoadingInFlightIDs().isEmpty)
        #expect(await loop.modelLoadingIsLoadingAny() == false)
        #expect(await loop.modelLoadingResidentIDs().isEmpty)
    }
}
