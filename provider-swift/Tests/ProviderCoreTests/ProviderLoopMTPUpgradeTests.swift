import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

private let upgradeModelID = "gemma-4-26b-qat-4bit"

private func upgradeQuote(state: ProviderState, modelID: String) -> ProviderMessage.CapacityQuote {
    CapacityQuoteEngine.quote(.init(
        probe: .init(quoteId: "upgrade-quote", model: modelID,
            promptTokensBucket: 512, maxOutputTokens: 128,
            requiresVision: false, visionImageCount: 0, deadlineRemainingMs: 9000),
        capacity: state.publishedCapacity,
        model: ModelInfo(id: modelID, sizeBytes: 1, estimatedMemoryGb: 1),
        ttft: nil,
        visionLimits: .init(maxBufferBytes: 38 << 30, attentionElementBytes: 2, headFactor: 1),
        refusingNewWork: state.refusingNewWork(forModel: modelID)))
}

private final class UpgradeMessageCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    func append(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    var all: [OutboundMessage] { lock.withLock { messages } }
}

private final class UpgradeScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int
    private var busy = false
    private var stops = 0
    private var reads = 0
    private let shutdownBarrier: UpgradeBarrier?
    init(bytes: Int, shutdownBarrier: UpgradeBarrier? = nil) {
        self.bytes = bytes
        self.shutdownBarrier = shutdownBarrier
    }
    var shutdownCount: Int { lock.withLock { stops } }
    var capacityReadCount: Int { lock.withLock { reads } }
    func setBusy(_ value: Bool) { lock.withLock { busy = value } }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> { AsyncStream { $0.finish() } }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            reads += 1
            return .init(activeRequests: busy ? 1 : 0, waitingRequests: 0,
                kvBytesInUse: 0, kvBytesCapacity: bytes, activeTokens: 0, stepsExecuted: 0)
        }
    }
    func updateKVBytesCapacity(_ bytes: Int) { lock.withLock { self.bytes = bytes } }
    func shutdown() async {
        lock.withLock { stops += 1 }
        await shutdownBarrier?.wait()
    }
}

private final class UpgradeScriptedFactory: @unchecked Sendable {
    enum Failure: Error { case injected }
    private let lock = NSLock()
    private var fail = false
    private var built: [UpgradeScriptedEngine] = []
    func failBuild() { lock.withLock { fail = true } }
    var latest: UpgradeScriptedEngine? { lock.withLock { built.last } }
    func make(_ bytes: Int) throws -> UpgradeScriptedEngine {
        try lock.withLock {
            if fail { throw Failure.injected }
            let engine = UpgradeScriptedEngine(bytes: bytes)
            built.append(engine)
            return engine
        }
    }
}

final class UpgradeWeakTarget: @unchecked Sendable {
    weak var container: ModelContainer?
    init(_ container: ModelContainer?) { self.container = container }
}

struct UpgradePausedAssistantLoader: ProviderMTPAssistantLoading {
    let gate: UpgradeBarrier?
    func loadAndBind(artifact: SpecDecArtifact,
                     target: any LanguageModel) async throws -> ProviderMTPAssistantHandle {
        await gate?.wait()
        return try await MTPFloorAssistantLoader().loadAndBind(artifact: artifact, target: target)
    }
}

actor UpgradeBlockedCachedCatalog: SpecDecCatalogLooking {
    let gate: UpgradeBarrier
    init(_ gate: UpgradeBarrier) { self.gate = gate }
    func cachedModel(id: String) async -> CatalogModel? { await gate.wait(); return nil }
    func model(id: String) async throws -> CatalogModel? { nil }
}

private struct ProviderUpgradeFixture {
    let loop: ProviderLoop
    let runtime: EngineV2Runtime
    let original: EngineV2Bridge
    let originalEngine: UpgradeScriptedEngine
    let factory: UpgradeScriptedFactory
    let telemetry: UpgradePostureSink
    let artifact: SpecDecArtifact
    let targetDirectory: URL

