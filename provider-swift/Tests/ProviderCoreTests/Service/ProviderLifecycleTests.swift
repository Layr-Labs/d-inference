import Foundation
import Testing
@testable import ProviderAppAttest
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
    func setAppAttestStopWait(_ seconds: Double) { appAttestStopWaitSeconds = seconds }
    /// Starts `attest` as `handleAppAttestShadow` does, so a stop cancels it
    /// through `cancelAppAttestShadow`.
    func beginAppAttestation(_ client: AppAttestShadowClient, key: String) {
        appAttestShadowClient = client
        let request = lifecycleShadowRequest("attest", key: key)
        appAttestShadowTask = Task.detached {
            _ = await client.respond(to: request, publicKey: lifecycleEndpoint, status: lifecycleShadowStatus)
        }
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

    /// SIGTERM, `darkbloom stop` and the cluster service's part stop all drain
    /// here. Apple already has the attestation: the stop lets it answer, so the
    /// next process sends the proof instead of retiring the key for an hour.
    @Test(.timeLimit(.minutes(1)))
    func shutdownWaitsForAnAttestationAppleIsAnswering() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        let apple = SlowAttestingApple(answerAfter: 1)
        let keys = LifecycleShadowKeys()
        let client = AppAttestShadowClient(scope: "test", service: AvailableAttestingApple(apple), storage: keys)
        let ready = await client.respond(to: lifecycleShadowRequest("prepare"), publicKey: lifecycleEndpoint)
        let key = try #require(ready.keyID)
        await loop.beginAppAttestation(client, key: key)
        #expect(await waitFor { apple.attestationsStarted == 1 })
        let identity = try #require(ProcessIdentity.current())
        let stop = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 3))
        #expect(stop.outcome == .drained)
        #expect(apple.attestationsAnswered == 1, "the stop waited for Apple's answer")
        let stored = try #require(keys.load(scope: lifecycleKeyScope))
        #expect(stored.keyID == key)
        #expect(stored.pendingProof == Data("attestation-\(key)".utf8).base64EncodedString())
        #expect(stored.attestationStartedAt == nil)
        #expect(await loop.drainAndShutdown(timeoutSeconds: 1))
    }

    /// Apple keeps the attestation until the test answers it, so the stop can
    /// only return by giving up on Apple at the bound. Wall time is checked
    /// from below only: a busy host can delay the stop, never hurry it.
    @Test(.timeLimit(.minutes(1)))
    func shutdownStopsWaitingForAppleAtTheBound() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        let apple = SlowAttestingApple(answerAfter: nil)
        let keys = LifecycleShadowKeys()
        let client = AppAttestShadowClient(scope: "test", service: AvailableAttestingApple(apple), storage: keys)
        let ready = await client.respond(to: lifecycleShadowRequest("prepare"), publicKey: lifecycleEndpoint)
        let key = try #require(ready.keyID)
        await loop.setAppAttestStopWait(0.2)
        await loop.beginAppAttestation(client, key: key)
        #expect(await waitFor { apple.attestationsStarted == 1 })
        let identity = try #require(ProcessIdentity.current())
        let started = ContinuousClock.now
        let stop = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 3))
        #expect(stop.outcome == .drained)
        #expect(ContinuousClock.now - started >= .milliseconds(200), "the stop gave Apple the bound")
        // Apple still has the attestation: the stop ended at the bound, not at
        // Apple's answer or at its 25 s callback deadline.
        #expect(await !client.waitForOutstandingAttestation(atMostSeconds: 0), "the stop returned before Apple answered")
        // This process outlives the stop here, so Apple's later answer is still kept.
        apple.answerHeldAttestations()
        #expect(await waitFor { keys.load(scope: lifecycleKeyScope)?.pendingProof != nil })
        #expect(keys.load(scope: lifecycleKeyScope)?.keyID == key)
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

