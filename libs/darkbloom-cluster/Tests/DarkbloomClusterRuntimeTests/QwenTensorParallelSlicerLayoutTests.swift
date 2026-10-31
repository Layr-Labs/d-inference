import Foundation
import MLX
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// A rank's cut of an interior axis is a new row-major buffer holding the
/// gathered elements (`QwenTensorParallelSlicer.cut`), and every quantized
/// product read from it equals, byte for byte, the one read from the
/// transposed gather view the cut used to keep (which MLX copied to a
/// row-major buffer at each call). On the GPU with `QWEN_TP_BATCH_GPU=1`.
struct QwenTensorParallelSlicerLayoutTests {
    private var device: Device { ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1" ? .gpu : .cpu }
    private func bytes(_ a: MLXArray) -> Data { eval(a); return a.asData(access: .copy).data }
    private func rowMajor(_ a: MLXArray) -> Bool {
        eval(a)
        var expected = 1
        for (size, stride) in zip(a.shape, a.strides).reversed() where size > 1 {
            guard stride == expected else { return false }
            expected *= size
        }
        return true
    }
    private func view(_ value: MLXArray, axis: Int, _ ranges: [Range<Int>]) -> MLXArray {
        take(value, MLXArray(ranges.flatMap { $0.map { Int32($0) } }), axis: axis)
    }

    @Test func interiorCutsAreRowMajorCopiesWithTheSameProducts() throws {
        try Device.withDefaultDevice(device) {
            MLXRandom.seed(11)
            // A row-parallel projection, 96 outputs by 512 inputs: rank 1 keeps inputs 256..<512.
            let (w, s, b) = MLX.quantized(MLXRandom.normal([96, 512]).asType(.bfloat16), groupSize: 64, bits: 4)
            let leaves = [("weight", w, 32..<64), ("scales", s, 4..<8), ("biases", b!, 4..<8)]
            let cuts = try leaves.map {
                try QwenTensorParallelSlicer.cut($0.1, .inputColumns(256..<512), leaf: $0.0, groupSize: 64, bits: 4)
            }
            let views = leaves.map { view($0.1, axis: 1, [$0.2]) }
            #expect(cuts.allSatisfy(rowMajor) && !rowMajor(views[0]))
            for (cut, former) in zip(cuts, views) { #expect(cut.shape == former.shape && bytes(cut) == bytes(former)) }
            // One row alone, the batched rows' leading broadcast dimension, and a
            // 40-token prefill chunk (a matrix product, not the vector kernel).
            for x in [MLXRandom.normal([1, 1, 256]), MLXRandom.normal([3, 1, 256]), MLXRandom.normal([1, 40, 256])] {
                func product(_ p: [MLXArray]) -> MLXArray {
                    x.dim(0) == 1
                        ? quantizedMM(x, p[0], scales: p[1].asType(.float32), biases: p[2].asType(.float32),
                            transpose: true, groupSize: 64, bits: 4)
                        : quantizedMM(x, p[0].expandedDimensions(axis: 0), scales: p[1].asType(.float32).expandedDimensions(axis: 0),
                            biases: p[2].asType(.float32).expandedDimensions(axis: 0), transpose: true, groupSize: 64, bits: 4)
                }
                #expect(bytes(product(cuts)) == bytes(product(views)))
            }

            // An expert bank's input columns, [4 experts, 64 outputs, 512 inputs].
            let (bw, bs, bb) = MLX.quantized(MLXRandom.normal([4, 64, 512]).asType(.bfloat16), groupSize: 64, bits: 4)
            let bank = [("weight", bw, 32..<64), ("scales", bs, 4..<8), ("biases", bb!, 4..<8)]
            let bankCuts = try bank.map {
                try QwenTensorParallelSlicer.cut($0.1, .expertInputColumns(256..<512), leaf: $0.0, groupSize: 64, bits: 4)
            }
            let bankViews = bank.map { view($0.1, axis: 2, [$0.2]) }
            #expect(bankCuts.allSatisfy(rowMajor) && !rowMajor(bankViews[0]))
            let routes = MLXArray([Int32(3), 1]).reshaped([1, 2]).asType(.uint32)
            let activated = MLXRandom.normal([1, 2, 1, 256])
            func gathered(_ p: [MLXArray]) -> MLXArray {
                gatherQuantizedMM(activated, p[0], scales: p[1].asType(.float32), biases: p[2].asType(.float32),
                    rhsIndices: routes, transpose: true, groupSize: 64, bits: 4)
            }
            #expect(bytes(gathered(bankCuts)) == bytes(gathered(bankViews)))
            // A prefill's sorted gather (T x top-K >= 64 rows, routes ascending).
            let sortedRoutes = MLXArray((0..<80).map { UInt32($0 * 4 / 80) })
            let sortedRows = MLXRandom.normal([80, 1, 256])
            func sortedGather(_ p: [MLXArray]) -> MLXArray {
                gatherQuantizedMM(sortedRows, p[0], scales: p[1].asType(.float32), biases: p[2].asType(.float32),
                    rhsIndices: sortedRoutes, transpose: true, groupSize: 64, bits: 4, sortedIndices: true)
            }
            #expect(bytes(sortedGather(bankCuts)) == bytes(sortedGather(bankViews)))

            // Fused gate/up expert rows, each rank two ordered ranges of axis 1.
            let rows = [32..<64, 96..<128]
            let fused = try QwenTensorParallelSlicer.cut(bw.reshaped([4, 128, 32]), .expertRowRanges(rows),
                leaf: "weight", groupSize: 64, bits: 4)
            let fusedView = view(bw.reshaped([4, 128, 32]), axis: 1, rows)
            #expect(rowMajor(fused) && !rowMajor(fusedView) && bytes(fused) == bytes(fusedView))
            let single = try QwenTensorParallelSlicer.cut(bw, .expertRows(0..<32), leaf: "weight", groupSize: 64, bits: 4)
            #expect(rowMajor(single) && bytes(single) == bytes(view(bw, axis: 1, [0..<32])))
        }
    }

    /// Batched decode rows (`QwenTensorParallelRowLinear.qwen35BatchDecode`)
    /// take the FP32 scales and biases the single-row forward caches: every
    /// row's partial equals, byte for byte, the call that widened the BF16
    /// constants inside the quantized matmul, and equals that row alone.
    @Test func batchedRowsReuseTheSingleRowConstants() throws {
        try Device.withDefaultDevice(device) {
            MLXRandom.seed(12)
            let (w, s, b) = MLX.quantized(MLXRandom.normal([96, 512]).asType(.bfloat16), groupSize: 64, bits: 4)
            let linear = QuantizedLinear(weight: w, bias: nil, scales: s, biases: b, groupSize: 64, bits: 4, mode: .affine)
            let rows = MLXRandom.normal([3, 1, 512])
            let widenedInside = quantizedMM(rows, w.expandedDimensions(axis: 0), scales: s.expandedDimensions(axis: 0),
                biases: b!.expandedDimensions(axis: 0), transpose: true, groupSize: 64, bits: 4)
            _ = linear(rows[0 ..< 1])  // the single-row forward caches its widened constants first
            let cached = linear.independentRowsForward(rows)
            #expect(s.dtype == .bfloat16 && cached.shape == widenedInside.shape && bytes(cached) == bytes(widenedInside))
            for row in 0 ..< 3 {
                #expect(bytes(cached[row ..< row + 1]) == bytes(linear.independentRowsForward(rows[row ..< row + 1])))
            }
        }
    }
}