    static func make(shutdownBarrier: UpgradeBarrier? = nil,
                     useLocalAssistant: Bool = true, assistantBarrier: UpgradeBarrier? = nil,
                     availableMemoryGb: Double? = nil) async throws -> Self {
        let artifact = try mtpFloorArtifact()
        let targetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtp-upgrade-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: targetDirectory.appendingPathComponent("config.json"))
        let loop = try mtpFloorLoop(models: [ModelInfo(id: upgradeModelID,
            modelType: "gemma4", sizeBytes: 1, estimatedMemoryGb: 1)],
            mtpDrafterPath: useLocalAssistant ? artifact.directory.path : nil, mtpMode: .auto)
        let runtime = EngineV2Runtime()
        let telemetry = UpgradePostureSink()
        let factory = UpgradeScriptedFactory()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(.init(
            emitTelemetry: { telemetry.record($0) }, physicalMemoryBytes: 64 << 30,
            availableMemoryGb: availableMemoryGb,
            assistantLoader: UpgradePausedAssistantLoader(gate: assistantBarrier),
            makeEngine: { _, bytes in try factory.make(bytes) }))
        let engine = UpgradeScriptedEngine(bytes: 1 << 30, shutdownBarrier: shutdownBarrier)
        let bridge = EngineV2Bridge(engine: engine, modelId: upgradeModelID,
            tokenizer: TokenizerHandle(MTPFloorTokenizer()), eosTokenIds: [], kvBytesPerToken: 20_480)
        await runtime.register(modelId: upgradeModelID, bridge: bridge)
        await loop.installModelSlotForTesting(modelId: upgradeModelID,
            container: mtpFloorContainer(), tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            engineV2: bridge, sizing: mtpFloorSizing(weightsGiB: 1), modelType: "gemma4")
        return Self(loop: loop, runtime: runtime, original: bridge, originalEngine: engine,
            factory: factory, telemetry: telemetry, artifact: artifact, targetDirectory: targetDirectory)
    }

    func prepare() async throws -> StagedProviderMTPUpgrade? {
        try await loop.prepareMTPUpgrade(upgradeModelID, modelDirectory: targetDirectory)
    }

    func checkOriginal() async {
        #expect(await loop.slotBridgeForTesting(modelId: upgradeModelID) === original)
        #expect(await runtime.bridge(forModel: upgradeModelID) === original)
        #expect(originalEngine.shutdownCount == 0)
    }
    func clean() async {
        await loop.beginShutdownForTesting()
        if let bridge = await runtime.unregister(modelId: upgradeModelID) { await bridge.shutdown() }
        await loop.removeModelSlotForTesting(modelId: upgradeModelID)
        cleanFiles()
    }
    func cleanFiles() {
        try? FileManager.default.removeItem(at: artifact.directory)
        try? FileManager.default.removeItem(at: targetDirectory)
    }
}

private extension ProviderLoop {
    func setUpgradeCoordinatorPin(_ pinned: Bool) {
        requestToModel["upgrade-test-request"] = pinned ? upgradeModelID : nil
    }
    func hasUpgradeCoordinatorPin() -> Bool { requestToModel["upgrade-test-request"] == upgradeModelID }
    func upgradeDrainActive() -> Bool { mtpAdmissionDrains.contains(upgradeModelID) }
    func upgradePublicationActive() -> Bool { mtpUpgradeTransitions.contains(upgradeModelID) }
    func advertiseUpgradePeer(_ modelID: String) {
        advertisedModels[modelID] = ModelInfo(id: modelID, modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1)
    }
    func weakUpgradeTarget() -> UpgradeWeakTarget { UpgradeWeakTarget(modelSlots[upgradeModelID]?.container) }
    func configureUpgradeEvictionProbe() {
        advertisedModels["upgrade-cold"] = ModelInfo(id: "upgrade-cold",
            modelType: "gemma4", sizeBytes: 1, estimatedMemoryGb: 1)
        if let slot = modelSlots[upgradeModelID] {
            modelSlots[upgradeModelID] = ModelSlot(engineBundle: slot.engineBundle,
                container: slot.container, tokenizer: slot.tokenizer,
                sizing: mtpFloorSizing(weightsGiB: 50),
                cacheEligibleWeightHash: slot.cacheEligibleWeightHash,
                isVLM: slot.isVLM, modelType: slot.modelType,
                lastInferenceAt: slot.lastInferenceAt)
        }
    }
    func upgradeResliceWaiterCount() -> Int { resliceGateWaiters.count }
    func upgradeAdmissionWaiterCount() -> Int { mtpUpgradeWaiters[upgradeModelID]?.count ?? 0 }
}

