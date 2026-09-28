import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

private struct EndpointTestFailure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw EndpointTestFailure(message: message) }
}

/// Fabricated transport loss/withheld owner proof around an ACTUAL local child.
/// This does not implement SSH or authenticate a remote owner.
private final class HeldProofEndpoint: ClusterWorkerEndpoint, @unchecked Sendable {
    let child: ClusterWorkerProcess
    private let lock = NSLock(), proof = DispatchGroup()
    private var eof = false, released = false
    private var invalidated: (@Sendable () -> Void)?
    init(_ child: ClusterWorkerProcess) { self.child = child; proof.enter() }
    var expectedIdentity: ClusterWorkerIdentity { child.expectedIdentity }
    var expectedProfile: ClusterWorkerProfile { child.expectedProfile }
    var rank: Int { child.rank }
    var executionPlanSHA256: String { child.executionPlanSHA256 }
    var localLifetimeDeadlineUptimeNanoseconds: UInt64 { child.localLifetimeDeadlineUptimeNanoseconds }
    var readiness: ClusterWorkerReady? { lock.withLock { eof ? nil : child.readiness } }
    var nativeCleanupObserved: Bool { lock.withLock { released && child.nativeCleanupObserved } }
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { invalidated = handler }; child.setInvalidationHandler(handler)
    }
    func sendWorkerCommand(_ command: ClusterWorkerCommand, requestID: UUID?, deadline: UInt64) throws {
        if lock.withLock({ eof }) { throw ClusterWorkerOwnerError.closed }
        try child.sendWorkerCommand(command, requestID: requestID, deadline: deadline)
    }
    func receiveWorkerEvent(until deadline: UInt64, cancelled: () -> Bool) throws -> ClusterWorkerEventFrame {
        if lock.withLock({ eof }) { throw ClusterWorkerOwnerError.closed }
        return try child.receiveWorkerEvent(until: deadline, cancelled: cancelled)
    }
    func requestNativeCleanup() { child.requestNativeCleanup() }
    func waitForNativeCleanup() { child.waitForNativeCleanup(); proof.wait() }
    func waitUntilNativeCleanup() async {
        await child.waitUntilNativeCleanup()
        await withCheckedContinuation { c in proof.notify(queue: .global()) { c.resume() } }
    }
    func simulateTransportEOF() {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in eof = true; return invalidated }
        if let callback { DispatchQueue.global().async(execute: callback) }
    }
    func allowObservedProof() {
        let first = lock.withLock { if released { return false }; released = true; return true }
        if first { proof.leave() }
    }
}

@main struct EndpointOwnershipTests {
    static func children(_ executable: URL) throws -> [ClusterWorkerProcess] {
        let now = DispatchTime.now().uptimeNanoseconds
        let values = try (0..<2).map { rank in
            try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [String(rank), "normal"], environment: [:]),
                expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: now + 5_000_000_000, lifetimeDeadline: now + UInt64(20 + rank) * 1_000_000_000)
        }
        do { for value in values { try value.launch() } }
        catch { for value in values { value.fence() }; throw error }
        return values
    }

    static func reservation() -> ClusterWorkerReservation {
        .init(profileID: fixtureProfile.id, promptTokenIDs: [1, 2, 3], stopTokenIDs: [],
              outputCount: 2, chunkSize: 2,
              deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000,
              capacityLimitBytes: 1800)
    }

    static func awaitFact(_ message: String, _ fact: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while !fact() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try require(fact(), message)
    }

    static func main() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        try await retainedProof(executable)
        try await deadlineCompatibility(executable)
        print("{\"passed\":true,\"groups\":2,\"actualLocalChildren\":true,\"simulatedTransportFailure\":true,\"remoteExecution\":false}")
    }

    static func retainedProof(_ executable: URL) async throws {
        let workers = try children(executable), held = HeldProofEndpoint(workers[1])
        defer { held.allowObservedProof(); for worker in workers { worker.requestNativeCleanup() } }
        let pair = try ClusterWorkerPair(workers: [workers[0], held],
                                        startupDeadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        let lease = try pair.reserve(requestID: UUID(), reservation: reservation())
        try require(lease.bytesInUse == 1600, "Real fake-child admission did not reserve both ranks")
        held.simulateTransportEOF()
        // No start: transport failure must still fence both native reservations.
        try await awaitFact("Missing actual local child exits") { workers.allSatisfy(\.observedExit) }
        try require(!held.nativeCleanupObserved && !lease.isRetired,
                    "Transport EOF or unacknowledged native exit manufactured endpoint cleanup")
        lease.releaseResources()
        try require(lease.bytesInUse == 1600 && pair.readiness == nil, "Missing proof dropped reserved capacity")
        held.allowObservedProof()
        try await awaitFact("Matching owner proof did not complete cleanup") { lease.isRetired }
        lease.releaseResources()
        try require(lease.bytesInUse == 0, "Actual cleanup did not release request")
        await pair.shutdown()
        try require(held.nativeCleanupObserved, "Final owner cleanup missing")
    }

    static func deadlineCompatibility(_ executable: URL) async throws {
        let workers = try children(executable)
        defer { for worker in workers { worker.requestNativeCleanup() } }
        // Explicit existential array also proves mixed-endpoint construction is public.
        let endpoints: [any ClusterWorkerEndpoint] = workers
        let pair = try ClusterWorkerPair(workers: endpoints,
                                        startupDeadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        try require(pair.localLifetimeDeadlineUptimeNanoseconds == workers.map(\.lifetimeDeadline).min(),
                    "Endpoint factoring lost the local lifetime minimum")
        let id = UUID()
        var refused = false
        do { _ = try pair.reserve(requestID: id, reservation: reservation(), admissionDeadline: 1) }
        catch { refused = true }
        try require(refused && pair.readiness != nil, "Expired TTFT admission consumed pair ownership")
        let lease = try pair.reserve(requestID: id, reservation: reservation())
        try lease.start { _ in true }
        try await awaitFact("Normal endpoint request did not retire") { lease.isRetired }
        lease.releaseResources()
        await pair.shutdown()
        try require(workers.allSatisfy(\.nativeCleanupObserved), "Direct-child shutdown lost observed-exit proof")
    }
}
