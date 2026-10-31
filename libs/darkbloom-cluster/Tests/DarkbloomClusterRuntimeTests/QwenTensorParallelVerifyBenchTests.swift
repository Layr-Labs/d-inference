import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// Opt-in local timing of batched verify windows on ONE Mac with a real Qwen27
/// shard and no peer (`QwenTensorParallelLocalReduction`: the outputs are not a
/// tensor-parallel result). Each round is split into graph construction,
/// evaluation (with confirmation) and settlement for 1...4 rows, so a row's
/// own cost can be told apart from the pair's collectives.
/// QWEN_TP_VERIFY_BENCH_MODEL=<model dir> [QWEN_TP_VERIFY_BENCH_RANK=1]
/// [QWEN_TP_VERIFY_BENCH_SHARES=2,1] [QWEN_TP_VERIFY_BENCH_COLUMNS=4] [QWEN_TP_VERIFY_BENCH_ROUNDS=12]
@Suite(.serialized)
struct QwenTensorParallelVerifyBenchTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_VERIFY_BENCH_MODEL"] != nil))
    func verifyWindowRoundsByRowCount() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: environment["QWEN_TP_VERIFY_BENCH_MODEL"]!)
        let rank = Int(environment["QWEN_TP_VERIFY_BENCH_RANK"] ?? "1") ?? 1
        let shares = (environment["QWEN_TP_VERIFY_BENCH_SHARES"] ?? "2,1").split(separator: ",").compactMap { Int($0) }
        let columns = Int(environment["QWEN_TP_VERIFY_BENCH_COLUMNS"] ?? "4") ?? 4
        let rounds = Int(environment["QWEN_TP_VERIFY_BENCH_ROUNDS"] ?? "12") ?? 12
        try Device.withDefaultDevice(.gpu) {
            let configuration = try Data(contentsOf: directory.appendingPathComponent("config.json"))
            let model = try QwenTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank, size: 2),
                reduction: QwenTensorParallelLocalReduction(rank: rank, size: 2), shares: shares)
            let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: 4,
                maximumTokensPerRequest: 4096, maximumChunkTokens: 512)
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-verify-bench",
                vocabularySize: model.plan.vocabularySize, hiddenSize: model.plan.hiddenSize, activationDType: "bfloat16",
                maximumPromptTokens: 1024, maximumChunkTokens: 512, maximumOutputTokens: 512, maximumContextTokens: 4096)
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            for width in 1...4 {
                var sessions: [QwenTensorParallelBatchSession] = []
                for row in 0..<width {
                    let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                        promptTokenIDs: (0..<96).map { ($0 * 131 + row * 17 + 11) % 150_000 },
                        chunkSize: 512, outputCount: 256, stopTokenIDs: [])
                    let session = try QwenTensorParallelBatchSession(model: model, configuration: configuration,
                        host: host, request: request)
                    while session.schedule.committedPromptTokens < request.promptCount { _ = try session.prefill(check: {}) }
                    sessions.append(session)
                }
                var build: [Double] = [], evaluate: [Double] = [], settle: [Double] = []
                for round in 0..<rounds {
                    let tokens = MLXArray((0..<width * columns).map { Int32(($0 * 37 + round * 101) % 150_000) })
                        .reshaped([width, columns])
                    let started = DispatchTime.now().uptimeNanoseconds
                    let built = try QwenTensorParallelBatchSession.beginWindows(sessions, tokens: tokens)
                    let constructed = DispatchTime.now().uptimeNanoseconds
                    eval(built.outputs + built.roots)
                    try QwenTensorParallelBatchSession.confirmWindows(sessions, check: {})
                    let evaluated = DispatchTime.now().uptimeNanoseconds
                    let roots = try QwenTensorParallelBatchSession.settleWindows(sessions,
                        keeping: Array(repeating: columns, count: width))
                    eval(roots)
                    try QwenTensorParallelBatchSession.confirmSettledWindows(sessions, check: {})
                    let settled = DispatchTime.now().uptimeNanoseconds
                    if round >= 2 {
                        build.append(Double(constructed - started) / 1e6)
                        evaluate.append(Double(evaluated - constructed) / 1e6)
                        settle.append(Double(settled - evaluated) / 1e6)
                    }
                }
                print("qwen-tp-verify-bench rank=\(rank) shares=\(shares) rows=\(width) columns=\(columns) "
                    + "build_ms=\(median(build)) eval_ms=\(median(evaluate)) settle_ms=\(median(settle))")
                for session in sessions { try session.retire() }
            }
        }
    }

    /// Opt-in kernel throughput study (QWEN_TP_WIDE_BENCH=1): MLX's own per-row
    /// windows, the SDK's wide kernel and exact-arithmetic variants that give a
    /// thread R output rows (each input vector converted once for R rows). Every
    /// variant must equal each row's own MLX call byte for byte.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_WIDE_BENCH"] != nil))
    func wideKernelVariantThroughput() throws {
        try Device.withDefaultDevice(.gpu) {
            func random(_ shape: [Int], seed: UInt64, scale: Float) -> MLXArray {
                withRandomState(MLXRandom.RandomState(seed: seed)) { (MLXRandom.normal(shape) * scale).asType(.bfloat16) }
            }
            func seconds(_ body: () -> [MLXArray]) -> Double {
                eval(body())
                var samples: [Double] = []
                for _ in 0..<5 {
                    let started = DispatchTime.now().uptimeNanoseconds
                    eval(body())
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
                }
                return samples.sorted()[2]
            }
            let reps = 8
            let shapes: [(Int, Int, DType)] = [(5120, 11648, .bfloat16), (11648, 5120, .float32), (5120, 8192, .bfloat16)]
            for (index, (inputs, outputs, dtype)) in shapes.enumerated() {
                let linear = QuantizedLinear(weight: random([outputs, inputs], seed: UInt64(300 + index), scale: 0.02),
                    bias: nil, groupSize: 64, bits: 4)
                eval(linear.weight, linear.scales, linear.biases!)
                let bytes = Double(linear.weight.nbytes + linear.scales.nbytes + linear.biases!.nbytes)
                for rows in [1, 2, 3, 4, 8] {
                    let x = random([rows, 4, inputs], seed: UInt64(400 + rows), scale: 1).asType(dtype)
                    eval(x)
                    let alone = concatenated((0..<rows).map { linear(x[$0 ..< $0 + 1]) }, axis: 0)
                    eval(alone)
                    let expected = alone.asData(access: .copy).data
                    func report(_ name: String, _ time: Double, _ out: MLXArray) {
                        let flops = 2.0 * Double(inputs * outputs * rows * 4)
                        let same = out.asData(access: .copy).data == expected
                        print("qwen-tp-wide-bench [\(inputs)->\(outputs)] \(dtype) rows=\(rows) \(name) "
                            + "us=\(Int(time / Double(reps) * 1e6)) weight_GBps=\(Int(bytes / (time / Double(reps)) / 1e9)) "
                            + "TFLOPS=\(String(format: "%.2f", flops / (time / Double(reps)) / 1e12)) exact=\(same)")
                        #expect(same, "\(name) differs from each row's own call")
                    }
                    report("mlx-rows", seconds { (0..<reps).map { _ in
                        concatenated((0..<rows).map { linear(x[$0 ..< $0 + 1]) }, axis: 0) } }, alone)
                    if rows > 1, let wide = Qwen35WideQuantizedKernel.project(x, weight: linear.weight, scales: linear.scales,
                        biases: linear.biases, groupSize: 64, bits: 4, mode: .affine) {
                        report("sdk-wide", seconds { (0..<reps).map { _ in Qwen35WideQuantizedKernel.project(x, weight: linear.weight,
                            scales: linear.scales, biases: linear.biases, groupSize: 64, bits: 4, mode: .affine)! } }, wide)
                    }
                    for (perThread, maximum) in [(1, 8), (2, 8), (4, 8), (2, 16), (4, 4)] {
                        let variant = WideVariant(rowsPerThread: perThread, maximumVectors: maximum)
                        let out = variant.project(x, linear)
                        report("rows\(perThread)-v\(maximum)", seconds { (0..<reps).map { _ in variant.project(x, linear) } }, out)
                    }
                }
            }
        }
    }
}

