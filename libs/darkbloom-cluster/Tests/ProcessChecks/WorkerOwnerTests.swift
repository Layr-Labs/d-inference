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
    var tokens: [Int] { lock.withLock { values.compactMap { if case .token(let id) = $0 { return id }; return nil } } }
    var clean: Bool { lock.withLock { values.contains { if case .finished = $0 { return true }; return false } } }
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
                startupDeadline: deadline, lifetimeDeadline: lifetime)
        }
        do { for worker in workers { try worker.launch() }; pair = try .init(workers: workers, startupDeadline: deadline) }
        catch { for worker in workers { worker.fence() }; throw error }
    }
    func reservation(outputs: Int = 2, stops: [Int] = [], seconds: UInt64 = 10, capacity: Int = 1800) -> ClusterWorkerReservation {
        .init(profileID: fixtureProfile.id, promptTokenIDs: [1, 2, 3], stopTokenIDs: stops,
            outputCount: outputs, chunkSize: 2, deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + seconds * 1_000_000_000,
            capacityLimitBytes: capacity)
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
        print("{\"passed\":true,\"groups\":10,\"actualOwnedChildIO\":true,\"modelExecution\":false}")
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
            try require(!captured.clean && h.pair.readiness == nil, "Cancellation cannot become clean callback stop")
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
        try require(h.pair.readiness == nil, "Partial admission must quarantine the pair")
        try require(h.workers[1].observedExit, "Failed reserve returned before its partial ownership was retired/fenced")
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
    static func processLifetime(_ executable: URL) async throws {
        let h = try Harness(executable, lifetimeSeconds: 1)
        defer { for worker in h.workers { worker.fence() } }
        try rejects { _ = try h.pair.reserve(requestID: UUID(), reservation: h.reservation()) }
        let end = ContinuousClock.now.advanced(by: .seconds(4))
        while !h.workers.allSatisfy(\.observedExit) && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try require(h.workers.allSatisfy(\.observedExit) && h.pair.readiness == nil, "Idle process lifetime needs independent exit observation")
        try await h.finish()
    }
    static func blockedFailureCallback(_ executable: URL) async throws {
        let h = try Harness(executable, behaviors: ["bad-token", "normal"])
        defer { for worker in h.workers { worker.fence() } }
        let lease = try h.pair.reserve(requestID: UUID(), reservation: h.reservation())
        let entered = DispatchSemaphore(value: 0), leave = DispatchSemaphore(value: 0)
        defer { leave.signal() }
        try lease.start { value in
            if case .failed = value { entered.signal(); _ = leave.wait(timeout: .now() + 10) }
            return true
        }
        let began = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 2) == .success) }
        }
        try require(began, "Failure callback never entered")
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
