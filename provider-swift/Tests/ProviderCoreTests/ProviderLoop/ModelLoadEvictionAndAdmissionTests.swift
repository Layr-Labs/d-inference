import Foundation
import Testing

@testable import ProviderCore

/// Memory admission for model loads: eviction until the load fits, the fast
/// pre-accept reject, the activation reserve push, and the load-error status
/// mapping. Memory samples are pinned through the slot hooks; no weights load.
@Suite("Model load memory admission")
struct ModelLoadEvictionAndAdmissionTests {

    // MARK: - evictUntilAvailable

    @Test("eviction during shutdown throws CancellationError")
    func evictionDuringShutdownCancels() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 1_000)
        await loop.beginShutdownForTesting()

        await #expect(throws: CancellationError.self) {
            try await loop.evictUntilAvailable(weightsGb: 1)
        }
    }

    @Test("enough free memory: no eviction happens")
    func enoughMemoryEvictsNothing() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/idle-resident"
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 1_000)
        let stub = makeInertStubBridge(modelId: id)
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge)

        try await loop.evictUntilAvailable(weightsGb: 1)

        #expect(await loop.modelLoadingResidentIDs() == [id])
        #expect(stub.engine.shutdownCalls == 0)
    }

    @Test("when evicting every idle model cannot make room, nothing is evicted")
    func infeasibleEvictionRefusesWithoutEvicting() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/small-idle"
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 0)
        let stub = makeInertStubBridge(modelId: id)
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge, weightsBytes: 0)

        do {
            try await loop.evictUntilAvailable(weightsGb: 100_000)
            Issue.record("expected the eviction feasibility check to refuse")
        } catch let InferenceError.modelLoadFailed(message) {
            #expect(message.hasPrefix("Insufficient memory (0.0 GB free, need "))
            #expect(message.contains("even after evicting every idle model"))
            #expect(message.hasSuffix("refusing without evicting"))
        }

        #expect(await loop.modelLoadingResidentIDs() == [id])
        #expect(stub.engine.shutdownCalls == 0)
    }

    @Test("an idle model is evicted; if memory is still short the load is refused")
    func evictsIdleModelThenRefuses() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/large-idle"
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        // The pinned sample never changes, so freeing the slot cannot make
        // room; the eviction itself must still happen first.
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 1)
        let stub = makeInertStubBridge(modelId: id)
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge, weightsBytes: 100 << 30)

        do {
            try await loop.evictUntilAvailable(weightsGb: 10)
            Issue.record("expected the load to be refused after the eviction")
        } catch let InferenceError.modelLoadFailed(message) {
            #expect(message.hasPrefix("Insufficient memory (1.0 GB free, need "))
            #expect(message.hasSuffix("and all loaded models are actively serving"))
        }

        #expect(await loop.modelLoadingResidentIDs().isEmpty)
        #expect(stub.engine.shutdownCalls == 1)
    }

    @Test("a model with a live request is never evicted")
    func busyModelIsNotEvicted() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/busy-large"
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 0)
        let stub = makeInertStubBridge(modelId: id)
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge, weightsBytes: 100 << 30)
        await loop.modelLoadingSetRequest("request-busy", model: id)

        do {
            try await loop.evictUntilAvailable(weightsGb: 10)
            Issue.record("expected the load to be refused")
        } catch let InferenceError.modelLoadFailed(message) {
            #expect(message.hasSuffix("and all loaded models are actively serving"))
        }

        #expect(await loop.modelLoadingResidentIDs() == [id])
        #expect(stub.engine.shutdownCalls == 0)
    }

    @Test("with eviction disabled an idle model stays and the load is refused")
    func noEvictKeepsIdleModel() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/kept-idle"
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 0)
        let stub = makeInertStubBridge(modelId: id)
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge, weightsBytes: 100 << 30)

        do {
            try await loop.evictUntilAvailable(weightsGb: 10, allowEviction: false)
            Issue.record("expected the no-evict load to be refused")
        } catch let InferenceError.modelLoadFailed(message) {
            #expect(message.hasSuffix("to load without evicting resident models"))
        }

        #expect(await loop.modelLoadingResidentIDs() == [id])
        #expect(stub.engine.shutdownCalls == 0)
    }

    // MARK: - fastAdmissionReject

    @Test("fast admission accepts an advertised model when memory is free")
    func fastAdmissionAcceptsWhenMemoryIsFree() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/fast-free"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id, memoryGb: 1)])
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 1_000)

        #expect(await loop.fastAdmissionReject(modelId: id) == false)
    }

    @Test("fast admission rejects when evicting every idle model cannot make room")
    func fastAdmissionRejectsInfeasibleEviction() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/fast-infeasible"
        let idle = "test/fast-small-idle"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox,
            models: [
                ModelLoadingFixtures.model(id, memoryGb: 100_000),
                ModelLoadingFixtures.model(idle),
            ])
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 0)
        let stub = makeInertStubBridge(modelId: idle)
        await loop.modelLoadingInstallSlot(idle, bridge: stub.bridge, weightsBytes: 0)

        #expect(await loop.fastAdmissionReject(modelId: id) == true)
        // Fast admission is read-only: the idle model is still resident.
        #expect(await loop.modelLoadingResidentIDs() == [idle])
        #expect(stub.engine.shutdownCalls == 0)
    }

    @Test("fast admission rejects when memory is short and nothing can be evicted")
    func fastAdmissionRejectsWithoutEvictableModels() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/fast-no-room"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model(id, memoryGb: 1)])
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 0)

        #expect(await loop.fastAdmissionReject(modelId: id) == true)
    }

    @Test("fast admission accepts when evicting an idle model can make room")
    func fastAdmissionAcceptsFeasibleEviction() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/fast-feasible"
        let idle = "test/fast-large-idle"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox,
            models: [
                ModelLoadingFixtures.model(id, memoryGb: 10),
                ModelLoadingFixtures.model(idle),
            ])
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 0)
        let stub = makeInertStubBridge(modelId: idle)
        await loop.modelLoadingInstallSlot(idle, bridge: stub.bridge, weightsBytes: 100 << 30)

        #expect(await loop.fastAdmissionReject(modelId: id) == false)
        #expect(await loop.modelLoadingResidentIDs() == [idle])
    }

    @Test("fast admission rejects when every slot is busy, even with free memory")
    func fastAdmissionRejectsFullBusySlots() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/fast-slot-cap"
        let busy = "test/fast-busy"
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox,
            models: [ModelLoadingFixtures.model(id), ModelLoadingFixtures.model(busy)],
            maxModelSlots: 1)
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 1_000)
        await loop.modelLoadingInstallSlot(busy, bridge: makeInertStubBridge(modelId: busy).bridge)
        await loop.modelLoadingSetRequest("request-busy", model: busy)

        #expect(await loop.maxModelSlotsForTesting() == 1)
        #expect(await loop.fastAdmissionReject(modelId: id) == true)

        // Control: once the request ends the slot is evictable again.
        await loop.modelLoadingSetRequest("request-busy", model: nil)
        #expect(await loop.fastAdmissionReject(modelId: id) == false)
    }

    @Test("fast admission rejects a removed build whose self-test failed")
    func fastAdmissionRejectsFailedSelfTestBuild() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let id = "test/fast-failed-build"
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 1_000)
        #expect(await loop.fastAdmissionReject(modelId: id) == false)

        await loop.modelLoadingMarkFailedSelfTest(id, hash: "hash-failed")

        #expect(await loop.fastAdmissionReject(modelId: id) == true)
        do {
            try await loop.throwIfRetiring(id)
            Issue.record("expected the failed build to be refused")
        } catch let InferenceError.invalidModelDirectory(message) {
            #expect(message == "Model '\(id)' slot is retiring after a failed self-test")
        }
    }

    // MARK: - Memory figures and the activation reserve

    @Test("the load memory sample comes from the hook when set, else from the budget")
    func availableMemorySource() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        let budget = await loop.kvBudgetForTesting()

        #expect(await loop.availableMemoryGb() == budget.availableForLoadGb())

        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 12.5)
        #expect(await loop.availableMemoryGb() == 12.5)
    }

    @Test("reserve pushes reach the budget in order and the load headroom follows the reserve")
    func activationReservePushes() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let loop = try await ModelLoadingFixtures.makeLoop(
            sandbox: sandbox, models: [ModelLoadingFixtures.model("test/reserve-model")])
        let budget = await loop.kvBudgetForTesting()
        #expect(await loop.modelLoadingReserveEpoch() == 0)

        await loop.refreshActivationReserve()
        let resolved = await loop.resolvedActivationReserveBytes
        #expect(budget.memoryHeadroomSnapshot().activationReserveBytes == resolved)
        #expect(await loop.modelLoadingReserveEpoch() == 1)

        let raised: UInt64 = 40 << 30
        await loop.pushActivationReserve(raised)
        #expect(budget.memoryHeadroomSnapshot().activationReserveBytes == raised)
        #expect(await loop.modelLoadingReserveEpoch() == 2)

        let expectedHeadroomGb = Double(UnifiedMemoryCap.loadHeadroomBytes(
            activationReserveBytes: resolved)) / (1024.0 * 1024.0 * 1024.0)
        #expect(await loop.loadHeadroomGb == expectedHeadroomGb)
    }

    // MARK: - Load error mapping and the VLM check

    @Test("load errors map to 503 for capacity, 404 for missing, 500 for faults")
    func loadErrorStatusCodes() {
        let cases: [(any Error, UInt16)] = [
            (InferenceError.invalidModelDirectory("All 2 model slot(s) are active; cannot load 'x'"), 503),
            (InferenceError.invalidModelDirectory("config.json is malformed"), 500),
            (InferenceError.noModelLoaded, 500),
            (InferenceError.generationFailed("decode failed"), 500),
            (InferenceError.unsupportedRole("tool"), 500),
            (CancellationError(), 500),
        ]
        for (error, status) in cases {
            #expect(ProviderLoop.loadErrorStatusCode(for: error) == status, "\(error)")
        }

        let capacity = ProviderLoop.loadInferenceFailure(
            for: InferenceError.invalidModelDirectory("All 1 model slot(s) are active; cannot load 'x'"))
        #expect(capacity.code == .capacity)
        #expect(capacity.statusCode == 503)

        let missing = ProviderLoop.loadInferenceFailure(
            for: InferenceError.invalidModelDirectory("Model 'x' not in advertised model list"))
        #expect(missing.code == .modelUnavailable)
        #expect(missing.statusCode == 404)

        let fault = ProviderLoop.loadInferenceFailure(
            for: InferenceError.invalidModelDirectory("config.json is malformed"))
        #expect(fault.code == .internalFailure)
        #expect(fault.statusCode == 500)
        #expect(fault.errorReason == .modelLoad)
    }

    @Test("a model is a VLM only when its config declares vision and does not opt out")
    func modelIsVLMReadsConfig() throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let vision = try sandbox.makeSnapshot(
            "vision", config: #"{"model_type":"gemma4","vision_config":{}}"#)
        let optedOut = try sandbox.makeSnapshot(
            "vision-opt-out",
            config: #"{"model_type":"gemma4","vision_config":{},"language_model_only":true}"#)
        let textOnly = try sandbox.makeSnapshot("text-only")
        let noConfig = sandbox.root.appendingPathComponent("no-config", isDirectory: true)

        #expect(ProviderLoop.modelIsVLM(at: vision))
        #expect(ProviderLoop.modelIsVLM(at: optedOut) == false)
        #expect(ProviderLoop.modelIsVLM(at: textOnly) == false)
        #expect(ProviderLoop.modelIsVLM(at: noConfig) == false)
    }
}
