import Foundation
import Testing
import ProviderAppAttest
@testable import ProviderCore

private func lifecycleHardware() -> HardwareInfo {
    HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
        chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4), gpuCores: 40, memoryBandwidthGbs: 546)
}

private func lifecycleLoop() async throws -> (ProviderLoop, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let loop = try ProviderLoop(config: ProviderLoopConfig(coordinatorURL: "ws://127.0.0.1:0/unused",
        hardware: lifecycleHardware(), models: [], config: ProviderConfig(provider: ProviderSettings(name: "lifecycle-test"))), attestationSigner: nil)
    await loop.setDaemonStateFileForTesting(root.appendingPathComponent("state.json"))
    return (loop, root)
}

private func lifecycleClient(url: String, state: ProviderState) -> CoordinatorClient {
    CoordinatorClient(
        config: CoordinatorClientConfig(url: url, hardware: lifecycleHardware(), models: [],
            backendName: "mlx-swift", heartbeatInterval: 60),
        stats: AtomicProviderStats(), state: state, liveAPNsToken: { nil })
}

private extension ProviderLoop {
    func installAppAttestWorker(_ worker: any AppAttestWorkerExchangeClient) { appAttestWorkerClient = worker }
    func holdLifecycleRequests(_ ids: Set<String>) { acceptedLifecycleRequests.formUnion(ids) }
    func completeLifecycleRequest(_ id: String) { acceptedLifecycleRequests.remove(id) }
    func installCancellableLifecycleRequest(_ id: String) {
        acceptedLifecycleRequests.insert(id)
        inflightTasks[id] = Task {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            // In production this occurs only after the terminal was queued.
            self.acceptedLifecycleRequests.remove(id)
        }
    }
}

