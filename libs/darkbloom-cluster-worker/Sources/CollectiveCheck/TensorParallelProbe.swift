import Cmlx
import DarkbloomClusterRuntime
import Darwin
import Foundation
import MLX

// Tensor-parallel collective probe (`--mode tp`). Both ranks run the same
// program with the same arguments. It carries no model.
//
// What it measures, for the hidden size of a model (5,120 for the registered
// Qwen3.8 27B):
//
// 1. Exactness of the reduction itself: an all-sum of [1, 1, hidden] and
//    [1, rows, hidden] in bfloat16 and float32, against the sum computed on
//    this CPU in float32 (and, for bfloat16, rounded to nearest even), bit for
//    bit, on both ranks. The inputs mix activation-like values with the cases
//    where two code paths could disagree: exact rounding ties, cancellation,
//    subnormals, overflow to infinity, signed zeros. Each rank regenerates the
//    peer's input from a shared seed, so no data crosses outside the reduction.
//    Inputs with infinities or NaN are tested separately and reported as
//    information only (activations never hold them).
// 2. Latency of the reduction alone (input already on the CPU), p50/p90/p99.
// 3. The per-layer round trip a TP layer pays: a 4-bit quantized projection on
//    the GPU, the all-sum on the CPU stream, and the residual + RMSNorm on the
//    GPU, chained for `chainSteps` steps. Variants: GPU only (no collective),
//    explicit (eval the partial, synchronize, all-sum, eval), single eval per
//    collective, and lazy (one eval for the whole chain). The explicit and lazy
//    chains must end bit-identical, and both ranks must hold the same final
//    residual.
// 4. Tiny int32 reductions, every value checked (uninitialized high bits were
//    seen under load in the owner's stack).
//
// A blocked collective cannot be interrupted from inside the process; the
// caller's deadline (`ProcessDeadline`) and the JACCL progress guard end it.

struct LatencyStats: Encodable {
    let label: String
    let bytes: Int
    let iterations: Int
    let p50Microseconds: Double
    let p90Microseconds: Double
    let p99Microseconds: Double
    let maxMicroseconds: Double
    let meanMicroseconds: Double
    let gigabytesPerSecondAtP50: Double
    let mismatches: Int
}

struct ExactnessResult: Encodable {
    let label: String
    let elements: Int
    let iterations: Int
    let mismatches: Int
    let firstMismatch: String?
    let ranksEqual: Bool
}

struct ChainResult: Encodable {
    let label: String
    let rows: Int
    let reduction: String
    let steps: Int
    let measuredRepeats: Int
    let gpuOnlyStepMicroseconds: Double
    let explicitStepMicroseconds: Double
    let explicitStepP50Microseconds: Double
    let explicitStepP99Microseconds: Double
    let singleEvalStepMicroseconds: Double
    let lazyStepMicroseconds: Double
    let explicitEqualsSingleEval: Bool
    let explicitEqualsLazy: Bool
    let ranksEqual: Bool
}

struct TensorParallelReport: Encodable {
    let schema = "darkbloom_cluster_tp_collective_probe_v1"
    let backend = "jaccl"
    let rank: Int
    let worldSize: Int
    let chip: String
    let initSeconds: Double
    var nativeBF16ByRank: [Bool] = []
    var hidden = 0
    var rows = 0
    var int32Calls = 0
    var int32Mismatches = 0
    var firstInt32Mismatch: String?
    var exactness: [ExactnessResult] = []
    var specialValues: [ExactnessResult] = []
    var latency: [LatencyStats] = []
    var chains: [ChainResult] = []
    var localFailures = 0
    var worldFailures = -1
    var totalSeconds = 0.0
    var passed = false
}

/// Deterministic generator both ranks can run for either rank's input.
struct SplitMix64 {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum BitArithmetic {
    static func float(bf16 bits: UInt16) -> Float { Float(bitPattern: UInt32(bits) << 16) }