@Suite("ProviderLoop assistant upgrade integration", .serialized)
struct ProviderLoopMTPUpgradeTests {
    init() { _ = LiveInferenceFixtures.ensureMetallibColocated() }

    @Test("coordinator pins, local acquisition and engine capacity block the real publication")
    func realReservationsKeepOldEngineUntilIdle() async throws {
        let fixture = try await ProviderUpgradeFixture.make()
        defer { fixture.cleanFiles() }
        let staged = try #require(try await fixture.prepare())
        #expect(fixture.telemetry.postureCount == 0)
        #expect(await fixture.loop.outstandingKVReservationBytesForTesting() > 0)
        await fixture.checkOriginal()
        await fixture.loop.setUpgradeCoordinatorPin(true)
        #expect(try await !fixture.loop.commitMTPUpgradeIfIdle(staged))
        await fixture.loop.setUpgradeCoordinatorPin(false)
        let acquired = try await fixture.loop.acquireModelForLocal(upgradeModelID)
        #expect(acquired.engineV2Bridge === fixture.original)
        #expect(try await !fixture.loop.commitMTPUpgradeIfIdle(staged))
        await acquired.releaseToken.fire()
        fixture.originalEngine.setBusy(true)
        #expect(try await !fixture.loop.commitMTPUpgradeIfIdle(staged))
        fixture.originalEngine.setBusy(false)
        await fixture.checkOriginal()
        #expect(try await fixture.loop.commitMTPUpgradeIfIdle(staged))
        #expect(await fixture.loop.slotBridgeForTesting(modelId: upgradeModelID) === staged.replacement.bridge)
        #expect(await fixture.runtime.bridge(forModel: upgradeModelID) === staged.replacement.bridge)
        #expect(await fixture.loop.slotMTPStatusForTesting(modelId: upgradeModelID)?.active == true)
        #expect(fixture.originalEngine.shutdownCount == 1)
        #expect(fixture.telemetry.postureCount == 1)
        #expect(await fixture.loop.outstandingKVReservationBytesForTesting() == 0)
        await fixture.clean()
    }

