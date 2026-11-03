import Foundation
import Testing
import ProviderAppAttest
@testable import ProviderCore

private func lifecycleHardware() -> HardwareInfo {
    HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
        chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4), gpuCores: 40, memoryBandwidthGbs: 546)
}

private func lifecycleLoop(role: ProviderExecutionRole = .solo) async throws -> (ProviderLoop, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let loop = try ProviderLoop(config: ProviderLoopConfig(coordinatorURL: "ws://127.0.0.1:0/unused",
        hardware: lifecycleHardware(), models: [], config: ProviderConfig(provider: ProviderSettings(name: "lifecycle-test")),
        executionRole: role), attestationSigner: nil)
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
    /// Fakes only the launchd/exec boundary and Apple's live `isSupported`.
    /// A restart that reaches the boundary is recorded, never issued.
    func setAppAttestRestartSeams(route: ProcessLifecycle.RelaunchRoute, supported: @escaping @Sendable () -> Bool,
                                  restarts: AppAttestRestartLog = AppAttestRestartLog(), updater: SelfUpdater? = nil) {
        appAttestRelaunchRoute = { route }
        appAttestSupportProbe = supported
        appAttestRestart = { restarts.append($0, $1) }
        appAttestRestartUpdater = updater
        appAttestEvidenceLog = { _ in }
    }
    func captureAppAttestEvidence(_ contexts: AppAttestEvidenceContexts) {
        appAttestEvidenceLog = { contexts.append($0) }
    }
    func setAppAttestRestartSeams(route: ProcessLifecycle.RelaunchRoute, supported: Bool) {
        setAppAttestRestartSeams(route: route, supported: { supported })
    }
    func installIdleAppAttestClient() {
        appAttestShadowClient = AppAttestShadowClient(scope: loopConfig.coordinatorURL, service: IdleAppAttestService(),
                                                      storage: EmptyShadowKeys())
    }
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

private final class AppAttestRestartLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(ProviderRunMarker.ExitCause, ProcessLifecycle.RelaunchRoute)] = []
    func append(_ cause: ProviderRunMarker.ExitCause, _ route: ProcessLifecycle.RelaunchRoute) {
        lock.withLock { entries.append((cause, route)) }
    }
    var routes: [ProcessLifecycle.RelaunchRoute] { lock.withLock { entries.map(\.1) } }
    var causes: [ProviderRunMarker.ExitCause] { lock.withLock { entries.map(\.0) } }
}

private final class AppAttestEvidenceContexts: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ context: String) { lock.withLock { entries.append(context) } }
    var values: [String] { lock.withLock { entries } }
}

/// Apple boundary with no outstanding call; availability comes from the probe seam.
private actor IdleAppAttestService: AppAttestService {
    func checkAvailability(environment: String) {}
    func generateKey() -> String { "" }
    func attestKey(_ id: String, hash: Data) -> Data { Data() }
    func generateAssertion(_ id: String, hash: Data) -> Data { Data() }
    func operationHeldSince() -> Date? { nil }
}

private struct EmptyShadowKeys: ShadowKeyStorage {
    func load(scope: String) -> ShadowKeyRecord? { nil }
    func save(_ record: ShadowKeyRecord, scope: String) {}
}

