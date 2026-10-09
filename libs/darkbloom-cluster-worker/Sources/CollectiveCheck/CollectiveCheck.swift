import Cmlx
import DarkbloomClusterRuntime
import Darwin
import Foundation
import MLX

// Two-rank collective transport qualification. Both ranks run this same
// program with the same arguments; every step is a matching collective on both
// sides, in the same order. It carries no model and no weights.
//
// What a pass means: the strict JACCL backend initialized, both ranks agree on
// rank/world size and on the workload, and every reduction and point-to-point
// transfer returned exactly the expected bytes. What it does not mean: it says
// nothing about which physical device carried the bytes. The caller records
// that separately (interface byte counters, loaded images, stack samples).
//
// A blocked native collective cannot be interrupted from inside the process,
// so a fixed SIGALRM deadline ends the run. It holds no model memory.

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    enum Mode: String { case raw, wrapper }
    var mode = Mode.raw
    var maximumMiB = 64
    var smallIterations = 2000
    var orderedMessages = 64
    var tokenSteps = 512
    var deadlineSeconds = 180

    init(arguments: [String]) throws {
        var index = 0
        func value(_ name: String) throws -> String {
            guard index + 1 < arguments.count else { throw CheckFailure("\(name) needs a value") }
            index += 1
            return arguments[index]
        }
        func bounded(_ name: String, _ range: ClosedRange<Int>) throws -> Int {
            let text = try value(name)
            guard let number = Int(text), String(number) == text, range.contains(number) else {
                throw CheckFailure("\(name) must be an integer in \(range)")
            }
            return number
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--mode":
                guard let parsed = Mode(rawValue: try value("--mode")) else {
                    throw CheckFailure("--mode must be raw or wrapper")
                }
                mode = parsed
            case "--max-mib": maximumMiB = try bounded("--max-mib", 1...1024)
            case "--small-iterations": smallIterations = try bounded("--small-iterations", 1...100_000)
            case "--ordered-messages": orderedMessages = try bounded("--ordered-messages", 1...4096)
            case "--token-steps": tokenSteps = try bounded("--token-steps", 1...100_000)
            case "--deadline-seconds": deadlineSeconds = try bounded("--deadline-seconds", 5...3600)
            default: throw CheckFailure("Unknown argument \(arguments[index])")
            }
            index += 1
        }
    }

    /// Carried through the first agreement so mismatched launches fail on both ranks.
    var agreement: [Int32] {
        [1, mode == .raw ? 1 : 2, Int32(maximumMiB), Int32(smallIterations),
         Int32(orderedMessages), Int32(tokenSteps)]
    }
}

struct Transfer: Encodable {
    let label: String
    let bytes: Int
    let seconds: Double
    let mismatches: Int
}

struct Report: Encodable {
    let schema = "darkbloom_cluster_collective_check_v1"
    let mode: String
    let backend = "jaccl"
    let rank: Int
    let worldSize: Int
    let initSeconds: Double
    var smallReductionCalls = 0
    var smallReductionMismatches = 0
    var firstSmallMismatch: String?
    var reductions: [Transfer] = []
    var pointToPoint: [Transfer] = []
    var orderedMessages = 0
    var orderedMismatches = 0
    var tokenSteps = 0
    var localFailures = 0
    var worldFailures = -1
    var totalSeconds = 0.0
    var passed = false
}

func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func note(_ rank: Int?, _ message: String) {
    let prefix = rank.map { "[collective-check rank \($0)] " } ?? "[collective-check] "
    FileHandle.standardError.write(Data((prefix + message + "\n").utf8))
}

/// Deterministic Int32 payload both ranks can regenerate without overflow.
func pattern(elements: Int, sequence: Int, stream: StreamOrDevice) -> MLXArray {
    let base = MLXArray.arange(elements, dtype: .int32, stream: stream)
    return remainder(base, Int32(65_521), stream: stream) * Int32(31) + Int32(sequence % 1_000_003)
}

