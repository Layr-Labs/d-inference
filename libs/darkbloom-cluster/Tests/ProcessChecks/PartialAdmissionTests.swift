import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

private struct PartialFailure: Error { let message: String }
private func requirePartial(_ condition: Bool, _ message: String) throws {
    if !condition { throw PartialFailure(message: message) }
}
private final class SubmissionEndpoint: ClusterWorkerEndpoint, @unchecked Sendable {
    let child: ClusterWorkerProcess
    private let lock = NSLock()
    private let proof = DispatchGroup()
    private var proofGranted: Bool
    private var reserves = 0, cancels = 0, fences = 0
    /// Refuses every reservation as a full command queue does
    /// (`ClusterWorkerOwnerError.refused(.busy)`): the rank is never asked.
    private let queueFull: Bool
    init(_ child: ClusterWorkerProcess, holdProof: Bool = false, queueFull: Bool = false) {
        self.child = child; proofGranted = !holdProof; self.queueFull = queueFull
        if holdProof { proof.enter() }
    }
    var counts: (Int, Int) { lock.withLock { (reserves, cancels) } }
    var fenceCount: Int { lock.withLock { fences } }
    var expectedIdentity: ClusterWorkerIdentity { child.expectedIdentity }
    var expectedProfile: ClusterWorkerProfile { child.expectedProfile }
    var rank: Int { child.rank }
    var executionPlanSHA256: String { child.executionPlanSHA256 }
    var readiness: ClusterWorkerReady? { child.readiness }
    var localLifetimeDeadlineUptimeNanoseconds: UInt64 { child.localLifetimeDeadlineUptimeNanoseconds }
    var nativeCleanupObserved: Bool { child.nativeCleanupObserved && lock.withLock { proofGranted } }
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) { child.setInvalidationHandler(handler) }
    func sendWorkerCommand(_ command: ClusterWorkerCommand, requestID: UUID?, deadline: UInt64) throws {
        lock.withLock {
            switch command { case .reserve: reserves += 1; case .cancel: cancels += 1; default: break }
        }
        if queueFull, case .reserve = command { throw ClusterWorkerOwnerError.refused(.busy) }
        try child.sendWorkerCommand(command, requestID: requestID, deadline: deadline)
    }
    func receiveWorkerEvent(until deadline: UInt64, cancelled: () -> Bool) throws -> ClusterWorkerEventFrame {
        try child.receiveWorkerEvent(until: deadline, cancelled: cancelled)
    }
    func requestNativeCleanup() { lock.withLock { fences += 1 }; child.requestNativeCleanup() }
    func waitForNativeCleanup() { child.waitForNativeCleanup(); proof.wait() }
    func waitUntilNativeCleanup() async {
        await child.waitUntilNativeCleanup()
        await withCheckedContinuation { c in proof.notify(queue: .global()) { c.resume() } }
    }
    func allowCleanupProof() {
        let release = lock.withLock { if proofGranted { return false }; proofGranted = true; return true }
        if release { proof.leave() }
    }
}

/// What a request's consumer saw, in order.
private final class AbortRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ event: ClusterWorkerRequestEvent) {
        let line: String
        switch event {
        case .token(let token, _): line = "token \(token)"
        case .aborted(let abort): line = "aborted \(abort.reason.rawValue) \(abort.rank)"
        case .finished(let reason): line = "finished \(reason.rawValue)"
        case .failed: line = "failed"
        case .promptCache: line = "promptCache"
        case .telemetry: line = "telemetry"
        }
        lock.withLock { values.append(line) }
    }
    var events: [String] { lock.withLock { values } }
}

private final class AdmissionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func complete(refused: Bool) { lock.withLock { value = refused } }
    var result: Bool? { lock.withLock { value } }
}

