import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
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
    /// Reservations to refuse for this request alone, as a live gate does.
    var refusals = 0
    private(set) var released: [UUID] = []
    private var reservedID: UUID?
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
        lock.lock(); defer { lock.unlock() }
        if refusals > 0 {
            refusals -= 1
            throw ClusterResidentRequestRefusal(reason: .capacity, message: "Resident request needs 11.90 GiB and has 11.39 GiB")
        }
        request = value; reservedID = id; held = true; return 1024
    }
    func releaseReservation(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard reservedID == id else { throw WorkerFailure.invalid("Fake release has no reservation") }
        released.append(id); reservedID = nil; request = nil; cancelled = false; held = false
    }
    func refreshServingContext() -> Int? { 6000 }
    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason {
        lock.lock(); starts += 1; let value = request!; lock.unlock()
        defer { lock.lock(); held = false; lock.unlock() }
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
    func keepWarmPulse() throws -> UInt64 { lock.lock(); pulses += 1; lock.unlock(); return 1 }
    func dataPlanePing() throws -> UInt64 { lock.lock(); pings += 1; lock.unlock(); return 1 }
    var pulses = 0, pings = 0
    /// Each idle release's `underPressure`, and whether a request was reserved
    /// or running then (`held`).
    private var releases: [(pressure: Bool, reserved: Bool)] = []
    private var held = false
    var idleReleases: [Bool] { lock.lock(); defer { lock.unlock() }; return releases.map(\.pressure) }
    var releasedWhileReserved: Bool { lock.lock(); defer { lock.unlock() }; return releases.contains(where: \.reserved) }
    func releaseIdleMemory(underPressure: Bool) -> Int? {
        lock.lock(); releases.append((underPressure, held)); lock.unlock(); return 4096
    }
}

/// Host pressure a test sets, for `WorkerIdleRelease`.
private final class PressureSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var on: Bool { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); value = newValue; lock.unlock() } }
}

extension WorkerIdleRelease {
    /// Never due and never under pressure: the release stays out of other tests.
    static let never = WorkerIdleRelease(delayNanoseconds: UInt64.max / 2, hostUnderPressure: { false })
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?
    func save(_ error: Error) { lock.lock(); value = error; lock.unlock() }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Records when the coordinator would begin the process's forced exit, and
/// whether the runtime was still loaded at that moment.
private final class ExitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(reason: String, runtimeClosed: Bool)] = []
    weak var runtime: FakeRuntime?
    var hooks: WorkerExitHooks {
        WorkerExitHooks(begin: { [self] reason in
            lock.lock(); calls.append((reason, runtime?.didClose ?? true)); lock.unlock()
        })
    }
    var reasons: [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.reason) }
    var beganBeforeRelease: Bool { lock.lock(); defer { lock.unlock() }; return calls.first.map { !$0.runtimeClosed } ?? false }
}