private actor LifecycleWorker: AppAttestWorkerExchangeClient {
    var stopCalls = 0
    var failStop = false
    var blocked = false
    private var waiter: CheckedContinuation<Void, Never>?
    func respond(to request: AppAttestShadowPayload, status: AppAttestStatus) async throws -> AppAttestWorkerReply {
        throw AppAttestWorkerError.stopped
    }
    func cancelExchange() async throws {}
    func configure(blocked: Bool = false, failStop: Bool = false) {
        self.blocked = blocked
        self.failStop = failStop
    }
    func stop() async throws {
        stopCalls += 1
        if failStop { throw AppAttestWorkerError.childWouldNotExit }
        if blocked { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { blocked = false; waiter?.resume(); waiter = nil }
}

@Suite("Provider lifecycle drain")
struct ProviderLifecycleTests {
    @Test func shutdownWaitsForAppAttestWorkerRetirement() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = LifecycleWorker()
        await worker.configure(blocked: true)
        await loop.installAppAttestWorker(worker)
        let identity = try #require(ProcessIdentity.current())
        let draining = Task { await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 3)) }
        for _ in 0..<200 {
            if await worker.stopCalls > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await worker.stopCalls == 1)
        #expect(await loop.lifecycleStatus.outcome == .draining)
        #expect(await loop.servingDrain.phase != .drained)
        await worker.release()
        #expect(await draining.value.outcome == .drained)
        #expect(await loop.drainAndShutdown(timeoutSeconds: 1))
    }

    @Test func failedWorkerRetirementCannotAcknowledgeForcedShutdown() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = LifecycleWorker()
        await worker.configure(failStop: true)
        await loop.installAppAttestWorker(worker)
        let identity = try #require(ProcessIdentity.current())
        let status = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 0, force: true))
        #expect(status.outcome == .timedOut)
        #expect(await !loop.drainAndShutdown(timeoutSeconds: 0))
        await worker.configure()
        #expect(await loop.drainAndShutdown(timeoutSeconds: 1))
    }

    @Test func failedUpdateReopensWorkerOnlyAfterConfirmedRetirement() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = LifecycleWorker()
        await loop.installAppAttestWorker(worker)
        await loop.beginUpdateDraining()
        #expect(await loop.stopAppAttestWorkerForUpdateAndWait())
        #expect(await loop.appAttestWorkerStopped)
        await loop.resumeServingAfterUpdate()
        #expect(await !loop.appAttestWorkerStopped)
        #expect(await loop.appAttestWorkerClient == nil)
    }

    @Test func concurrentAcceptedWorkAndLocalResponsesFinishBeforeDrain() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.holdLifecycleRequests(["stream-model-a", "nonstream-model-b", "accepted-cold-load"])
        let tracker = await loop.localResponseTracker
        let lease = try tracker.admit()
        let identity = try #require(ProcessIdentity.current())
        let task = Task { await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 3)) }
        for _ in 0..<100 {
            if await loop.servingDrain.refusing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await loop.state.refusingNewWork)
        #expect(throws: (any Error).self) { try tracker.admit() }
        await #expect(throws: (any Error).self) { try await loop.throwIfRefusingNewLocalWork() }
        for id in ["stream-model-a", "nonstream-model-b", "accepted-cold-load"] { await loop.completeLifecycleRequest(id) }
        #expect(await loop.lifecycleRemaining == 1)
        #expect(await loop.lifecycleStatus.outcome == .draining)
        lease.release()
        let result = await task.value
        #expect(result.outcome == .drained)
        #expect(result.remaining == 0)
        #expect(await loop.servingDrain.phase == .drained)
    }

    @Test func timeoutDoesNotCancelAcceptedWorkAndRetryCanFinish() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.holdLifecycleRequests(["stalled"])
        let identity = try #require(ProcessIdentity.current())
        let result = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 0))
        #expect(result.outcome == .timedOut)
        #expect(result.remaining == 1)
        #expect(await loop.servingDrain.refusing)
        await loop.completeLifecycleRequest("stalled")
        let retried = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 1))
        #expect(retried.outcome == .drained)
    }

    @Test func forceCancelsOwnedWorkButWaitsForTerminalCleanup() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.installCancellableLifecycleRequest("forced")
        let result = await loop.drainForLifecycle(request: .init(target: try #require(ProcessIdentity.current()), timeoutSeconds: 0, force: true))
        #expect(result.outcome == .forced)
        #expect(result.remaining == 0)
    }

    @Test func interruptedCallerDoesNotCancelDrainOrReopenAdmission() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.holdLifecycleRequests(["accepted"])
        let identity = try #require(ProcessIdentity.current())
        let task = Task { await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 2)) }
        task.cancel()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(await loop.lifecycleRemaining == 1)
        await loop.completeLifecycleRequest("accepted")
        #expect(await task.value.outcome == .drained)
    }

    @Test func forceCanReplaceAnExistingWaitWithoutLosingOwnership() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.installCancellableLifecycleRequest("stalled")
        let identity = try #require(ProcessIdentity.current())
        let first = Task { await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 5)) }
        for _ in 0..<100 {
            if await loop.servingDrain.refusing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await loop.lifecycleRemaining == 1)
        let forced = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 0, force: true))
        #expect(forced.outcome == .forced)
        #expect(forced.remaining == 0)
        #expect(await first.value.outcome == .timedOut)
    }

    @Test func failedUpdateCannotResumeLifecycleOwnedAdmission() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.beginUpdateDraining()
        _ = await loop.drainForLifecycle(request: .init(target: try #require(ProcessIdentity.current()), timeoutSeconds: 1))
        await loop.resumeServingAfterUpdate()
        #expect(await loop.state.refusingNewWork)
        #expect(await loop.servingDrain.refusing)
    }

    @Test func lifecycleDrainTakesOwnershipFromAnAppAttestStallRestart() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await !loop.appAttestStallRestartOwnsDrain)
        await loop.beginUpdateDraining()
        #expect(await loop.appAttestStallRestartOwnsDrain)
        await loop.holdLifecycleRequests(["accepted"])
        let identity = try #require(ProcessIdentity.current())
        let stop = Task { await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 2)) }
        for _ in 0..<100 {
            if await loop.servingDrain.owner == .lifecycle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await !loop.appAttestStallRestartOwnsDrain)
        await loop.completeLifecycleRequest("accepted")
        #expect(await stop.value.outcome == .drained)
        // The finished stop keeps ownership: the stall path must not restart.
        #expect(await !loop.appAttestStallRestartOwnsDrain)
    }

    /// A slot whose native retirement is unproven stays resident and
    /// unloading for the rest of the process (`GLM5NextRetirement`); nothing
    /// resumes a wait for it. Shutdown must still finish: process exit
    /// releases that memory.
    @Test(.timeLimit(.minutes(1)))
    func shutdownDoesNotWaitForeverForAnUnloadThatNeverFinishes() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox,
            models: [ModelLoadingFixtures.model("retained-glm")])
        await loop.modelLoadingInstallSlot("retained-glm", bridge: makeInertStubBridge(modelId: "retained-glm").bridge)
        await loop.modelLoadingMarkUnloading("retained-glm")
        let finished = OneShotBoolContinuation()
        let shutdown = Task { _ = await loop.shutdownBeforeRegistration(); finished.resume(returning: true) }
        let timer = Task {
            try? await Task.sleep(for: .seconds(40))
            finished.resume(returning: false)
        }
        let completed = await withCheckedContinuation { finished.install($0) }
        timer.cancel()
        #expect(completed, "shutdown is still waiting for the retained slot")
        if completed { _ = await shutdown.value }
    }

    @Test func abandonedAppAttestStallRestartReopensServingAndDefersTheNextDrain() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await !loop.appAttestStallRetryDeferred)
        await loop.beginUpdateDraining()
        #expect(await loop.servingDrain.refusing)
        await loop.abandonAppAttestStallRestart(after: .markerNotPersisted)
        // Serving reopens at once, but the monitor may not drain again on its next tick.
        #expect(await !loop.servingDrain.refusing)
        #expect(await loop.updatePhase == .idle)
        #expect(await loop.appAttestStallRetryDeferred)
    }

    /// A provider whose reconnect keeps failing (for example after a
    /// coordinator restart) has a client but no registered session, so no
    /// coordinator can ever acknowledge. `stop` must not require `--force`.
    @Test func drainWithoutARegisteredCoordinatorSessionCompletes() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.setCoordinatorClientForTesting(
            lifecycleClient(url: "ws://127.0.0.1:0/unused", state: await loop.state))
        let identity = try #require(ProcessIdentity.current())
        let result = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 1))
        #expect(result.outcome == .drained)
        #expect(result.remaining == 0)
        #expect(!result.coordinatorAcknowledged)
        #expect(await loop.servingDrain.phase == .drained)
    }

    /// Losing the session waives only the acknowledgement: accepted work still
    /// keeps the drain open, and a timeout leaves it in place.
    @Test func drainWithoutARegisteredSessionStillWaitsForAcceptedWork() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.setCoordinatorClientForTesting(
            lifecycleClient(url: "ws://127.0.0.1:0/unused", state: await loop.state))
        await loop.holdLifecycleRequests(["accepted"])
        let identity = try #require(ProcessIdentity.current())
        let result = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 0))
        #expect(result.outcome == .timedOut)
        #expect(result.remaining == 1)
        #expect(await loop.servingDrain.refusing)
        await loop.completeLifecycleRequest("accepted")
        let retried = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 1))
        #expect(retried.outcome == .drained)
        #expect(!retried.coordinatorAcknowledged)
    }

    @Test(.timeLimit(.minutes(1)))
    func drainWithARegisteredSessionStillRequiresTheAcknowledgement() async throws {
        let mock = MockCoordinator(acknowledgeDrains: false)
        let url = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = lifecycleClient(url: url.mockProviderWebSocketURL(), state: await loop.state)
        let (events, _) = await client.start()
        defer { Task { await client.shutdown() } }
        for await event in events { if case .connected = event { break } }
        await loop.setCoordinatorClientForTesting(client)

        let identity = try #require(ProcessIdentity.current())
        let result = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 1))
        #expect(result.outcome == .timedOut)
        #expect(!result.coordinatorAcknowledged)
        let barrier = try await mock.waitForSnapshot(timeout: .seconds(5)) { !$0.drainBarriers.isEmpty }
        #expect(barrier != nil)
    }
}
