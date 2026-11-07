import Foundation
import Testing

@testable import ProviderCore

/// A settable wall clock in Unix milliseconds.
final class MeFirstTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds: Int64
    init(_ start: Int64 = 1_800_000_000_000) { milliseconds = start }
    var now: Int64 { lock.withLock { milliseconds } }
    func advance(ms: Int64) { lock.withLock { milliseconds += ms } }
}

final class OwnerPauseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// What the loop sends the coordinator, in order.
final class OwnerPauseOutbound: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    func append(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }

    func messages(for requestID: String) -> [OutboundMessage] {
        lock.withLock { messages }.filter {
            switch $0 {
            case .inferenceAccepted(let id), .inferenceError(let id, _, _), .inferenceComplete(let id, _, _, _, _, _),
                 .inferenceChunk(let id, _, _): return id == requestID
            default: return false
            }
        }
    }

    func failure(for requestID: String) -> InferenceFailure? {
        for case .inferenceError(let id, let failure, _) in messages(for: requestID) where id == requestID {
            return failure
        }
        return nil
    }

    var prefetchStatuses: [(model: String, status: ProviderMessage.PrefetchModelStatus.Status, error: String?)] {
        lock.withLock { messages }.compactMap {
            if case .prefetchModelStatus(let model, let status, _, _, let error) = $0 { return (model, status, error) }
            return nil
        }
    }

    var loadStatuses: [(model: String, status: ProviderMessage.LoadModelStatus.Status, error: String?)] {
        lock.withLock { messages }.compactMap {
            if case .loadModelStatus(let model, let status, let error) = $0 { return (model, status, error) }
            return nil
        }
    }
}

/// Records the builds it is asked to fetch, then fails them.
final class OwnerPausePrefetcher: ModelPrefetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    var requested: [String] { lock.withLock { ids } }

    func prefetchToDisk(modelID: String, onByteProgress: @Sendable @escaping (Int64, Int64) -> Void) async throws {
        lock.withLock { ids.append(modelID) }
        throw CancellationError()
    }
}

/// Holds a tracked request until it is opened, and records a cancellation.
final class OwnerPauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private var cancelled = false
    private var done = false
    var wasCancelled: Bool { lock.withLock { cancelled } }
    var finished: Bool { lock.withLock { done } }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in
                    if opened { return true }
                    self.continuation = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { cancelled = true }
        }
        lock.withLock { done = true }
    }

    func open() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume()
    }
}

extension ProviderLoop {
    func useMeFirstClockForTesting(_ clock: MeFirstTestClock) { meFirstNowMs = { clock.now } }

    /// Moves the test clock and asks for the resume in one actor turn. The real
    /// resume timer, armed by the last `.end`, could otherwise read the new time
    /// first and end the pause itself.
    func resumeIfOwnerIdleForTesting(advancing clock: MeFirstTestClock, by milliseconds: Int64) -> Bool {
        clock.advance(ms: milliseconds)
        return resumeIfOwnerIdle()
    }

    /// A Darkbloom request as admission tracks one once accepted.
    func startOwnerPauseTestRequest(_ id: String, model: String, gate: OwnerPauseGate) {
        acceptedLifecycleRequests.insert(id)
        requestToModel[id] = model
        inflightTasks[id] = Task {
            await gate.wait()
            self.acceptedLifecycleRequests.remove(id)
            self.requestToModel.removeValue(forKey: id)
            self.inflightTasks.removeValue(forKey: id)
        }
    }

    func ownerPauseTestRequestIsRunning(_ id: String) -> Bool {
        inflightTasks[id] != nil && acceptedLifecycleRequests.contains(id) && requestToModel[id] != nil
    }
    var meFirstResumeTimerArmedForTesting: Bool { meFirstResumeTimer != nil }
    /// The capacity rebuild reads MLX's Metal allocator: these CPU-only tests skip it.
    func skipCapacityRebuildForTesting(counting rebuilds: OwnerPauseCounter? = nil) {
        capacityRebuildForTesting = { rebuilds?.increment() }
    }
}