private final class Harness {
    let runtime: FakeRuntime
    let exits = ExitRecorder()
    let done = DispatchGroup()
    let result = ResultBox()
    private(set) var input: Int32
    private(set) var output: Int32
    private var sequence: UInt64 = 0
    private var renewals: UInt64 = 0
    init(rank: Int = 0, leaseNanoseconds: UInt64 = 5_000_000_000, idleRelease: WorkerIdleRelease = .never) throws {
        runtime = FakeRuntime(rank: rank)
        exits.runtime = runtime
        var a: [Int32] = [0, 0], b: [Int32] = [0, 0]
        guard pipe(&a) == 0, pipe(&b) == 0 else { throw WorkerFailure.invalid("Test pipe creation failed") }
        input = a[1]; output = b[0]
        let childInput = a[0], childOutput = b[1], runtime = runtime, result = result, done = done, hooks = exits.hooks
        let box = coordinatorBox
        done.enter()
        Thread.detachNewThread {
            do {
                let io = try WorkerPipes(input: childInput, output: childOutput,
                    deadline: DispatchTime.now().uptimeNanoseconds + leaseNanoseconds)
                let coordinator = try WorkerCoordinator(runtime: runtime, pipes: io, exitHooks: hooks,
                    idleRelease: idleRelease)
                box.set(coordinator)
                try coordinator.run()
            } catch { result.save(error) }
            close(childInput); close(childOutput); done.leave()
        }
    }
    /// The coordinator under test, for the force-cancel hook (set before `run`).
    final class CoordinatorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: WorkerCoordinator?
        func set(_ coordinator: WorkerCoordinator) { lock.lock(); value = coordinator; lock.unlock() }
        var coordinator: WorkerCoordinator? { lock.lock(); defer { lock.unlock() }; return value }
    }
    let coordinatorBox = CoordinatorBox()
    /// One rank-lease renewal line, outside the request sequence.
    func renew(ttl: UInt64) throws {
        renewals += 1
        let data = try ClusterWorkerCodec.encode(ClusterWorkerLeaseRenewal(membershipEpoch: runtime.ready.identity.membershipEpoch,
            renewal: renewals, ttlNanoseconds: ttl))
        let count = data.withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) }
        guard count == data.count else { throw WorkerFailure.invalid("Test renewal short write") }
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
            capacityLimitBytes: 4096, sampling: nil)
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
            "--deadline-uptime-nanoseconds", "120000000100"]
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
        // The launch deadline is the rank lease's first grant: at most 120 s.
        for (index, value) in [(3, "00"), (7, epoch.uppercased()), (9, "other"), (23, "120000000101"), (23, "300000000100")] {
            var changed = args; changed[index] = value
            XCTAssertThrowsError(try WorkerConfiguration(arguments: changed, now: 100))
        }
        XCTAssertThrowsError(try WorkerConfiguration(arguments: args + ["--rank", "1"], now: 100))
    }

    /// The model ID is a closed choice and the cut must be one of that model's.
    func testRegistered27BArgumentsAndCrossedModelCuts() throws {
        let epoch = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let args = ["--model-dir", "/invented/model", "--rank", "0", "--stage-cut", "16",
            "--membership-epoch", epoch, "--model-id", "registered_qwen38_27b",
            "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
            "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
            "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
            "--deadline-uptime-nanoseconds", "120000000100"]
        for cut in stride(from: 4, through: 60, by: 4) { for rank in [0, 1] {
            var selected = args; selected[3] = String(rank); selected[5] = String(cut)
            let value = try WorkerConfiguration(arguments: selected, now: 100)
            XCTAssertEqual(value.load.rank, rank); XCTAssertEqual(value.load.stageCut, cut)
            XCTAssertEqual(value.load.identity.modelID, "registered_qwen38_27b")
            XCTAssertEqual(value.load.allocatorPolicy, .disableFreedBufferCache)
            XCTAssertEqual(value.load.prefillSchedule, .serial)
        } }
        XCTAssertEqual(try WorkerConfiguration(arguments: args + ["--prefill-schedule", "one_chunk_lookahead_v1"], now: 100)
            .load.prefillSchedule, .oneChunkLookahead)
        for cut in ["0", "2", "6", "18", "30", "62", "64", "68", "-4", "016", "+16", "16.0"] {
            var selected = args; selected[5] = cut
            XCTAssertThrowsError(try WorkerConfiguration(arguments: selected, now: 100), "27B cut \(cut)")
        }
        // A cut only the 27B has is refused for the 9B, and an ID outside the
        // closed catalog is refused whatever the cut.
        for cut in ["20", "32", "60"] {
            var selected = args; selected[9] = "registered_qwen35_9b"; selected[5] = cut
            XCTAssertThrowsError(try WorkerConfiguration(arguments: selected, now: 100), "9B cut \(cut)")
        }
        for model in ["registered_qwen38_27b ", "Registered_Qwen38_27B", "EigenLabs/Qwen3.8-27B-4bit-mtp",
                      "registered_qwen4", "registered_qwen38_27b_v2", "qwen38_27b"] {
            var selected = args; selected[9] = model
            XCTAssertThrowsError(try WorkerConfiguration(arguments: selected, now: 100), "model \(model)")
        }
    }

    /// The Prism Hadamard pack is its own closed ID with the 27B's cuts; its
    /// catalog ID and near misses are refused like any unregistered model.
    func testRegisteredBonsaiArgumentsAndUnregisteredNeighbours() throws {
        let args = ["--model-dir", "/invented/model", "--rank", "0", "--stage-cut", "24",
            "--membership-epoch", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--model-id", "registered_ternary_bonsai_2_27b",
            "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
            "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
            "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
            "--deadline-uptime-nanoseconds", "120000000100"]
        for cut in stride(from: 4, through: 60, by: 4) { for rank in [0, 1] {
            var selected = args; selected[3] = String(rank); selected[5] = String(cut)
            let value = try WorkerConfiguration(arguments: selected, now: 100)
            XCTAssertEqual(value.load.rank, rank); XCTAssertEqual(value.load.stageCut, cut)
            XCTAssertEqual(value.load.identity.modelID, "registered_ternary_bonsai_2_27b")
            XCTAssertEqual(value.load.allocatorPolicy, .disableFreedBufferCache)
        } }
        XCTAssertEqual(try WorkerConfiguration(arguments: args + ["--prefill-schedule", "one_chunk_lookahead_v1"], now: 100)
            .load.prefillSchedule, .oneChunkLookahead)
        for cut in ["0", "2", "26", "30", "62", "64", "-4", "024", "24.0"] {
            var selected = args; selected[5] = cut
            XCTAssertThrowsError(try WorkerConfiguration(arguments: selected, now: 100), "Bonsai cut \(cut)")
        }
        for model in ["ternary-bonsai-2-27b", "registered_ternary_bonsai_2_27b ", "registered_ternary_bonsai_2",
                      "registered_bonsai_2_27b", "Registered_Ternary_Bonsai_2_27B", "prism_hadamard_qwen35"] {
            var selected = args; selected[9] = model
            XCTAssertThrowsError(try WorkerConfiguration(arguments: selected, now: 100), "model \(model)")
        }
    }

    func testEvidenceDirectoryIsOptionalAndMustBeNormalized() throws {
        let args = ["--model-dir", "/invented/model", "--rank", "1", "--stage-cut", "4",
            "--membership-epoch", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--model-id", "registered_qwen35_9b",
            "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
            "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
            "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
            "--deadline-uptime-nanoseconds", "120000000100"]
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

    /// `--generation-mode` is a closed choice that the named model's own row
    /// must list; absent, the worker runs the pipeline exactly as before.
    func testGenerationModeIsADeclaredClosedChoicePerRegisteredModel() throws {
        func args(_ model: String, _ cut: String) -> [String] {
            ["--model-dir", "/invented/model", "--rank", "1", "--stage-cut", cut,
             "--membership-epoch", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--model-id", model,
             "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
             "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
             "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
             "--deadline-uptime-nanoseconds", "120000000100"]
        }
        for (model, cut) in [("registered_qwen35_9b", "8"), ("registered_qwen38_27b", "16"),
                             ("registered_ternary_bonsai_2_27b", "24")] {
            let base = args(model, cut)
            let plain = try WorkerConfiguration(arguments: base, now: 100)
            XCTAssertEqual(plain.generationMode, .pipeline, "absent means the pipeline")
            XCTAssertFalse(plain.qualificationSwitchesPermitted)
            let row = try XCTUnwrap(QwenResidentCapabilityMetadata.registeredModel(runtimeModelID: model)?.supportedGenerationModes)
            for mode in ClusterGenerationMode.allCases {
                guard row.contains(mode) else {
                    // A mode the model's own row does not list stops the worker.
                    XCTAssertThrowsError(try WorkerConfiguration(arguments: base + ["--generation-mode", mode.rawValue], now: 100),
                        "\(model) \(mode.rawValue)")
                    continue
                }
                let value = try WorkerConfiguration(arguments: base + ["--generation-mode", mode.rawValue], now: 100)
                XCTAssertEqual(value.generationMode, mode, "\(model) \(mode.rawValue)")
                // The mode is no part of the load configuration the runtime already had.
                XCTAssertEqual(value.load.stageCut, plain.load.stageCut); XCTAssertEqual(value.load.prefillSchedule, plain.load.prefillSchedule)
                XCTAssertFalse(value.qualificationSwitchesPermitted)
            }
            // Never a fallback: an unknown, misspelt, empty or repeated mode stops the worker.
            for bad in ["phase_split", "phase-split", "phase_split_v2", "PIPELINE_V1", "pipeline", " phase_split_v1", "1"] {
                XCTAssertThrowsError(try WorkerConfiguration(arguments: base + ["--generation-mode", bad], now: 100), bad)
            }
            XCTAssertThrowsError(try WorkerConfiguration(arguments: base + ["--generation-mode", ""], now: 100))
            XCTAssertThrowsError(try WorkerConfiguration(arguments: base + ["--generation-mode", "phase_split_v1",
                                                                          "--generation-mode", "pipeline_v1"], now: 100))
            XCTAssertThrowsError(try WorkerConfiguration(arguments: base + ["--generation-mode"], now: 100))
            // The speculative depth: only with the speculative phase split, 1...4, canonical, once.
            if row.contains(.phaseSplitMTP) {
                let speculative = base + ["--generation-mode", "phase_split_mtp_v1"]
                XCTAssertNil(try WorkerConfiguration(arguments: speculative, now: 100).speculativeTerms, "absent means the default")
                XCTAssertEqual(try WorkerConfiguration(arguments: speculative + ["--mtp-depth", "2"], now: 100).speculativeTerms?.depth, 2)
                for bad in ["0", "5", "04", "", "four", "-1"] {
                    XCTAssertThrowsError(try WorkerConfiguration(arguments: speculative + ["--mtp-depth", bad], now: 100), bad)
                }
                XCTAssertThrowsError(try WorkerConfiguration(arguments: base + ["--generation-mode", "phase_split_v1", "--mtp-depth", "4"], now: 100))
                XCTAssertThrowsError(try WorkerConfiguration(arguments: base + ["--mtp-depth", "4"], now: 100))
                XCTAssertThrowsError(try WorkerConfiguration(arguments: speculative + ["--mtp-depth", "4", "--mtp-depth", "4"], now: 100))
            }
            // It composes with every other optional argument.
            let all = try WorkerConfiguration(arguments: base + ["--prefill-schedule", "one_chunk_lookahead_v1",
                "--generation-mode", "phase_split_v1", "--startup-deadline-uptime-nanoseconds", "90000000100",
                "--evidence-directory", "/private/run/evidence", "--qualification-switches", "yes"], now: 100)
            XCTAssertEqual(all.generationMode, .phaseSplit); XCTAssertEqual(all.load.prefillSchedule, .oneChunkLookahead)
            XCTAssertEqual(all.startupDeadlineUptimeNanoseconds, 90_000_000_100)
            XCTAssertEqual(all.evidenceDirectory, "/private/run/evidence"); XCTAssertTrue(all.qualificationSwitchesPermitted)
        }
        // The catalog the worker checks against is the runtime's own row; the 9B and 27B ship a head and run
        // tensor parallel (round 6e).
        for model in ["registered_qwen35_9b", "registered_qwen38_27b", "registered_ternary_bonsai_2_27b"] {
            XCTAssertEqual(QwenResidentCapabilityMetadata.registeredModel(runtimeModelID: model)?.supportedGenerationModes,
                           [.pipeline, .pipelineCompactDecode, .phaseSplit]
                               + (model.contains("bonsai") ? [] : [.phaseSplitMTP, .tensorParallel, .pipelineMTP]), model)
        }
    }

    /// The two qualification switches cannot take effect in a worker that was
    /// not started with the explicit test flag: it stops, and says which.
    func testQualificationSwitchesAreRefusedWithoutTheExplicitTestFlag() throws {
        let args = ["--model-dir", "/invented/model", "--rank", "0", "--stage-cut", "8",
            "--membership-epoch", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--model-id", "registered_qwen35_9b",
            "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
            "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
            "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
            "--deadline-uptime-nanoseconds", "120000000100"]
        let installed = try WorkerConfiguration(arguments: args, now: 100)
        let qualification = try WorkerConfiguration(arguments: args + ["--qualification-switches", "yes"], now: 100)
        XCTAssertFalse(installed.qualificationSwitchesPermitted); XCTAssertTrue(qualification.qualificationSwitchesPermitted)
        // The flag takes one value. Anything else is not "off": it is refused.
        for bad in ["no", "true", "1", "YES", "yes ", ""] {
            XCTAssertThrowsError(try WorkerConfiguration(arguments: args + ["--qualification-switches", bad], now: 100), bad)
        }
        let serving = ["PATH": "/usr/bin:/bin", "JACCL_RANK": "0", "JACCL_COORDINATOR": "10.0.0.1:47000",
                       "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1", "DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128"]
        func refusal(_ permitted: Bool, _ extra: [String: String]) -> String? {
            do {
                _ = try WorkerQualificationGate.admit(permitted: permitted, environment: serving.merging(extra) { $1 })
                return nil
            } catch { return "\(error)" }
        }
        // An ordinary serving environment passes either way and yields the matching switches.
        XCTAssertEqual(try WorkerQualificationGate.admit(permitted: false, environment: serving), .refused)
        XCTAssertEqual(try WorkerQualificationGate.admit(permitted: true, environment: serving), .permittedByExplicitFlag)
        XCTAssertFalse(QwenResidentQualificationSwitches.refused.permitted)
        // Without the flag each switch is refused by name, whatever its value,
        // including an empty or unknown one: present is enough.
        for (name, values) in [("DARKBLOOM_CLUSTER_TRANSPORT", ["local-socket-test", "jaccl", "", "tcp"]),
                               ("DARKBLOOM_CLUSTER_QUALIFICATION_FAULT", ["handoff_corrupt_segment=3", "handoff_stall_after_segment=2:1500", "", "x"]),
                               // S16: the data-plane tamper fault and the short rekey interval.
                               ("DARKBLOOM_CLUSTER_QUALIFICATION_TAMPER", ["residualPayload:3", "", "x"]),
                               ("DARKBLOOM_CLUSTER_QUALIFICATION_REKEY", ["records:64", "", "x"])] {
            for value in values {
                let message = refusal(false, [name: value])
                XCTAssertNotNil(message, "\(name)=\(value) must be refused without the flag")
                XCTAssertTrue(message?.contains(name) == true, message ?? "")
                XCTAssertTrue(message?.contains("--qualification-switches") == true, message ?? "")
                XCTAssertNil(refusal(true, [name: value]), "\(name)=\(value) passes the gate with the flag")
            }
        }
        XCTAssertNotNil(refusal(false, ["DARKBLOOM_CLUSTER_TRANSPORT": "local-socket-test",
                                        "DARKBLOOM_CLUSTER_QUALIFICATION_FAULT": "handoff_corrupt_segment=3"]))
        // The retired declaration of the mode is refused with or without the flag.
        for permitted in [false, true] {
            let message = refusal(permitted, ["DARKBLOOM_CLUSTER_GENERATION_MODE": "phase_split_v1"])
            XCTAssertTrue(message?.contains("DARKBLOOM_CLUSTER_GENERATION_MODE") == true, message ?? "nil")
            XCTAssertTrue(message?.contains("--generation-mode") == true, message ?? "nil")
        }
        // The names the gate refuses are the names the runtime would have read.
        XCTAssertEqual(QwenResidentQualificationSwitches.transportEnvironmentName, "DARKBLOOM_CLUSTER_TRANSPORT")
        XCTAssertEqual(QwenResidentQualificationSwitches.faultEnvironmentName, "DARKBLOOM_CLUSTER_QUALIFICATION_FAULT")
        XCTAssertEqual(QwenResidentQualificationSwitches.permittingArgument, "--qualification-switches")
    }

    func testStartupDeadlineIsOptionalCanonicalAndWithinTheHour() throws {
        let args = ["--model-dir", "/invented/model", "--rank", "0", "--stage-cut", "4",
            "--membership-epoch", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--model-id", "registered_qwen35_9b",
            "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
            "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
            "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
            "--deadline-uptime-nanoseconds", "120000000100"]
        XCTAssertNil(try WorkerConfiguration(arguments: args, now: 100).startupDeadlineUptimeNanoseconds)
        let named = try WorkerConfiguration(arguments: args + ["--startup-deadline-uptime-nanoseconds", "90000000100"], now: 100)
        XCTAssertEqual(named.startupDeadlineUptimeNanoseconds, 90_000_000_100)
        // A startup may outlast the first lease grant (the lease is renewed
        // while the model loads), up to the protocol's hour.
        XCTAssertEqual(try WorkerConfiguration(arguments: args + ["--startup-deadline-uptime-nanoseconds", "300000000100"], now: 100)
            .startupDeadlineUptimeNanoseconds, 300_000_000_100)
        // In the past, beyond the hour, or not canonical.
        for value in ["100", "99", "3600000000101", "090000000100", "+90000000100", "9e10", ""] {
            XCTAssertThrowsError(try WorkerConfiguration(arguments: args + ["--startup-deadline-uptime-nanoseconds", value], now: 100), value)
        }
        // It composes with the other optional arguments.
        let all = try WorkerConfiguration(arguments: args + ["--prefill-schedule", "one_chunk_lookahead_v1",
            "--startup-deadline-uptime-nanoseconds", "90000000100", "--evidence-directory", "/private/run/evidence"], now: 100)
        XCTAssertEqual(all.startupDeadlineUptimeNanoseconds, 90_000_000_100)
        XCTAssertEqual(all.load.prefillSchedule, .oneChunkLookahead)
    }

    /// The rank lease (S03): renewals are read outside the request sequence
    /// and keep the worker past its first grant; the keep-warm command (S27
    /// tier 2) runs the data-plane exchange on the executor and is answered.
    func testLeaseRenewalsKeepTheWorkerAndKeepWarmIsAnswered() throws {
        let h = try Harness(leaseNanoseconds: 1_000_000_000)
        guard case .ready = try h.event().event else { return XCTFail("Missing fake ready") }
        // Four renewals over 2.4 s, each good for one second: well past the first grant.
        for _ in 0..<4 { try h.renew(ttl: 1_000_000_000); Thread.sleep(forTimeInterval: 0.6) }
        try h.send(.keepWarm(ordinal: 1))
        guard case .keptWarm(1, _, let serving) = try h.event().event else { return XCTFail("Keep-warm was not answered") }
        // The answer carries the serving context the runtime re-derived now.
        XCTAssertEqual(serving, 6000)
        // The renewals took no command sequence number: keep-warm was command 0.
        XCTAssertEqual(h.runtime.pings, 1)
        try h.renew(ttl: 1_000_000_000)
        try h.send(.shutdown)
        XCTAssertEqual(h.done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(h.exits.reasons.isEmpty, "\(h.exits.reasons)")
    }

    /// Idle memory (`WorkerIdleRelease`): nothing is given back before the
    /// first request, once a request has been retired for the delay it is,
    /// exactly once, and again after the next request.
    func testIdleMemoryIsGivenBackOnceAfterEachRetiredRequest() throws {
        // The rank lease outlasts the test's waits (no renewals here).
        let h = try Harness(leaseNanoseconds: 30_000_000_000,
            idleRelease: .init(delayNanoseconds: 0, hostUnderPressure: { false }))
        guard case .ready = try h.event().event else { return XCTFail("Missing fake ready") }
        Thread.sleep(forTimeInterval: 1.3) // at least one idle tick (one a second without keep-warm)
        XCTAssertEqual(h.runtime.idleReleases, [])
        for (index, id) in [UUID(), UUID()].enumerated() {
            try h.send(.reserve(h.reservation()), id: id)
            XCTAssertEqual(try h.event().event, .admitted(reservedBytes: 1024))
            try h.send(.start, id: id)
            for ordinal in 0..<2 {
                XCTAssertEqual(try h.event().event, .committedToken(ordinal: ordinal, tokenID: 7 + ordinal, committedTokens: 3 + ordinal))
                try h.send(.tokenDecision(ordinal: ordinal, decision: .proceed), id: id)
            }
            XCTAssertEqual(try h.event().event, .finished(.length))
            XCTAssertEqual(try h.event().event, .retired(.clean))
            Thread.sleep(forTimeInterval: 2.5)
            XCTAssertEqual(h.runtime.idleReleases, Array(repeating: false, count: index + 1))
        }
        try h.send(.shutdown); XCTAssertEqual(try h.event().event, .shutdownComplete)
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success); XCTAssertNil(h.result.error)
        XCTAssertFalse(h.runtime.releasedWhileReserved)
    }

    /// The delay holds the release back, and host memory pressure brings it
    /// on every idle tick, never while a request is reserved.
    func testIdleReleaseWaitsForTheDelayAndFollowsHostPressure() throws {
        let pressure = PressureSwitch()
        let h = try Harness(rank: 1, leaseNanoseconds: 30_000_000_000,
            idleRelease: .init(delayNanoseconds: 3_600_000_000_000, hostUnderPressure: { pressure.on }))
        let id = UUID()
        try h.start(id)
        XCTAssertEqual(try h.event().event, .finished(.length))
        XCTAssertEqual(try h.event().event, .retired(.clean))
        Thread.sleep(forTimeInterval: 2.3)
        XCTAssertEqual(h.runtime.idleReleases, [], "an hour's delay has not passed")
        let reserved = UUID()
        try h.send(.reserve(h.reservation()), id: reserved)
        XCTAssertEqual(try h.event().event, .admitted(reservedBytes: 1024))
        pressure.on = true
        Thread.sleep(forTimeInterval: 2.3)
        XCTAssertEqual(h.runtime.idleReleases, [], "a reserved request is never idle")
        try h.send(.cancel(.callerCancelled), id: reserved)
        XCTAssertEqual(try h.event().event, .retired(.cancelled))
        try h.send(.shutdown); XCTAssertEqual(try h.event().event, .shutdownComplete)
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success); XCTAssertNil(h.result.error)
        XCTAssertFalse(h.runtime.releasedWhileReserved)

        let idle = try Harness(leaseNanoseconds: 30_000_000_000,
            idleRelease: .init(delayNanoseconds: 3_600_000_000_000, hostUnderPressure: { pressure.on }))
        guard case .ready = try idle.event().event else { return XCTFail("Missing fake ready") }
        Thread.sleep(forTimeInterval: 3.2)
        XCTAssertGreaterThanOrEqual(idle.runtime.idleReleases.count, 2)
        XCTAssertTrue(idle.runtime.idleReleases.allSatisfy { $0 })
        try idle.send(.shutdown); XCTAssertEqual(try idle.event().event, .shutdownComplete)
        XCTAssertEqual(idle.done.wait(timeout: .now() + 2), .success); XCTAssertNil(idle.result.error)
    }

    /// Without renewals the lease lapses: the reader ends the worker through
    /// the forced exit's hook, as an owner that died would leave it.
    func testUnrenewedLeaseEndsTheWorker() throws {
        let h = try Harness(leaseNanoseconds: 1_000_000_000)
        guard case .ready = try h.event().event else { return XCTFail("Missing fake ready") }
        XCTAssertEqual(h.done.wait(timeout: .now() + 5), .success)
        XCTAssertNotNil(h.result.error); XCTAssertTrue(h.runtime.didClose)
        XCTAssertEqual(h.exits.reasons.first, "lease-expired")
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
            // A clean end never begins the forced exit.
            XCTAssertEqual(h.exits.reasons, [])
        }
    }

    /// A reservation the runtime refuses for this request alone (its live
    /// gate) is answered `refused(capacity)` and the worker keeps serving:
    /// the next reservation is admitted and runs. Round 2: the worker exited.
    func testRefusedReservationKeepsTheWorkerServing() throws {
        let h = try Harness(), first = UUID(), second = UUID()
        h.runtime.refusals = 1
        guard case .ready = try h.event().event else { return XCTFail("Missing fake ready") }
        try h.send(.reserve(h.reservation()), id: first)
        XCTAssertEqual(try h.event().event, .refused(.capacity))
        try h.send(.reserve(h.reservation()), id: second)
        XCTAssertEqual(try h.event().event, .admitted(reservedBytes: 1024))
        try h.send(.start, id: second)
        for ordinal in 0..<2 {
            XCTAssertEqual(try h.event().event, .committedToken(ordinal: ordinal, tokenID: 7 + ordinal, committedTokens: 3 + ordinal))
            try h.send(.tokenDecision(ordinal: ordinal, decision: .proceed), id: second)
        }
        XCTAssertEqual(try h.event().event, .finished(.length))
        XCTAssertEqual(try h.event().event, .retired(.clean))
        try h.send(.shutdown); XCTAssertEqual(try h.event().event, .shutdownComplete)
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success); XCTAssertNil(h.result.error)
        XCTAssertEqual(h.exits.reasons, [])
    }

    /// The owner gives back a reservation that never started because the
    /// other rank refused the request: `cancel` is answered `retired(cancelled)`,
    /// the runtime's reservation is released and the worker keeps serving.
    func testCancelledUnstartedReservationIsGivenBack() throws {
        let h = try Harness(rank: 1), first = UUID(), second = UUID()
        guard case .ready = try h.event().event else { return XCTFail("Missing fake ready") }
        try h.send(.reserve(h.reservation()), id: first)
        XCTAssertEqual(try h.event().event, .admitted(reservedBytes: 1024))
        try h.send(.cancel(.callerCancelled), id: first)
        XCTAssertEqual(try h.event().event, .retired(.cancelled))
        XCTAssertEqual(h.runtime.released, [first])
        try h.send(.reserve(h.reservation()), id: second)
        XCTAssertEqual(try h.event().event, .admitted(reservedBytes: 1024))
        try h.send(.start, id: second)
        XCTAssertEqual(try h.event().event, .finished(.length))
        XCTAssertEqual(try h.event().event, .retired(.clean))
        try h.send(.shutdown); XCTAssertEqual(try h.event().event, .shutdownComplete)
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success); XCTAssertNil(h.result.error)
        XCTAssertEqual(h.exits.reasons, [])
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
        // The reader saw the deadline: the forced exit begins there, before release.
        XCTAssertEqual(h.exits.reasons.first, "request-deadline")
        XCTAssertTrue(h.exits.beganBeforeRelease)
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
        // Lost input begins the forced exit from the reader, before the
        // executor releases the model; the executor's own failure path joins it.
        XCTAssertEqual(h.exits.reasons.first, "lost-input")
        XCTAssertTrue(h.exits.beganBeforeRelease)
    }

    func testExecutorFailureBeginsTheForcedExitBeforeLocalCleanup() throws {
        let h = try Harness(), id = UUID()
        try h.start(id); _ = try h.event()
        try h.send(.cancel(.callerCancelled), id: id)
        XCTAssertEqual(try h.event().event, .failed(.runtimeError))
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(h.exits.reasons.contains("worker-failure"), "\(h.exits.reasons)")
        XCTAssertTrue(h.exits.beganBeforeRelease)
    }

    /// The rank-side force-cancel hook (SIGUSR1 handler): mid-request it
    /// claims the forced exit first, the active request is published as
    /// failed, the model is released and the run ends; the signal's reason is
    /// what the exit records.
    func testForceCancelMidRequestReleasesAndEndsTheWorker() throws {
        let h = try Harness(), id = UUID()
        try h.start(id); _ = try h.event()
        var coordinator: WorkerCoordinator?
        for _ in 0..<50 { coordinator = h.coordinatorBox.coordinator; if coordinator != nil { break }; usleep(20_000) }
        XCTAssertEqual(coordinator?.forceCancel(reason: "signal-usr1"), 1, "one active request")
        // As after a lost input: nothing more is published once the worker
        // fails; the owner's evidence is the exit it observes directly.
        XCTAssertThrowsError(try h.event(), "the event stream ends with the worker")
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success)
        XCTAssertNotNil(h.result.error); XCTAssertTrue(h.runtime.didClose)
        XCTAssertEqual(h.exits.reasons.first, "force-cancel-signal-usr1", "\(h.exits.reasons)")
        XCTAssertTrue(h.exits.beganBeforeRelease)
        XCTAssertEqual(h.runtime.startCount, 1)
    }

    /// Idle, a force-cancel still ends the worker through the same path (the
    /// owner then starts a fresh one): nothing is left half-cancelled.
    func testForceCancelWhileIdleEndsTheWorkerWithNoRequestToFail() throws {
        let h = try Harness()
        _ = try h.event()
        var coordinator: WorkerCoordinator?
        for _ in 0..<50 { coordinator = h.coordinatorBox.coordinator; if coordinator != nil { break }; usleep(20_000) }
        XCTAssertEqual(coordinator?.forceCancel(reason: "test"), 0)
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(h.runtime.didClose)
        // The force-cancel claims first; the executor's own failure path joins it.
        XCTAssertEqual(h.exits.reasons.first, "force-cancel-test", "\(h.exits.reasons)")
        XCTAssertEqual(h.exits.reasons.last, "worker-failure")
    }

    func testCleanShutdownThenEOFNeverBeginsTheForcedExit() throws {
        let h = try Harness()
        _ = try h.event()
        try h.send(.shutdown); XCTAssertEqual(try h.event().event, .shutdownComplete)
        h.closeInput()
        XCTAssertEqual(h.done.wait(timeout: .now() + 2), .success)
        XCTAssertNil(h.result.error)
        XCTAssertEqual(h.exits.reasons, [])
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
