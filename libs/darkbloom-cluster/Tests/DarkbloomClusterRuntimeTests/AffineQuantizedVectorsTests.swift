import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing

/// The SDK's batch-invariant affine quantized product
/// (`AffineQuantizedVectors`): every vector of a call, whatever the call's
/// vector count, its position in the call or the kernel layout, has the bits
/// of that vector alone (M = 1). GPU checks are opt-in
/// (`QWEN_TP_AQV_GPU=1`, also run with `QWEN_TP_MTP_GPU=1`); the
/// throughput study is `QWEN_TP_AQV_BENCH=1`.
@Suite(.serialized)
struct AffineQuantizedVectorsTests {
    static var gpu: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["QWEN_TP_AQV_GPU"] == "1" || environment["QWEN_TP_MTP_GPU"] == "1"
    }

    private static func random(_ shape: [Int], seed: UInt64, scale: Float) -> MLXArray {
        withRandomState(MLXRandom.RandomState(seed: seed)) { MLXRandom.normal(shape) * scale }
    }

    private static func bytes(_ value: MLXArray) -> Data { value.asData(access: .copy).data }

    /// One quantized weight of `[outputs, inputs]` at `bits`/`group`, scales in `scaleType`.
    private static func linear(_ outputs: Int, _ inputs: Int, bits: Int, group: Int, scaleType: DType,
                               seed: UInt64) -> QuantizedLinear {
        let source = QuantizedLinear(weight: random([outputs, inputs], seed: seed, scale: 0.02), bias: nil,
            groupSize: group, bits: bits)
        let made = QuantizedLinear(weight: source.weight, bias: nil, scales: source.scales.asType(scaleType),
            biases: source.biases!.asType(scaleType), groupSize: group, bits: bits, mode: .affine)
        eval(made.weight, made.scales, made.biases!)
        return made
    }

    @Test func layoutsAreValidForEveryVectorCountAndFamily() {
        for architecture in ["applegpu_g15d", "applegpu_g17s", "applegpu_g16s", ""] {
            for vectors in 1...64 {
                let layout = AffineQuantizedVectors.layout(vectors: vectors, inputs: 5120, outputs: 6144, bits: 4,
                    architecture: architecture)
                #expect([1, 2, 4, 8].contains(layout.rowsPerSimdgroup) && [1, 2, 4, 8].contains(layout.simdgroups)
                    && (1...AffineQuantizedVectors.Layout.maximumVectorsPerTile).contains(layout.vectorsPerTile)
                    && layout.schedule != .sharedInputs, "\(architecture) M=\(vectors) \(layout)")
            }
        }
        // The measured families read the weights once for a whole cohort's vectors (up to sixteen a
        // tile past five), instead of once per four.
        for architecture in ["applegpu_g15d", "applegpu_g17s"] {
            for vectors in 6...48 {
                let layout = AffineQuantizedVectors.layout(vectors: vectors, inputs: 5120, outputs: 6144, bits: 4,
                    architecture: architecture)
                #expect(layout.vectorsPerTile >= min(vectors, 8), "\(architecture) M=\(vectors) \(layout)")
            }
        }
        #expect(AffineQuantizedVectors.parseLayout("b:2:4:32") != nil && AffineQuantizedVectors.parseLayout("b:2:4:33") == nil)
        #expect(AffineQuantizedVectors.family("applegpu_g15d") == 15)
        #expect(AffineQuantizedVectors.family("applegpu_g17s") == 17)
        #expect(AffineQuantizedVectors.family("") == 0)
    }

    /// Refusals: what the kernel does not cover goes back to the caller.
    @Test(.enabled(if: Self.gpu)) func declinesWhatItDoesNotCover() throws {
        try Device.withDefaultDevice(.gpu) {
            let four = Self.linear(64, 256, bits: 4, group: 64, scaleType: .bfloat16, seed: 1)
            let x = Self.random([2, 256], seed: 2, scale: 1).asType(.bfloat16)
            #expect(AffineQuantizedVectors.project(x, four) != nil)
            // A half-precision input with scales of another type, an integer input, another mode.
            #expect(AffineQuantizedVectors.project(x.asType(.float16), four) == nil)
            #expect(AffineQuantizedVectors.project(x.asType(.int32), four) == nil)
            #expect(AffineQuantizedVectors.project(x, weight: four.weight, scales: four.scales, biases: four.biases,
                groupSize: 64, bits: 4, mode: .mxfp4) == nil)
            // No biases, a width that is not the weight's.
            #expect(AffineQuantizedVectors.project(x, weight: four.weight, scales: four.scales, biases: nil,
                groupSize: 64, bits: 4) == nil)
            #expect(AffineQuantizedVectors.project(Self.random([2, 192], seed: 3, scale: 1).asType(.bfloat16), four) == nil)
            Device.withDefaultDevice(.cpu) { #expect(AffineQuantizedVectors.project(x, four) == nil) }
        }
    }

    /// The kernel computes the affine product: against the dequantized weight in float32
    /// (not bitwise: a different summation order), relative error within float accumulation noise.
    @Test(.enabled(if: Self.gpu), arguments: AffineQuantizedVectors.Arithmetic.allCases)
    func agreesWithTheDequantizedProduct(arithmetic: AffineQuantizedVectors.Arithmetic) throws {
        try AffineQuantizedVectors.$arithmeticOverride.withValue(arithmetic) { try Device.withDefaultDevice(.gpu) {
            for (bits, group) in [(4, 64), (4, 32), (4, 128), (8, 64), (8, 32), (2, 64)] {
                let layer = Self.linear(96, 1024, bits: bits, group: group, scaleType: .bfloat16, seed: UInt64(10 + bits + group))
                let x = Self.random([5, 1024], seed: UInt64(20 + bits), scale: 1).asType(.bfloat16)
                // The weights dequantized in float32 (bf16 scales and biases widen exactly) and the
                // product, on the CPU: the GPU's float32 matmul may round its inputs to TF32.
                let expected = Device.withDefaultDevice(.cpu) {
                    let dense = dequantized(layer.weight, scales: layer.scales.asType(.float32),
                        biases: layer.biases!.asType(.float32), groupSize: group, bits: bits)
                    let product = matmul(x.asType(.float32), dense.transposed())
                    eval(product)
                    return product
                }
                let got = try #require(AffineQuantizedVectors.project(x, layer, outputDType: .float32))
                let mlx = layer(x.asType(.float32))
                let error = (abs(got - expected).max() / abs(expected).max()).item(Float.self)
                let mlxError = (abs(mlx - expected).max() / abs(expected).max()).item(Float.self)
                #expect(error < 1e-5 && error <= max(4 * mlxError, 1e-6),
                    "bits=\(bits) group=\(group) relative error \(error) (MLX's own \(mlxError))")
            }
        } }
    }

    /// Batch- and window-invariance: rows B = 1...8 by columns S = 1...6 (the
    /// shapes a verify window and a batched cohort take), every vector equals
    /// the same vector alone, byte for byte; 4- and 8-bit, groups 32/64/128,
    /// bf16 and f32 inputs (bf16 scales) and f16 inputs (f16 scales), widths
    /// on and off 256/512 and output counts on and off the layout's row blocks.
    @Test(.enabled(if: Self.gpu), arguments: [1, 2, 8], AffineQuantizedVectors.Arithmetic.allCases)
    func everyVectorEqualsItsOwnSingleVectorCall(wordsPerLane: Int, arithmetic: AffineQuantizedVectors.Arithmetic) throws {
        try AffineQuantizedVectors.$arithmeticOverride.withValue(arithmetic) {
        try AffineQuantizedVectors.$wordsPerLaneOverride.withValue(wordsPerLane) { try Device.withDefaultDevice(.gpu) {
            let cases: [(inputs: Int, outputs: Int, bits: Int, group: Int)] = [
                (5120, 1032, 4, 64), (3072, 517, 4, 64), (1088, 96, 4, 32), (2560, 200, 4, 128),
                (5120, 1032, 8, 64), (1056, 77, 8, 32), (2048, 136, 8, 128), (1024, 40, 2, 64),
            ]
            for (index, shape) in cases.enumerated() {
                for (input, scale) in [(DType.bfloat16, DType.bfloat16), (.float32, .bfloat16), (.float16, .float16)] {
                    let layer = Self.linear(shape.outputs, shape.inputs, bits: shape.bits, group: shape.group,
                        scaleType: scale, seed: UInt64(100 + index))
                    let all = Self.random([48, shape.inputs], seed: UInt64(200 + index), scale: 1).asType(input)
                    eval(all)
                    let alone = (0..<48).map { AffineQuantizedVectors.project(all[$0 ..< $0 + 1], layer)! }
                    eval(alone)
                    let reference = alone.map(Self.bytes)
                    for rows in 1...8 {
                        for columns in 1...6 {
                            let count = rows * columns
                            let x = all[0 ..< count].reshaped([rows, columns, shape.inputs])
                            let together = try #require(AffineQuantizedVectors.project(x, layer))
                            eval(together)
                            #expect(together.shape == [rows, columns, shape.outputs] && together.dtype == input)
                            let flat = together.reshaped([count, shape.outputs])
                            for vector in 0..<count where Self.bytes(flat[vector ..< vector + 1]) != reference[vector] {
                                Issue.record("[\(shape.inputs)->\(shape.outputs)] \(shape.bits)-bit g\(shape.group) \(input) B=\(rows) S=\(columns) vector \(vector) differs from its own call")
                                break
                            }
                        }
                    }
                    // f32 output from a bf16 input (the tensor-parallel partial): the same sums, rounded once to f32.
                    if input == .bfloat16 {
                        let wide = try #require(AffineQuantizedVectors.project(all[0 ..< 8], layer, outputDType: .float32))
                        let single = try #require(AffineQuantizedVectors.project(all[3 ..< 4], layer, outputDType: .float32))
                        let viaF32 = try #require(AffineQuantizedVectors.project(all[3 ..< 4].asType(.float32), layer))
                        eval(wide, single, viaF32)
                        #expect(Self.bytes(wide[3 ..< 4]) == Self.bytes(single) && Self.bytes(single) == Self.bytes(viaF32),
                            "[\(shape.inputs)->\(shape.outputs)] an f32 partial of a bf16 input differs from the f32 input's")
                    }
                }
            }
        } }
        }
    }

    /// Every layout (rows per SIMD group, SIMD groups, vectors per tile) gives the same bits, with
    /// 37 vectors: whole tiles and a last tile past the call's end (a tile wider than its whole call:
    /// the family layouts in `everyVectorEqualsItsOwnSingleVectorCall`).
    @Test(.enabled(if: Self.gpu), arguments: [1, 8], AffineQuantizedVectors.Arithmetic.allCases)
    func everyLayoutGivesTheSameBits(wordsPerLane: Int, arithmetic: AffineQuantizedVectors.Arithmetic) throws {
        try AffineQuantizedVectors.$arithmeticOverride.withValue(arithmetic) {
        try AffineQuantizedVectors.$wordsPerLaneOverride.withValue(wordsPerLane) { try Device.withDefaultDevice(.gpu) {
            for (index, (inputs, outputs, bits)) in [(5120, 520, 4), (3072, 333, 4), (2048, 264, 8)].enumerated() {
                let layer = Self.linear(outputs, inputs, bits: bits, group: 64, scaleType: .bfloat16, seed: UInt64(300 + index))
                for input in [DType.bfloat16, .float32] {
                    let x = Self.random([37, inputs], seed: UInt64(400 + index), scale: 1).asType(input)
                    let base = try #require(AffineQuantizedVectors.project(x, layer,
                        layout: AffineQuantizedVectors.Layout(rowsPerSimdgroup: 1, simdgroups: 1, vectorsPerTile: 1)))
                    eval(base)
                    let expected = Self.bytes(base)
                    // Every schedule at rows per SIMD group 1...8, SIMD groups 1...8 and
                    // tiles 1...32 (each value at least once, tiles of 1-8, 12, 16, 24 and
                    // 32), and the bit-built decode.
                    let shapes = [(1, 1, 1), (2, 4, 3), (4, 2, 5), (8, 4, 8), (8, 1, 4), (1, 8, 2), (4, 4, 4),
                                  (2, 4, 6), (1, 2, 7), (4, 4, 8), (4, 4, 12), (2, 4, 16), (4, 4, 16), (8, 2, 16), (2, 1, 24),
                                  (1, 4, 32), (2, 4, 32), (2, 8, 32)]
                    for schedule in AffineQuantizedVectors.Layout.Schedule.allCases {
                        for (rows, groups, tile) in shapes {
                            for magic in (rows == 4 || rows == 8 ? [false, true] : [false]) {
                                let layout = AffineQuantizedVectors.Layout(rowsPerSimdgroup: rows, simdgroups: groups,
                                    vectorsPerTile: tile, schedule: schedule, magicDecode: magic)
                                // A shared-input layout past threadgroup memory declines.
                                guard let got = AffineQuantizedVectors.project(x, layer, layout: layout) else {
                                    #expect(schedule == .sharedInputs, "\(layout) declined")
                                    continue
                                }
                                eval(got)
                                #expect(Self.bytes(got) == expected, "[\(inputs)->\(outputs)] \(bits)-bit \(input) \(layout) differs")
                            }
                        }
                    }
                }
            }
        } }
        }
    }

    /// The fused gate/up SwiGLU equals two `project` calls and the SwiGLU on
    /// their products, byte for byte, at every vector count and register layout.
    @Test(.enabled(if: Self.gpu), arguments: AffineQuantizedVectors.Arithmetic.allCases)
    func swigluEqualsTwoProjectionsAndTheSwiGLU(arithmetic: AffineQuantizedVectors.Arithmetic) throws {
        try AffineQuantizedVectors.$arithmeticOverride.withValue(arithmetic) { try Device.withDefaultDevice(.gpu) {
            for (index, (inputs, outputs, bits)) in [(5120, 520, 4), (3072, 333, 4), (2048, 264, 8)].enumerated() {
                for input in [DType.bfloat16, .float16] {
                    let scaleType = input
                    let gate = Self.linear(outputs, inputs, bits: bits, group: 64, scaleType: scaleType, seed: UInt64(600 + index))
                    let up = Self.linear(outputs, inputs, bits: bits, group: 64, scaleType: scaleType, seed: UInt64(700 + index))
                    for vectors in [1, 2, 4, 5, 8, 13] {
                        let x = (Self.random([1, vectors, inputs], seed: UInt64(800 + vectors), scale: 1)).asType(input)
                        let g = try #require(AffineQuantizedVectors.project(x, gate))
                        let u = try #require(AffineQuantizedVectors.project(x, up))
                        let expected = silu(g) * u
                        eval(expected)
                        for layout in [nil,
                                       AffineQuantizedVectors.Layout(rowsPerSimdgroup: 2, simdgroups: 4, vectorsPerTile: 4),
                                       AffineQuantizedVectors.Layout(rowsPerSimdgroup: 4, simdgroups: 2, vectorsPerTile: 3,
                                           schedule: .rowsInRegisters),
                                       AffineQuantizedVectors.Layout(rowsPerSimdgroup: 1, simdgroups: 8, vectorsPerTile: 5,
                                           schedule: .rowsInRegisters, magicDecode: true)] as [AffineQuantizedVectors.Layout?] {
                            let fused = try #require(AffineQuantizedVectors.projectSwiGLU(x, gate: gate, up: up, layout: layout))
                            eval(fused)
                            #expect(fused.shape == expected.shape && Self.bytes(fused) == Self.bytes(expected),
                                "[\(inputs)->\(outputs)] \(bits)-bit \(input) M=\(vectors) \(layout.map { "\($0)" } ?? "auto") SwiGLU differs")
                        }
                    }
                }
            }
        } }
    }

    /// Throughput against MLX's own calls (qmv at one vector, qmv_wide below the vector limit,
    /// QMM past it), MLX's qmv_wide for one vector (padded to two), and the SDK's wide kernel (MLX's
    /// qmv_wide arithmetic, one or two rows a thread), at tensor-parallel shard shapes, every call on
    /// its own weights (about 1 GB in all, past the system cache). `f32out` is the tensor-parallel
    /// partial: a bf16 activation into an FP32 sum (MLX: widen, then FP32 scales; SDK: widen; ours:
    /// in-kernel).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_AQV_BENCH"] == "1"))
    func throughputAgainstMLXCalls() throws {
        let environment = ProcessInfo.processInfo.environment
        let shapes: [(Int, Int)] = (environment["QWEN_TP_AQV_BENCH_SHAPES"] ?? "5120x10240,5120x7168,10240x5120,3072x5120")
            .split(separator: ",").compactMap { part in
                let fields = part.split(separator: "x").compactMap { Int($0) }
                return fields.count == 2 ? (fields[0], fields[1]) : nil
            }
        let counts = (environment["QWEN_TP_AQV_BENCH_VECTORS"] ?? "1,2,4,5,8,16").split(separator: ",").compactMap { Int($0) }
        // schedule(a|b|t)[m]:rows:simdgroups:vectors, for every count
        // (QWEN_TP_AQV_BENCH_LAYOUTS) or one (QWEN_TP_AQV_BENCH_LAYOUTS_<count>).
        func layouts(_ vectors: Int) -> [AffineQuantizedVectors.Layout?] {
            let list = environment["QWEN_TP_AQV_BENCH_LAYOUTS_\(vectors)"] ?? environment["QWEN_TP_AQV_BENCH_LAYOUTS"] ?? ""
            return [nil] + list.split(separator: ",").compactMap { AffineQuantizedVectors.parseLayout(String($0)) }
        }
        let modes = (environment["QWEN_TP_AQV_BENCH_MODES"] ?? "bf16,f32out").split(separator: ",").map(String.init)
        let perLane = (environment["QWEN_TP_AQV_BENCH_WPL"] ?? "1").split(separator: ",").compactMap { Int($0) }
        let arithmetics = (environment["QWEN_TP_AQV_BENCH_ARITH"] ?? "scaled").split(separator: ",")
            .compactMap { AffineQuantizedVectors.Arithmetic(rawValue: String($0)) }
        let label = "aqv-bench arch=\(AffineQuantizedVectors.architecture)"
        try Device.withDefaultDevice(.gpu) {
            func timed(_ body: () -> [MLXArray]) -> Double {
                eval(body())
                var samples: [Double] = []
                for _ in 0..<5 {
                    let built = body()
                    let started = DispatchTime.now().uptimeNanoseconds
                    eval(built)
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
                }
                return samples.sorted()[2]
            }
            for (inputs, outputs) in shapes {
                var layers: [QuantizedLinear] = []
                var bytes = 0.0
                while bytes < 1.0e9 {
                    let layer = Self.linear(outputs, inputs, bits: 4, group: 64, scaleType: .bfloat16,
                        seed: UInt64(layers.count + 1))
                    bytes += Double(layer.weight.nbytes + layer.scales.nbytes + layer.biases!.nbytes)
                    layers.append(layer)
                }
                func rate(_ ms: Double) -> String { "\(Int(ms * 1000 / Double(layers.count)))us/\(Int(bytes / (ms / 1000) / 1e9))GBps" }
                for mode in modes {
                    let f32out = mode == "f32out"
                    for vectors in counts {
                        let x = Self.random([1, vectors, inputs], seed: 9, scale: 1).asType(.bfloat16)
                        eval(x)
                        var line = "\(label) [\(inputs)->\(outputs)] \(mode) M=\(vectors) calls=\(layers.count)"
                        // MLX's own call (an FP32 partial: the widened activation and FP32 scales, as cached).
                        line += " mlx=" + rate(timed { layers.map { f32out ? $0(x.asType(.float32)) : $0(x) } })
                        if vectors == 1 {
                            let two = concatenated([x, x], axis: 1)
                            line += " mlx_wide_pad2=" + rate(timed { layers.map { f32out ? $0(two.asType(.float32)) : $0(two) } })
                        }
                        // The SDK's wide kernel (qmv_wide arithmetic): [tiles, columns<=4, K] windows.
                        let columns = vectors == 1 ? 1 : (vectors % 4 == 0 ? 4 : (vectors % 5 == 0 ? 5 : vectors))
                        if (2...5).contains(columns) {
                            let shaped = x.reshaped([vectors / columns, columns, inputs])
                            for perThread in [1, 2] {
                                let layout = Qwen35WideQuantizedKernel.Layout(rowsPerThread: perThread, maximumVectors: 8)
                                let ok = Qwen35WideQuantizedKernel.project(f32out ? shaped.asType(.float32) : shaped,
                                    weight: layers[0].weight, scales: layers[0].scales, biases: layers[0].biases,
                                    groupSize: 64, bits: 4, mode: .affine, layout: layout) != nil
                                if ok {
                                    line += " sdkwide_r\(perThread)=" + rate(timed { layers.map {
                                        Qwen35WideQuantizedKernel.project(f32out ? shaped.asType(.float32) : shaped,
                                            weight: $0.weight, scales: $0.scales, biases: $0.biases, groupSize: 64, bits: 4,
                                            mode: .affine, layout: layout)! } })
                                }
                            }
                        }
                        for arithmetic in arithmetics {
                          for words in perLane {
                            AffineQuantizedVectors.$arithmeticOverride.withValue(arithmetic) {
                            AffineQuantizedVectors.$wordsPerLaneOverride.withValue(words) {
                                for layout in layouts(vectors) {
                                    // w<words>[d]<layout>: d marks the dequantized-weights arithmetic.
                                    let name = "w\(words)" + (arithmetic == .dequantizedWeights ? "d" : "") + (layout.map { "\($0)" }
                                        ?? "auto(\(AffineQuantizedVectors.layout(vectors: vectors, inputs: inputs, outputs: outputs, bits: 4)))")
                                    guard AffineQuantizedVectors.project(x, layers[0], outputDType: f32out ? .float32 : nil,
                                        layout: layout) != nil else { continue }
                                    line += " \(name)=" + rate(timed { layers.map {
                                        AffineQuantizedVectors.project(x, $0, outputDType: f32out ? .float32 : nil, layout: layout)! } })
                                }
                            }
                            }
                          }
                        }
                        // A dense MLP's gate and up (consecutive weights as pairs) with the SwiGLU: the fused
                        // kernel against two projections and the SwiGLU, in the process's arithmetic and words
                        // per lane (QWEN_TP_AQV_BENCH_SWIGLU=1; bf16 mode).
                        if environment["QWEN_TP_AQV_BENCH_SWIGLU"] == "1", !f32out, layers.count >= 2 {
                            let pairs = stride(from: 0, to: layers.count - 1, by: 2).map { (layers[$0], layers[$0 + 1]) }
                            func pairRate(_ ms: Double) -> String {
                                "\(Int(ms * 1000 / Double(pairs.count)))us/\(Int(bytes / (ms / 1000) / 1e9))GBps"
                            }
                            for arithmetic in arithmetics {
                                AffineQuantizedVectors.$arithmeticOverride.withValue(arithmetic) {
                                    let tag = arithmetic == .dequantizedWeights ? "d" : ""
                                    line += " swiglu_fused\(tag)=" + pairRate(timed { pairs.map {
                                        AffineQuantizedVectors.projectSwiGLU(x, gate: $0.0, up: $0.1)! } })
                                    line += " swiglu_split\(tag)=" + pairRate(timed { pairs.map {
                                        silu(AffineQuantizedVectors.project(x, $0.0)!) * AffineQuantizedVectors.project(x, $0.1)! } })
                                }
                            }
                        }
                        print(line)
                    }
                }
                layers.removeAll()
                Memory.clearCache()
            }
        }
    }
}