@main struct PartialAdmissionTests {
    static func main() async throws {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(30)
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        try await requestScopedRefusals(executable)
        try await endpointRefusals(executable)
        try await cancelledBeforeStart(executable)
        try await servingContext(executable)
        try await admissionDeadline(executable)
        try await missingProof(executable)
        try await abortedWhileRunning(executable)
        print("{\"passed\":true,\"groups\":9,\"actualLocalChildren\":true,\"partialAdmission\":true,"
            + "\"requestScopedRefusal\":true,\"endpointRefusal\":true,\"cancelBeforeStart\":true,\"servingContext\":true,"
            + "\"admissionDeadline\":true,\"abortedWhileRunning\":true}")
        alarm(0)
    }

    /// D6: both ranks report that rank 1's memory refused the running request
    /// (`aborted`, then `retired(aborted)`). The request's consumer gets the
    /// abort after the token it already had; nothing is cancelled, fenced or
    /// invalidated, and the same pair serves the next request.
    static func abortedWhileRunning(_ executable: URL) async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        let endpoints = try launch(executable, ["abort-once", "abort-once"], until: end)
        defer { for endpoint in endpoints { endpoint.requestNativeCleanup() } }
        let pair = try ClusterWorkerPair(workers: endpoints, startupDeadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
        let lease = try pair.reserve(requestID: UUID(), reservation: reservation(output: 3, until: end))
        let seen = AbortRecorder()
        // The provider's engine cancels a lease on every failure, this one too:
        // that cancel crosses the abort and must change nothing.
        try lease.start { event in
            seen.record(event)
            if case .aborted = event { lease.cancel(reason: .callerCancelled) }
            return true
        }
        await lease.waitUntilRetired(); lease.releaseResources()
        try requirePartial(seen.events == ["token 9", "aborted memory 1"], "The consumer saw \(seen.events)")
        try requirePartial(pair.readiness != nil && pair.admissionState.isValid, "An aborted request ended the pair")
        try requirePartial(pair.requestsAborted == 1, "The abort was not counted")
        try requirePartial(endpoints.map { $0.counts.1 } == [0, 0], "An aborted request was cancelled")
        try requirePartial(endpoints.allSatisfy { $0.fenceCount == 0 && $0.child.termination == nil },
            "A rank was fenced for an aborted request")
        try await serve(pair, until: end)
        try requirePartial(pair.readiness != nil, "The pair did not stay ready after the next request")
        await pair.shutdown()
        try requirePartial(endpoints.allSatisfy { $0.child.termination == .exited(0) }, "A rank did not exit cleanly")
    }

    fileprivate static func launch(_ executable: URL, _ behaviors: [String], until end: UInt64,
                                   queueFull: [Bool] = [false, false]) throws -> [SubmissionEndpoint] {
        let now = DispatchTime.now().uptimeNanoseconds
        return try (0..<2).map { rank -> SubmissionEndpoint in
            let child = try ClusterWorkerProcess(launch: .init(executable: executable,
                arguments: [String(rank), behaviors[rank]], environment: [:]), expectedIdentity: fixtureIdentity,
                rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: now + 3_000_000_000, initialLeaseDeadline: end)
            try child.launch(); return SubmissionEndpoint(child, queueFull: queueFull[rank])
        }
    }