    /// Round to nearest even, NaN canonical: the conversion MLX and JACCL's
    /// portable path use. The native path converts with the CPU's BFCVT.
    static func bf16(_ value: Float) -> UInt16 {
        if value.isNaN { return 0x7FC0 }
        var bits = value.bitPattern
        bits &+= ((bits >> 16) & 1) &+ 0x7FFF
        return UInt16(truncatingIfNeeded: bits >> 16)
    }

    static func fnv1a<T: FixedWidthInteger>(_ values: [T]) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for value in values {
            var v = UInt64(truncatingIfNeeded: value)
            for _ in 0..<(T.bitWidth / 8) {
                hash = (hash ^ (v & 0xFF)) &* 0x100_0000_01B3
                v >>= 8
            }
        }
        return hash
    }
}

enum PairGenerator {
    private static func bf16(sign: UInt64, exponent: Int, mantissa: UInt64) -> UInt16 {
        UInt16(truncatingIfNeeded: ((sign & 1) << 15) | ((UInt64(max(0, min(255, exponent))) & 0xFF) << 7) | (mantissa & 0x7F))
    }

    private static func activation(_ g: inout SplitMix64) -> UInt16 {
        bf16(sign: g.next(), exponent: 127 - 24 + Int(g.next() % 33), mantissa: g.next())
    }

    /// One (rank 0, rank 1) bfloat16 pair. Finite inputs only unless `special`.
    static func bf16Pair(_ g: inout SplitMix64, special: Bool = false) -> (UInt16, UInt16) {
        if special {
            let pool: [UInt16] = [0x7F80, 0xFF80, 0x7FC0, 0xFFC0, 0x7F81, 0x7FFF, 0x0000, 0x8000, 0x3F80, 0xBF80, 0x7F7F, 0xFF7F]
            return (pool[Int(g.next() % UInt64(pool.count))], g.next() % 3 == 0 ? activation(&g) : pool[Int(g.next() % UInt64(pool.count))])
        }
        switch g.next() % 100 {
        case 0..<60:
            return (activation(&g), activation(&g))
        case 60..<70: // near cancellation
            let a = activation(&g)
            let magnitude = Int(a & 0x7FFF) + Int(g.next() % 7) - 3
            return (a, ((a & 0x8000) ^ 0x8000) | UInt16(max(0, min(0x7F7F, magnitude))))
        case 70..<82: // exponent gap 7...9: the sum lands on or next to a rounding tie
            let e = 127 - 16 + Int(g.next() % 24)
            return (bf16(sign: g.next(), exponent: e, mantissa: g.next()),
                    bf16(sign: g.next(), exponent: e - 7 - Int(g.next() % 3), mantissa: g.next() % 2 == 0 ? 0 : g.next()))
        case 82..<88: // subnormal and smallest normal
            return (bf16(sign: g.next(), exponent: Int(g.next() % 2), mantissa: g.next()),
                    bf16(sign: g.next(), exponent: Int(g.next() % 2), mantissa: g.next()))
        case 88..<94: // largest finite exponents: same signs may overflow to infinity
            return (bf16(sign: g.next(), exponent: 250 + Int(g.next() % 5), mantissa: g.next()),
                    bf16(sign: g.next(), exponent: 250 + Int(g.next() % 5), mantissa: g.next()))
        case 94..<97: // signed zeros
            return (g.next() % 2 == 0 ? 0x0000 : 0x8000, g.next() % 2 == 0 ? 0x8000 : activation(&g))
        default: // equal operands
            let a = activation(&g)
            return (a, a)
        }
    }