/// The SDK wide kernel's arithmetic with `rowsPerThread` output rows per
/// thread (rows `base + 4j` of a simdgroup's block): each row and vector keeps
/// its lanes, sub-chunk sums and shuffle ladder, so only the instruction mix
/// changes (one conversion of each input value serves R rows).
private struct WideVariant {
    let rowsPerThread: Int
    let maximumVectors: Int
    private let kernel: MLXFast.MLXFastKernel

    init(rowsPerThread: Int, maximumVectors: Int) {
        self.rowsPerThread = rowsPerThread
        self.maximumVectors = maximumVectors
        let header = """
            inline void wide_variant_dequantize4(
                const device uint8_t* w, float scale, float bias, thread float* w_local) {
              const float s = float(scale);
              const float b = float(bias);
              float sc[2] = {s, s / 16.0f};
              for (int i = 0; i < 4; i++) {
                w_local[2 * i] = static_cast<float>(sc[0] * (w[i] & 0x0f) + b);
                w_local[2 * i + 1] = static_cast<float>(sc[1] * (w[i] & 0xf0) + b);
              }
            }
            """
        let source = """
            constexpr int k_lanes = 8;
            constexpr int num_simdgroups = 2;
            constexpr int results_per_simdgroup = 32 / k_lanes;
            constexpr int R = \(rowsPerThread);
            constexpr int sub = 8;
            constexpr int bits = 4;
            const int in_vec_size = dims[0];
            const int out_vec_size = dims[1];
            const int M = dims[2];
            const uint3 tid = threadgroup_position_in_grid;
            const uint simd_gid = simdgroup_index_in_threadgroup;
            const uint simd_lid = thread_index_in_simdgroup;
            const short k_lane = simd_lid % k_lanes;
            const short sg_row = simd_lid / k_lanes;
            const int base_row = tid.y * (results_per_simdgroup * num_simdgroups * R) +
                results_per_simdgroup * R * simd_gid + sg_row;
            const int vec0 = tid.x * V;
            const int in_vec_size_w = in_vec_size * bits / 8;
            const int in_vec_size_g = in_vec_size / GROUP;
            const device uint8_t* wrow[R];
            const device TS* srow[R];
            const device TS* brow[R];
            for (int j = 0; j < R; j++) {
              const int row = min(base_row + j * results_per_simdgroup, out_vec_size - 1);
              wrow[j] = (const device uint8_t*)w + row * in_vec_size_w;
              srow[j] = scales + row * in_vec_size_g;
              brow[j] = biases + row * in_vec_size_g;
            }
            const device TX* xv[V];
            for (int v = 0; v < V; v++) {
              xv[v] = x + min(vec0 + v, M - 1) * in_vec_size;
            }
            float result[R][V];
            for (int j = 0; j < R; j++) {
              for (int v = 0; v < V; v++) { result[j][v] = 0; }
            }
            for (int g = k_lane; g < in_vec_size_g; g += k_lanes) {
              float scale[R];
              float bias[R];
              for (int j = 0; j < R; j++) { scale[j] = srow[j][g]; bias[j] = brow[j][g]; }
            #pragma unroll
              for (int sc = 0; sc < GROUP / sub; sc++) {
                const int k0 = g * GROUP + sc * sub;
                float w_dq[R][sub];
            #pragma unroll
                for (int j = 0; j < R; j++) {
                  wide_variant_dequantize4(wrow[j] + k0 * bits / 8, scale[j], bias[j], w_dq[j]);
                }
            #pragma unroll
                for (int v = 0; v < V; v++) {
                  const device TX* xc = xv[v] + k0;
                  float xf[sub];
            #pragma unroll
                  for (int i = 0; i < sub; i++) { xf[i] = static_cast<float>(xc[i]); }
            #pragma unroll
                  for (int j = 0; j < R; j++) {
                    float acc = 0;
            #pragma unroll
                    for (int i = 0; i < sub; i++) {
                      acc += xf[i] * w_dq[j][i];
                    }
                    result[j][v] += acc;
                  }
                }
              }
            }
            for (int j = 0; j < R; j++) {
              for (int v = 0; v < V; v++) {
                result[j][v] += simd_shuffle_down(result[j][v], 4);
                result[j][v] += simd_shuffle_down(result[j][v], 2);
                result[j][v] += simd_shuffle_down(result[j][v], 1);
              }
            }
            if (k_lane == 0) {
              for (int j = 0; j < R; j++) {
                const int out_row = base_row + j * results_per_simdgroup;
                if (out_row < out_vec_size) {
                  for (int v = 0; v < V; v++) {
                    if (vec0 + v < M) {
                      y[(vec0 + v) * out_vec_size + out_row] = static_cast<TX>(result[j][v]);
                    }
                  }
                }
              }
            }
            """
        kernel = MLXFast.metalKernel(name: "wide_variant_r\(rowsPerThread)", inputNames: ["w", "scales", "biases", "x", "dims"],
            outputNames: ["y"], source: source, header: header)
    }

    func project(_ input: MLXArray, _ linear: QuantizedLinear) -> MLXArray {
        let rows = input.dim(0), columns = input.dim(1), inputs = input.dim(2)
        let outputs = linear.weight.dim(0), vectors = rows * columns
        let tiles = (vectors + maximumVectors - 1) / maximumVectors
        let perTile = (vectors + tiles - 1) / tiles
        let dims = MLXArray([Int32(inputs), Int32(outputs), Int32(vectors)])
        let flat = input.reshaped([vectors, inputs])
        let block = 8 * rowsPerThread
        return kernel([linear.weight, linear.scales, linear.biases!, flat, dims],
            template: [("TX", flat.dtype), ("TS", linear.scales.dtype), ("GROUP", 64), ("V", perTile)],
            grid: (tiles * 32, ((outputs + block - 1) / block) * 2, 1), threadGroup: (32, 2, 1),
            outputShapes: [[vectors, outputs]], outputDTypes: [flat.dtype])[0].reshaped([rows, columns, outputs])
    }
}