private let lifecycleEndpoint = Data(repeating: 7, count: 32).base64EncodedString()
private let lifecycleKeyScope = "test:production:account:" + String(repeating: "a", count: 64)
private let lifecycleShadowStatus = AppAttestStatus(osVersion: "27.2.0", osBuild: "test", appVersion: "0.10.7",
                                                    chip: "test", binaryHash: String(repeating: "b", count: 64))

private func lifecycleShadowRequest(_ action: String, key: String? = nil) -> AppAttestShadowPayload {
    var request = AppAttestShadowPayload(action: action, session: Data(repeating: 3, count: 32).base64EncodedString())
    request.protocolVersion = 3
    request.accountScope = String(repeating: "a", count: 64)
    request.environment = "production"
    request.keyID = key
    if action != "prepare" { request.challenge = Data(repeating: 4, count: 32).base64EncodedString() }
    return request
}

private final class LifecycleShadowKeys: ShadowKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ShadowKeyRecord] = [:]
    func load(scope: String) -> ShadowKeyRecord? { lock.withLock { records[scope] } }
    func save(_ record: ShadowKeyRecord, scope: String) { lock.withLock { records[scope] = record } }
}

/// Apple's side: keys at once, each attestation `answerAfter` seconds after it
/// starts. With nil, Apple answers only when the test calls `answerHeldAttestations`.
private final class SlowAttestingApple: AppAttestCallbacks, @unchecked Sendable {
    private let lock = NSLock()
    private let answerAfter: Double?
    private var started = 0
    private var answered = 0
    private var heldAnswers: [@Sendable () -> Void] = []
    init(answerAfter: Double?) { self.answerAfter = answerAfter }
    func generateKey(_ complete: @escaping @Sendable (Result<String, Error>) -> Void) {
        complete(.success(Data(repeating: 1, count: 32).base64EncodedString()))
    }
    func attestKey(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) {
        let answer: @Sendable () -> Void = { [self] in
            lock.withLock { answered += 1 }
            complete(.success(Data("attestation-\(id)".utf8)))
        }
        lock.withLock {
            started += 1
            if answerAfter == nil { heldAnswers.append(answer) }
        }
        if let answerAfter {
            DispatchQueue.global().asyncAfter(deadline: .now() + answerAfter, execute: answer)
        }
    }
    func answerHeldAttestations() {
        let answers = lock.withLock { () -> [@Sendable () -> Void] in
            defer { heldAnswers = [] }
            return heldAnswers
        }
        answers.forEach { $0() }
    }
    func generateAssertion(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) {
        complete(.success(Data("assertion".utf8)))
    }
    var attestationsStarted: Int { lock.withLock { started } }
    var attestationsAnswered: Int { lock.withLock { answered } }
}