func mismatchCount(_ actual: MLXArray, _ expected: MLXArray) -> Int {
    guard actual.shape == expected.shape, actual.dtype == expected.dtype else { return max(1, expected.size) }
    return Int((actual .!= expected).sum().item(Int32.self))
}

/// Direct C calls: the strict backend, with the C status and the MLX error
/// handler both checked after every construction and evaluation.
struct RawGroup {
    let handle: mlx_distributed_group
    let rank: Int
    let size: Int
    let error: ErrorBox
    let stream = StreamOrDevice.cpu

    private func evaluated(_ operation: String, _ build: (inout mlx_array) -> Int32) throws -> MLXArray {
        var result = mlx_array_new()
        let status = build(&result)
        let array = MLXArray(result)
        try error.check()
        guard status == 0 else { throw CheckFailure("\(operation) graph construction failed: \(status)") }
        let evaluation = mlx_array_eval(array.ctx)
        try error.check()
        guard evaluation == 0 else { throw CheckFailure("\(operation) evaluation failed: \(evaluation)") }
        let completion = mlx_synchronize(stream.ctx)
        try error.check()
        guard completion == 0 else { throw CheckFailure("\(operation) completion failed: \(completion)") }
        return array
    }

    func allSum(_ input: MLXArray) throws -> MLXArray {
        try evaluated("all_sum") { mlx_distributed_all_sum(&$0, input.ctx, handle, stream.ctx) }
    }

    func send(_ input: MLXArray, to peer: Int) throws {
        _ = try evaluated("send") { mlx_distributed_send(&$0, input.ctx, Int32(peer), handle, stream.ctx) }
    }

    func receive(elements: Int, from peer: Int) throws -> MLXArray {
        let shape = [Int32(elements)]
        return try evaluated("recv") { result in
            shape.withUnsafeBufferPointer {
                mlx_distributed_recv(&result, $0.baseAddress, $0.count, MLX_INT32, Int32(peer), handle, stream.ctx)
            }
        }
    }
}

