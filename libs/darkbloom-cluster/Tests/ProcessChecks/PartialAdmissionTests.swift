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
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(20)
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        // Refusal on either rank and an unanswered submitted reservation are
        // distinct native-request states. Real children enforce their protocol.
        for (behaviors, milliseconds, reserves, cancels) in [
            (["refuse", "normal"], 3000, [1, 0], [0, 0]),
            (["normal", "refuse"], 3000, [1, 1], [1, 0]),
            (["slow-admit", "normal"], 100, [1, 0], [0, 0])
        ] {
            let now = DispatchTime.now().uptimeNanoseconds, end = now + 10_000_000_000
            let endpoints = try (0..<2).map { rank -> SubmissionEndpoint in
                let child = try ClusterWorkerProcess(launch: .init(executable: executable,
                    arguments: [String(rank), behaviors[rank]], environment: [:]), expectedIdentity: fixtureIdentity,
                    rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                    startupDeadline: now + 3_000_000_000, lifetimeDeadline: end)
                try child.launch(); return SubmissionEndpoint(child)
            }
            defer { for endpoint in endpoints { endpoint.requestNativeCleanup() } }
            let pair = try ClusterWorkerPair(workers: endpoints, startupDeadline: now + 3_000_000_000)
            var refused = false
            do {
                _ = try pair.reserve(requestID: UUID(), reservation: .init(profileID: fixtureProfile.id,
                    promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: 2, chunkSize: 2,
                    deadlineUptimeNanoseconds: end, capacityLimitBytes: 1800),
                    admissionDeadline: DispatchTime.now().uptimeNanoseconds + UInt64(milliseconds) * 1_000_000)
            } catch { refused = true }
            try requirePartial(refused && pair.readiness == nil, "Admission failure did not quarantine pair")
            try requirePartial(endpoints.map { $0.counts.0 } == reserves, "Unexpected reservation submission")
            try requirePartial(endpoints.map { $0.counts.1 } == cancels, "Cancel reached an unconfirmed or refused rank")
            await pair.shutdown()
            try requirePartial(endpoints.allSatisfy(\.nativeCleanupObserved), "Missing actual child cleanup")
        }
        try await missingProof(executable)
        print("{\"passed\":true,\"groups\":4,\"actualLocalChildren\":true,\"partialAdmission\":true}")
        alarm(0)
    }

    static func missingProof(_ executable: URL) async throws {
        let now = DispatchTime.now().uptimeNanoseconds, end = now + 10_000_000_000
        let endpoints = try (0..<2).map { rank -> SubmissionEndpoint in
            let child = try ClusterWorkerProcess(launch: .init(executable: executable,
                arguments: [String(rank), rank == 0 ? "slow-admit" : "normal"], environment: [:]),
                expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: now + 3_000_000_000, lifetimeDeadline: end)
            try child.launch(); return SubmissionEndpoint(child, holdProof: rank == 1)
        }
        defer { for endpoint in endpoints { endpoint.allowCleanupProof(); endpoint.requestNativeCleanup() } }
        let pair = try ClusterWorkerPair(workers: endpoints, startupDeadline: now + 3_000_000_000)
        let completion = AdmissionCompletion()
        DispatchQueue.global().async {
            do {
                _ = try pair.reserve(requestID: UUID(), reservation: .init(profileID: fixtureProfile.id,
                    promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: 2, chunkSize: 2,
                    deadlineUptimeNanoseconds: end, capacityLimitBytes: 1800),
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
