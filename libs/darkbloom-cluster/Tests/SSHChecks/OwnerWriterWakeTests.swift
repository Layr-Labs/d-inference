import Foundation
import Darwin
import DarkbloomClusterProtocol
@_spi(OwnerService) import DarkbloomClusterProcess
@testable import DarkbloomClusterRemote

/// The owner writer must write a queued frame as soon as it is queued, and
/// rest otherwise. It used to write one frame per pass and sleep 5 ms between
/// passes, so every command waited for the next pass: a leader that answers
/// each token with a decision paid a whole pass per token on the product path.
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ClusterOwnerStateError.invalid(message) }
}
func directory() throws -> URL {
    let value = URL(fileURLWithPath: "/private/tmp/cluster-writer-wake-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return value
}
/// CPU time of this whole process (every endpoint thread included).
func cpuNanoseconds() -> UInt64 {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    let seconds = UInt64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
    let micros = UInt64(usage.ru_utime.tv_usec) + UInt64(usage.ru_stime.tv_usec)
    return seconds * 1_000_000_000 + micros * 1_000
}
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func milliseconds(_ value: UInt64) -> String { String(format: "%.3f", Double(value) / 1_000_000) }

/// How late this host wakes a thread that waits for a deadline. The writer
/// sleeps on a semaphore until its renewal is due, on a user-interactive
/// queue; the probe does the same every 20 ms while the renewals run and
/// keeps the worst overshoot. A renewal may be late by that much, which
/// depends on the host (Blacksmith's VMs mostly wake within a few
/// milliseconds but one was 46 ms late, a Darkbloom VM was 17 ms late once).
final class WakeLatencyProbe: @unchecked Sendable {
    private let lock = NSLock(), sleeper = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
    private var running = true, worst: UInt64 = 0, samples = 0

    init(periodNanoseconds: UInt64 = 20_000_000) {
        DispatchQueue(label: "owner-writer-wake.probe", qos: .userInteractive).async { [self] in
            while lock.withLock({ running }) {
                let deadline = now() + periodNanoseconds
                _ = sleeper.wait(timeout: .init(uptimeNanoseconds: deadline))
                let woke = now(), late = woke > deadline ? woke - deadline : 0
                lock.withLock { worst = max(worst, late); samples += 1 }
            }
            stopped.signal()
        }
    }

    /// Stops the probe; returns its worst overshoot and its number of waits.
    func stop() -> (worst: UInt64, samples: Int) {
        lock.withLock { running = false }
        stopped.wait()
        return lock.withLock { (worst, samples) }
    }
}

@main struct OwnerWriterWakeTests {
    static func main() throws {
        let owner = URL(fileURLWithPath: CommandLine.arguments[1]), worker = CommandLine.arguments[2]
        try idleWakeDeadline()
        try commandsAreWrittenWhenQueued(owner, worker)
        try theWriterRestsBeforeTheHello(owner, worker)
        try renewalsKeepTheirCadenceAndAFencedWriterRests(owner, worker)
        print("owner-writer-wake: 4 CPU groups passed")
    }

    static func endpoint(_ owner: URL, _ worker: String, _ dir: URL, behavior: String,
                         lifetimeNanoseconds: UInt64 = 15_000_000_000,
                         writerIdleNanoseconds: UInt64 = ClusterRemoteWorkerEndpoint.writerIdleNanoseconds) throws -> ClusterRemoteWorkerEndpoint {
        try .init(transport: .init(executable: owner, arguments: [worker, dir.path, "0", behavior], environment: [:]),
            clusterID: "cpu-test", expectedIdentity: fixtureIdentity, profile: fixtureProfile, rank: 0,
            executionPlanSHA256: fixturePlan, lifetimeDeadlineUptimeNanoseconds: now() + lifetimeNanoseconds,
            writerIdleNanoseconds: writerIdleNanoseconds)
    }
    static func event(_ e: ClusterRemoteWorkerEndpoint) throws -> ClusterWorkerEvent {
        try e.receiveWorkerEvent(until: now() + 5_000_000_000).event
    }
    /// Ends a session the way the product does and requires the owner's release.
    static func finish(_ e: ClusterRemoteWorkerEndpoint) throws {
        try e.sendWorkerCommand(.shutdown, requestID: nil, deadline: now() + 5_000_000_000)
        if case .shutdownComplete = try event(e) {} else { throw OwnerWire.invalid("Expected shutdown acknowledgment") }
        try require(e.waitForOwnerReleased(deadline: now() + 5_000_000_000) && e.ownerTermination == .exited(0),
            "Owner was not released after shutdown: \(String(describing: e.ownerTermination))")
    }

    /// An idle writer rests until the next renewal, at most the idle bound.
    /// The renewal time counts only while a renewal can still be sent: before
    /// the hello it is zero and after a fence it is stale, and either would
    /// otherwise put the wake in the past and spin the writer.
    static func idleWakeDeadline() throws {
        let deadline = ClusterRemoteWorkerEndpoint.writerWakeDeadline, idle = ClusterRemoteWorkerEndpoint.writerIdleNanoseconds
        func wake(_ now: UInt64, _ renewal: UInt64, _ canBeSent: Bool) -> UInt64 { deadline(now, renewal, canBeSent, idle) }
        let t: UInt64 = 1_000_000_000_000
        try require(idle == 50_000_000, "The idle bound is not 50 ms")
        try require(wake(t, 0, false) == t + idle, "Before the hello the zero renewal time was used")
        try require(wake(t, t - 3_000_000_000, false) == t + idle, "After a fence the stale renewal time was used")
        try require(wake(t, t + 10_000_000, false) == t + idle, "A renewal that cannot be sent woke the writer")
        try require(wake(t, t + 10_000_000, true) == t + 10_000_000, "A renewal due within the idle bound was not the wake")
        try require(wake(t, t + 5_000_000_000, true) == t + idle, "A renewal beyond the idle bound was not capped")
        // The cadence check below rests its writer longer than a renewal interval.
        let renew = ClusterWorkerLease.renewNanoseconds, longRest = renew + 1_000_000_000
        try require(deadline(t, t + renew, true, longRest) == t + renew, "A renewal due within a longer idle rest was not the wake")
        try require(deadline(t, t + renew, false, longRest) == t + longRest, "A longer idle rest was not the wake when no renewal can be sent")
        try require(wake(t, t - 1, true) == t, "An overdue renewal that can be sent is not due now")
        try require(wake(UInt64.max - 10, UInt64.max - 5, false) == UInt64.max, "The idle bound overflowed")
        try require(wake(UInt64.max - 10, UInt64.max - 5, true) == UInt64.max - 5, "The renewal time near the end of the clock was lost")
    }

    /// Round trips through the actual owner service and a stand-in worker that
    /// answers at once: the time from queuing a command to its answer is the
    /// transport alone. A polling writer adds a whole pass (at least 5 ms) to
    /// every one of them, because the next command is queued just after the
    /// pass that wrote the previous one.
    static func commandsAreWrittenWhenQueued(_ owner: URL, _ worker: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = try endpoint(owner, worker, dir, behavior: "normal")
        guard case .ready = try event(e) else { throw OwnerWire.invalid("Expected readiness") }
        var keepWarm: [UInt64] = [], request: [UInt64] = []
        // Keep-warm exchanges; the first four warm the path and are not counted.
        for ordinal in 1...36 {
            let sent = now()
            try e.sendWorkerCommand(.keepWarm(ordinal: ordinal), requestID: nil, deadline: sent + 5_000_000_000)
            guard case .keptWarm(let answered, _, _) = try event(e), answered == ordinal else { throw OwnerWire.invalid("Expected keep-warm \(ordinal)") }
            if ordinal > 4 { keepWarm.append(now() - sent) }
        }
        // Requests as the leader drives them: reserve, start, then one decision
        // per committed token. Each sample runs from the command to its answer.
        for _ in 0..<6 {
            let id = UUID(), deadline = now() + 8_000_000_000
            var sent = now()
            try e.sendWorkerCommand(.reserve(.init(profileID: fixtureProfile.id, promptTokenIDs: [1, 2], stopTokenIDs: [],
                outputCount: 4, chunkSize: 1, deadlineUptimeNanoseconds: deadline, capacityLimitBytes: 1024, sampling: nil, prefixCache: nil)), requestID: id, deadline: deadline)
            guard case .admitted = try event(e) else { throw OwnerWire.invalid("Expected admission") }
            request.append(now() - sent)
            sent = now()
            try e.sendWorkerCommand(.start, requestID: id, deadline: deadline)
            for ordinal in 0..<4 {
                guard case .committedToken(let committed, _, _, _) = try event(e), committed == ordinal else { throw OwnerWire.invalid("Expected token \(ordinal)") }
                request.append(now() - sent)
                sent = now()
                try e.sendWorkerCommand(.tokenDecision(ordinal: ordinal, decision: .proceed), requestID: id, deadline: deadline)
            }
            guard case .finished(.length) = try event(e) else { throw OwnerWire.invalid("Expected length") }
            request.append(now() - sent)
            guard case .retired(.clean) = try event(e) else { throw OwnerWire.invalid("Expected clean retirement") }
        }
        try finish(e)
        func summary(_ values: [UInt64]) -> (median: UInt64, p90: UInt64, text: String) {
            let sorted = values.sorted()
            let median = sorted[sorted.count / 2], p90 = sorted[sorted.count * 9 / 10]
            return (median, p90, "n=\(sorted.count) min=\(milliseconds(sorted[0])) median=\(milliseconds(median)) p90=\(milliseconds(p90)) max=\(milliseconds(sorted.last!)) ms")
        }
        let warm = summary(keepWarm), served = summary(request)
        print("owner-writer-wake: keep-warm round trips \(warm.text)")
        print("owner-writer-wake: request round trips \(served.text)")
        // A polling writer cannot go below one 5 ms pass here.
        try require(warm.median < 2_500_000, "Keep-warm commands waited for a writer pass: \(warm.text)")
        try require(served.median < 2_500_000, "Request commands waited for a writer pass: \(served.text)")
        try require(served.p90 < 4_500_000, "Most request commands waited for a writer pass: \(served.text)")
    }

    /// Before the hello there is no renewal to schedule (nextRenewalAt is still
    /// zero): the writer must rest, not spin on an expired renewal time. This
    /// owner prepares for 1.5 s before it reads the open.
    static func theWriterRestsBeforeTheHello(_ owner: URL, _ worker: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cpu = cpuNanoseconds(), begin = now()
        let e = try endpoint(owner, worker, dir, behavior: "late-open+normal")
        guard case .ready = try event(e) else { throw OwnerWire.invalid("Expected readiness") }
        let waited = now() - begin, used = cpuNanoseconds() - cpu
        print("owner-writer-wake: before the hello waited \(milliseconds(waited)) ms using \(milliseconds(used)) ms CPU")
        try require(waited >= 1_400_000_000, "The late owner answered before it read the open")
        try require(used < 300_000_000, "The writer spun before the hello: \(milliseconds(used)) ms CPU in \(milliseconds(waited)) ms")
        // The hello itself wakes the writer: the first command is not delayed.
        let sent = now()
        try e.sendWorkerCommand(.keepWarm(ordinal: 1), requestID: nil, deadline: sent + 5_000_000_000)
        guard case .keptWarm = try event(e) else { throw OwnerWire.invalid("Expected keep-warm") }
        print("owner-writer-wake: first command after a late hello answered in \(milliseconds(now() - sent)) ms")
        try finish(e)
    }

    /// An idle writer still renews on time: each renewal follows the last by
    /// the renewal interval, late by no more than this host wakes any waiting
    /// thread (`WakeLatencyProbe`, at least 15 ms allowed). After a fence no
    /// renewal is sent, and the stale renewal time does not make the writer
    /// spin while the owner retires its child (this child needs 3 s).
    ///
    /// This writer's idle rest is one second longer than the renewal
    /// interval, so it renews on time only if it wakes for the renewal. One
    /// that rested a whole idle wait instead is woken last by the readiness
    /// and next one rest later: its first renewal is at least a second late
    /// and its interval at least a second too long, whatever this host's wake
    /// latency. With the 50 ms rest such a writer was late by anything from 0
    /// to 50 ms, so it could pass, and a host that wakes threads 46 ms late
    /// left no room for the allowance at all.
    static func renewalsKeepTheirCadenceAndAFencedWriterRests(_ owner: URL, _ worker: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let begin = now(), idleRest = ClusterWorkerLease.renewNanoseconds + 1_000_000_000
        let e = try endpoint(owner, worker, dir, behavior: "slow-exit", writerIdleNanoseconds: idleRest)
        guard case .ready = try event(e) else { throw OwnerWire.invalid("Expected readiness") }
        let readyAt = now(), cpu = cpuNanoseconds(), probe = WakeLatencyProbe()
        // Each renewal moves the grant to its own send time plus the time to live.
        var last = e.localLifetimeDeadlineUptimeNanoseconds, renewals: [UInt64] = []
        // Long enough for two renewals of a writer that rests whole idle waits.
        while renewals.count < 2 && now() < readyAt + 2 * idleRest + 1_000_000_000 {
            let grant = e.localLifetimeDeadlineUptimeNanoseconds
            if grant != last { renewals.append(grant - ClusterWorkerLease.ttlNanoseconds); last = grant }
            Thread.sleep(forTimeInterval: 0.002)
        }
        let latency = probe.stop()
        let idleCPU = cpuNanoseconds() - cpu, idle = now() - readyAt
        // A renewal may be as late as this host's slowest observed wake, with
        // 5 ms to spare, and never less than the 15 ms a fast host gets.
        let late = max(15_000_000, latency.worst + 5_000_000)
        try require(renewals.count == 2, "Expected two renewals in \(milliseconds(idle)) ms of idle, saw \(renewals.count)")
        let interval = renewals[1] - renewals[0]
        let afterReady = Double(Int64(bitPattern: renewals[0] &- readyAt)) / 1_000_000
        print("owner-writer-wake: first renewal \(String(format: "%.3f", afterReady)) ms after readiness, interval \(milliseconds(interval)) ms; idle CPU \(milliseconds(idleCPU)) ms in \(milliseconds(idle)) ms")
        print("owner-writer-wake: host wake latency worst \(milliseconds(latency.worst)) ms in \(latency.samples) waits; a renewal may be \(milliseconds(late)) ms late")
        try require(latency.samples >= 100, "The wake latency probe ran only \(latency.samples) waits")
        // A writer that rested whole idle waits renews at least this late.
        try require(late < idleRest - ClusterWorkerLease.renewNanoseconds,
            "This host wakes threads \(milliseconds(latency.worst)) ms late: too late to tell a renewal on time from one a whole idle wait late")
        try require(renewals[0] >= begin + ClusterWorkerLease.renewNanoseconds, "The first renewal came before one interval")
        try require(renewals[0] <= readyAt + ClusterWorkerLease.renewNanoseconds + late, "The first renewal was late")
        try require(interval >= ClusterWorkerLease.renewNanoseconds && interval <= ClusterWorkerLease.renewNanoseconds + late,
            "Renewal interval drifted: \(milliseconds(interval)) ms (allowed \(milliseconds(late)) ms late)")
        try require(idleCPU < 500_000_000, "An idle writer used \(milliseconds(idleCPU)) ms CPU in \(milliseconds(idle)) ms")
        // Fence just before the next renewal is due, so its time goes stale
        // while the owner still runs.
        while now() < renewals[1] + ClusterWorkerLease.renewNanoseconds - 200_000_000 { Thread.sleep(forTimeInterval: 0.01) }
        let fencedCPU = cpuNanoseconds(), fencedAt = now()
        e.requestNativeCleanup()
        let grantAtFence = e.localLifetimeDeadlineUptimeNanoseconds
        try require(e.waitForNativeCleanup(until: fencedAt + 8_000_000_000), "The fenced child's terminal did not arrive")
        let fencedFor = now() - fencedAt, used = cpuNanoseconds() - fencedCPU
        print("owner-writer-wake: fenced owner retired its child in \(milliseconds(fencedFor)) ms using \(milliseconds(used)) ms CPU")
        try require(fencedFor >= 2_500_000_000, "The slow child ended sooner than it can")
        try require(used < 300_000_000, "The fenced writer spun on a stale renewal time: \(milliseconds(used)) ms CPU")
        try require(e.localLifetimeDeadlineUptimeNanoseconds == grantAtFence, "A renewal was sent after the fence")
        try require(e.waitForOwnerReleased(deadline: now() + 5_000_000_000) && e.ownerTermination == .exited(0),
            "The fenced owner was not released: \(String(describing: e.ownerTermination))")
    }
}