@main enum CollectiveCheck {
    static func main() {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            signal(SIGPIPE, SIG_IGN)
            signal(SIGALRM) { _ in Darwin._exit(124) }
            alarm(UInt32(options.deadlineSeconds))
            let report = try Device.withDefaultDevice(.cpu) {
                try options.mode == .raw ? raw(options) : wrapper(options)
            }
            alarm(0)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            Darwin.exit(report.passed ? 0 : 2)
        } catch {
            note(nil, "failed: \(error)")
            Darwin.exit(1)
        }
    }

    static func raw(_ options: Options) throws -> Report {
        try MLX.withError { error in
            let started = uptime()
            guard mlx_distributed_is_available("jaccl") else {
                throw CheckFailure("The jaccl backend is not available in this build or on this host; no fallback is allowed")
            }
            var handle = mlx_distributed_group_new()
            let status = mlx_distributed_init(&handle, true, "jaccl")
            try error.check()
            guard status == 0 else { throw CheckFailure("jaccl initialization failed: \(status)") }
            defer { mlx_distributed_group_free(handle) }
            let rank = Int(mlx_distributed_group_rank(handle))
            let size = Int(mlx_distributed_group_size(handle))
            guard size == 2, rank == 0 || rank == 1 else {
                throw CheckFailure("Expected a two-rank group, got rank=\(rank) size=\(size)")
            }
            let group = RawGroup(handle: handle, rank: rank, size: size, error: error)
            let peer = 1 - rank
            var report = Report(mode: options.mode.rawValue, rank: rank, worldSize: size,
                                initSeconds: uptime() - started)
            note(rank, "initialized in \(String(format: "%.3f", report.initSeconds)) s; world size \(size)")

            // Rank handshake, then the workload itself: a launch with different
            // arguments on the two Macs must stop here on both.
            let handshake = try group.allSum(MLXArray([Int32(rank + 1)]))
            guard handshake.asArray(Int32.self) == [3] else { throw CheckFailure("Rank handshake did not sum to 3") }
            let agreed = try group.allSum(MLXArray(options.agreement))
            guard agreed.asArray(Int32.self) == options.agreement.map({ $0 * 2 }) else {
                throw CheckFailure("Ranks disagree on the check workload")
            }

            // Small reductions of 1...8 elements, Int32 and Float32. The token
            // agreement and control handshakes of the runtime are this size.
            note(rank, "small reductions: \(options.smallIterations) iterations x 8 sizes x 2 dtypes")
            func small(_ forRank: Int, _ count: Int, _ iteration: Int, _ element: Int) -> Int32 {
                Int32((forRank + 1) * 1_000_003 + iteration * 7_919 + element * 104_729 + count)
            }
            for iteration in 0..<options.smallIterations {
                for count in 1...8 {
                    let mine = (0..<count).map { small(rank, count, iteration, $0) }
                    let expected = (0..<count).map { small(0, count, iteration, $0) + small(1, count, iteration, $0) }
                    let integers = try group.allSum(MLXArray(mine)).asArray(Int32.self)
                    // Values up to 2^24 are exact in Float32; scale down to stay inside it.
                    let floats = try group.allSum(MLXArray(mine.map { Float($0 % 4_096) })).asArray(Float.self)
                    let expectedFloats = (0..<count).map {
                        Float(small(0, count, iteration, $0) % 4_096) + Float(small(1, count, iteration, $0) % 4_096)
                    }
                    report.smallReductionCalls += 2
                    if integers != expected {
                        report.smallReductionMismatches += 1
                        report.firstSmallMismatch = report.firstSmallMismatch
                            ?? "int32 count=\(count) iteration=\(iteration) got=\(integers) expected=\(expected)"
                    }
                    if floats != expectedFloats {
                        report.smallReductionMismatches += 1
                        report.firstSmallMismatch = report.firstSmallMismatch
                            ?? "float32 count=\(count) iteration=\(iteration) got=\(floats) expected=\(expectedFloats)"
                    }
                }
            }

            // Large Float32 reductions, 4 KiB up to the configured maximum.
            let maximumBytes = options.maximumMiB * 1_048_576
            var bytes = 4_096
            while bytes <= maximumBytes {
                let elements = bytes / 4
                let base = remainder(MLXArray.arange(elements, dtype: .int32, stream: group.stream), Int32(1_024),
                                     stream: group.stream)
                let mine = (base * Int32(rank + 1)).asType(.float32, stream: group.stream)
                let expected = (base * Int32(3)).asType(.float32, stream: group.stream)
                eval(mine, expected)
                let before = uptime()
                let summed = try group.allSum(mine)
                let seconds = uptime() - before
                report.reductions.append(.init(label: "all_sum float32", bytes: bytes, seconds: seconds,
                                               mismatches: mismatchCount(summed, expected)))
                bytes *= 4
            }
            note(rank, "large reductions done")

            // Point-to-point in both directions, same sizes, exact payload check
            // on the receiving rank.
            var sequence = 0
            for sender in 0..<2 {
                bytes = 4_096
                while bytes <= maximumBytes {
                    let elements = bytes / 4
                    sequence += 1
                    let payload = pattern(elements: elements, sequence: sequence, stream: group.stream)
                    eval(payload)
                    let before = uptime()
                    var mismatches = 0
                    if rank == sender {
                        try group.send(payload, to: peer)
                    } else {
                        mismatches = mismatchCount(try group.receive(elements: elements, from: peer), payload)
                    }
                    report.pointToPoint.append(.init(label: "\(sender)->\(1 - sender)", bytes: bytes,
                                                     seconds: uptime() - before, mismatches: mismatches))
                    bytes *= 4
                }
            }
            note(rank, "point-to-point done")

            // Ordering: back-to-back 64 KiB messages must arrive in send order.
            for sender in 0..<2 {
                for _ in 0..<options.orderedMessages {
                    sequence += 1
                    let payload = pattern(elements: 16_384, sequence: sequence, stream: group.stream)
                    eval(payload)
                    if rank == sender {
                        try group.send(payload, to: peer)
                    } else if mismatchCount(try group.receive(elements: 16_384, from: peer), payload) != 0 {
                        report.orderedMismatches += 1
                    }
                    report.orderedMessages += 1
                }
            }

            report.localFailures = report.smallReductionMismatches + report.orderedMismatches
                + report.reductions.filter { $0.mismatches != 0 }.count
                + report.pointToPoint.filter { $0.mismatches != 0 }.count
            // Both ranks learn the combined verdict in one last collective.
            let verdict = try group.allSum(MLXArray([Int32(min(report.localFailures, 1_000_000)), 1]))
                .asArray(Int32.self)
            guard verdict.count == 2, verdict[1] == 2 else { throw CheckFailure("Final verdict collective was malformed") }
            report.worldFailures = Int(verdict[0])
            report.totalSeconds = uptime() - started
            report.passed = report.worldFailures == 0
            note(rank, "finished: world failures \(report.worldFailures)")
            return report
        }
    }

    /// The same transport through the runtime's own `Collective` type: the
    /// barrier, workload agreement, checked point-to-point transfers and the
    /// token-selection collective the generation loop uses.
    static func wrapper(_ options: Options) throws -> Report {
        let started = uptime()
        let collective = try Collective(transport: .jaccl)
        let rank = collective.rank
        let peer = 1 - rank
        var report = Report(mode: options.mode.rawValue, rank: rank, worldSize: collective.size,
                            initSeconds: uptime() - started)
        note(rank, "runtime collective initialized; transport \(collective.transportLabel)")
        collective.barrier()
        try collective.requireAgreement(options.agreement)

        let maximumBytes = options.maximumMiB * 1_048_576
        var sequence = 0
        for sender in 0..<2 {
            var bytes = 4_096
            while bytes <= maximumBytes {
                let elements = bytes / 4
                sequence += 1
                let payload = pattern(elements: elements, sequence: sequence, stream: .cpu)
                eval(payload)
                let before = uptime()
                var mismatches = 0
                if rank == sender {
                    _ = try collective.sendCompleted(payload, to: peer, maximumBytes: maximumBytes) {}
                } else {
                    let received = try collective.receiveCompleted(shape: [elements], dtype: .int32, from: peer,
                                                                   maximumBytes: maximumBytes) {}
                    mismatches = mismatchCount(received, payload)
                }
                report.pointToPoint.append(.init(label: "\(sender)->\(1 - sender)", bytes: bytes,
                                                 seconds: uptime() - before, mismatches: mismatches))
                bytes *= 4
            }
        }

        // Rank 0 proposes a token per step; both ranks must select the same one.
        let vocabulary = 248_320
        collective.beginTokenSequence(sequence: 1, vocabularySize: vocabulary, outputCount: options.tokenSteps)
        var tokenMismatches = 0
        for step in 0..<options.tokenSteps {
            let proposed = (step * 7_919 + 13) % vocabulary
            let selected = try collective.selectToken(localArgmax: proposed, sequence: 1, step: step)
            if selected != proposed { tokenMismatches += 1 }
            report.tokenSteps += 1
        }

        report.localFailures = tokenMismatches + report.pointToPoint.filter { $0.mismatches != 0 }.count
        // The closing agreement doubles as the combined verdict: it only holds
        // when both ranks report zero local failures.
        try collective.requireAgreement([Int32(min(report.localFailures, 1_000_000))])
        report.worldFailures = report.localFailures
        report.totalSeconds = uptime() - started
        report.passed = report.localFailures == 0
        note(rank, "finished: local failures \(report.localFailures)")
        return report
    }
}