    /// Candidate 33 (2026-10-22): a ~256K-token reservation was larger than
    /// rank 0's owner command queue (1 MiB); the throw ended the pair ("the
    /// request was cancelled before it started"). An endpoint that cannot
    /// take a reservation now refuses that request alone (retryable `busy`):
    /// the rank that had admitted it gives it back, the other was never
    /// asked, and the same pair serves the next request.
    static func endpointRefusals(_ executable: URL) async throws {
        for (queueFull, reserves, cancels) in [([true, false], [1, 0], [0, 0]), ([false, true], [1, 1], [1, 0])] {
            let end = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
            let endpoints = try launch(executable, ["normal", "normal"], until: end, queueFull: queueFull)
            defer { for endpoint in endpoints { endpoint.requestNativeCleanup() } }
            let pair = try ClusterWorkerPair(workers: endpoints, startupDeadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
            var refusal: ClusterWorkerOwnerError?
            do { _ = try pair.reserve(requestID: UUID(), reservation: reservation(until: end)) }
            catch let error as ClusterWorkerOwnerError { refusal = error }
            try requirePartial(refusal == .refused(.busy), "A full command queue was not this request's refusal (\(String(describing: refusal)))")
            try requirePartial(pair.readiness != nil && pair.admissionState.isValid, "A full command queue quarantined the pair")
            try requirePartial(endpoints.map { $0.counts.0 } == reserves, "Unexpected reservation submission")
            try requirePartial(endpoints.map { $0.counts.1 } == cancels, "Cancel reached an unconfirmed or unasked rank")
            try requirePartial(endpoints.allSatisfy { $0.child.termination == nil }, "A rank was fenced for a request-scoped refusal")
            await pair.shutdown()
            try requirePartial(endpoints.allSatisfy { $0.child.termination == .exited(0) }, "A rank did not exit cleanly")
        }
    }

    /// A request its caller cancels after both ranks admitted it, before it
    /// started, gives both reservations back (`retired(cancelled)`); nothing
    /// is fenced and the pair serves the next request.
    static func cancelledBeforeStart(_ executable: URL) async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        let endpoints = try launch(executable, ["normal", "normal"], until: end)
        defer { for endpoint in endpoints { endpoint.requestNativeCleanup() } }
        let pair = try ClusterWorkerPair(workers: endpoints, startupDeadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
        let lease = try pair.reserve(requestID: UUID(), reservation: reservation(until: end))
        lease.cancel(reason: .callerCancelled)
        await lease.waitUntilRetired(); lease.releaseResources()
        try requirePartial(lease.withdrewBeforeStart, "A cancel before start was not given back cleanly")
        try requirePartial(pair.readiness != nil && pair.admissionState.isValid, "A cancel before start quarantined the pair")
        try requirePartial(endpoints.map { $0.counts.1 } == [1, 1], "Both admitted ranks must be told to give the reservation back")
        try requirePartial(endpoints.allSatisfy { $0.child.termination == nil }, "A rank was fenced for a cancel before start")
        try await serve(pair, until: end)
        await pair.shutdown()
        try requirePartial(endpoints.allSatisfy { $0.child.termination == .exited(0) }, "A rank did not exit cleanly")
    }

    static func reservation(prompt: Int = 3, output: Int = 2, until end: UInt64) -> ClusterWorkerReservation {
        .init(profileID: fixtureProfile.id, promptTokenIDs: Array(1...prompt), stopTokenIDs: [], outputCount: output,
              chunkSize: 2, deadlineUptimeNanoseconds: end, capacityLimitBytes: 1800, sampling: nil, prefixCache: nil)
    }

    /// One complete request on the pair: reserved, started, every token taken.
    static func serve(_ pair: ClusterWorkerPair, until end: UInt64, prompt: Int = 3) async throws {
        let lease = try pair.reserve(requestID: UUID(), reservation: reservation(prompt: prompt, until: end))
        let finished = AdmissionCompletion()
        try lease.start { event in
            if case .finished = event { finished.complete(refused: false) }
            if case .failed = event { finished.complete(refused: true) }
            return true
        }
        await lease.waitUntilRetired(); lease.releaseResources()
        try requirePartial(finished.result == false, "The request after a refusal did not finish")
    }

    /// Production rule (round 2): a rank's refusal fails that request alone.
    /// The rank that had admitted it gives its reservation back
    /// (`retired(cancelled)`), the pair stays ready, and the same pair serves
    /// the next request. Before, either refusal quarantined the pair.
    static func requestScopedRefusals(_ executable: URL) async throws {
        for (behaviors, reserves, cancels) in [
            (["refuse-once", "normal"], [1, 0], [0, 0]),
            (["normal", "refuse-once"], [1, 1], [1, 0])
        ] {
            let end = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
            let endpoints = try launch(executable, behaviors, until: end)
            defer { for endpoint in endpoints { endpoint.requestNativeCleanup() } }
            let pair = try ClusterWorkerPair(workers: endpoints, startupDeadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
            var refusal: ClusterWorkerOwnerError?
            do { _ = try pair.reserve(requestID: UUID(), reservation: reservation(until: end)) }
            catch let error as ClusterWorkerOwnerError { refusal = error }
            try requirePartial(refusal == .refused(.capacity), "Refusal was not reported as this request's (\(String(describing: refusal)))")
            try requirePartial(pair.readiness != nil && pair.admissionState.isValid, "A request-scoped refusal quarantined the pair")
            try requirePartial(endpoints.map { $0.counts.0 } == reserves, "Unexpected reservation submission")
            try requirePartial(endpoints.map { $0.counts.1 } == cancels, "Cancel reached an unconfirmed or refused rank")
            try requirePartial(pair.requestsRefused == 1, "Refusal not counted")
            try await serve(pair, until: end)
            try requirePartial(pair.readiness != nil, "The pair did not stay ready after serving")
            await pair.shutdown()
            try requirePartial(endpoints.allSatisfy(\.nativeCleanupObserved), "Missing actual child cleanup")
            try requirePartial(endpoints.allSatisfy { $0.child.termination == .exited(0) }, "A rank did not exit cleanly")
        }
    }

    /// A request longer than what a rank's gate admits now is refused before
    /// either rank is asked; a keep-warm answer that reports more room lets the
    /// same request through.
    static func servingContext(_ executable: URL) async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        let endpoints = try launch(executable, ["normal", "context-4-8"], until: end)
        defer { for endpoint in endpoints { endpoint.requestNativeCleanup() } }
        let pair = try ClusterWorkerPair(workers: endpoints, startupDeadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000,
            keepWarm: .init(enabled: true, dataPlaneIntervalNanoseconds: 50_000_000, answerNanoseconds: 2_000_000_000))
        // The first exchange may already have run: read the value before it can.
        let first = endpoints[1].readiness?.servingContextTokens
        try requirePartial(first == 4, "Readiness did not carry the serving context")
        var refusal: ClusterWorkerOwnerError?
        if pair.servingContextTokens == 4 {
            do { _ = try pair.reserve(requestID: UUID(), reservation: reservation(prompt: 3, output: 2, until: end)) }
            catch let error as ClusterWorkerOwnerError { refusal = error }
            try requirePartial(refusal == .refused(.capacity), "A request above the serving context was not refused up front")
            try requirePartial(endpoints.map { $0.counts.0 } == [0, 0], "A rank was asked for a request above the serving context")
            try requirePartial(pair.readiness?.servingContextTokens == 4 && pair.admissionState.isValid,
                "An up-front refusal changed the pair")
        }
        let wait = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while pair.servingContextTokens != 8, DispatchTime.now().uptimeNanoseconds < wait { try await Task.sleep(nanoseconds: 10_000_000) }
        try requirePartial(pair.servingContextTokens == 8, "A keep-warm answer did not update the serving context")
        try await serve(pair, until: end)
        await pair.shutdown()
        try requirePartial(endpoints.allSatisfy { $0.child.termination == .exited(0) }, "A rank did not exit cleanly")
    }

    /// Production, 2026-11-03 (six drops of a GLM pair in 19 minutes): a
    /// request whose own admission deadline, its first-content budget, passes
    /// while rank 0 is still answering ends alone. Rank 0 gives back its late
    /// admission, rank 1 is never asked, nothing is fenced and the same pair
    /// serves the next request. Before, the pair was quarantined and both
    /// ranks were fenced.
    static func admissionDeadline(_ executable: URL) async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        let endpoints = try launch(executable, ["slow-admit", "normal"], until: end)
        defer { for endpoint in endpoints { endpoint.requestNativeCleanup() } }
        let pair = try ClusterWorkerPair(workers: endpoints, startupDeadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
        var outcome: ClusterWorkerOwnerError?
        do {
            _ = try pair.reserve(requestID: UUID(), reservation: reservation(until: end),
                admissionDeadline: DispatchTime.now().uptimeNanoseconds + 100_000_000)
        } catch let error as ClusterWorkerOwnerError { outcome = error }
        try requirePartial(outcome == .deadline, "The request did not end with its deadline (\(String(describing: outcome)))")
        try requirePartial(pair.readiness != nil && pair.admissionState.isValid,
            "One request's admission deadline quarantined the pair: \(pair.lastRequestFailure ?? "no failure noted")")
        try requirePartial(endpoints.map(\.fenceCount) == [0, 0], "A rank was fenced for one request's deadline")
        try requirePartial(endpoints.map { $0.counts.0 } == [1, 0], "Rank 1 was asked after the request's deadline")
        try requirePartial(endpoints.map { $0.counts.1 } == [1, 0], "Rank 0's late admission was not given back")
        try await serve(pair, until: end)
        await pair.shutdown()
        try requirePartial(endpoints.allSatisfy { $0.child.termination == .exited(0) }, "A rank did not exit cleanly")
    }

    /// A rank that does not answer within the pair's own admission wait has
    /// failed: the pair is quarantined, that rank is fenced, and reserve does
    /// not return before its actual cleanup proof. The rank never asked holds
    /// nothing of the request: it is not fenced, and the pair's shutdown ends it.
    static func missingProof(_ executable: URL) async throws {
        let now = DispatchTime.now().uptimeNanoseconds, end = now + 10_000_000_000
        let endpoints = try (0..<2).map { rank -> SubmissionEndpoint in
            let child = try ClusterWorkerProcess(launch: .init(executable: executable,
                arguments: [String(rank), rank == 0 ? "slow-admit" : "normal"], environment: [:]),
                expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: now + 3_000_000_000, initialLeaseDeadline: end)
            try child.launch(); return SubmissionEndpoint(child, holdProof: rank == 0)
        }
        defer { for endpoint in endpoints { endpoint.allowCleanupProof(); endpoint.requestNativeCleanup() } }
        let pair = try ClusterWorkerPair(workers: endpoints, startupDeadline: now + 3_000_000_000,
            timing: .init(admissionWaitNanoseconds: 100_000_000, shutdownAcknowledgementNanoseconds: 2_000_000_000))
        let completion = AdmissionCompletion()
        DispatchQueue.global().async {
            do {
                _ = try pair.reserve(requestID: UUID(), reservation: .init(profileID: fixtureProfile.id,
                    promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: 2, chunkSize: 2,
                    deadlineUptimeNanoseconds: end, capacityLimitBytes: 1800, sampling: nil, prefixCache: nil))
                completion.complete(refused: false)
            } catch { completion.complete(refused: true) }
        }
        let wait = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !endpoints[0].child.nativeCleanupObserved, DispatchTime.now().uptimeNanoseconds < wait {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try requirePartial(endpoints[0].child.nativeCleanupObserved, "Expected rank 0's actual child exit")
        try requirePartial(completion.result == nil && !endpoints[0].nativeCleanupObserved && pair.readiness == nil,
            "Missing endpoint proof allowed reserve to return/release its partial ownership")
        try requirePartial(endpoints.map { $0.counts.1 } == [0, 0], "Pending/never-submitted rank received cancel")
        try requirePartial(endpoints[1].counts.0 == 0 && endpoints[1].fenceCount == 0,
            "The rank never asked was fenced (\(endpoints[1].fenceCount)) or asked")
        endpoints[0].allowCleanupProof()
        while completion.result == nil, DispatchTime.now().uptimeNanoseconds < wait {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try requirePartial(completion.result == true, "Actual cleanup proof did not finish failed admission")
        await pair.shutdown()
        try requirePartial(endpoints[1].child.termination == .exited(0), "The rank never asked did not exit by its shutdown")
    }
}
