import Darwin
import Foundation
import ProviderAppAttest
import Testing
@testable import ProviderCore

private actor UpdateRetiringWorker: AppAttestWorkerExchangeClient {
    var stopCalls = 0
    private var blocked = false
    private var failStop = false
    private var waiter: CheckedContinuation<Void, Never>?

    func configure(blocked: Bool = false, failStop: Bool = false) {
        self.blocked = blocked
        self.failStop = failStop
    }
    func respond(to request: AppAttestShadowPayload, status: AppAttestStatus) async throws -> AppAttestWorkerReply {
        Issue.record("A permanently retired owner must not receive fresh verification work")
        throw AppAttestWorkerError.stopped
    }
    func cancelExchange() async throws {
        Issue.record("An update-retired owner must be stopped, not reopened by cancelExchange")
    }
    func stop() async throws {
        stopCalls += 1
        if blocked { await withCheckedContinuation { waiter = $0 } }
        if failStop { throw AppAttestWorkerError.childWouldNotExit }
    }
    func release() {
        blocked = false
        waiter?.resume()
        waiter = nil
    }
}

private actor DispatchFailingWorker: AppAttestWorkerExchangeClient {
    var calls = 0
    func respond(to request: AppAttestShadowPayload, status: AppAttestStatus) async throws -> AppAttestWorkerReply {
        calls += 1
        throw AppAttestWorkerError.deadlineExceeded
    }
    func cancelExchange() async throws {}
    func stop() async throws {}
}

private extension ProviderLoop {
    func installUpdateRetiringWorker(_ worker: UpdateRetiringWorker) { appAttestWorkerClient = worker }
    func installDispatchFailingWorker(_ worker: DispatchFailingWorker) { appAttestWorkerClient = worker }
}

private struct WorkerUpdateFixture {
    let files: UpdateRecoveryFixture
    let mock: MockCoordinator
    let url: URL
    let loop: ProviderLoop
    let worker = UpdateRetiringWorker()
    let restarts = RecoveryRestartCounter()

    init() async throws {
        files = try UpdateRecoveryFixture()
        mock = MockCoordinator(release: files.mockReleaseFixture(), releaseArtifact: files.artifact)
        url = try await mock.start()
        let hardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
            chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4), gpuCores: 40, memoryBandwidthGbs: 546)
        loop = try ProviderLoop(config: ProviderLoopConfig(coordinatorURL: url.mockProviderWebSocketURL(),
            hardware: hardware, models: [], config: ProviderConfig(
                provider: ProviderSettings(name: "worker-update-test", updateJitterSeconds: 0))), attestationSigner: nil)
        await loop.setDaemonStateFileForTesting(files.root.appendingPathComponent("state.json"))
    }

    func cleanup() async {
        await worker.release()
        await mock.shutdown()
        files.cleanup()
    }

    func run() async -> AutoUpdateController.Outcome {
        await loop.performAutoUpdateCheck(coordinatorURL: url.absoluteString,
            updater: files.updater(baseURL: url),
            launchSnapshot: { ProviderLaunchSnapshot(label: "fixture", runs: 1, process: nil) },
            restart: { _ = restarts.increment() })
    }

    func installCandidate() throws {
        let updater = files.updater(baseURL: url)
        let session = try updater.beginUpdateSession(operation: "fixture-install", timeout: 0)
        defer { session.release() }
        let staged = try updater.stageBundle(from: files.tarball, release: files.release, session: session).get()
        _ = try updater.commitStagedBundle(staged, session: session).get()
    }

    func waitForStop(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await worker.stopCalls < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await worker.stopCalls >= count)
    }
}