private func waitFor(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

private func unsupportedReady(profileExpired: Bool? = false) -> AppAttestLocalStatus {
    AppAttestLocalStatus(observedAt: 0, launchSession: .gui, availabilityReason: .isSupportedFalse,
                         process: AppAttestProcessDiagnostics(preflight: AppAttestPreflight(profileExpired: profileExpired)))
}

private func appAttestGrant(expiresAt: Double, path: String = "app_attest") -> ProviderAuthorizationStatus {
    ProviderAuthorizationStatus(appAttestAvailable: true, path: path, expiresAt: expiresAt,
                                sessionID: "connection", machineID: "machine")
}

/// Whole seconds, so dates survive the JSON marker unchanged.
private func wholeSecondsNow() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

@Suite("App Attest unsupported restart")
struct AppAttestUnsupportedRestartTests {
    @Test func unsupportedOnAVerifiedLaunchdMacBecomesATriggerUntilAppleAnswersSupported() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.setAppAttestRestartSeams(route: .launchd, supported: false)
        let start = wholeSecondsNow()
        // An earlier coordinator grant on this Mac is the evidence of verification.
        await loop.handleTrustStatus(trustLevel: "self_signed", status: "online", reason: "",
                                     authorization: appAttestGrant(expiresAt: start.timeIntervalSince1970 + 900),
                                     receivedAt: start.timeIntervalSince1970)
        #expect(AppAttestVerifiedMarker(directory: root).lastVerified() == start)

        await loop.noteAppAttestAvailability(unsupportedReady(), now: start)
        #expect(await loop.appAttestUnsupportedSince == start)
        // A later unsupported `ready` keeps the first observation.
        await loop.noteAppAttestAvailability(unsupportedReady(), now: start.addingTimeInterval(60))
        #expect(await loop.appAttestUnsupportedSince == start)

        let due = AppAttestStallRestartPolicy.unsupportedThreshold
        let trigger = await loop.appAttestRestartTrigger(heldSince: nil, now: start.addingTimeInterval(due))
        #expect(trigger == .unsupported(seconds: Int(due)))
        #expect(AppAttestStallRestartPolicy.decide(trigger: trigger, inferenceActive: false, lifecycleBusy: false,
            lastRestartAt: nil, retryDeferred: false, now: start.addingTimeInterval(due)) == .restart)
        // An unanswered Apple call outranks it: that is the stall restart.
        #expect(await loop.appAttestRestartTrigger(heldSince: start, now: start.addingTimeInterval(due))
                == .stalled(seconds: Int(due)))

        // Apple answers supported again inside the same process: no restart.
        await loop.setAppAttestRestartSeams(route: .launchd, supported: true)
        #expect(await loop.appAttestRestartTrigger(heldSince: nil, now: start.addingTimeInterval(due)) == nil)
        #expect(await loop.appAttestUnsupportedSince == nil)
        await loop.cancelAppAttestStallMonitor()
    }

    @Test func unsupportedNeverArmsWithoutVerificationLaunchdOrAValidProfile() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.setAppAttestRestartSeams(route: .launchd, supported: false)
        let start = wholeSecondsNow()

        // Never verified: this Mac may not support App Attest at all.
        await loop.noteAppAttestAvailability(unsupportedReady(), now: start)
        #expect(await loop.appAttestUnsupportedSince == nil)
        #expect(await loop.appAttestRestartTrigger(heldSince: nil, now: start.addingTimeInterval(3600)) == nil)

        // A legacy path or an expired lease is not verification.
        await loop.handleTrustStatus(trustLevel: "self_signed", status: "online", reason: "",
            authorization: appAttestGrant(expiresAt: start.timeIntervalSince1970 + 900, path: "legacy"),
            receivedAt: start.timeIntervalSince1970)
        await loop.handleTrustStatus(trustLevel: "self_signed", status: "online", reason: "",
            authorization: appAttestGrant(expiresAt: start.timeIntervalSince1970 - 1),
            receivedAt: start.timeIntervalSince1970)
        #expect(AppAttestVerifiedMarker(directory: root).lastVerified() == nil)

        try AppAttestVerifiedMarker(directory: root).record(start)
        // A provider that launchd does not run would restart by exec: never for this state.
        await loop.setAppAttestRestartSeams(route: .exec, supported: false)
        await loop.noteAppAttestAvailability(unsupportedReady(), now: start)
        #expect(await loop.appAttestUnsupportedSince == nil)

        // A restart cannot renew an expired provisioning profile.
        await loop.setAppAttestRestartSeams(route: .launchd, supported: false)
        await loop.noteAppAttestAvailability(unsupportedReady(profileExpired: true), now: start)
        #expect(await loop.appAttestUnsupportedSince == nil)

        // Eligible, then a `ready` with any other answer clears it.
        await loop.noteAppAttestAvailability(unsupportedReady(), now: start)
        #expect(await loop.appAttestUnsupportedSince == start)
        await loop.noteAppAttestAvailability(AppAttestLocalStatus(observedAt: 0, launchSession: .gui), now: start)
        #expect(await loop.appAttestUnsupportedSince == nil)
        await loop.cancelAppAttestStallMonitor()
    }

    @Test func verifiedMarkerIsRewrittenAtMostOncePerInterval() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = wholeSecondsNow()
        func grant(at date: Date) async {
            await loop.handleTrustStatus(trustLevel: "self_signed", status: "online", reason: "",
                authorization: appAttestGrant(expiresAt: date.timeIntervalSince1970 + 900),
                receivedAt: date.timeIntervalSince1970)
        }
        let marker = AppAttestVerifiedMarker(directory: root)
        await grant(at: start)
        #expect(marker.lastVerified() == start)
        // Leases renew every few seconds; the marker does not.
        await grant(at: start.addingTimeInterval(60))
        #expect(marker.lastVerified() == start)
        let later = start.addingTimeInterval(AppAttestVerifiedMarker.refreshInterval)
        await grant(at: later)
        #expect(marker.lastVerified() == later)
    }

    /// The real monitor, policy, lease, drain and marker run; only the
    /// launchd/exec boundary and Apple's `isSupported` are fakes.
    @Test func unsupportedRestartDrainsSpendsTheSharedMarkerAndUsesLaunchdOnce() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        let install = try UpdateRecoveryFixture()
        defer { install.cleanup() }
        let restarts = AppAttestRestartLog()
        await loop.setAppAttestRestartSeams(route: .launchd, supported: { false }, restarts: restarts,
                                            updater: install.updater(baseURL: URL(string: "http://127.0.0.1:9")!))
        await loop.installIdleAppAttestClient()
        let now = Date()
        try AppAttestVerifiedMarker(directory: root).record(now.addingTimeInterval(-3600))
        let marker = AppAttestStallRestartMarker(directory: root)
        #expect(marker.lastRestart() == nil)

        // First seen longer ago than the threshold: the monitor's first tick is due.
        await loop.noteAppAttestAvailability(
            unsupportedReady(), now: now.addingTimeInterval(-AppAttestStallRestartPolicy.unsupportedThreshold - 60))
        #expect(await waitFor { restarts.routes.count == 1 })
        #expect(restarts.routes == [.launchd])
        #expect(restarts.causes == [.stallRestart])
        let spent = try #require(marker.lastRestart(), "the shared marker is written before the restart")

        // One restart per verified episode: the same state does not arm again
        // until the coordinator verifies this Mac after the restart.
        await loop.noteAppAttestAvailability(unsupportedReady(), now: spent)
        #expect(await loop.appAttestUnsupportedSince == nil)
        await loop.cancelAppAttestStallMonitor()
    }

    @Test func unsupportedThatClearsDuringTheDrainResumesWithoutARestart() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        let install = try UpdateRecoveryFixture()
        defer { install.cleanup() }
        let restarts = AppAttestRestartLog()
        // Unsupported when the monitor decides; supported again after the drain.
        let probes = RecoveryRestartCounter()
        await loop.setAppAttestRestartSeams(route: .launchd, supported: { probes.increment() > 1 }, restarts: restarts,
                                            updater: install.updater(baseURL: URL(string: "http://127.0.0.1:9")!))
        await loop.installIdleAppAttestClient()
        let now = Date()
        try AppAttestVerifiedMarker(directory: root).record(now.addingTimeInterval(-3600))

        await loop.noteAppAttestAvailability(
            unsupportedReady(), now: now.addingTimeInterval(-AppAttestStallRestartPolicy.unsupportedThreshold - 60))
        #expect(await waitFor { await loop.appAttestUnsupportedSince == nil })
        #expect(await waitFor {
            let phase = await loop.updatePhase
            let refusing = await loop.servingDrain.refusing
            return phase == .idle && !refusing
        })
        #expect(probes.value == 2)
        #expect(restarts.routes.isEmpty)
        #expect(AppAttestStallRestartMarker(directory: root).lastRestart() == nil,
                "a state that cleared on its own does not spend the limit")
        await loop.cancelAppAttestStallMonitor()
    }

    @Test func everyUnsupportedReadyWritesEntitlementEvidenceEvenWithoutARestart() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.setAppAttestRestartSeams(route: .exec, supported: false)
        let contexts = AppAttestEvidenceContexts()
        await loop.captureAppAttestEvidence(contexts)
        // Never verified and not under launchd: no restart, but the evidence is written.
        await loop.noteAppAttestAvailability(unsupportedReady(), now: Date())
        await loop.noteAppAttestAvailability(AppAttestLocalStatus(observedAt: 0, launchSession: .gui), now: Date())
        await loop.noteAppAttestAvailability(unsupportedReady(), now: Date())
        #expect(contexts.values == ["is_supported_false", "is_supported_false"])
        #expect(await loop.appAttestUnsupportedSince == nil)
    }

    @Test func clusterMemberNeverArmsTheUnsupportedRestart() async throws {
        let (loop, root) = try await lifecycleLoop(role: .clusterMember)
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.setAppAttestRestartSeams(route: .launchd, supported: false)
        try AppAttestVerifiedMarker(directory: root).record(Date().addingTimeInterval(-3600))
        await loop.noteAppAttestAvailability(unsupportedReady(), now: Date())
        #expect(await loop.appAttestUnsupportedSince == nil)
        #expect(await loop.appAttestStallMonitorTask == nil)
    }
}
