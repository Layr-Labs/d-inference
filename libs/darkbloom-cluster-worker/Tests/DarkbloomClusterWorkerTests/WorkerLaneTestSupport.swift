import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Foundation
@testable import DarkbloomClusterWorker

/// CPU adapter at WorkerRuntime: the coordinator, pipes, codec and protocol
/// state machines remain real. No native state or model is constructed.
final class LaneTestRuntime: WorkerRuntime, @unchecked Sendable {
    let ready: ClusterWorkerReady
    let batchLanes = 2
    private let lock = NSLock()
    private var reservations: [UUID: ClusterWorkerReservation] = [:]
    private var pending: [UUID] = []
    private var started = Set<UUID>()
    private var cancelled = Set<UUID>()
    private var withdrawals: [UUID] = []
    private var closed = false

    init(rank: Int = 0) {
        ready = .init(identity: .init(membershipEpoch: UUID(), modelID: "registered_qwen35_9b",
            artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
            peers: [.init(id: "a", buildSHA256: String(repeating: "c", count: 64)),
                    .init(id: "b", buildSHA256: String(repeating: "d", count: 64))]),
            rank: rank, profile: .init(id: "test", vocabularySize: 100, maximumPromptTokens: 32,
                maximumOutputTokens: 4, maximumChunkTokens: 4, maximumContextTokens: 36),
            executionPlanSHA256: String(repeating: "e", count: 64), requestCapacityBytes: 4096)
    }
    var readiness: ClusterWorkerReady? { lock.withLock { closed ? nil : ready } }
    var hasStartedLanes: Bool { lock.withLock { !pending.isEmpty } }
    var withdrawalAttempts: [UUID] { lock.withLock { withdrawals } }
    var heldRequests: Set<UUID> { lock.withLock { Set(reservations.keys) } }
    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        throw WorkerFailure.invalid("Batch test entered single-request reserve")
    }
    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason {
        throw WorkerFailure.invalid("Batch test entered single-request start")
    }
    func reserveLane(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        try lock.withLock {
            guard reservations.count < batchLanes, reservations[id] == nil else {
                throw WorkerFailure.invalid("Test lanes full")
            }
            reservations[id] = value
            return 1024
        }
    }
    func startLane(_ id: UUID) throws {
        try lock.withLock {
            guard reservations[id] != nil, started.insert(id).inserted else {
                throw WorkerFailure.invalid("Test start lost its reservation")
            }
            pending.append(id)
        }
    }
    func withdrawLane(_ id: UUID) -> Bool {
        lock.withLock {
            withdrawals.append(id)
            guard reservations[id] != nil, !started.contains(id) else { return false }
            reservations[id] = nil
            cancelled.remove(id)
            return true
        }
    }
    func cancel(_ id: UUID) { cancelLane(id) }
    func cancelLane(_ id: UUID) { lock.withLock { _ = cancelled.insert(id) } }
    func serveBatch(host: QwenBatchServingHost) throws {
        while true {
            try host.serviceControl()
            let next: (UUID, ClusterWorkerReservation)? = try lock.withLock {
                guard cancelled.isEmpty else { throw WorkerFailure.invalid("Test batch cancelled") }
                guard !pending.isEmpty else { return nil }
                let id = pending.removeFirst()
                return (id, reservations[id]!)
            }
            guard let (id, value) = next else { return }
            if ready.rank == 0 {
                try host.publishToken(requestID: id, ordinal: 0, tokenID: 7, committedTokens: value.promptTokenIDs.count)
                _ = try host.awaitDecisions([id])
            }
            try host.publishFinished(requestID: id, reason: .length)
            lock.withLock { reservations[id] = nil; started.remove(id) }
        }
    }
    func shutdown() throws { lock.withLock { closed = true; reservations.removeAll(); pending.removeAll() } }
    func keepWarmPulse() throws -> UInt64 { 0 }
    func dataPlanePing() throws -> UInt64 { 0 }
}

final class LaneTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    private var exits: [String] = []
    func save(_ error: Error) { lock.withLock { failure = error } }
    func recordExit(_ reason: String) { lock.withLock { exits.append(reason) } }
    var error: Error? { lock.withLock { failure } }
    var exitReasons: [String] { lock.withLock { exits } }
}

final class LanePipeHarness {
    let runtime: LaneTestRuntime
    let result = LaneTestResult()
    let done = DispatchGroup()
    private let input: Int32
    private let output: Int32
    private var sequence: UInt64 = 0

    init(rank: Int = 0) throws {
        runtime = LaneTestRuntime(rank: rank)
        var a: [Int32] = [0, 0], b: [Int32] = [0, 0]
        guard pipe(&a) == 0 else { throw WorkerFailure.invalid("Test input pipe failed") }
        guard pipe(&b) == 0 else {
            close(a[0]); close(a[1]); throw WorkerFailure.invalid("Test output pipe failed")
        }
        input = a[1]; output = b[0]
        // A failed test must observe EPIPE, never terminate the test runner.
        _ = fcntl(input, F_SETNOSIGPIPE, 1); _ = fcntl(b[1], F_SETNOSIGPIPE, 1)
        let childInput = a[0], childOutput = b[1], runtime = runtime, result = result, done = done
        done.enter()
        Thread.detachNewThread {
            defer { close(childInput); close(childOutput); done.leave() }
            do {
                let pipes = try WorkerPipes(input: childInput, output: childOutput,
                    deadline: DispatchTime.now().uptimeNanoseconds + 15_000_000_000)
                let coordinator = try WorkerCoordinator(runtime: runtime, pipes: pipes,
                    exitHooks: .init(begin: { result.recordExit($0) }))
                try coordinator.run()
            } catch { result.save(error) }
        }
    }
    func send(_ command: ClusterWorkerCommand, id: UUID? = nil) throws {
        try send([(command, id)])
    }
    /// One pipe write preserves the reader's buffered-command schedule.
    func send(_ commands: [(ClusterWorkerCommand, UUID?)]) throws {
        var data = Data()
        for (command, id) in commands {
            data.append(try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(
                membershipEpoch: runtime.ready.identity.membershipEpoch, sequence: sequence, requestID: id, command: command)))
            sequence += 1
        }
        let written = data.withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) }
        guard written == data.count else { throw WorkerFailure.invalid("Test command write failed") }
    }
    func event() throws -> ClusterWorkerEventFrame {
        var bytes = Data()
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while bytes.last != 10 {
            guard DispatchTime.now().uptimeNanoseconds < deadline, bytes.count < 16384 else {
                throw WorkerFailure.invalid("Test event timeout/bound")
            }
            var fd = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
            if poll(&fd, 1, 100) == 0 { continue }
            var byte: UInt8 = 0
            guard Darwin.read(output, &byte, 1) == 1 else { throw WorkerFailure.invalid("Test event EOF") }
            bytes.append(byte)
        }
        return try ClusterWorkerCodec.decodeEvent(bytes)
    }
    var reservation: ClusterWorkerReservation {
        .init(profileID: "test", promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: 1,
            chunkSize: 2, deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000,
            capacityLimitBytes: 4096, sampling: nil)
    }
    deinit { close(input); _ = done.wait(timeout: .now() + 5); close(output) }
}