    private static func fp32(sign: UInt64, exponent: Int, mantissa: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: ((sign & 1) << 31) | ((UInt64(max(0, min(254, exponent))) & 0xFF) << 23) | (mantissa & 0x7F_FFFF))
    }

    static func fp32Pair(_ g: inout SplitMix64) -> (UInt32, UInt32) {
        func activation() -> UInt32 { fp32(sign: g.next(), exponent: 127 - 40 + Int(g.next() % 61), mantissa: g.next()) }
        switch g.next() % 100 {
        case 0..<65: return (activation(), activation())
        case 65..<75:
            let a = activation()
            let magnitude = Int64(a & 0x7FFF_FFFF) + Int64(g.next() % 7) - 3
            return (a, ((a & 0x8000_0000) ^ 0x8000_0000) | UInt32(max(0, min(0x7F7F_FFFF, magnitude))))
        case 75..<85:
            let e = 127 - 16 + Int(g.next() % 24)
            return (fp32(sign: g.next(), exponent: e, mantissa: g.next()),
                    fp32(sign: g.next(), exponent: e - 23 - Int(g.next() % 3), mantissa: g.next()))
        case 85..<91:
            return (fp32(sign: g.next(), exponent: Int(g.next() % 2), mantissa: g.next()),
                    fp32(sign: g.next(), exponent: Int(g.next() % 2), mantissa: g.next()))
        case 91..<96:
            return (fp32(sign: g.next(), exponent: 250 + Int(g.next() % 5), mantissa: g.next()),
                    fp32(sign: g.next(), exponent: 250 + Int(g.next() % 5), mantissa: g.next()))
        default:
            return (g.next() % 2 == 0 ? 0 : 0x8000_0000, activation())
        }
    }
}