@Suite(.serialized) struct AppAttestUpdateLifecycleTests {
    @Test(.timeLimit(.minutes(1))) func qualificationFlagLatchesWorkerDispatchWithoutStallRestart() async {
        await #expect(processExitsWith: .success) {
            setenv(AppAttestWorkerSelection.qualificationEnvironment, "1", 1)
            let fixture = try await WorkerUpdateFixture()
            defer { Task { await fixture.cleanup() } }
            unsetenv(AppAttestWorkerSelection.qualificationEnvironment)
            #expect(await fixture.loop.usesAppAttestWorker)
            let worker = DispatchFailingWorker()
            await fixture.loop.installDispatchFailingWorker(worker)
            let transport = CoordinatorClient(config: AppAttestResumeFixture.config(url: fixture.url.mockProviderWebSocketURL()),
                stats: AtomicProviderStats(), state: ProviderState())
            let (events, _) = await transport.start()
            defer { Task { await transport.shutdown() } }
            _ = try #require(try await fixture.mock.awaitFirstRegister(timeout: .seconds(5)))
            var iterator = events.makeAsyncIterator()
            let (request, reply) = try await workerUpdateRequest("assert", mock: fixture.mock, iterator: &iterator)
            await fixture.loop.handleAppAttestShadow(request, reply: reply)
            await fixture.loop.appAttestShadowTask?.value
            _ = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) { $0.appAttestShadow.count == 1 })
            #expect(await worker.calls == 1)
            #expect(fixture.mock.snapshot().appAttestShadow[0].result == "busy")
            #expect(await fixture.loop.appAttestShadowClient == nil)
            #expect(await fixture.loop.appAttestStallMonitorTask == nil)

            let (timeoutRequest, timeoutReply) = try await workerUpdateRequest("assert", mock: fixture.mock, iterator: &iterator)
            var timeout = AppAttestShadowPayload(action: "assertion", session: timeoutRequest.session)
            timeout.protocolVersion = 3
            timeout.result = "operation_timeout"
            let generation = await fixture.loop.appAttestShadowGeneration
            await fixture.loop.finishAppAttestShadow(timeout, localStatus: nil, prepared: false,
                generation: generation, reply: timeoutReply)
            _ = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) { $0.appAttestShadow.count == 2 })
            #expect(fixture.mock.snapshot().appAttestShadow[1].result == "operation_timeout")
            await fixture.loop.startAppAttestStallMonitorIfNeeded()
            #expect(await fixture.loop.appAttestStallMonitorTask == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func everyRestartWaitsForWorkerBeforeReleasingLease(alreadyInstalled: Bool) async throws {
        let fixture = try await WorkerUpdateFixture()
        defer { Task { await fixture.cleanup() } }
        if alreadyInstalled { try fixture.installCandidate() }
        await fixture.worker.configure(blocked: true)
        await fixture.loop.installUpdateRetiringWorker(fixture.worker)
        let cycle = Task { await fixture.run() }
        defer { cycle.cancel(); Task { await fixture.worker.release() } }
        try await fixture.waitForStop(1)
        #expect(fixture.restarts.value == 0)
        #expect(await fixture.loop.updateSession != nil)
        #expect(try fixture.files.liveBinaryContents() == (alreadyInstalled ? "2.0.0-darkbloom" : "1.0.0-darkbloom"))
        if !alreadyInstalled {
            let staged = await fixture.loop.stagedUpdateBundle
            #expect(staged != nil)
            if let staged { #expect(FileManager.default.fileExists(atPath: staged.stagingRoot.path)) }
        }
        await fixture.worker.release()
        #expect(await cycle.value == .restarted(from: "1.0.0", to: "2.0.0", drained: true))
        #expect(fixture.restarts.value == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func interruptionDuringWorkerStopCannotInstallOrRestart(alreadyInstalled: Bool, lifecycleTakesOver: Bool) async throws {
        let fixture = try await WorkerUpdateFixture()
        defer { Task { await fixture.cleanup() } }
        if alreadyInstalled { try fixture.installCandidate() }
        await fixture.worker.configure(blocked: true)
        await fixture.loop.installUpdateRetiringWorker(fixture.worker)
        let cycle = Task { await fixture.run() }
        defer { cycle.cancel(); Task { await fixture.worker.release() } }
        try await fixture.waitForStop(1)
        if lifecycleTakesOver { await fixture.loop.beginServingDrain(owner: .lifecycle) }
        else { cycle.cancel() }
        #expect(fixture.restarts.value == 0)
        if !alreadyInstalled { #expect(await fixture.loop.stagedUpdateBundle != nil) }
        await fixture.worker.release()
        let outcome = await cycle.value
        if case .restarted = outcome { Issue.record("Interruption cannot restart the provider") }
        #expect(fixture.restarts.value == 0)
        #expect(try fixture.files.liveBinaryContents() == (alreadyInstalled ? "2.0.0-darkbloom" : "1.0.0-darkbloom"))
        #expect(try fixture.files.persistentStateIsIntact())
        let recovery = try UpdateRecoveryStore(installRoot: fixture.files.installRoot, verifyCodeSignatures: false).loadState()
        #expect(recovery.candidate?.pendingAttemptID == nil)
        if !alreadyInstalled { #expect(recovery.candidate == nil) }
        // The rejected commit never consumes the stage into the live layout;
        // the existing cycle-abort cleanup may discard its temporary files.
        #expect(await fixture.loop.stagedUpdateBundle == nil)
        #expect(await fixture.loop.updateSession == nil)
        if lifecycleTakesOver { #expect(await fixture.loop.servingDrain.owner == .lifecycle) }
    }

    @Test(.timeLimit(.minutes(1))) func freshPrepareRetriesTheRetainedOwnerAfterFailedUpdate() async {
        await #expect(processExitsWith: .success) {
            try await runWorkerUpdateRecovery(lifecycleTakesOver: false)
        }
    }

    @Test(.timeLimit(.minutes(1))) func lifecycleClaimDuringCleanupCannotReopenWorker() async {
        await #expect(processExitsWith: .success) {
            try await runWorkerUpdateRecovery(lifecycleTakesOver: true)
        }
    }

    @Test(.timeLimit(.minutes(1))) func terminalStopIsNotAnUpdateRecoveryRequest() async {
        await #expect(processExitsWith: .success) {
            setenv(AppAttestWorkerSelection.qualificationEnvironment, "1", 1)
            let fixture = try await WorkerUpdateFixture()
            defer { Task { await fixture.cleanup() } }
            await fixture.loop.installUpdateRetiringWorker(fixture.worker)
            #expect(await fixture.loop.stopAppAttestWorkerAndWait())
            await fixture.loop.resumeServingAfterUpdate()
            #expect(await fixture.loop.appAttestWorkerStopped)
            let transport = CoordinatorClient(config: AppAttestResumeFixture.config(url: fixture.url.mockProviderWebSocketURL()),
                stats: AtomicProviderStats(), state: ProviderState())
            let (events, _) = await transport.start()
            defer { Task { await transport.shutdown() } }
            _ = try #require(try await fixture.mock.awaitFirstRegister(timeout: .seconds(5)))
            var iterator = events.makeAsyncIterator()
            let (request, reply) = try await workerUpdateRequest("prepare", mock: fixture.mock, iterator: &iterator)
            await fixture.loop.handleAppAttestWorker(request, reply: reply)
            await fixture.loop.appAttestShadowTask?.value
            #expect(await fixture.loop.appAttestWorkerStopped)
            #expect(await fixture.loop.appAttestShadowTask == nil)
            #expect((await fixture.loop.appAttestWorkerClient as? UpdateRetiringWorker) === fixture.worker)
        }
    }

    @Test(.timeLimit(.minutes(1))) func coldWorkerRequiresFreshPrepare() async {
        await #expect(processExitsWith: .success) {
            setenv(AppAttestWorkerSelection.qualificationEnvironment, "1", 1)
            let fixture = try await WorkerUpdateFixture()
            defer { Task { await fixture.cleanup() } }
            let transport = CoordinatorClient(config: AppAttestResumeFixture.config(url: fixture.url.mockProviderWebSocketURL()),
                stats: AtomicProviderStats(), state: ProviderState())
            let (events, _) = await transport.start()
            defer { Task { await transport.shutdown() } }
            _ = try #require(try await fixture.mock.awaitFirstRegister(timeout: .seconds(5)))
            var iterator = events.makeAsyncIterator()
            let (request, reply) = try await workerUpdateRequest("assert", mock: fixture.mock, iterator: &iterator)
            await fixture.loop.handleAppAttestWorker(request, reply: reply)
            await fixture.loop.appAttestShadowTask?.value
            #expect(await fixture.loop.appAttestWorkerClient == nil)
            #expect(await fixture.loop.appAttestShadowTask == nil)
        }
    }
}

