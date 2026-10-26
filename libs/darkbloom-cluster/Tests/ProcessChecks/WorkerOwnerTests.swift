import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

private struct TestFailure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure(message: message) }
}
private func rejects(_ body: () throws -> Void) throws {
    var rejected = false; do { try body() } catch { rejected = true }
    try require(rejected, "Expected refusal")
}
private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ClusterWorkerRequestEvent] = []
    func append(_ value: ClusterWorkerRequestEvent) { lock.withLock { values.append(value) } }
    var tokens: [Int] { lock.withLock { values.compactMap { if case .token(let id, _) = $0 { return id }; return nil } } }
    var clean: Bool { lock.withLock { values.contains { if case .finished = $0 { return true }; return false } } }
    var failureText: String? { lock.withLock { values.lazy.compactMap { if case .failed(let text) = $0 { return text }; return nil }.first } }
    var telemetry: (ClusterWorkerRequestTelemetry?, ClusterWorkerRequestTelemetry?)? {
        lock.withLock { values.lazy.compactMap { if case .telemetry(let a, let b) = $0 { return (a, b) }; return nil }.first }
    }
}
private struct Harness: Sendable {
    let workers: [ClusterWorkerProcess]
    let pair: ClusterWorkerPair
    init(_ executable: URL, behaviors: [String] = ["normal", "normal"], lifetimeSeconds: UInt64 = 20) throws {
        let now = DispatchTime.now().uptimeNanoseconds, lifetime = now + lifetimeSeconds * 1_000_000_000
        let deadline = min(now + 5_000_000_000, lifetime)
        workers = try (0..<2).map { rank in
            try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [String(rank), behaviors[rank]], environment: [:]),
                expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: deadline, initialLeaseDeadline: lifetime)
        }
        do { for worker in workers { try worker.launch() }; pair = try .init(workers: workers, startupDeadline: deadline) }
        catch { for worker in workers { worker.fence() }; throw error }
    }
    func reservation(outputs: Int = 2, stops: [Int] = [], seconds: UInt64 = 10, capacity: Int = 1800) -> ClusterWorkerReservation {
        .init(profileID: fixtureProfile.id, promptTokenIDs: [1, 2, 3], stopTokenIDs: stops,
            outputCount: outputs, chunkSize: 2, deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + seconds * 1_000_000_000,
            capacityLimitBytes: capacity, sampling: nil)
    }
    func awaitRetirement(_ request: ClusterWorkerRequest, seconds: Double = 8) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !request.isRetired && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(10)) }
        if !request.isRetired { for worker in workers { worker.fence() } }
        try require(request.isRetired, "Missing actual retirement/fence")
    }
    func finish() async throws {
        await pair.shutdown(); try require(workers.allSatisfy(\.observedExit), "Shutdown did not observe both child exits")
    }
}