enum TensorParallelProbe {
    static func chipName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }

    /// The same query JACCL makes to choose its bfloat16 code path.
    static func nativeBF16() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm.FEAT_BF16", &value, &size, nil, 0) == 0 && value != 0
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))
        return sorted[index]
    }

    static func median(_ values: [Double]) -> Double { percentile(values.sorted(), 0.5) }

    /// Unevaluated all-sum on the CPU stream: the graph decides when it runs.
    static func lazySum(_ input: MLXArray, _ group: RawGroup) -> MLXArray {
        var result = mlx_array_new()
        let status = mlx_distributed_all_sum(&result, input.ctx, group.handle, StreamOrDevice.cpu.ctx)
        precondition(status == 0, "all_sum graph construction failed")
        return MLXArray(result)
    }

    /// Both ranks learn whether they hold the same 64-bit digest: each sends
    /// its digest as four 16-bit pieces (no reduction involved).
    static func digestsEqual(_ digest: UInt64, _ group: RawGroup) throws -> Bool {
        let pieces = (0..<4).map { Int32((digest >> (16 * UInt64($0))) & 0xFFFF) }
        let mine = MLXArray(pieces)
        eval(mine)
        let theirs: [Int32]
        if group.rank == 0 {
            try group.send(mine, to: 1)
            theirs = try group.receive(elements: 4, from: 1).asArray(Int32.self)
        } else {
            theirs = try group.receive(elements: 4, from: 0).asArray(Int32.self)
            try group.send(mine, to: 0)
        }
        return theirs == pieces
    }

    static func run(_ options: Options) throws -> TensorParallelReport {
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
            var report = TensorParallelReport(rank: rank, worldSize: size, chip: chipName(), initSeconds: uptime() - started)
            report.hidden = options.hidden
            report.rows = options.rows
            note(rank, "tp probe: initialized in \(String(format: "%.3f", report.initSeconds)) s; chip \(report.chip)")

            let handshake = try group.allSum(MLXArray([Int32(rank + 1)]))
            guard handshake.asArray(Int32.self) == [3] else { throw CheckFailure("Rank handshake did not sum to 3") }
            let agreed = try group.allSum(MLXArray(options.agreement))
            guard agreed.asArray(Int32.self) == options.agreement.map({ $0 * 2 }) else {
                throw CheckFailure("Ranks disagree on the probe workload")
            }
            // One slot per rank: each rank fills its own, so the sum is the list.
            var flags: [Int32] = [0, 0]
            flags[rank] = nativeBF16() ? 1 : 0
            report.nativeBF16ByRank = try group.allSum(MLXArray(flags)).asArray(Int32.self).map { $0 == 1 }
            note(rank, "native bfloat16 (FEAT_BF16) by rank: \(report.nativeBF16ByRank)")

            try int32Hammer(options, group, &report)
            try exactness(options, group, &report)
            try latency(options, group, &report)
            for rows in [1, options.rows] {
                for reduction in [DType.bfloat16, DType.float32] {
                    report.chains.append(try chain(options, group, rows: rows, reduction: reduction))
                    let last = report.chains[report.chains.count - 1]
                    note(rank, "chain \(last.label): gpu-only \(fmt(last.gpuOnlyStepMicroseconds)) us/step, explicit \(fmt(last.explicitStepMicroseconds)) (p50 \(fmt(last.explicitStepP50Microseconds)), p99 \(fmt(last.explicitStepP99Microseconds))), single-eval \(fmt(last.singleEvalStepMicroseconds)), lazy \(fmt(last.lazyStepMicroseconds)); equal explicit/single \(last.explicitEqualsSingleEval) explicit/lazy \(last.explicitEqualsLazy) ranks \(last.ranksEqual)")
                }
            }

            report.localFailures = report.int32Mismatches
                + report.exactness.filter { $0.mismatches != 0 || !$0.ranksEqual }.count
                + report.latency.filter { $0.mismatches != 0 }.count
                + report.chains.filter { !$0.explicitEqualsLazy || !$0.explicitEqualsSingleEval || !$0.ranksEqual }.count
            let verdict = try group.allSum(MLXArray([Int32(min(report.localFailures, 1_000_000)), 1])).asArray(Int32.self)
            guard verdict.count == 2, verdict[1] == 2 else { throw CheckFailure("Final verdict collective was malformed") }
            report.worldFailures = Int(verdict[0])
            report.totalSeconds = uptime() - started
            report.passed = report.worldFailures == 0
            note(rank, "tp probe finished: world failures \(report.worldFailures)")
            return report
        }
    }

    static func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

    static func int32Hammer(_ options: Options, _ group: RawGroup, _ report: inout TensorParallelReport) throws {
        func value(_ forRank: Int, _ count: Int, _ iteration: Int, _ element: Int) -> Int32 {
            // High bits set on purpose: garbage high bits must not hide.
            Int32(bitPattern: UInt32(truncatingIfNeeded: (forRank + 1) * 0x0100_0003 + iteration * 7_919 + element * 104_729 + count) | 0x4000_0000) / 2
        }
        for iteration in 0..<options.smallIterations {
            for count in 1...8 {
                let mine = (0..<count).map { value(group.rank, count, iteration, $0) }
                let expected = (0..<count).map { value(0, count, iteration, $0) &+ value(1, count, iteration, $0) }
                let got = try group.allSum(MLXArray(mine)).asArray(Int32.self)
                report.int32Calls += 1
                if got != expected {
                    report.int32Mismatches += 1
                    report.firstInt32Mismatch = report.firstInt32Mismatch
                        ?? "count=\(count) iteration=\(iteration) got=\(got) expected=\(expected)"
                }
            }
        }
        note(group.rank, "int32: \(report.int32Calls) reductions, \(report.int32Mismatches) mismatched")
    }

    static func exactness(_ options: Options, _ group: RawGroup, _ report: inout TensorParallelReport) throws {
        let rank = group.rank
        let shapes: [(String, [Int], Int)] = [
            ("[1,1,\(options.hidden)]", [1, 1, options.hidden], 200),
            ("[1,\(options.rows),\(options.hidden)]", [1, options.rows, options.hidden], 6),
        ]
        for (shapeLabel, shape, iterations) in shapes {
            let count = shape.reduce(1, *)
            // bfloat16, finite inputs and the special inputs.
            for special in [false, true] {
                if special && count > options.hidden { continue }
                var mismatches = 0
                var first: String?
                var digest: UInt64 = 0
                for iteration in 0..<iterations {
                    var g = SplitMix64(UInt64(0xB16_0000) &+ UInt64(count) &* 131 &+ UInt64(iteration) &* 7 &+ (special ? 1 : 0))
                    var mine = [UInt16](repeating: 0, count: count)
                    var expected = [UInt16](repeating: 0, count: count)
                    for i in 0..<count {
                        let (a, b) = PairGenerator.bf16Pair(&g, special: special)
                        mine[i] = rank == 0 ? a : b
                        expected[i] = BitArithmetic.bf16(BitArithmetic.float(bf16: a) + BitArithmetic.float(bf16: b))
                    }
                    let input = MLXArray(mine, shape).view(dtype: .bfloat16, stream: .cpu)
                    eval(input)
                    let got = try group.allSum(input).view(dtype: .uint16, stream: .cpu).asArray(UInt16.self)
                    for i in 0..<count where got[i] != expected[i] {
                        mismatches += 1
                        if first == nil {
                            first = String(format: "iteration %d element %d got 0x%04x expected 0x%04x (this rank's input 0x%04x)",
                                           iteration, i, UInt32(got[i]), UInt32(expected[i]), UInt32(mine[i]))
                        }
                    }
                    digest = BitArithmetic.fnv1a([digest]) ^ BitArithmetic.fnv1a(got)
                }
                let result = ExactnessResult(label: "all_sum bfloat16 \(shapeLabel)\(special ? " inf/nan inputs" : "")",
                    elements: count, iterations: iterations, mismatches: mismatches, firstMismatch: first,
                    ranksEqual: try digestsEqual(digest, group))
                if special { report.specialValues.append(result) } else { report.exactness.append(result) }
                note(rank, "\(result.label): \(mismatches) mismatched of \(count * iterations), ranks equal \(result.ranksEqual)")
            }
            // float32, finite inputs.
            var mismatches = 0
            var first: String?
            var digest: UInt64 = 0
            for iteration in 0..<iterations {
                var g = SplitMix64(UInt64(0xF32_0000) &+ UInt64(count) &* 131 &+ UInt64(iteration) &* 7)
                var mine = [UInt32](repeating: 0, count: count)
                var expected = [UInt32](repeating: 0, count: count)
                for i in 0..<count {
                    let (a, b) = PairGenerator.fp32Pair(&g)
                    mine[i] = rank == 0 ? a : b
                    expected[i] = (Float(bitPattern: a) + Float(bitPattern: b)).bitPattern
                }
                let input = MLXArray(mine, shape).view(dtype: .float32, stream: .cpu)
                eval(input)
                let got = try group.allSum(input).view(dtype: .uint32, stream: .cpu).asArray(UInt32.self)
                for i in 0..<count where got[i] != expected[i] {
                    mismatches += 1
                    if first == nil {
                        first = String(format: "iteration %d element %d got 0x%08x expected 0x%08x (this rank's input 0x%08x)", iteration, i, got[i], expected[i], mine[i])
                    }
                }
                digest = BitArithmetic.fnv1a([digest]) ^ BitArithmetic.fnv1a(got)
            }
            let result = ExactnessResult(label: "all_sum float32 \(shapeLabel)", elements: count, iterations: iterations,
                mismatches: mismatches, firstMismatch: first, ranksEqual: try digestsEqual(digest, group))
            report.exactness.append(result)
            note(rank, "\(result.label): \(mismatches) mismatched of \(count * iterations), ranks equal \(result.ranksEqual)")
        }
    }

    static func latency(_ options: Options, _ group: RawGroup, _ report: inout TensorParallelReport) throws {
        let rank = group.rank
        for (rows, iterations) in [(1, options.latencySmall), (options.rows, options.latencyLarge)] {
            for dtype in [DType.bfloat16, DType.float32] {
                let count = rows * options.hidden
                var g = SplitMix64(UInt64(0x1A7_0000) &+ UInt64(rows))
                var a = [Float](repeating: 0, count: count)
                var b = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    let (x, y) = PairGenerator.bf16Pair(&g)
                    a[i] = BitArithmetic.float(bf16: x & 0x7FFF > 0x7F00 ? 0x3F80 : x)
                    b[i] = BitArithmetic.float(bf16: y & 0x7FFF > 0x7F00 ? 0x3F80 : y)
                }
                let input = MLXArray(rank == 0 ? a : b, [1, rows, options.hidden]).asType(dtype, stream: .cpu)
                eval(input)
                let expected: [UInt32]
                if dtype == .bfloat16 {
                    expected = (0..<count).map { UInt32(BitArithmetic.bf16(a[$0] + b[$0])) }
                } else {
                    expected = (0..<count).map { (a[$0] + b[$0]).bitPattern }
                }
                func check(_ out: MLXArray) -> Int {
                    let got: [UInt32] = dtype == .bfloat16
                        ? out.view(dtype: .uint16, stream: .cpu).asArray(UInt16.self).map { UInt32($0) }
                        : out.view(dtype: .uint32, stream: .cpu).asArray(UInt32.self)
                    return zip(got, expected).filter { $0 != $1 }.count
                }
                for _ in 0..<10 { _ = try group.allSum(input) }
                var samples: [Double] = []
                samples.reserveCapacity(iterations)
                var mismatches = 0
                for iteration in 0..<iterations {
                    let before = uptime()
                    let out = try group.allSum(input)
                    samples.append((uptime() - before) * 1e6)
                    if iteration == 0 || iteration == iterations - 1 { mismatches += check(out) }
                }
                let sorted = samples.sorted()
                let bytes = count * dtype.size
                let p50 = percentile(sorted, 0.5)
                let stats = LatencyStats(label: "all_sum \(dtype) [1,\(rows),\(options.hidden)]", bytes: bytes,
                    iterations: iterations, p50Microseconds: p50, p90Microseconds: percentile(sorted, 0.9),
                    p99Microseconds: percentile(sorted, 0.99), maxMicroseconds: sorted.last ?? 0,
                    meanMicroseconds: samples.reduce(0, +) / Double(max(1, samples.count)),
                    gigabytesPerSecondAtP50: p50 > 0 ? Double(bytes) / (p50 * 1e3) : 0, mismatches: mismatches)
                report.latency.append(stats)
                note(rank, "\(stats.label): p50 \(fmt(stats.p50Microseconds)) us, p90 \(fmt(stats.p90Microseconds)), p99 \(fmt(stats.p99Microseconds)), max \(fmt(stats.maxMicroseconds)); mismatches \(mismatches)")
            }
        }
    }

    /// A chain of TP-like steps. Each rank holds its own quantized projection
    /// (its "shard"); the residual stream is replicated and stays identical on
    /// both ranks only if every reduction returns identical bytes on both.
    static func chain(_ options: Options, _ group: RawGroup, rows: Int, reduction: DType) throws -> ChainResult {
        let rank = group.rank
        let hidden = options.hidden
        let gpu = StreamOrDevice.gpu
        let weight = MLXRandom.normal([hidden, hidden], dtype: .bfloat16, scale: 1 / Float(hidden).squareRoot(),
                                      key: MLXRandom.key(UInt64(1_234 + rank)), stream: gpu)
        let packed = quantized(weight, groupSize: 64, bits: 4, stream: gpu)
        let wq = packed.wq
        let scales = reduction == .float32 ? packed.scales.asType(.float32, stream: gpu) : packed.scales
        let biases = reduction == .float32 ? packed.biases?.asType(.float32, stream: gpu) : packed.biases
        let norm = MLXArray.ones([hidden], dtype: .bfloat16, stream: gpu)
        let start = MLXRandom.normal([1, rows, hidden], dtype: .bfloat16, key: MLXRandom.key(99), stream: gpu)
        eval(wq, scales, norm, start)
        if let biases { eval(biases) }

        // The partial a rank contributes: bfloat16 out of a bfloat16 projection,
        // or float32 out of the same projection fed float32 (no rounding of the
        // partial before the sum).
        func partial(_ x: MLXArray) -> MLXArray {
            let input = reduction == .float32 ? x.asType(.float32, stream: gpu) : x
            return quantizedMM(input, wq, scales: scales, biases: biases, transpose: true, groupSize: 64, bits: 4, stream: gpu)
        }
        func advance(_ x: MLXArray, _ summed: MLXArray) -> MLXArray {
            let s = reduction == .float32 ? summed.asType(.bfloat16, stream: gpu) : summed
            return rmsNorm(x + s, weight: norm, eps: 1e-6, stream: gpu)
        }
        func bits(_ x: MLXArray) -> [UInt16] { x.view(dtype: .uint16, stream: .cpu).asArray(UInt16.self) }

        let steps = options.chainSteps
        var gpuOnly: [Double] = [], explicit: [Double] = [], single: [Double] = [], lazy: [Double] = []
        var explicitSteps: [Double] = []
        var finalExplicit: [UInt16] = [], finalSingle: [UInt16] = [], finalLazy: [UInt16] = []
        for repeatIndex in 0..<(options.chainRepeats + 1) {
            let measured = repeatIndex > 0
            // GPU only: the same projection and norm, one evaluation per step.
            var x = start
            var before = uptime()
            for _ in 0..<steps {
                x = advance(x, partial(x))
                eval(x)
            }
            if measured { gpuOnly.append((uptime() - before) * 1e6 / Double(steps)) }

            // Explicit: evaluate the partial, synchronize, all-sum, evaluate.
            x = start
            before = uptime()
            for _ in 0..<steps {
                let stepStart = uptime()
                let p = partial(x)
                eval(p)
                Stream.gpu.synchronize()
                let s = lazySum(p, group)
                eval(s)
                x = advance(x, s)
                if measured { explicitSteps.append((uptime() - stepStart) * 1e6) }
            }
            eval(x)
            if measured { explicit.append((uptime() - before) * 1e6 / Double(steps)) }
            if repeatIndex == options.chainRepeats { finalExplicit = bits(x) }

            // One evaluation per collective: the GPU->CPU dependency is left to the graph.
            x = start
            before = uptime()
            for _ in 0..<steps {
                let s = lazySum(partial(x), group)
                eval(s)
                x = advance(x, s)
            }
            eval(x)
            if measured { single.append((uptime() - before) * 1e6 / Double(steps)) }
            if repeatIndex == options.chainRepeats { finalSingle = bits(x) }

            // Lazy: the whole chain in one evaluation.
            if options.chainLazy {
                x = start
                before = uptime()
                for _ in 0..<steps { x = advance(x, lazySum(partial(x), group)) }
                eval(x)
                if measured { lazy.append((uptime() - before) * 1e6 / Double(steps)) }
                if repeatIndex == options.chainRepeats { finalLazy = bits(x) }
            }
        }
        let sortedSteps = explicitSteps.sorted()
        let digest = BitArithmetic.fnv1a(finalExplicit)
        return ChainResult(label: "\(reduction) partials [1,\(rows),\(hidden)]", rows: rows, reduction: "\(reduction)",
            steps: steps, measuredRepeats: options.chainRepeats,
            gpuOnlyStepMicroseconds: median(gpuOnly), explicitStepMicroseconds: median(explicit),
            explicitStepP50Microseconds: percentile(sortedSteps, 0.5), explicitStepP99Microseconds: percentile(sortedSteps, 0.99),
            singleEvalStepMicroseconds: median(single), lazyStepMicroseconds: options.chainLazy ? median(lazy) : -1,
            explicitEqualsSingleEval: finalExplicit == finalSingle,
            explicitEqualsLazy: !options.chainLazy || finalExplicit == finalLazy,
            ranksEqual: try digestsEqual(digest, group))
    }
}