private func workerUpdateRequest(_ action: String, mock: MockCoordinator,
    iterator: inout AsyncStream<CoordinatorEvent>.Iterator) async throws -> (AppAttestShadowPayload, AppAttestShadowReply) {
    var request = AppAttestShadowPayload(action: action, session: Data(repeating: 7, count: 32).base64EncodedString())
    request.protocolVersion = 3
    // Deliberately no account/environment: a real successor rejects this before
    // any Apple/Keychain/worker launch. These are ownership tests, not healthy-D evidence.
    try await mock.pushAppAttestShadow(request)
    while let event = await iterator.next() {
        if case .appAttestShadow(let message, let reply) = event { return (message, reply) }
    }
    throw CancellationError()
}

private func runWorkerUpdateRecovery(lifecycleTakesOver: Bool) async throws {
    setenv(AppAttestWorkerSelection.qualificationEnvironment, "1", 1)
    let fixture = try await WorkerUpdateFixture()
    defer { Task { await fixture.cleanup() } }
    await fixture.worker.configure(failStop: true)
    await fixture.loop.installUpdateRetiringWorker(fixture.worker)
    guard case .commitFailed = await fixture.run() else { Issue.record("Expected retirement to prevent commit"); return }
    #expect(await fixture.loop.updatePhase == .idle)
    #expect(await fixture.loop.appAttestWorkerStopped)
    #expect(try fixture.files.liveBinaryContents() == "1.0.0-darkbloom")
    let transport = CoordinatorClient(config: AppAttestResumeFixture.config(url: fixture.url.mockProviderWebSocketURL()),
        stats: AtomicProviderStats(), state: ProviderState())
    let (events, _) = await transport.start()
    defer { Task { await transport.shutdown() } }
    _ = try #require(try await fixture.mock.awaitFirstRegister(timeout: .seconds(5)))
    var iterator = events.makeAsyncIterator()

    let (first, firstReply) = try await workerUpdateRequest("prepare", mock: fixture.mock, iterator: &iterator)
    await fixture.loop.handleAppAttestWorker(first, reply: firstReply)
    _ = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) { $0.appAttestShadow.count == 1 })
    #expect(fixture.mock.snapshot().appAttestShadow[0].result == "busy")
    #expect(await fixture.worker.stopCalls == 2)
    #expect((await fixture.loop.appAttestWorkerClient as? UpdateRetiringWorker) === fixture.worker)
    #expect(await fixture.loop.appAttestWorkerStopped)
    #expect(await fixture.loop.appAttestShadowTask == nil)

    await fixture.worker.configure(blocked: true)
    let (fresh, freshReply) = try await workerUpdateRequest("prepare", mock: fixture.mock, iterator: &iterator)
    await fixture.loop.handleAppAttestWorker(fresh, reply: freshReply)
    try await fixture.waitForStop(3)
    #expect((await fixture.loop.appAttestWorkerClient as? UpdateRetiringWorker) === fixture.worker)
    if lifecycleTakesOver { await fixture.loop.beginServingDrain(owner: .lifecycle) }
    await fixture.worker.release()
    await fixture.loop.appAttestShadowTask?.value
    if lifecycleTakesOver {
        #expect(await fixture.loop.appAttestWorkerStopped)
        #expect((await fixture.loop.appAttestWorkerClient as? UpdateRetiringWorker) === fixture.worker)
    } else {
        _ = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) { $0.appAttestShadow.count == 2 })
        #expect(await !fixture.loop.appAttestWorkerStopped)
        #expect(await fixture.loop.appAttestWorkerClient is AppAttestWorkerClient)
        #expect(fixture.mock.snapshot().appAttestShadow[1].result == "busy")
        #expect(fixture.restarts.value == 0)
    }
    #expect(await fixture.loop.appAttestShadowTask == nil)
}
