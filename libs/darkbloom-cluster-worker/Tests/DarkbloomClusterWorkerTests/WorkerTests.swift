import Darwin
import DarkbloomClusterProtocol
import Foundation
import XCTest
@testable import DarkbloomClusterWorker

private final class FakeRuntime: WorkerRuntime, @unchecked Sendable {
    let ready: ClusterWorkerReady
    private let lock = NSLock()
    private var request: ClusterWorkerReservation?
    private var cancelled = false
    private var closed = false
    private var starts = 0
    private var shutdowns = 0
    init(rank: Int = 0) {
        ready = .init(identity: .init(membershipEpoch: UUID(), modelID: "registered_qwen35_9b",
            artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
            peers: [.init(id: "a", buildSHA256: String(repeating: "c", count: 64)),
                    .init(id: "b", buildSHA256: String(repeating: "d", count: 64))]),
            rank: rank, profile: .init(id: "test", vocabularySize: 100, maximumPromptTokens: 8192,
                maximumOutputTokens: 128, maximumChunkTokens: 512, maximumContextTokens: 8320),
            executionPlanSHA256: String(repeating: "e", count: 64), requestCapacityBytes: 4096)
    }
    var readiness: ClusterWorkerReady? { lock.lock(); defer { lock.unlock() }; return closed ? nil : ready }
    var didClose: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    var shutdownCount: Int { lock.lock(); defer { lock.unlock() }; return shutdowns }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        lock.lock(); defer { lock.unlock() }; request = value; return 1024
    }
    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason {
        lock.lock(); starts += 1; let value = request!; lock.unlock()
        if ready.rank == 1 { return .length }
        for ordinal in 0..<value.outputCount {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw WorkerFailure.invalid("Fake cancellation") }
            let proceed = try token(ordinal, 7 + ordinal, value.promptTokenIDs.count + ordinal)
            if ordinal + 1 == value.outputCount { return .length }
            if !proceed { return .clientStop }
        }
        throw WorkerFailure.invalid("Fake missing result")
    }
    func cancel(_ id: UUID) { lock.lock(); cancelled = true; lock.unlock() }
    func shutdown() throws { lock.lock(); shutdowns += 1; closed = true; lock.unlock() }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?
    func save(_ error: Error) { lock.lock(); value = error; lock.unlock() }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class Harness {
    let runtime: FakeRuntime
    let done = DispatchGroup()
    let result = ResultBox()
    private(set) var input: Int32
    private(set) var output: Int32
    private var sequence: UInt64 = 0
    init(rank: Int = 0) throws {
        runtime = FakeRuntime(rank: rank)
        var a: [Int32] = [0, 0], b: [Int32] = [0, 0]
        guard pipe(&a) == 0, pipe(&b) == 0 else { throw WorkerFailure.invalid("Test pipe creation failed") }
        input = a[1]; output = b[0]
        let childInput = a[0], childOutput = b[1], runtime = runtime, result = result, done = done
        done.enter()
        Thread.detachNewThread {
            do {
                let io = try WorkerPipes(input: childInput, output: childOutput,
                    deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
                try WorkerCoordinator(runtime: runtime, pipes: io).run()
            } catch { result.save(error) }
            close(childInput); close(childOutput); done.leave()
        }
    }
    func send(_ command: ClusterWorkerCommand, id: UUID? = nil) throws {
        let data = try ClusterWorkerCodec.encode(.init(membershipEpoch: runtime.ready.identity.membershipEpoch,
            sequence: sequence, requestID: id, command: command))
        sequence += 1
        let count = data.withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) }
        guard count == data.count else { throw WorkerFailure.invalid("Test command short write") }
    }
    func eagerStartAndDecision(_ id: UUID) throws {
        var bytes = try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: runtime.ready.identity.membershipEpoch,
            sequence: sequence, requestID: id, command: .start))
        sequence += 1
        bytes.append(try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: runtime.ready.identity.membershipEpoch,
            sequence: sequence, requestID: id, command: .tokenDecision(ordinal: 0, decision: .proceed))))
        sequence += 1
        let count = bytes.withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw WorkerFailure.invalid("Test batched command short write") }
    }
    func event() throws -> ClusterWorkerEventFrame {
        var data = Data()
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while data.last != 10 {
            guard DispatchTime.now().uptimeNanoseconds < deadline, data.count < 16384 else {
                throw WorkerFailure.invalid("Test event deadline/bound")
            }
            var fd = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
            if poll(&fd, 1, 100) == 0 { continue }
            var byte: UInt8 = 0
            guard Darwin.read(output, &byte, 1) == 1 else { throw WorkerFailure.invalid("Test event EOF") }
            data.append(byte)
        }
        return try ClusterWorkerCodec.decodeEvent(data)
    }
    func reservation(deadline: UInt64? = nil) -> ClusterWorkerReservation {
        .init(profileID: "test", promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: 2,
            chunkSize: 2, deadlineUptimeNanoseconds: deadline ?? (DispatchTime.now().uptimeNanoseconds + 3_000_000_000),
            capacityLimitBytes: 4096)
    }
    func start(_ id: UUID, deadline: UInt64? = nil) throws {
        guard case .ready = try event().event else { throw WorkerFailure.invalid("Missing fake ready") }
        try send(.reserve(reservation(deadline: deadline)), id: id)
        guard case .admitted(1024) = try event().event else { throw WorkerFailure.invalid("Missing actual fake admission") }
        try send(.start, id: id)
    }
    func closeInput() { if input >= 0 { close(input); input = -1 } }
    func closeOutput() { if output >= 0 { close(output); output = -1 } }
    deinit { closeInput(); closeOutput(); _ = done.wait(timeout: .now() + 6) }
}