    @Test("stale original after unload and reload cannot replace the new runtime")
    func staleOriginalCannotPublish() async throws {
        let fixture = try await ProviderUpgradeFixture.make()
        defer { fixture.cleanFiles() }
        let staged = try #require(try await fixture.prepare())
        let oldTarget = await fixture.loop.weakUpgradeTarget()
        await fixture.runtime.unregister(modelId: upgradeModelID)
        await fixture.loop.removeModelSlotForTesting(modelId: upgradeModelID)
        await fixture.original.shutdown()
        let reloadedEngine = UpgradeScriptedEngine(bytes: 1 << 30)
        let reloaded = EngineV2Bridge(engine: reloadedEngine, modelId: upgradeModelID,
            tokenizer: TokenizerHandle(MTPFloorTokenizer()), eosTokenIds: [])
        await fixture.runtime.register(modelId: upgradeModelID, bridge: reloaded)
        await fixture.loop.installModelSlotForTesting(modelId: upgradeModelID,
            container: mtpFloorContainer(), tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            engineV2: reloaded, sizing: mtpFloorSizing(weightsGiB: 1), modelType: "gemma4")
        await #expect(throws: CancellationError.self) {
            _ = try await fixture.loop.commitMTPUpgradeIfIdle(staged)
        }
        #expect(oldTarget.container != nil, "stale candidate still retains the original target")
        await fixture.loop.discardMTPUpgrade(staged)
        #expect(oldTarget.container == nil, "discard releases actual target ownership before removing its charge")
        #expect(await fixture.loop.slotBridgeForTesting(modelId: upgradeModelID) === reloaded)
        #expect(await fixture.runtime.bridge(forModel: upgradeModelID) === reloaded)
        #expect(reloadedEngine.shutdownCount == 0)
        #expect(fixture.factory.latest?.shutdownCount == 1)
        #expect(await fixture.loop.outstandingKVReservationBytesForTesting() == 0)
        await fixture.clean()
    }

    @Test("local admission waits through publication and acquires the replacement bridge")
    func admissionDuringPublicationSeesCoherentReplacement() async throws {
        let shutdown = UpgradeBarrier()
        let fixture = try await ProviderUpgradeFixture.make(shutdownBarrier: shutdown)
        defer { fixture.cleanFiles() }
        let staged = try #require(try await fixture.prepare())
        let commit = Task { try await fixture.loop.commitMTPUpgradeIfIdle(staged) }
        await shutdown.observeEntry()
        #expect(await fixture.loop.slotBridgeForTesting(modelId: upgradeModelID) === staged.replacement.bridge)
        #expect(await fixture.runtime.bridge(forModel: upgradeModelID) === staged.replacement.bridge)
        let admission = Task { try await fixture.loop.acquireModelForLocal(upgradeModelID) }
        for _ in 0..<2_000 {
            if await fixture.loop.upgradeAdmissionWaiterCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await fixture.loop.upgradeAdmissionWaiterCount() > 0)
        #expect(await !fixture.loop.hasLocalReservation(upgradeModelID))
        await shutdown.release()
        #expect(try await commit.value)
        let acquired = try await admission.value
        #expect(acquired.engineV2Bridge === staged.replacement.bridge)
        await acquired.releaseToken.fire()
        #expect(await fixture.loop.outstandingKVReservationBytesForTesting() == 0)
        await fixture.clean()
    }

    @Test("actual preparation build failure releases its lease and keeps the original registered")
    func failedBuildUnwindsActualPreparation() async throws {
        let gate = UpgradeBarrier()
        let fixture = try await ProviderUpgradeFixture.make(assistantBarrier: gate)
        defer { fixture.cleanFiles() }
        await fixture.loop.resliceGrowSurvivors()
        let fullGrant = await fixture.original.engineKVBytesCapacity()
        fixture.factory.failBuild()
        let preparation = Task { try await fixture.prepare() }
        await gate.observeEntry()
        await fixture.loop.resliceGrowSurvivors()
        #expect(await fixture.original.engineKVBytesCapacity() < fullGrant)
        await gate.release()
        await #expect(throws: UpgradeScriptedFactory.Failure.self) {
            _ = try await preparation.value
        }
        #expect(await fixture.original.engineKVBytesCapacity() == fullGrant)
        await fixture.checkOriginal()
        #expect(await fixture.loop.outstandingKVReservationBytesForTesting() == 0)
        await fixture.clean()
    }

    @Test("cancellation or shutdown while queued on the reslice gate cannot publish", arguments: [false, true])
    func interruptionWhileWaitingForGate(shutdown: Bool) async throws {
        let fixture = try await ProviderUpgradeFixture.make()
        defer { fixture.cleanFiles() }
        let staged = try #require(try await fixture.prepare())
        await fixture.loop.acquireResliceGateForTesting()
        let task = Task {
            await MTPIdleUpgrade.run(prepare: { staged },
                beginDrain: { try await fixture.loop.beginMTPUpgradeDrain($0) },
                commitIfIdle: { try await fixture.loop.commitMTPUpgradeIfIdle($0) },
                discard: { await fixture.loop.discardMTPUpgrade($0) },
                finishDrain: { await fixture.loop.finishMTPUpgradeDrain($0) }, pause: {})
        }
        for _ in 0..<2_000 {
            if await fixture.loop.upgradeResliceWaiterCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let waiting = await fixture.loop.upgradeResliceWaiterCount() > 0
        if shutdown { await fixture.loop.beginShutdownForTesting() }
        else { task.cancel() }
        await fixture.loop.releaseResliceGateForTesting()
        #expect(waiting, "test must interrupt the real actor while queued for reslice")
        #expect(await task.value == .cancelled)
        await fixture.checkOriginal()
        #expect(fixture.factory.latest?.shutdownCount == 1)
        #expect(await fixture.loop.outstandingKVReservationBytesForTesting() == 0)
        await fixture.clean()
    }

    @Test("target is not eviction credit during the first preparation await, before any staging lease")
    func preparingTargetExcludedFromAdmissionAndEviction() async throws {
        let fixture = try await ProviderUpgradeFixture.make(useLocalAssistant: false, availableMemoryGb: 0)
        defer { fixture.cleanFiles() }
        let gate = UpgradeBarrier()
        let funnel = SpecDecArtifactFunnel(resolver: SpecDecResolver(), catalog: UpgradeBlockedCachedCatalog(gate))
        await fixture.loop.setSpecDecFunnelForTesting(funnel)
        await fixture.loop.configureUpgradeEvictionProbe()
        await fixture.loop.updateAggregateCapacity()
        let priorReads = fixture.originalEngine.capacityReadCount
        let preparation = Task { try await fixture.prepare() }
        await gate.observeEntry()
        #expect(fixture.originalEngine.capacityReadCount > priorReads,
            "preparation must publish capacity before waiting for catalog lookup")
        #expect(await fixture.loop.isMTPUpgradeTargetRetained(upgradeModelID))
        #expect(await fixture.loop.outstandingKVReservationBytesForTesting() == 0)
        // A snapshot was republished before entering the blocked catalog call.
        let heldQuote = try #require(await fixture.loop.backendCapacityForTesting())
        #expect(heldQuote.slots.count == 1)
        #expect(await fixture.loop.fastAdmissionReject(modelId: "upgrade-cold"))
        #expect(await !fixture.loop.unloadModel(upgradeModelID, forEviction: true),
            "the unload mutation itself must recheck a newly retained target")
        await #expect(throws: (any Error).self) {
            try await fixture.loop.evictUntilAvailable(weightsGb: 1)
        }
        await fixture.checkOriginal()
        await gate.release()
        #expect(try await preparation.value == nil)
        #expect(await !fixture.loop.isMTPUpgradeTargetRetained(upgradeModelID))
        // The same idle target becomes legitimate eviction credit afterward.
        #expect(await !fixture.loop.fastAdmissionReject(modelId: "upgrade-cold"))
        await fixture.clean()
    }

    @Test("staging immediately clamps advertised capacity and discard regrows it without a heartbeat")
    func stagingAndDiscardRefreshCapacity() async throws {
        let fixture = try await ProviderUpgradeFixture.make()
        defer { fixture.cleanFiles() }
        await fixture.loop.resliceGrowSurvivors()
        await fixture.loop.updateAggregateCapacity()
        let fullGrant = await fixture.original.engineKVBytesCapacity()
        let initial = try #require(await fixture.loop.backendCapacityForTesting()?.slots.first)
        let staged = try #require(try await fixture.prepare())
        let reserved = try #require(await fixture.loop.backendCapacityForTesting()?.slots.first)
        #expect(reserved.activeTokenBudgetMax < initial.activeTokenBudgetMax)
        #expect(await fixture.loop.isMTPUpgradeTargetRetained(upgradeModelID))
        // A concurrent serving-set reslice shrinks survivors while staging.
        await fixture.loop.resliceGrowSurvivors()
        #expect(await fixture.original.engineKVBytesCapacity() < fullGrant)
        await fixture.loop.discardMTPUpgrade(staged)
        #expect(await fixture.original.engineKVBytesCapacity() == fullGrant)
        let restored = try #require(await fixture.loop.backendCapacityForTesting()?.slots.first)
        #expect(restored.activeTokenBudgetMax == initial.activeTokenBudgetMax)
        #expect(await !fixture.loop.isMTPUpgradeTargetRetained(upgradeModelID))
        #expect(await fixture.loop.mtpStagingBytes == 0)
        #expect(staged.original == nil, "discard must drop its strong original reference before regrow")
        await fixture.clean()
    }

    @Test("discard queues behind the real reslice gate and regrows only after the reservation is removed")
    func discardWaitsForResliceGate() async throws {
        let fixture = try await ProviderUpgradeFixture.make()
        defer { fixture.cleanFiles() }
        await fixture.loop.resliceGrowSurvivors()
        let fullGrant = await fixture.original.engineKVBytesCapacity()
        let staged = try #require(try await fixture.prepare())
        await fixture.loop.resliceGrowSurvivors()
        await fixture.loop.acquireResliceGateForTesting()
        let discard = Task { await fixture.loop.discardMTPUpgrade(staged) }
        for _ in 0..<2_000 {
            if await fixture.loop.upgradeResliceWaiterCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await fixture.loop.upgradeResliceWaiterCount() > 0)
        #expect(await fixture.loop.mtpStagingBytes > 0)
        #expect(await fixture.original.engineKVBytesCapacity() < fullGrant)
        discard.cancel() // Cleanup must finish even when its owner was cancelled.
        await fixture.loop.releaseResliceGateForTesting()
        await discard.value
        #expect(await fixture.loop.mtpStagingBytes == 0)
        #expect(await fixture.original.engineKVBytesCapacity() == fullGrant)
        await fixture.clean()
    }
    @Test("prepared drain closes only new target admission while accepted work and another slot stay live")
    func preparedDrainIsModelScopedAndPreservesAcceptedWork() async throws {
        let fixture = try await ProviderUpgradeFixture.make()
        defer { fixture.cleanFiles() }
        let peerID = "upgrade-peer"
        let peer = EngineV2Bridge(engine: UpgradeScriptedEngine(bytes: 1 << 30), modelId: peerID,
            tokenizer: TokenizerHandle(MTPFloorTokenizer()), eosTokenIds: [])
        await fixture.loop.advertiseUpgradePeer(peerID)
        await fixture.runtime.register(modelId: peerID, bridge: peer)
        await fixture.loop.installModelSlotForTesting(modelId: peerID,
            container: mtpFloorContainer(), tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            engineV2: peer, sizing: mtpFloorSizing(weightsGiB: 1), modelType: "qwen3")
        let staged = try #require(try await fixture.prepare())
        let state = await fixture.loop.state
        _ = state.stampAndPublishHeartbeatCapacity(await fixture.loop.backendCapacityForTesting())
        let publishedSequence = state.publishedCapacity?.capacitySeq
        #expect(upgradeQuote(state: state, modelID: upgradeModelID).admissibleNow)
        let acceptedLocal = try await fixture.loop.acquireModelForLocal(upgradeModelID)
        await fixture.loop.setUpgradeCoordinatorPin(true)
        fixture.originalEngine.setBusy(true)
        try await fixture.loop.beginMTPUpgradeDrain(staged)
        #expect(await fixture.loop.upgradeDrainActive())
        #expect(await !fixture.loop.upgradePublicationActive())
        #expect(!state.refusingNewWork)
        #expect(state.publishedCapacity?.capacitySeq == publishedSequence,
            "the fixture has no client: the last-sent heartbeat deliberately stays stale")
        let quote = upgradeQuote(state: state, modelID: upgradeModelID)
        #expect(!quote.admissibleNow)
        #expect(quote.rejectionReason == .slotState)
        #expect(upgradeQuote(state: state, modelID: peerID).admissibleNow)
        let capacity = try #require(await fixture.loop.backendCapacityForTesting())
        let draining = try #require(capacity.slots.first { $0.model == upgradeModelID })
        #expect(draining.state == "reloading")
        #expect(draining.numRunning == 1, "withdraw admission without erasing accepted work")
        #expect(capacity.slots.first { $0.model == peerID }?.state == "idle")
        #expect(try await !fixture.loop.commitMTPUpgradeIfIdle(staged))
        // This is the post-accept load call. It must not wait for a drain that
        // itself waits for this already-counted request to finish.
        try await fixture.loop.ensureModelLoaded(modelId: upgradeModelID)
        #expect(await fixture.loop.hasUpgradeCoordinatorPin())
        #expect(acceptedLocal.engineV2Bridge === fixture.original)
        await #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try await fixture.loop.acquireModelForLocal(upgradeModelID)
        }
        let peerRequest = try await fixture.loop.acquireModelForLocal(peerID)
        #expect(peerRequest.engineV2Bridge === peer)
        await peerRequest.releaseToken.fire()

        let capture = UpgradeMessageCapture()
        let send = SendHandle { capture.append($0) }
        #expect(await fixture.loop.rejectIfDrainingForMTP(modelId: upgradeModelID,
            requestId: "new-target", send: send,
            lookupReceiptFinalizer: PrefixCacheLookupReceiptFinalizer(callback: nil)))
        #expect(await !fixture.loop.rejectIfDrainingForMTP(modelId: peerID,
            requestId: "new-peer", send: send,
            lookupReceiptFinalizer: PrefixCacheLookupReceiptFinalizer(callback: nil)))
        #expect(capture.all.count == 1)
        let data = try CoordinatorClientCodec.encodeOutboundMessage(try #require(capture.all.first))
        let frame = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(frame["type"] as? String == "inference_error")
        #expect(frame["status_code"] as? Int == 503)
        #expect(frame["failure_code"] as? String == "capacity")
        #expect(frame["rejection_reason"] as? String == "slot_state")
        #expect(frame["error_reason"] as? String != "draining")
        await fixture.checkOriginal()

        await acceptedLocal.releaseToken.fire()
        await fixture.loop.setUpgradeCoordinatorPin(false)
        fixture.originalEngine.setBusy(false)
        #expect(try await fixture.loop.commitMTPUpgradeIfIdle(staged))
        await fixture.loop.finishMTPUpgradeDrain(staged)
        #expect(await !fixture.loop.upgradeDrainActive())
        #expect(upgradeQuote(state: state, modelID: upgradeModelID).admissibleNow)
        let reopened = try await fixture.loop.acquireModelForLocal(upgradeModelID)
        #expect(reopened.engineV2Bridge === staged.replacement.bridge)
        await reopened.releaseToken.fire()
        let reopenedCapacity = await fixture.loop.backendCapacityForTesting()
        #expect(reopenedCapacity?.slots.first(where: { $0.model == upgradeModelID })?.state == "idle")
        await fixture.runtime.unregister(modelId: peerID)
        await peer.shutdown()
        await fixture.loop.removeModelSlotForTesting(modelId: peerID)
        await fixture.clean()
    }

    @Test("drain timeout or cancellation reopens the old engine without cancelling accepted work", arguments: [false, true])
    func abandonedDrainPreservesAcceptedWork(cancel: Bool) async throws {
        let fixture = try await ProviderUpgradeFixture.make()
        defer { fixture.cleanFiles() }
        let staged = try #require(try await fixture.prepare())
        await fixture.loop.setUpgradeCoordinatorPin(true)
        let pause = UpgradeBarrier()
        let task = Task {
            await MTPIdleUpgrade.run(maximumIdleChecks: 1, prepare: { staged },
                beginDrain: { try await fixture.loop.beginMTPUpgradeDrain($0) },
                commitIfIdle: { try await fixture.loop.commitMTPUpgradeIfIdle($0) },
                discard: { await fixture.loop.discardMTPUpgrade($0) },
                finishDrain: { await fixture.loop.finishMTPUpgradeDrain($0) },
                pause: { await pause.wait(); try Task.checkCancellation() })
        }
        await pause.observeEntry()
        #expect(await fixture.loop.upgradeDrainActive())
        #expect(await fixture.loop.hasUpgradeCoordinatorPin())
        if cancel { task.cancel() }
        await pause.release()
        #expect(await task.value == (cancel ? .cancelled : .deferred))
        #expect(await !fixture.loop.upgradeDrainActive())
        #expect(await fixture.loop.hasUpgradeCoordinatorPin())
        #expect(await fixture.loop.outstandingKVReservationBytesForTesting() == 0)
        #expect(await fixture.loop.backendCapacityForTesting()?.slots.first?.state == "idle")
        await fixture.checkOriginal()
        let reopened = try await fixture.loop.acquireModelForLocal(upgradeModelID)
        #expect(reopened.engineV2Bridge === fixture.original)
        await reopened.releaseToken.fire()
        await fixture.loop.setUpgradeCoordinatorPin(false)
        await fixture.clean()
    }

    @Test("stale drain cleanup cannot clear a newer candidate admission fence")
    func drainCleanupRequiresItsCandidateOwner() async throws {
        let fixture = try await ProviderUpgradeFixture.make()
        defer { fixture.cleanFiles() }
        let first = try #require(try await fixture.prepare())
        let second = try #require(try await fixture.prepare())
        try await fixture.loop.beginMTPUpgradeDrain(first)
        await #expect(throws: CancellationError.self) {
            try await fixture.loop.beginMTPUpgradeDrain(second)
        }
        await fixture.loop.finishMTPUpgradeDrain(second)
        #expect(await fixture.loop.upgradeDrainActive())
        await fixture.loop.finishMTPUpgradeDrain(first)
        try await fixture.loop.beginMTPUpgradeDrain(second)
        await fixture.loop.finishMTPUpgradeDrain(first)
        #expect(await fixture.loop.upgradeDrainActive())
        #expect(await fixture.loop.state.refusingNewWork(forModel: upgradeModelID))
        #expect(await fixture.loop.backendCapacityForTesting()?.slots.first?.state == "reloading")
        await fixture.loop.discardMTPUpgrade(first)
        await fixture.loop.discardMTPUpgrade(second)
        await fixture.loop.finishMTPUpgradeDrain(second)
        #expect(await !fixture.loop.upgradeDrainActive())
        #expect(await fixture.loop.outstandingKVReservationBytesForTesting() == 0)
        await fixture.clean()
    }

}
