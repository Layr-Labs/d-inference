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
    private var reserves = 0, cancels = 0
    init(_ child: ClusterWorkerProcess, holdProof: Bool = false) {
        self.child = child; proofGranted = !holdProof
        if holdProof { proof.enter() }
    }
    var counts: (Int, Int) { lock.withLock { (reserves, cancels) } }
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
        try child.sendWorkerCommand(command, requestID: requestID, deadline: deadline)
    }
    func receiveWorkerEvent(until deadline: UInt64, cancelled: () -> Bool) throws -> ClusterWorkerEventFrame {
        try child.receiveWorkerEvent(until: deadline, cancelled: cancelled)
    }
    func requestNativeCleanup() { child.requestNativeCleanup() }
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
        try await servingContext(executable)
        // An unanswered submitted reservation is not a refusal: the pair is
        // quarantined. Real children enforce their protocol.
        for (behaviors, milliseconds, reserves, cancels) in [
            (["slow-admit", "normal"], 100, [1, 0], [0, 0])
        ] {
            let now = DispatchTime.now().uptimeNanoseconds, end = now + 10_000_000_000
            let endpoints = try (0..<2).map { rank -> SubmissionEndpoint in
                let child = try ClusterWorkerProcess(launch: .init(executable: executable,
                    arguments: [String(rank), behaviors[rank]], environment: [:]), expectedIdentity: fixtureIdentity,
                    rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                    startupDeadline: now + 3_000_000_000, initialLeaseDeadline: end)
                try child.launch(); return SubmissionEndpoint(child)
            }
            defer { for endpoint in endpoints { endpoint.requestNativeCleanup() } }
            let pair = try ClusterWorkerPair(workers: endpoints, startupDeadline: now + 3_000_000_000)
            var refused = false
            do {
                _ = try pair.reserve(requestID: UUID(), reservation: .init(profileID: fixtureProfile.id,
                    promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: 2, chunkSize: 2,
                    deadlineUptimeNanoseconds: end, capacityLimitBytes: 1800, sampling: nil),
                    admissionDeadline: DispatchTime.now().uptimeNanoseconds + UInt64(milliseconds) * 1_000_000)
            } catch { refused = true }
            try requirePartial(refused && pair.readiness == nil, "Admission failure did not quarantine pair")
            try requirePartial(endpoints.map { $0.counts.0 } == reserves, "Unexpected reservation submission")
            try requirePartial(endpoints.map { $0.counts.1 } == cancels, "Cancel reached an unconfirmed or refused rank")
            await pair.shutdown()
            try requirePartial(endpoints.allSatisfy(\.nativeCleanupObserved), "Missing actual child cleanup")
        }
        try await missingProof(executable)
        print("{\"passed\":true,\"groups\":6,\"actualLocalChildren\":true,\"partialAdmission\":true,"
            + "\"requestScopedRefusal\":true,\"servingContext\":true}")
        alarm(0)
    }

    fileprivate static func launch(_ executable: URL, _ behaviors: [String], until end: UInt64) throws -> [SubmissionEndpoint] {
        let now = DispatchTime.now().uptimeNanoseconds
        return try (0..<2).map { rank -> SubmissionEndpoint in
            let child = try ClusterWorkerProcess(launch: .init(executable: executable,
                arguments: [String(rank), behaviors[rank]], environment: [:]), expectedIdentity: fixtureIdentity,
                rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: now + 3_000_000_000, initialLeaseDeadline: end)
            try child.launch(); return SubmissionEndpoint(child)
        }
    }

    static func reservation(prompt: Int = 3, output: Int = 2, until end: UInt64) -> ClusterWorkerReservation {
        .init(profileID: fixtureProfile.id, promptTokenIDs: Array(1...prompt), stopTokenIDs: [], outputCount: output,
              chunkSize: 2, deadlineUptimeNanoseconds: end, capacityLimitBytes: 1800, sampling: nil)
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

    static func missingProof(_ executable: URL) async throws {
        let now = DispatchTime.now().uptimeNanoseconds, end = now + 10_000_000_000
        let endpoints = try (0..<2).map { rank -> SubmissionEndpoint in
            let child = try ClusterWorkerProcess(launch: .init(executable: executable,
                arguments: [String(rank), rank == 0 ? "slow-admit" : "normal"], environment: [:]),
                expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: now + 3_000_000_000, initialLeaseDeadline: end)
            try child.launch(); return SubmissionEndpoint(child, holdProof: rank == 1)
        }
        defer { for endpoint in endpoints { endpoint.allowCleanupProof(); endpoint.requestNativeCleanup() } }
        let pair = try ClusterWorkerPair(workers: endpoints, startupDeadline: now + 3_000_000_000)
        let completion = AdmissionCompletion()
        DispatchQueue.global().async {
            do {
                _ = try pair.reserve(requestID: UUID(), reservation: .init(profileID: fixtureProfile.id,
                    promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: 2, chunkSize: 2,
                    deadlineUptimeNanoseconds: end, capacityLimitBytes: 1800, sampling: nil),
                    admissionDeadline: DispatchTime.now().uptimeNanoseconds + 100_000_000)
                completion.complete(refused: false)
            } catch { completion.complete(refused: true) }
        }
        let wait = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !endpoints.allSatisfy({ $0.child.nativeCleanupObserved }), DispatchTime.now().uptimeNanoseconds < wait {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try requirePartial(endpoints.allSatisfy({ $0.child.nativeCleanupObserved }), "Expected actual child exits")
        try requirePartial(completion.result == nil && !endpoints[1].nativeCleanupObserved && pair.readiness == nil,
            "Missing endpoint proof allowed reserve to return/release its partial ownership")
        try requirePartial(endpoints.map { $0.counts.1 } == [0, 0], "Pending/never-submitted rank received cancel")
        endpoints[1].allowCleanupProof()
        while completion.result == nil, DispatchTime.now().uptimeNanoseconds < wait {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try requirePartial(completion.result == true, "Actual cleanup proof did not finish failed admission")
        await pair.shutdown()
    }
}