final class WorkerTests: XCTestCase {
    func testExactCLIAndCanonicalBounds() throws {
        let epoch = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let args = ["--model-dir", "/invented/model", "--rank", "0", "--stage-cut", "12",
            "--membership-epoch", epoch, "--model-id", "registered_qwen35_9b",
            "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
            "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
            "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
            "--deadline-uptime-nanoseconds", "300000000100"]
        for cut in [4, 8, 12, 16] { for rank in [0, 1] {
            var selected = args; selected[3] = String(rank); selected[5] = String(cut)
            let value = try WorkerConfiguration(arguments: selected, now: 100)
            XCTAssertEqual(value.load.rank, rank); XCTAssertEqual(value.load.stageCut, cut)
            XCTAssertEqual(value.load.allocatorPolicy, .disableFreedBufferCache)
        } }
        for cut in ["7", "9", "10", "11", "13", "15", "17", "20", "28", "0", "32", "04", "+4", "4.0", "08", "+8", "8.0"] {
            var selected = args; selected[5] = cut
            XCTAssertThrowsError(try WorkerConfiguration(arguments: selected, now: 100))
        }
        for (index, value) in [(3, "00"), (7, epoch.uppercased()), (9, "other"), (23, "300000000101")] {
            var changed = args; changed[index] = value
            XCTAssertThrowsError(try WorkerConfiguration(arguments: changed, now: 100))
        }
        XCTAssertThrowsError(try WorkerConfiguration(arguments: args + ["--rank", "1"], now: 100))
    }

    func testEvidenceDirectoryIsOptionalAndMustBeNormalized() throws {
        let args = ["--model-dir", "/invented/model", "--rank", "1", "--stage-cut", "4",
            "--membership-epoch", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--model-id", "registered_qwen35_9b",
            "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
            "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
            "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
            "--deadline-uptime-nanoseconds", "300000000100"]
        // A serving launch names no evidence directory and gets none.
        XCTAssertNil(try WorkerConfiguration(arguments: args, now: 100).evidenceDirectory)
        let recording = try WorkerConfiguration(arguments: args + ["--evidence-directory", "/private/run/evidence"], now: 100)
        XCTAssertEqual(recording.evidenceDirectory, "/private/run/evidence")
        XCTAssertEqual(recording.load.prefillSchedule, .serial)
        let both = try WorkerConfiguration(arguments: args + ["--prefill-schedule", "one_chunk_lookahead_v1",
            "--evidence-directory", "/private/run/evidence"], now: 100)
        XCTAssertEqual(both.evidenceDirectory, "/private/run/evidence"); XCTAssertEqual(both.load.prefillSchedule, .oneChunkLookahead)
        for path in ["relative/evidence", "/private/../evidence", "/private//evidence", "/private/evidence/", "/", ""] {
            XCTAssertThrowsError(try WorkerConfiguration(arguments: args + ["--evidence-directory", path], now: 100), path)
        }
        XCTAssertThrowsError(try WorkerConfiguration(arguments: args + ["--evidence-directory", "/a", "--evidence-directory", "/b"], now: 100))
    }