@main struct WorkerOwnerTests {
    static func main() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        try progress("normal"); try await normal(executable)
        try progress("cleanStop"); try await cleanStop(executable)
        try progress("cancellation"); try await cancellation(executable)
        try progress("faults"); try await faults(executable)
        try progress("blockedCallback"); try await blockedCallback(executable)
        try progress("refusal"); try await refusal(executable)
        try progress("asymmetricCapacity"); try await asymmetricCapacity(executable)
        try progress("processLifetime"); try await processLifetime(executable)
        try progress("blockedFailureCallback"); try await blockedFailureCallback(executable)
        try progress("slowInvalidation"); try await slowInvalidation(executable)
        try progress("telemetryAndDiagnostics"); try await telemetryAndDiagnostics(executable)
        print("{\"passed\":true,\"groups\":11,\"actualOwnedChildIO\":true,\"modelExecution\":false}")
    }
    static func progress(_ group: String) throws {
        try FileHandle.standardOutput.write(contentsOf: Data(("{\"testing\":\"\(group)\"}\n").utf8))
    }
    static func normal(_ executable: URL) async throws {
        let h = try Harness(executable); defer { for worker in h.workers { worker.fence() } }
        let id = UUID(), lease = try h.pair.reserve(requestID: UUID(), reservation: h.reservation())
        let captured = Captured()
        try require(lease.reservedBytes == 1600 && lease.bytesInUse == 1600 && captured.tokens.isEmpty, "Reserve has no token work")
        lease.releaseResources(); try require(lease.bytesInUse == 1600, "Early release must retain ownership")
        try rejects { _ = try h.pair.reserve(requestID: id, reservation: h.reservation()) }
        try lease.start { captured.append($0); return true }
        try rejects { try lease.start { _ in true } }
        try await h.awaitRetirement(lease); try require(captured.tokens == [9, 10] && captured.clean, "Length tokens/finish")
        lease.releaseResources(); lease.releaseResources(); try require(lease.bytesInUse == 0, "Single resource release")
        let again = try h.pair.reserve(requestID: id, reservation: h.reservation(outputs: 3)), second = Captured()
        try again.start { second.append($0); return true }; try await h.awaitRetirement(again); again.releaseResources()
        try require(second.tokens == [9, 10, 11] && h.pair.readiness != nil, "Fresh request on resident workers")
        try rejects { _ = try h.pair.reserve(requestID: id, reservation: h.reservation()) }
        try await h.finish(); await h.pair.shutdown()
    }
    static func cleanStop(_ executable: URL) async throws {
        for eos in [false, true] {
            let h = try Harness(executable, behaviors: ["normal", eos ? "normal" : "clean-stop"])
            defer { for worker in h.workers { worker.fence() } }
            let lease = try h.pair.reserve(requestID: UUID(), reservation: h.reservation(outputs: 3, stops: eos ? [9] : []))
            let captured = Captured(); try lease.start { captured.append($0); return eos }
            try await h.awaitRetirement(lease); lease.releaseResources()
            try require(captured.tokens == [9] && captured.clean && h.pair.readiness != nil, "Clean stop remains reusable")
            try await h.finish()
        }
    }
    static func cancellation(_ executable: URL) async throws {
        for insideCallback in [false, true] {
            let h = try Harness(executable); defer { for worker in h.workers { worker.fence() } }
            let lease = try h.pair.reserve(requestID: UUID(), reservation: h.reservation()), captured = Captured()
            if insideCallback {
                try lease.start { event in captured.append(event); lease.cancel(); return false }
            } else { lease.cancel() }
            try await h.awaitRetirement(lease); lease.releaseResources()
            try require(!captured.clean, "Cancellation cannot become clean callback stop")
            // Cancelled before it started, the request gives both reservations
            // back and the pair serves on; cancelled while it runs, a pair
            // without lanes ends.
            try require(insideCallback ? h.pair.readiness == nil : h.pair.readiness != nil && lease.withdrewBeforeStart,
                insideCallback ? "A cancel inside a running request must end a pair without lanes"
                    : "A cancel before start must leave the pair serving")
            try await h.finish()
        }
    }
    static func faults(_ executable: URL) async throws {
        for mode in ["exit", "bad-sequence", "partial", "stderr", "hang"] {
            let h = try Harness(executable, behaviors: [mode, "normal"])
            defer { for worker in h.workers { worker.fence() } }
            let lease = try h.pair.reserve(requestID: UUID(), reservation: h.reservation(seconds: mode == "hang" ? 1 : 10))
            let captured = Captured(); try lease.start { captured.append($0); return true }
            try await h.awaitRetirement(lease); lease.releaseResources()
            try require(!captured.clean && h.pair.readiness == nil, "Fault must remain abnormal")
            if mode == "hang" { try require(h.workers[0].observedExit, "Silent hung worker needs actual fence") }
            if mode == "stderr" { try require(h.workers[0].diagnosticTail.count <= 65_536, "Bounded stderr tail") }
            try await h.finish()
        }
    }
    /// S24: each rank's request telemetry reaches the owner's callback once,
    /// before the finish; a worker that writes more than 1 MiB of diagnostics
    /// slowly over a long session is not failed for it (only a flood is).
    static func telemetryAndDiagnostics(_ executable: URL) async throws {
        let h = try Harness(executable, behaviors: ["telemetry", "telemetry"])
        do {
            defer { for worker in h.workers { worker.fence() } }
            let lease = try h.pair.reserve(requestID: UUID(), reservation: h.reservation())
            let captured = Captured(); try lease.start { captured.append($0); return true }
            try await h.awaitRetirement(lease); lease.releaseResources()
            let telemetry = captured.telemetry
            try require(captured.clean && captured.tokens == [9, 10], "Telemetry request finished cleanly")
            try require(telemetry?.0?.handoffNanoseconds == 70_000_000 && telemetry?.1?.handoffNanoseconds == 81_000_000
                && telemetry?.1?.mtpAccepted == 8 && telemetry?.1?.mtpDrafted == 10, "Both ranks' telemetry reached the callback")
            try await h.finish()
        }
        let c = try Harness(executable, behaviors: ["chatty", "normal"], lifetimeSeconds: 40)
        defer { for worker in c.workers { worker.fence() } }
        let lease = try c.pair.reserve(requestID: UUID(), reservation: c.reservation(seconds: 30))
        let captured = Captured(); try lease.start { captured.append($0); return true }
        try progress("telemetryAndDiagnostics:chatty")
        try await c.awaitRetirement(lease, seconds: 25); lease.releaseResources()
        try require(captured.clean && c.pair.readiness != nil, "Slow diagnostics past 1 MiB do not fail the worker")
        try require(c.workers[0].diagnosticBytesTotal > 1_048_576 && c.workers[0].diagnosticTail.count <= 65_536,
            "Every diagnostic byte is counted; the tail stays bounded")
        try await c.finish()
    }
    static func blockedCallback(_ executable: URL) async throws {
        let h = try Harness(executable); defer { for worker in h.workers { worker.fence() } }
        let lease = try h.pair.reserve(requestID: UUID(), reservation: h.reservation()), entered = DispatchSemaphore(value: 0), leave = DispatchSemaphore(value: 0)
        defer { leave.signal() }
        try lease.start { value in
            if case .token = value { entered.signal(); _ = leave.wait(timeout: .now() + 10) }
            return true
        }
        let began = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 2) == .success) }
        }
        try require(began, "Callback never entered")
        lease.cancel(); try await h.awaitRetirement(lease)
        try require(h.workers.allSatisfy(\.observedExit), "Blocked callback needs observed process fences")
        lease.releaseResources(); leave.signal(); try await h.finish()
    }
    static func refusal(_ executable: URL) async throws {
        let h = try Harness(executable, behaviors: ["normal", "refuse"])
        defer { for worker in h.workers { worker.fence() } }
        try rejects { _ = try h.pair.reserve(requestID: UUID(), reservation: h.reservation()) }
        // Round 2: a rank's refusal is the request's alone. Rank 0 gave back
        // what it had admitted; the pair is ready and both ranks still run.
        try require(h.pair.readiness != nil, "A request-scoped refusal must not quarantine the pair")
        try require(!h.workers[0].observedExit && !h.workers[1].observedExit, "A refusal ended a rank")
        try await h.finish()
    }
    static func asymmetricCapacity(_ executable: URL) async throws {
        let h = try Harness(executable, behaviors: ["normal", "larger"])
        defer { for worker in h.workers { worker.fence() } }
        try require(h.pair.readiness?.requestCapacityBytes == 3072, "Named local budgets must aggregate")
        let lease = try h.pair.reserve(requestID: UUID(), reservation: h.reservation(capacity: 2400))
        try require(lease.reservedBytes == 2200, "Larger rank must retain its own allowance")
        try lease.start { _ in true }; try await h.awaitRetirement(lease); lease.releaseResources()
        try await h.finish()
        let tooSmall = try Harness(executable, behaviors: ["normal", "larger"])
        defer { for worker in tooSmall.workers { worker.fence() } }
        try rejects { _ = try tooSmall.pair.reserve(requestID: UUID(), reservation: tooSmall.reservation(capacity: 2100)) }
        try await tooSmall.finish()
    }
    /// A first lease grant (1 s) that lapses before the owner's first renewal
    /// (5 s): the owner fences each child and observes it end by itself.
    /// There is no lifetime: an owner that renews keeps its child.
    static func processLifetime(_ executable: URL) async throws {
        let h = try Harness(executable, lifetimeSeconds: 1)
        defer { for worker in h.workers { worker.fence() } }
        let end = ContinuousClock.now.advanced(by: .seconds(4))
        while !h.workers.allSatisfy(\.observedExit) && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try require(h.workers.allSatisfy(\.observedExit) && h.pair.readiness == nil, "A lapsed lease needs independent exit observation")
        try require(h.workers.allSatisfy { $0.sentSignals.isEmpty }, "A lapsed lease ended its child with a signal")
        try await h.finish()
    }
    static func blockedFailureCallback(_ executable: URL) async throws {
        let h = try Harness(executable, behaviors: ["bad-token", "normal"])
        defer { for worker in h.workers { worker.fence() } }
        let lease = try h.pair.reserve(requestID: UUID(), reservation: h.reservation())
        let entered = DispatchSemaphore(value: 0), leave = DispatchSemaphore(value: 0)
        let cause = Captured()
        defer { leave.signal() }
        try lease.start { value in
            if case .failed = value { cause.append(value); entered.signal(); _ = leave.wait(timeout: .now() + 10) }
            return true
        }
        let began = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 2) == .success) }
        }
        try require(began, "Failure callback never entered")
        // S24: the failure names its cause (the owner side's own fixed text), never a bare "failed".
        try require(cause.failureText?.lowercased().contains("token") == true, "The failure does not name its cause: \(cause.failureText ?? "none")")
        try await h.awaitRetirement(lease)
        try require(h.workers.allSatisfy(\.observedExit), "A blocked failed callback cannot suppress real fencing")
        lease.releaseResources(); leave.signal(); try await h.finish()
    }
    static func slowInvalidation(_ executable: URL) async throws {
        let h = try Harness(executable, behaviors: ["hang", "hang"], lifetimeSeconds: 1)
        defer { for worker in h.workers { worker.fence() } }
        let entered = DispatchSemaphore(value: 0), leave = DispatchSemaphore(value: 0)
        defer { leave.signal() }
        h.pair.setInvalidationHandler { entered.signal(); _ = leave.wait(timeout: .now() + 10) }
        let began = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 2) == .success) }
        }
        try require(began, "Invalidation handler never entered")
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !h.workers.allSatisfy(\.observedExit) && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try require(h.workers.allSatisfy(\.observedExit), "Slow invalidation cannot stop the SIGKILL pump")
        leave.signal(); try await h.finish()
    }
}