/// Me first on the provider loop, without a serve loop or a GPU: every flow here
/// stays off MLX, and the suite runs under a sandbox that hides the GPU.
@Suite("Owner pause (me first)", .serialized)
struct OwnerPauseLoopTests {
    static let model = "test/owner-model"
    static let busyKeys = ["busy_reason", "busy_since_ms", "busy_addon"]

    struct Harness {
        let loop: ProviderLoop
        let sandbox: ModelLoadingSandbox
        let clock: MeFirstTestClock
        let state: ProviderState
        /// A client on the loop's state that never connects: it builds the
        /// heartbeat the coordinator would get.
        let client: CoordinatorClient

        func heartbeat() async throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(await client.buildHeartbeatJSON().utf8)) as? [String: Any])
        }

        /// The owner's last request ends and the idle time passes.
        func ownerGoesIdle(after milliseconds: Int64 = 60_000) async -> Bool {
            await loop.noteLocalUse(.end)
            return await loop.resumeIfOwnerIdleForTesting(advancing: clock, by: milliseconds)
        }

        func remove() { sandbox.remove() }
    }

    private func harness(meFirst: Bool = true, idle: Duration = .seconds(60),
                         rebuilds: OwnerPauseCounter? = nil) async throws -> Harness {
        let sandbox = try ModelLoadingSandbox()
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        let clock = MeFirstTestClock()
        await loop.useMeFirstClockForTesting(clock)
        await loop.skipCapacityRebuildForTesting(counting: rebuilds)
        if meFirst { await loop.enableMeFirst(idle: idle) }
        let state = await loop.state
        let client = CoordinatorClient(
            config: .init(url: "ws://127.0.0.1:0/ws/provider", hardware: ModelLoadingFixtures.defaultHardware,
                          models: [], backendName: "mlx-swift"),
            stats: AtomicProviderStats(), state: state, liveAPNsToken: { nil })
        return Harness(loop: loop, sandbox: sandbox, clock: clock, state: state, client: client)
    }

    @Test func theHeartbeatSaysDrainingForTheOwnerWhilePausedAndIdleOrServingAfterwards() async throws {
        let h = try await harness()
        defer { h.remove() }
        let open = try await h.heartbeat()
        #expect(open["status"] as? String == "idle")
        for key in Self.busyKeys { #expect(open[key] == nil) }

        await h.loop.noteLocalUse(.start)
        let since = h.clock.now
        let paused = try await h.heartbeat()
        #expect(paused["status"] as? String == "draining")
        #expect(paused["busy_reason"] as? String == "owner")
        #expect((paused["busy_since_ms"] as? NSNumber)?.int64Value == since)
        #expect(paused["busy_addon"] == nil)
        // Only Darkbloom work pauses: local admission stays open.
        #expect(h.state.ownerPausesPublic)
        #expect(!h.state.refusingNewWork)

        // The pause outranks serving, and lasts the whole idle time.
        h.state.inferenceActive = true
        #expect(await !h.ownerGoesIdle(after: 59_900))
        #expect(try await h.heartbeat()["status"] as? String == "draining")
        #expect(await h.loop.resumeIfOwnerIdleForTesting(advancing: h.clock, by: 100))
        let serving = try await h.heartbeat()
        #expect(serving["status"] as? String == "serving")
        for key in Self.busyKeys { #expect(serving[key] == nil) }
        h.state.inferenceActive = false
        #expect(try await h.heartbeat()["status"] as? String == "idle")
        #expect(h.state.busy == nil && !h.state.ownerPausesPublic)
    }

    @Test func aCoordinatorRequestDuringThePauseGetsOneTypedDrainingRefusal() async throws {
        let h = try await harness()
        defer { h.remove() }
        let outbound = OwnerPauseOutbound()
        let send = SendHandle { outbound.append($0) }
        // Open, a request passes the drain gate (and is refused later, for its missing key).
        await h.loop.handleInferenceRequest(requestId: "open", ciphertext: Data([1]), senderPublicKey: nil,
            cacheReceiptNonce: nil, authenticatedCacheScope: nil, send: send)
        #expect(outbound.failure(for: "open")?.statusCode == 400)

        await h.loop.noteLocalUse(.start)
        await h.loop.handleInferenceRequest(requestId: "raced", ciphertext: Data([1]), senderPublicKey: nil,
            cacheReceiptNonce: nil, authenticatedCacheScope: nil, send: send)
        #expect(outbound.messages(for: "raced").count == 1)
        let refusal = try #require(outbound.failure(for: "raced"))
        #expect(refusal.code == .capacity && refusal.statusCode == 503 && refusal.errorReason == .draining)

        // Coordinator-driven residency changes are refused the same way, as transient drain failures.
        await h.loop.handleLoadModelRequest(modelId: "org/racing-load", send: send)
        await h.loop.handleCoordinatorPrefetch(modelId: "org/racing-prefetch", priority: 1, send: send)
        #expect(outbound.loadStatuses.map(\.status) == [.failed])
        #expect(outbound.loadStatuses.first?.error == providerDrainingForUpdateReason)
        #expect(outbound.prefetchStatuses.map(\.status) == [.failed])
        #expect(outbound.prefetchStatuses.first?.error == providerDrainingForUpdateReason)
        #expect(await h.loop.autopilotBusyReasons().contains(.draining))

        #expect(await h.ownerGoesIdle())
        #expect(await h.loop.autopilotBusyReasons().isEmpty)
        await h.loop.handleInferenceRequest(requestId: "after", ciphertext: Data([1]), senderPublicKey: nil,
            cacheReceiptNonce: nil, authenticatedCacheScope: nil, send: send)
        #expect(outbound.failure(for: "after")?.statusCode == 400)
    }

    @Test func aLocalRequestIsAdmittedDuringThePause() async throws {
        let h = try await harness()
        defer { h.remove() }
        let stub = makeInertStubBridge(modelId: Self.model)
        await h.loop.modelLoadingInstallSlot(Self.model, bridge: stub.bridge)
        await h.loop.noteLocalUse(.start)
        #expect(h.state.ownerPausesPublic)
        try await h.loop.throwIfRefusingNewLocalWork(modelId: Self.model)
        let acquired = try await h.loop.acquireModelForLocal(Self.model)
        #expect(await h.loop.hasLocalReservation(Self.model))
        await acquired.releaseToken.fire()
        #expect(await !h.loop.hasLocalReservation(Self.model))
        #expect(h.state.ownerPausesPublic)
        #expect(await h.loop.modelLoadingResidentIDs() == [Self.model])
    }

    /// A real request's terminal reads MLX's allocator, so the Darkbloom
    /// request here is tracked exactly as admission tracks one, and ends
    /// when its gate opens.
    @Test func darkbloomWorkAcceptedBeforeThePauseFinishesAndIsNeverCancelled() async throws {
        let h = try await harness()
        defer { h.remove() }
        let gate = OwnerPauseGate()
        await h.loop.startOwnerPauseTestRequest("accepted", model: Self.model, gate: gate)

        await h.loop.noteLocalUse(.start)
        #expect(h.state.ownerPausesPublic)
        #expect(await h.loop.meFirstSnapshot?.darkbloomRequestsFinishing == 1)
        // The whole pause, resume included, leaves the request alone.
        #expect(await h.ownerGoesIdle())
        await h.loop.noteLocalUse(.start)
        #expect(await h.loop.ownerPauseTestRequestIsRunning("accepted"))
        #expect(await h.loop.meFirstSnapshot?.darkbloomRequestsFinishing == 1)

        gate.open()
        #expect(try await addonEventually { await !h.loop.ownerPauseTestRequestIsRunning("accepted") })
        #expect(gate.finished && !gate.wasCancelled)
        #expect(await h.loop.stats.cancellationsReceived == 0)
        #expect(await h.loop.meFirstSnapshot?.darkbloomRequestsFinishing == 0)
        #expect(h.state.ownerPausesPublic)
    }

    @Test func quotesRefuseWhilePausedAndAdmitAgainAfterwards() async throws {
        let h = try await harness()
        defer { h.remove() }
        let slot = BackendSlotCapacity(model: "org/model-a", state: "running", numRunning: 1, numWaiting: 0,
            activeTokens: 0, maxTokensPotential: 0, maxConcurrency: 4, observedDecodeTps: 50,
            observedPrefillTps: 1000, activeTokenBudgetUsed: 1000, activeTokenBudgetMax: 9000, queuedTokenBudget: 0)
        let capacity = BackendCapacity(slots: [slot], gpuMemoryActiveGb: 1, gpuMemoryPeakGb: 1,
            gpuMemoryCacheGb: 0, totalMemoryGb: 64, freeForLoadGb: 40, capacitySeq: 7)
        let probe = CoordinatorMessage.CapacityProbe(quoteId: "q-owner", model: "org/model-a",
            promptTokensBucket: 512, maxOutputTokens: 512, requiresVision: false, visionImageCount: 0,
            deadlineRemainingMs: 9000)
        func quote() async -> ProviderMessage.CapacityQuote {
            // The inputs the client's probe handler reads from the shared state.
            CapacityQuoteEngine.quote(.init(probe: probe, capacity: capacity,
                model: ModelInfo(id: "org/model-a", sizeBytes: 8 << 30, estimatedMemoryGb: 8), ttft: nil,
                visionLimits: .init(maxBufferBytes: 38 << 30, attentionElementBytes: 2, headFactor: 1),
                refusingNewWork: h.state.refusingNewWork(forModel: "org/model-a")))
        }
        #expect(await quote().admissibleNow)
        await h.loop.noteLocalUse(.start)
        let refused = await quote()
        #expect(!refused.admissibleNow && refused.rejectionReason == .slotState)
        #expect(await h.ownerGoesIdle())
        #expect(await quote().admissibleNow)
    }

    @Test func anAddOnHoldOutranksThePauseAndItsReleaseKeepsIt() async throws {
        let rebuilds = OwnerPauseCounter()
        let h = try await harness(rebuilds: rebuilds)
        defer { h.remove() }
        let addon = AddonHoldLoopTests.addon
        let peer = AddonPeer(identifier: addon)
        await h.loop.useAddonHoldForTesting(paths: nil, clock: AddonTestClock(h.clock.now))
        let outbound = OwnerPauseOutbound()
        let send = SendHandle { outbound.append($0) }
        await h.loop.setAddonTestOutbound(send)
        // Darkbloom work accepted earlier keeps the hold draining, so it never reaches its unload here.
        await h.loop.acceptAddonTestRequest("accepted")

        await h.loop.noteLocalUse(.start)
        let ownerSince = h.clock.now
        guard case .hold(let holdID, _, let holdSince, _) = await h.loop.handleAddonIPC(
            .hold(addon: addon, vmBytes: 1 << 30, leaseSeconds: 60), peer: peer) else {
            Issue.record("the hold was refused")
            return
        }
        #expect(h.state.busy == ProviderBusy(reason: .addon, sinceMs: holdSince, addon: addon))
        let held = try await h.heartbeat()
        #expect(held["status"] as? String == "draining" && held["busy_reason"] as? String == "addon")
        #expect(h.state.ownerPausesPublic)
        let desired = CoordinatorMessage.DesiredModelEntry(modelName: "alias", desiredBuild: "org/desired-build")
        await h.loop.handleDesiredModels([desired], send: send)
        #expect(await h.loop.deferredDesiredModels == [desired])

        #expect(await h.loop.handleAddonIPC(.release(holdID: holdID), peer: peer) == .released)
        // The release hands the busy fields back to the pause, which goes on.
        #expect(h.state.busy == ProviderBusy(reason: .owner, sinceMs: ownerSince))
        #expect(h.state.ownerPausesPublic && !h.state.refusingNewWork)
        let released = try await h.heartbeat()
        #expect(released["status"] as? String == "draining" && released["busy_reason"] as? String == "owner")
        // The release's announcement leaves desired_models to the pause.
        #expect(try await addonEventually { rebuilds.value >= 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await h.loop.deferredDesiredModels == [desired])
        #expect(outbound.prefetchStatuses.isEmpty)

        #expect(await h.ownerGoesIdle())
        #expect(h.state.busy == nil)
        #expect(try await addonEventually { await h.loop.deferredDesiredModels == nil })
        #expect(try await addonEventually { outbound.prefetchStatuses.contains { $0.model == "org/desired-build" } })
        await h.loop.finishAddonTestRequest("accepted")
    }

    /// The other order: the pause ends under the hold, which keeps the busy
    /// fields and desired_models until its release.
    @Test func aPauseEndingUnderAnAddOnHoldLeavesTheBusyFieldsAndDesiredModelsToIt() async throws {
        let h = try await harness()
        defer { h.remove() }
        let addon = AddonHoldLoopTests.addon
        let peer = AddonPeer(identifier: addon)
        await h.loop.useAddonHoldForTesting(paths: nil, clock: AddonTestClock(h.clock.now))
        let outbound = OwnerPauseOutbound()
        let send = SendHandle { outbound.append($0) }
        await h.loop.setAddonTestOutbound(send)
        // Darkbloom work accepted earlier keeps the hold draining, so it never reaches its unload here.
        await h.loop.acceptAddonTestRequest("accepted")

        await h.loop.noteLocalUse(.start)
        guard case .hold(let holdID, _, let holdSince, _) = await h.loop.handleAddonIPC(
            .hold(addon: addon, vmBytes: 1 << 30, leaseSeconds: 60), peer: peer) else {
            Issue.record("the hold was refused")
            return
        }
        let desired = CoordinatorMessage.DesiredModelEntry(modelName: "alias", desiredBuild: "org/desired-build")
        await h.loop.handleDesiredModels([desired], send: send)

        #expect(await h.ownerGoesIdle())
        #expect(!h.state.ownerPausesPublic)
        #expect(h.state.busy == ProviderBusy(reason: .addon, sinceMs: holdSince, addon: addon))
        let held = try await h.heartbeat()
        #expect(held["status"] as? String == "draining" && held["busy_reason"] as? String == "addon")
        // The pause's end leaves desired_models to the hold.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await h.loop.deferredDesiredModels == [desired])
        #expect(outbound.prefetchStatuses.isEmpty)

        #expect(await h.loop.handleAddonIPC(.release(holdID: holdID), peer: peer) == .released)
        #expect(h.state.busy == nil)
        #expect(try await addonEventually { await h.loop.deferredDesiredModels == nil })
        #expect(try await addonEventually { outbound.prefetchStatuses.contains { $0.model == "org/desired-build" } })
        await h.loop.finishAddonTestRequest("accepted")
    }

    @Test func desiredModelsWaitForTheOwnerAndReplayWhenThePauseEnds() async throws {
        let h = try await harness()
        defer { h.remove() }
        let outbound = OwnerPauseOutbound()
        let send = SendHandle { outbound.append($0) }
        let prefetcher = OwnerPausePrefetcher()
        let prefetch = ModelPrefetchCoordinator(prefetcher: prefetcher, preCheck: { _ in .needsFetch },
                                                onVerified: { _ in })
        await h.loop.installPrefetchCoordinatorForTesting(prefetch, client: h.client, send: send)
        await h.loop.setDesiredPrefetchRetryDelaysForTesting([])
        // Open, desired_models converge at once.
        let before = CoordinatorMessage.DesiredModelEntry(modelName: "before", desiredBuild: "org/before-pause")
        await h.loop.handleDesiredModels([before], send: send)
        #expect(await h.loop.deferredDesiredModels == nil)
        #expect(try await addonEventually { prefetcher.requested == ["org/before-pause"] })

        await h.loop.noteLocalUse(.start)
        let during = CoordinatorMessage.DesiredModelEntry(modelName: "during", desiredBuild: "org/during-pause")
        await h.loop.handleDesiredModels([during], send: send)
        #expect(await h.loop.deferredDesiredModels == [during])
        #expect(await !h.ownerGoesIdle(after: 30_000))
        #expect(await h.loop.deferredDesiredModels == [during])

        #expect(await h.loop.resumeIfOwnerIdleForTesting(advancing: h.clock, by: 30_000))
        #expect(try await addonEventually { await h.loop.deferredDesiredModels == nil })
        #expect(try await addonEventually { prefetcher.requested == ["org/before-pause", "org/during-pause"] })
    }

    @Test func theDaemonStateSaysWhetherDarkbloomIsPausedAndUntilWhen() async throws {
        let h = try await harness()
        defer { h.remove() }
        let open = MeFirstSnapshot(idleMs: 60_000, paused: false)
        #expect(await h.loop.currentDaemonState().meFirst == open)
        #expect(DaemonStateFile.read(from: h.sandbox.daemonStateFile)?.meFirst == open)

        await h.loop.noteLocalUse(.start)
        let start = h.clock.now
        let entered = MeFirstSnapshot(idleMs: 60_000, paused: true, sinceMs: start, lastUseMs: start,
                                      localRequestsInFlight: 1)
        #expect(await h.loop.currentDaemonState().meFirst == entered)
        // Transitions write the file `status` reads; requests do not.
        #expect(DaemonStateFile.read(from: h.sandbox.daemonStateFile)?.meFirst == entered)
        h.clock.advance(ms: 5_000)
        await h.loop.noteLocalUse(.end)
        #expect(await h.loop.currentDaemonState().meFirst == MeFirstSnapshot(idleMs: 60_000, paused: true,
            sinceMs: start, lastUseMs: start + 5_000, resumesAtMs: start + 65_000))
        #expect(DaemonStateFile.read(from: h.sandbox.daemonStateFile)?.meFirst == entered)
        let raw = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: h.sandbox.daemonStateFile)) as? [String: Any])
        let written = try #require(raw["me_first"] as? [String: Any])
        #expect(Set(written.keys) == ["idle_ms", "paused", "since_ms", "last_use_ms", "local_requests_in_flight",
                                      "darkbloom_requests_finishing"])

        #expect(await h.loop.resumeIfOwnerIdleForTesting(advancing: h.clock, by: 60_000))
        let resumed = MeFirstSnapshot(idleMs: 60_000, paused: false, lastUseMs: start + 5_000)
        #expect(await h.loop.currentDaemonState().meFirst == resumed)
        #expect(DaemonStateFile.read(from: h.sandbox.daemonStateFile)?.meFirst == resumed)
    }

    @Test func withMeFirstOffNothingPausesAndNoTimerOrTaskIsLeft() async throws {
        let h = try await harness(meFirst: false)
        defer { h.remove() }
        for _ in 0..<10 {
            await h.loop.noteLocalUse(.start)
            await h.loop.noteLocalUse(.end)
        }
        #expect(await !h.loop.meFirstResumeTimerArmedForTesting)
        #expect(!h.state.ownerPausesPublic && h.state.busy == nil)
        #expect(await h.loop.meFirstSnapshot == nil)
        #expect(await h.loop.currentDaemonState().meFirst == nil)
        #expect(await !h.loop.resumeIfOwnerIdle())
        let heartbeat = try await h.heartbeat()
        #expect(heartbeat["status"] as? String == "idle")
        for key in Self.busyKeys { #expect(heartbeat[key] == nil) }
    }

    /// The real clock: the one timer exists only while the owner's idle time counts down,
    /// ends the pause by itself, and is gone afterwards.
    @Test func theResumeTimerRunsOnlyWhileIdleTimeCountsAndEndsThePauseByItself() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        await loop.skipCapacityRebuildForTesting()
        await loop.enableMeFirst(idle: .milliseconds(200))
        #expect(await !loop.meFirstResumeTimerArmedForTesting)
        await loop.noteLocalUse(.start)
        #expect(await loop.state.ownerPausesPublic)
        #expect(await !loop.meFirstResumeTimerArmedForTesting)
        await loop.noteLocalUse(.end)
        #expect(await loop.meFirstResumeTimerArmedForTesting)
        #expect(try await addonEventually(timeout: .seconds(5)) { await !loop.state.ownerPausesPublic })
        #expect(try await addonEventually(timeout: .seconds(5)) { await !loop.meFirstResumeTimerArmedForTesting })
    }
}