    func testStartupDeadlineIsOptionalCanonicalAndWithinTheLifetime() throws {
        let args = ["--model-dir", "/invented/model", "--rank", "0", "--stage-cut", "4",
            "--membership-epoch", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--model-id", "registered_qwen35_9b",
            "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
            "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
            "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
            "--deadline-uptime-nanoseconds", "300000000100"]
        XCTAssertNil(try WorkerConfiguration(arguments: args, now: 100).startupDeadlineUptimeNanoseconds)
        let named = try WorkerConfiguration(arguments: args + ["--startup-deadline-uptime-nanoseconds", "90000000100"], now: 100)
        XCTAssertEqual(named.startupDeadlineUptimeNanoseconds, 90_000_000_100)
        XCTAssertEqual(try WorkerConfiguration(arguments: args + ["--startup-deadline-uptime-nanoseconds", "300000000100"], now: 100)
            .startupDeadlineUptimeNanoseconds, 300_000_000_100)
        // In the past, beyond the lifetime, or not canonical.
        for value in ["100", "99", "300000000101", "090000000100", "+90000000100", "9e10", ""] {
            XCTAssertThrowsError(try WorkerConfiguration(arguments: args + ["--startup-deadline-uptime-nanoseconds", value], now: 100), value)
        }
        // It composes with the other optional arguments.
        let all = try WorkerConfiguration(arguments: args + ["--prefill-schedule", "one_chunk_lookahead_v1",
            "--startup-deadline-uptime-nanoseconds", "90000000100", "--evidence-directory", "/private/run/evidence"], now: 100)
        XCTAssertEqual(all.startupDeadlineUptimeNanoseconds, 90_000_000_100)
        XCTAssertEqual(all.load.prefillSchedule, .oneChunkLookahead)
    }

    func testStartupDeadlineFiresOnlyWhileArmed() throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock(); private var count = 0
            func set() { lock.lock(); count += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let fired = Flag(), spared = Flag()
        let begin = DispatchTime.now().uptimeNanoseconds
        _ = try WorkerStartupDeadline.arm(uptimeNanoseconds: begin + 150_000_000) { fired.set() }
        let ready = try WorkerStartupDeadline.arm(uptimeNanoseconds: begin + 150_000_000) { spared.set() }
        XCTAssertEqual(fired.value, 0, "The deadline acted before its time")
        ready.disarm()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(fired.value, 1, "A worker that never became ready must be ended exactly once at its startup deadline")
        XCTAssertEqual(spared.value, 0, "A worker that became ready must not be ended by its startup deadline")
        XCTAssertEqual(WorkerStartupDeadline.exitStatus, 123)
    }

