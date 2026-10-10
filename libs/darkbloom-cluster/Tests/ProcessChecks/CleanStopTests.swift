import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

/// A request ended by its consumer or by its owner's stop, without giving up
/// the pair: the clean stop answers the next committed token, both ranks
/// retire, and the pair takes the next request or answers `shutdown`.
private struct TestFailure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure(message: message) }
}
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ClusterWorkerRequestEvent] = []
    func append(_ value: ClusterWorkerRequestEvent) { lock.withLock { values.append(value) } }
    var tokens: [Int] { lock.withLock { values.compactMap { if case .token(let id) = $0 { return id }; return nil } } }
    var finish: ClusterWorkerFinishReason? {
        lock.withLock { values.lazy.compactMap { if case .finished(let reason) = $0 { return reason }; return nil }.first }
    }
    var failed: Bool { lock.withLock { values.contains { if case .failed = $0 { return true }; return false } } }
}
private struct Pair: Sendable {
    let workers: [ClusterWorkerProcess]
    let pair: ClusterWorkerPair
    init(_ executable: URL, behaviors: [String], cleanStopWait: UInt64 = 0, lifetimeSeconds: UInt64 = 30) throws {
        let now = DispatchTime.now().uptimeNanoseconds, lifetime = now + lifetimeSeconds * 1_000_000_000
        let startup = now + 5_000_000_000
        workers = try (0..<2).map { rank in
            try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [String(rank), behaviors[rank]], environment: [:]),
                expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: startup, lifetimeDeadline: lifetime)
        }
        do {
            for worker in workers { try worker.launch() }
            pair = try .init(workers: workers, startupDeadline: startup, timing: .init(admissionWaitNanoseconds: 5_000_000_000,
                shutdownAcknowledgementNanoseconds: 2_000_000_000, cleanStopWaitNanoseconds: cleanStopWait))
        } catch { for worker in workers { worker.fence() }; throw error }
    }
    func reservation(outputs: Int = 4, seconds: UInt64 = 20) -> ClusterWorkerReservation {
        .init(profileID: fixtureProfile.id, promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: outputs, chunkSize: 2,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + seconds * 1_000_000_000, capacityLimitBytes: 1800)
    }
    func awaitRetirement(_ request: ClusterWorkerRequest, seconds: Double = 8) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !request.isRetired && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(10)) }
        try require(request.isRetired, "The request did not retire")
    }
    /// Both ranks ended themselves: exit status 0 after answering `shutdown`,
    /// and no signal from the owner.
    var endedByShutdown: Bool {
        workers.allSatisfy { $0.observedExit && $0.termination == .exited(0) && $0.sentSignals.isEmpty }
    }
    var description: String { workers.map { "\(String(describing: $0.termination)) signals \($0.sentSignals)" }.joined(separator: "; ") }
}
@main struct CleanStopTests {
    static func main() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        try await consumerGoesAway(executable)
        try await beforeFirstToken(executable)
        try await shutdownMidRequest(executable)
        try await fallBackToCancel(executable)
        print("{\"passed\":true,\"groups\":4,\"cleanStop\":true,\"actualOwnedChildren\":true,\"modelExecution\":false}")
    }

    /// The consumer goes away after the second token of four. The pair stays
    /// valid, nothing is fenced, and the next request is served.
    static func consumerGoesAway(_ executable: URL) async throws {
        let p = try Pair(executable, behaviors: ["normal", "clean-stop"]); defer { for worker in p.workers { worker.fence() } }
        let first = try p.pair.reserve(requestID: UUID(), reservation: p.reservation()), events = Events()
        try first.start { event in
            events.append(event)
            // Gone while the second token was being delivered: the token was
            // wanted, the stop answers it.
            if events.tokens.count == 2 { _ = first.requestCleanStop() }
            return true
        }
        try await p.awaitRetirement(first); first.releaseResources()
        try require(first.cleanStopWasRequested, "the clean stop was not recorded")
        try require(events.tokens == [9, 10] && events.finish == .clientStop && !events.failed,
                    "the request did not end with the clean stop at the next token: \(events.tokens) \(String(describing: events.finish))")
        try require(!first.requestCleanStop(), "a retired request accepted a clean stop")
        try require(p.pair.readiness != nil && p.workers.allSatisfy({ !$0.observedExit }), "the clean stop gave up the pair")
        let second = try p.pair.reserve(requestID: UUID(), reservation: p.reservation()), next = Events()
        try second.start { next.append($0); return false }
        try await p.awaitRetirement(second); second.releaseResources()
        try require(next.tokens == [9] && next.finish == .clientStop, "the next request was not served")
        await p.pair.shutdown()
        try require(p.endedByShutdown, "the ranks did not end by shutdown: \(p.description)")
    }

    /// A consumer that is gone before the first token: the request ends at
    /// its first token, cleanly.
    static func beforeFirstToken(_ executable: URL) async throws {
        let p = try Pair(executable, behaviors: ["normal", "clean-stop"]); defer { for worker in p.workers { worker.fence() } }
        let lease = try p.pair.reserve(requestID: UUID(), reservation: p.reservation()), events = Events()
        try require(lease.requestCleanStop(), "a reserved request refused the clean stop")
        try lease.start { events.append($0); return true }
        try await p.awaitRetirement(lease); lease.releaseResources()
        try require(events.tokens == [9] && events.finish == .clientStop && p.pair.readiness != nil,
                    "a clean stop before the first token did not end at it: \(events.tokens) \(String(describing: events.finish))")
        await p.pair.shutdown()
        try require(p.endedByShutdown, "the ranks did not end by shutdown: \(p.description)")
    }

    /// The owner stops while a request is running: the request ends with the
    /// clean stop well within the wait and both ranks answer `shutdown`.
    static func shutdownMidRequest(_ executable: URL) async throws {
        let p = try Pair(executable, behaviors: ["normal", "clean-stop"], cleanStopWait: 3_000_000_000)
        defer { for worker in p.workers { worker.fence() } }
        let lease = try p.pair.reserve(requestID: UUID(), reservation: p.reservation()), events = Events()
        let entered = DispatchSemaphore(value: 0)
        try lease.start { event in
            events.append(event)
            // A consumer that takes its time with the first token: the stop
            // arrives while the request is running.
            if case .token = event, events.tokens.count == 1 { entered.signal(); usleep(300_000) }
            return true
        }
        let began = await withCheckedContinuation { c in
            DispatchQueue.global().async { c.resume(returning: entered.wait(timeout: .now() + 3) == .success) }
        }
        try require(began, "the first token never arrived")
        let clock = ContinuousClock(), start = clock.now
        await p.pair.shutdown()
        let took = start.duration(to: clock.now)
        try require(events.finish == .clientStop && !events.failed && events.tokens == [9],
                    "the running request was cancelled, not stopped cleanly: \(events.tokens) \(String(describing: events.finish))")
        try require(took < .seconds(2), "the stop took \(took), beyond the clean path")
        try require(p.endedByShutdown, "the ranks did not end by shutdown: \(p.description)")
    }

    /// A request that does not reach a token within the wait is cancelled:
    /// the stop is bounded by the wait plus the ranks' own exit, and still no
    /// signal is sent.
    static func fallBackToCancel(_ executable: URL) async throws {
        let p = try Pair(executable, behaviors: ["stall", "normal"], cleanStopWait: 500_000_000)
        defer { for worker in p.workers { worker.fence() } }
        let lease = try p.pair.reserve(requestID: UUID(), reservation: p.reservation(seconds: 25)), events = Events()
        try lease.start { events.append($0); return true }
        try await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock(), start = clock.now
        await p.pair.shutdown()
        let took = start.duration(to: clock.now)
        try require(lease.isRetired && events.finish == nil, "a stalled request reported a clean finish")
        try require(took >= .milliseconds(500), "the stop did not wait for the clean stop first: \(took)")
        // 0.5 s wait, 2 s until the stream is closed, 1.5 s for the rank to end.
        try require(took < .seconds(7), "the fall-back to cancel was not taken in time: \(took)")
        try require(p.workers.allSatisfy { $0.observedExit && $0.sentSignals.isEmpty }, "a rank was signalled: \(p.description)")
        try require(p.pair.readiness == nil, "a cancelled pair still reports readiness")
    }
}
