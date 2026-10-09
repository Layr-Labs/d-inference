import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

private struct TestFailure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure(message: message) }
}
private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
private func seconds(_ value: Double) -> UInt64 { UInt64(value * 1_000_000_000) }

/// The owner's signal policy against stand-in children: a fence is the end of
/// the command stream, and no signal precedes the child's own hard deadline.
@main struct RetirementPolicyTests {
    static func main() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        try cooperativeFence(executable)
        try silentChildKeepsItsLifetime(executable)
        try finalKillFollowsTheChildsOwnDeadline(executable)
        try startupDeadlineBelongsToTheChild(executable)
        try pairWatchesBothRanks(executable)
        try pairWaitsComeFromItsCaller(executable)
        print("{\"passed\":true,\"groups\":6,\"retirementPolicy\":true,\"actualOwnedChildren\":true,\"modelExecution\":false}")
    }

    static func child(_ executable: URL, rank: Int = 0, _ behavior: String, startup: Double, lifetime: Double,
                      retirement: ClusterWorkerSignalPolicy) throws -> ClusterWorkerProcess {
        let begin = now()
        let value = try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [String(rank), behavior], environment: [:]),
            expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
            startupDeadline: begin + seconds(startup), lifetimeDeadline: begin + seconds(lifetime), retirement: retirement)
        try value.launch()
        return value
    }

    /// A worker that takes three seconds to end itself is left to do so. The
    /// previous owner sent SIGTERM at once and SIGKILL two seconds later.
    static func cooperativeFence(_ executable: URL) throws {
        let worker = try child(executable, "slow-exit", startup: 5, lifetime: 20, retirement: .standard)
        _ = try worker.receiveWorkerEvent(until: now() + seconds(5))
        let fenced = now()
        worker.fence()
        try require(worker.readiness == nil, "Fenced worker still advertised readiness")
        try require(!worker.waitForExit(until: fenced + seconds(1)), "Bounded wait reported an exit that had not happened")
        try require(worker.waitForExit(until: fenced + seconds(8)), "Worker did not end itself after its stream closed")
        try require(worker.termination == .exited(3), "Worker was not left to exit by its own path: \(String(describing: worker.termination))")
        try require(worker.sentSignals.isEmpty, "A signal was sent to a worker that ended itself: \(worker.sentSignals)")
        try require(now() - fenced >= seconds(2.5), "Exit was observed before the worker's own three seconds")
    }

    /// Ignores its stream. Nothing is sent before lifetime plus margin; SIGTERM then suffices.
    static func silentChildKeepsItsLifetime(_ executable: URL) throws {
        let begin = now()
        let worker = try child(executable, "deaf-term", startup: 1.5, lifetime: 1.5,
            retirement: .init(terminateMarginNanoseconds: seconds(0.4), killMarginNanoseconds: seconds(5), reapMarginNanoseconds: seconds(1)))
        _ = try worker.receiveWorkerEvent(until: now() + seconds(1))
        worker.fence()
        try require(!worker.waitForExit(until: begin + seconds(1.2)) && worker.sentSignals.isEmpty,
            "A fenced worker was signalled before its own lifetime ended")
        try require(worker.waitForExit(until: begin + seconds(6)), "Silent worker was never ended")
        try require(worker.termination == .signalled(SIGTERM) && worker.sentSignals == [SIGTERM], "Expected SIGTERM alone: \(worker.sentSignals)")
        try require(now() - begin >= seconds(1.85), "SIGTERM preceded lifetime plus margin")
    }

    /// Ignores its stream and SIGTERM. SIGKILL comes last, after both margins, never on the fence.
    static func finalKillFollowsTheChildsOwnDeadline(_ executable: URL) throws {
        let begin = now()
        let policy = ClusterWorkerSignalPolicy(terminateMarginNanoseconds: seconds(0.3), killMarginNanoseconds: seconds(0.5), reapMarginNanoseconds: seconds(1))
        let worker = try child(executable, "deaf", startup: 1, lifetime: 1, retirement: policy)
        _ = try worker.receiveWorkerEvent(until: now() + seconds(1))
        worker.fence()
        try require(worker.retirementDeadlineUptimeNanoseconds == worker.lifetimeDeadline + seconds(1.8), "Retirement ceiling differs from its margins")
        try require(!worker.waitForExit(until: begin + seconds(0.9)) && worker.sentSignals.isEmpty, "Signal preceded the worker's lifetime")
        try require(worker.waitForExit(until: worker.retirementDeadlineUptimeNanoseconds), "Worker outlived the final signal")
        try require(worker.termination == .signalled(SIGKILL) && worker.sentSignals == [SIGTERM, SIGKILL], "Expected SIGTERM then SIGKILL: \(worker.sentSignals)")
        try require(now() - begin >= seconds(1.75), "SIGKILL preceded lifetime plus both margins")
    }

    /// A child that never becomes ready may be signalled at its startup deadline
    /// only when it was told that deadline and is contracted to end itself there.
    static func startupDeadlineBelongsToTheChild(_ executable: URL) throws {
        let margin = ClusterWorkerSignalPolicy(childEndsItselfAtStartupDeadline: true, terminateMarginNanoseconds: seconds(0.3),
            killMarginNanoseconds: seconds(5), reapMarginNanoseconds: seconds(1))
        var begin = now()
        let told = try child(executable, "never-ready", startup: 0.5, lifetime: 4, retirement: margin)
        try require(told.waitForExit(until: begin + seconds(2.5)), "Child told its startup deadline was not ended after it")
        try require(told.termination == .signalled(SIGTERM) && told.sentSignals == [SIGTERM], "Expected SIGTERM after the startup deadline")
        try require(now() - begin >= seconds(0.75), "SIGTERM preceded startup deadline plus margin")

        begin = now()
        let untold = try child(executable, "never-ready", startup: 0.5, lifetime: 2,
            retirement: .init(terminateMarginNanoseconds: seconds(0.3), killMarginNanoseconds: seconds(5), reapMarginNanoseconds: seconds(1)))
        try require(!untold.waitForExit(until: begin + seconds(1.6)) && untold.sentSignals.isEmpty,
            "A child that owns only its lifetime was signalled at the owner's startup deadline")
        try require(untold.readiness == nil, "Startup expiry left the child usable")
        try require(untold.waitForExit(until: begin + seconds(5)) && untold.sentSignals == [SIGTERM], "Lifetime escalation missing")
        try require(now() - begin >= seconds(2.25), "SIGTERM preceded lifetime plus margin")

        begin = now()
        let own = try child(executable, "startup-exit", startup: 2, lifetime: 4, retirement: margin)
        try require(own.waitForExit(until: begin + seconds(2)), "Self-ending child was not observed")
        try require(own.termination == .exited(123) && own.sentSignals.isEmpty, "Self-ending child was signalled")
    }

    /// The admission and shutdown waits are the caller's, chosen for the model
    /// its ranks hold. Neither ends in a signal.
    static func pairWaitsComeFromItsCaller(_ executable: URL) throws {
        func pair(_ behaviors: [String], _ timing: ClusterWorkerPairTiming) throws -> ([ClusterWorkerProcess], ClusterWorkerPair) {
            let workers = try (0..<2).map { try child(executable, rank: $0, behaviors[$0], startup: 5, lifetime: 20, retirement: .standard) }
            return (workers, try ClusterWorkerPair(workers: workers, startupDeadline: now() + seconds(5), timing: timing))
        }
        func reservation() -> ClusterWorkerReservation {
            .init(profileID: fixtureProfile.id, promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: 2, chunkSize: 2,
                  deadlineUptimeNanoseconds: now() + seconds(10), capacityLimitBytes: 1800)
        }
        func settle(_ pair: ClusterWorkerPair) {
            let done = DispatchSemaphore(value: 0)
            Task.detached { await pair.shutdown(); done.signal() }
            done.wait()
        }
        try require(ClusterWorkerPairTiming.standard == .init(admissionWaitNanoseconds: seconds(5), shutdownAcknowledgementNanoseconds: seconds(2)),
            "The standing waits changed")
        var refused = false
        do { _ = try ClusterWorkerPair(workers: [], startupDeadline: now() + seconds(1), timing: .init(admissionWaitNanoseconds: 0, shutdownAcknowledgementNanoseconds: seconds(2))) }
        catch { refused = true }
        try require(refused, "An unbounded wait was accepted")

        // A rank that takes 0.3 s to admit: refused under a 0.1 s wait, admitted under the standing one.
        let hasty = try pair(["slow-admit", "normal"], .init(admissionWaitNanoseconds: seconds(0.1), shutdownAcknowledgementNanoseconds: seconds(2)))
        var admitted = true
        do { _ = try hasty.1.reserve(requestID: UUID(), reservation: reservation()) } catch { admitted = false }
        try require(!admitted && hasty.1.readiness == nil, "The caller's admission wait was not applied")
        settle(hasty.1)
        try require(hasty.0.allSatisfy { $0.observedExit && $0.sentSignals.isEmpty }, "An admission wait ended in a signal")
        let patient = try pair(["slow-admit", "normal"], .standard)
        let lease = try patient.1.reserve(requestID: UUID(), reservation: reservation())
        try require(lease.reservedBytes == 1600, "A rank that admitted within the standing wait was refused")
        lease.cancel()
        let limit = now() + seconds(6)
        while !lease.isRetired && now() < limit { Thread.sleep(forTimeInterval: 0.01) }
        lease.releaseResources()
        settle(patient.1)

        // A rank that takes 0.5 s to release: its stream is closed after a 0.2 s
        // wait (the stand-in reports that as status 21), and it is left to
        // finish; under a 2 s wait it acknowledges and exits 0.
        let brisk = try pair(["slow-shutdown", "slow-shutdown"], .init(admissionWaitNanoseconds: seconds(5), shutdownAcknowledgementNanoseconds: seconds(0.2)))
        settle(brisk.1)
        try require(brisk.0.allSatisfy { $0.termination == .exited(21) && $0.sentSignals.isEmpty },
            "The caller's shutdown wait was not applied, or ended in a signal: \(brisk.0.map { String(describing: $0.termination) })")
        let calm = try pair(["slow-shutdown", "slow-shutdown"], .standard)
        settle(calm.1)
        try require(calm.0.allSatisfy { $0.termination == .exited(0) && $0.sentSignals.isEmpty }, "A rank that released within its wait was not left to acknowledge")
    }

    /// Rank 1 exits while rank 0 is still starting. The pair fails at once
    /// rather than waiting out rank 0's startup deadline.
    static func pairWatchesBothRanks(_ executable: URL) throws {
        let policy = ClusterWorkerSignalPolicy(childEndsItselfAtStartupDeadline: true, terminateMarginNanoseconds: seconds(0.2),
            killMarginNanoseconds: seconds(5), reapMarginNanoseconds: seconds(1))
        let begin = now()
        let first = try child(executable, rank: 0, "never-ready", startup: 2.5, lifetime: 2.5, retirement: policy)
        let second = try child(executable, rank: 1, "exit-early", startup: 2.5, lifetime: 2.5, retirement: policy)
        var refused = false
        do { _ = try ClusterWorkerPair(workers: [first, second], startupDeadline: begin + seconds(2.5)) } catch { refused = true }
        let elapsed = now() - begin
        try require(refused, "A pair formed without rank 1")
        try require(elapsed < seconds(1.2), "Pair waited for rank 0's startup deadline before looking at rank 1 (\(elapsed / 1_000_000) ms)")
        try require(second.termination == .exited(9), "Rank 1's own exit was not observed")
        try require(first.readiness == nil && first.sentSignals.isEmpty, "Rank 0 was signalled when the pair failed")
        try require(first.waitForExit(until: begin + seconds(6)) && first.sentSignals == [SIGTERM], "Rank 0 was not retired after its own startup deadline")
    }
}