    func testEvidenceSinkWritesEachRequestOncePrivatelyAndRefusesLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worker-evidence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = try WorkerEvidenceSink(path: root.path)
        let id = UUID(), bytes = Data(repeating: 0x61, count: 150_001)
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        try sink.publish(bytes, requestID: id, deadline: deadline)
        let file = root.appendingPathComponent(WorkerEvidenceSink.fileName(id))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        var info = stat()
        XCTAssertTrue(lstat(file.path, &info) == 0 && info.st_mode & 0o077 == 0)
        // Never replaced: not by the same sink, not by a second one.
        XCTAssertThrowsError(try sink.publish(Data([1]), requestID: id, deadline: deadline))
        XCTAssertThrowsError(try WorkerEvidenceSink(path: root.path).publish(Data([2]), requestID: id, deadline: deadline))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let expired = UUID()
        XCTAssertThrowsError(try sink.publish(Data([1]), requestID: expired, deadline: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(WorkerEvidenceSink.fileName(expired)).path))
        XCTAssertThrowsError(try sink.publish(Data(), requestID: UUID(), deadline: deadline))
        XCTAssertThrowsError(try sink.publish(Data(count: WorkerEvidenceSink.maximumBytes + 1), requestID: UUID(), deadline: deadline))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try WorkerEvidenceSink(path: link.path))
        let linked = UUID()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(WorkerEvidenceSink.fileName(linked)), withDestinationURL: file)
        XCTAssertThrowsError(try sink.publish(Data([1]), requestID: linked, deadline: deadline))
        let open = root.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try WorkerEvidenceSink(path: open.path))
        XCTAssertThrowsError(try WorkerEvidenceSink(path: root.appendingPathComponent("missing").path))
    }

    func testBothRankPathsRetireThenShutdown() throws {
        for rank in [0, 1] {
            let h = try Harness(rank: rank), id = UUID()
            try h.start(id)
            if rank == 0 {
                for ordinal in 0..<2 {
                    XCTAssertEqual(try h.event().event, .committedToken(ordinal: ordinal, tokenID: 7 + ordinal, committedTokens: 3 + ordinal))
                    try h.send(.tokenDecision(ordinal: ordinal, decision: .proceed), id: id)
                }
            }
            XCTAssertEqual(try h.event().event, .finished(.length))
            XCTAssertEqual(try h.event().event, .retired(.clean))
            try h.send(.shutdown)
            XCTAssertEqual(try h.event().event, .shutdownComplete)
            XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success)
            XCTAssertNil(h.result.error); XCTAssertTrue(h.runtime.didClose)
        }
    }

    func testFalseDecisionCleanlyStopsBeforeNextToken() throws {
        let h = try Harness(), id = UUID()
        try h.start(id)
        XCTAssertEqual(try h.event().event, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3))
        try h.send(.tokenDecision(ordinal: 0, decision: .cleanStop), id: id)
        XCTAssertEqual(try h.event().event, .finished(.clientStop))
        XCTAssertEqual(try h.event().event, .retired(.clean))
        try h.send(.shutdown); XCTAssertEqual(try h.event().event, .shutdownComplete)
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success); XCTAssertNil(h.result.error)
    }

    func testCancelAtTokenCreditFailsWithoutInventedRetirement() throws {
        let h = try Harness(), id = UUID()
        try h.start(id); _ = try h.event()
        try h.send(.cancel(.callerCancelled), id: id)
        XCTAssertEqual(try h.event().event, .failed(.runtimeError))
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success)
        XCTAssertNotNil(h.result.error); XCTAssertTrue(h.runtime.didClose)
        XCTAssertThrowsError(try h.event())
    }

    func testRequestDeadlineExpiresWhileWaitingForDecision() throws {
        let h = try Harness(), id = UUID()
        try h.start(id, deadline: DispatchTime.now().uptimeNanoseconds + 300_000_000)
        _ = try h.event()
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success)
        XCTAssertNotNil(h.result.error); XCTAssertTrue(h.runtime.didClose)
        XCTAssertThrowsError(try h.event())
    }

    func testOutputFailurePreventsNativeStart() throws {
        let prior = signal(SIGPIPE, SIG_IGN); defer { signal(SIGPIPE, prior) }
        let h = try Harness(), id = UUID()
        _ = try h.event(); h.closeOutput()
        try h.send(.reserve(h.reservation()), id: id)
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success)
        XCTAssertNotNil(h.result.error); XCTAssertTrue(h.runtime.didClose)
        XCTAssertEqual(h.runtime.startCount, 0)
    }

    func testFailedShutdownPublicationDoesNotReleaseTwice() throws {
        let prior = signal(SIGPIPE, SIG_IGN); defer { signal(SIGPIPE, prior) }
        let h = try Harness()
        _ = try h.event(); h.closeOutput()
        try h.send(.shutdown)
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success)
        XCTAssertNotNil(h.result.error); XCTAssertTrue(h.runtime.didClose)
        XCTAssertEqual(h.runtime.shutdownCount, 1)
    }

    func testUnexpectedEOFReleasesLoadedOwner() throws {
        let h = try Harness()
        _ = try h.event(); h.closeInput()
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success)
        XCTAssertNotNil(h.result.error); XCTAssertTrue(h.runtime.didClose)
        XCTAssertEqual(h.runtime.startCount, 0)
    }

    func testBufferedStartAndEarlyDecisionCannotBorrowFutureCredit() throws {
        let h = try Harness(), id = UUID()
        _ = try h.event()
        try h.send(.reserve(h.reservation()), id: id); _ = try h.event()
        try h.eagerStartAndDecision(id)
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success)
        XCTAssertNotNil(h.result.error); XCTAssertTrue(h.runtime.didClose)
        XCTAssertEqual(h.runtime.startCount, 0)
    }
}