/// Availability passes; key calls go through the real Apple adapter.
private actor AvailableAttestingApple: AppAttestService {
    private let apple: AppleAppAttestService
    init(_ callbacks: SlowAttestingApple) { apple = AppleAppAttestService(callbacks: callbacks, operationTimeout: 25) }
    func checkAvailability(environment: String) {}
    func generateKey() async throws -> String { try await apple.generateKey() }
    func attestKey(_ id: String, hash: Data) async throws -> Data { try await apple.attestKey(id, hash: hash) }
    func generateAssertion(_ id: String, hash: Data) async throws -> Data { try await apple.generateAssertion(id, hash: hash) }
    func operationHeldSince() async -> Date? { await apple.operationHeldSince() }
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

/// The first `is_supported_false` episode after an update from a version that
/// never wrote `app-attest-verified.json`.
@Suite("App Attest verified marker seed")
struct AppAttestVerifiedSeedTests {
    /// The shape the serving provider writes, through today's encoder.
    private func previousRunState(at now: Date, attested: Bool = true, lastSuccessAge: Int? = 600,
                                  unsupported: Bool = false,
                                  grant: ProviderAuthorizationStatus? = nil, grantAt: Date? = nil) -> DaemonState {
        let status = unsupported
            ? AppAttestLocalStatus(observedAt: now.timeIntervalSince1970 - 30, launchSession: .gui,
                                   availabilityReason: .isSupportedFalse)
            : AppAttestLocalStatus(
                observedAt: now.timeIntervalSince1970 - 30, launchSession: .gui,
                key: AppAttestKeyState(recordPresent: true, attested: attested, generationBlockedUntil: nil),
                keyHistory: AppAttestKeyHistory(lastSuccessAgeSeconds: lastSuccessAge),
                keyHistoryObservedAt: now.timeIntervalSince1970 - 30)
        let trust = grant.map { DaemonState.Trust(trustLevel: "self_signed", status: "online", reason: "",
                                                   receivedAt: (grantAt ?? now).timeIntervalSince1970, authorization: $0) }
        return DaemonState(pid: 1, version: "0.10.6", writtenAt: now.timeIntervalSince1970 - 30,
                           startedAt: 0, trust: trust, appAttest: status)
    }

    private func stateDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func evidenceIsAnAttestedKeysLastSuccessOrAGrant() {
        let now = wholeSecondsNow()
        #expect(previousRunState(at: now).appAttestVerifiedAt == now.addingTimeInterval(-630))
        #expect(previousRunState(at: now, attested: false).appAttestVerifiedAt == nil,
                "a key Apple never attested is no evidence")
        #expect(previousRunState(at: now, lastSuccessAge: nil).appAttestVerifiedAt == nil,
                "evidence without a time is not used")
        // The previous process was itself unsupported: it published no key.
        #expect(previousRunState(at: now, unsupported: true).appAttestVerifiedAt == nil)
        // A grant (left only by an unclean exit) newer than the key's last success wins.
        let granted = previousRunState(at: now, lastSuccessAge: 7200,
            grant: appAttestGrant(expiresAt: now.timeIntervalSince1970 + 900), grantAt: now.addingTimeInterval(-60))
        #expect(granted.appAttestVerifiedAt == now.addingTimeInterval(-60))
        let legacy = previousRunState(at: now, attested: false,
            grant: appAttestGrant(expiresAt: now.timeIntervalSince1970 + 900, path: "legacy"))
        #expect(legacy.appAttestVerifiedAt == nil)
        let expired = previousRunState(at: now, attested: false,
            grant: appAttestGrant(expiresAt: now.timeIntervalSince1970 - 1))
        #expect(expired.appAttestVerifiedAt == nil)
    }

    /// A file as v0.10.6 writes it (snake_case keys, its field set), not one
    /// from today's encoder: a future required field would break the seed.
    @Test func aDaemonStateWrittenByV0106Seeds() throws {
        let root = try stateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = 1_793_700_000.0
        let json = """
        {"schema":1,"pid":4242,"version":"0.10.6","written_at":\(now),"started_at":\(now - 3600),
         "warm_models":[],"inference_active":false,
         "stats":{"requests_served":3,"tokens_generated":40,"usage_gaps":0},
         "app_attest":{"observed_at":\(now - 20),"launch_session":"gui","boot_time":1789441846,
           "key":{"record_present":true,"attested":true},
           "key_history":{"generations_last_24h":0,"last_success_age_seconds":120,"key_age_seconds":86400},
           "key_history_observed_at":\(now - 20)}}
        """
        let stateFile = root.appendingPathComponent("daemon-state.json")
        try Data(json.utf8).write(to: stateFile)
        let seeded = AppAttestVerifiedMarker.seedFromPreviousRun(stateFile: stateFile, now: Date(timeIntervalSince1970: now))
        #expect(seeded == Date(timeIntervalSince1970: now - 140))
        #expect(AppAttestVerifiedMarker(directory: root).lastVerified() == Date(timeIntervalSince1970: now - 140))
    }

    @Test func seedWritesOnlyAMissingMarkerWithRecentEvidence() throws {
        let root = try stateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateFile = root.appendingPathComponent("state.json")
        let marker = AppAttestVerifiedMarker(directory: root)
        let now = wholeSecondsNow()

        // No previous state, or evidence older than 7 days: nothing is written,
        // so fresher evidence can still seed later.
        #expect(AppAttestVerifiedMarker.seedFromPreviousRun(stateFile: stateFile, now: now) == nil)
        let old = Int(AppAttestStallRestartPolicy.verifiedWithin) + 3600
        DaemonStateFile.write(previousRunState(at: now, lastSuccessAge: old), to: stateFile)
        #expect(AppAttestVerifiedMarker.seedFromPreviousRun(stateFile: stateFile, now: now) == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.url.path))

        DaemonStateFile.write(previousRunState(at: now), to: stateFile)
        #expect(AppAttestVerifiedMarker.seedFromPreviousRun(stateFile: stateFile, now: now) == now.addingTimeInterval(-630))
        // Seeded once: newer evidence never replaces an existing marker, even a damaged one.
        DaemonStateFile.write(previousRunState(at: now.addingTimeInterval(60), lastSuccessAge: 0), to: stateFile)
        #expect(AppAttestVerifiedMarker.seedFromPreviousRun(stateFile: stateFile, now: now) == nil)
        #expect(marker.lastVerified() == now.addingTimeInterval(-630))
        try Data("not json".utf8).write(to: marker.url)
        #expect(AppAttestVerifiedMarker.seedFromPreviousRun(stateFile: stateFile, now: now) == nil)
        #expect(marker.lastVerified() == nil, "a damaged marker is no evidence and is not replaced")
    }

    /// The seed arms the restart on the first episode; every other guard holds.
    @Test func firstUnsupportedEpisodeAfterAnUpdateFromAnOlderVersionRestartsOnce() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        let install = try UpdateRecoveryFixture()
        defer { install.cleanup() }
        let restarts = AppAttestRestartLog()
        await loop.setAppAttestRestartSeams(route: .launchd, supported: { false }, restarts: restarts,
                                            updater: install.updater(baseURL: URL(string: "http://127.0.0.1:9")!))
        await loop.installIdleAppAttestClient()
        let now = wholeSecondsNow()
        let stateFile = root.appendingPathComponent("state.json")
        DaemonStateFile.write(previousRunState(at: now), to: stateFile)
        #expect(AppAttestVerifiedMarker.seedFromPreviousRun(stateFile: stateFile, now: now) != nil)

        await loop.noteAppAttestAvailability(
            unsupportedReady(), now: now.addingTimeInterval(-AppAttestStallRestartPolicy.unsupportedThreshold - 60))
        #expect(await waitFor { restarts.routes.count == 1 })
        #expect(restarts.routes == [.launchd])
        // The same episode in the next process: the seeded time is older than
        // the restart, so it does not restart again.
        await loop.noteAppAttestAvailability(unsupportedReady(), now: now.addingTimeInterval(120))
        #expect(await loop.appAttestUnsupportedSince == nil, "one restart per episode")
        await loop.cancelAppAttestStallMonitor()
    }

    /// An older version's stall restart after the seeded evidence also counts.
    @Test func aStallRestartByTheOlderVersionAfterTheEvidenceBlocksTheRestart() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.setAppAttestRestartSeams(route: .launchd, supported: false)
        let now = wholeSecondsNow()
        let stateFile = root.appendingPathComponent("state.json")
        DaemonStateFile.write(previousRunState(at: now), to: stateFile)
        try AppAttestStallRestartMarker(directory: root).record(now.addingTimeInterval(-60))
        #expect(AppAttestVerifiedMarker.seedFromPreviousRun(stateFile: stateFile, now: now) != nil)
        await loop.noteAppAttestAvailability(unsupportedReady(), now: now)
        #expect(await loop.appAttestUnsupportedSince == nil)
    }
}
