import Foundation
import MLX
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// The batched cohort drafts' head arithmetic (`QwenTensorParallelMTPDecoder.stepBatch`).
struct QwenTensorParallelMTPHeadRowsTests {
    /// A cohort's proposals share one head call, and each row's product is
    /// byte-equal to that row's own call (MLX's single-vector kernel) at
    /// Qwen27's hidden width, for two to eight rows: one call that hands MLX
    /// all rows at once may use another kernel (qmv_wide on GPU family 15+).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func cohortHeadRowsKeepEachRowsOwnProduct() throws {
        try Device.withDefaultDevice(.gpu) {
            func random(_ shape: [Int], seed: UInt64, scale: Float) -> MLXArray {
                withRandomState(MLXRandom.RandomState(seed: seed)) { (MLXRandom.normal(shape) * scale).asType(.bfloat16) }
            }
            let head = QuantizedLinear(weight: random([4096, 5120], seed: 51, scale: 0.02), bias: nil,
                groupSize: 64, bits: 4)
            eval(head)
            for rows in 2...8 {
                let x = random([rows, 1, 5120], seed: UInt64(60 + rows), scale: 1)
                let shared = QwenTensorParallelMTPProjection.rowsAlone(head, x)
                let alone = concatenated((0..<rows).map { head(x[$0 ..< $0 + 1]) }, axis: 0)
                let plain = head(x)
                eval(shared, alone, plain)
                #expect(shared.shape == [rows, 1, 4096])
                #expect(shared.asData(access: .copy).data == alone.asData(access: .copy).data,
                    "rows=\(rows): the shared head call changed a row's arithmetic")
                print("darkbloom-cohort-head-rows-v1 rows=\(rows) plain_call_equal=\(plain.asData(access: .copy).data == alone.asData(access: .copy).data)")
            }
        }
    }

    /// Exact drafts (`QwenTensorParallelMTPDecoder.draftsOnExactVectors`): the
    /// head and the assistant's projections take `AffineQuantizedVectors`, one
    /// weight read for every row. At Qwen27's head and assistant shapes, every
    /// row of a two-to-eight-row product is byte-equal to the same row alone
    /// (one vector), so a row's proposal is the same solo and in any cohort.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func exactDraftProjectionsKeepEachRowsOwnProductAtQwen27Shapes() throws {
        try Device.withDefaultDevice(.gpu) {
            func random(_ shape: [Int], seed: UInt64, scale: Float) -> MLXArray {
                withRandomState(MLXRandom.RandomState(seed: seed)) { (MLXRandom.normal(shape) * scale).asType(.bfloat16) }
            }
            // The head shard, then the assistant's FC, q/k/v/o and MLP at Qwen27's widths.
            let shapes: [(outputs: Int, inputs: Int)] = [(4096, 5120), (5120, 10240), (12288, 5120), (1024, 5120),
                (5120, 6144), (17408, 5120), (5120, 17408)]
            for (index, shape) in shapes.enumerated() {
                let linear = QuantizedLinear(weight: random([shape.outputs, shape.inputs], seed: UInt64(70 + index), scale: 0.02),
                    bias: nil, groupSize: 64, bits: 4)
                eval(linear)
                for rows in [2, 4, 6, 8] {
                    let x = random([rows, 1, shape.inputs], seed: UInt64(90 + rows + 10 * index), scale: 1)
                    let together = QwenTensorParallelMTPDecoder.exactDraftProjection(linear, x)
                    let alone = concatenated((0..<rows).map {
                        QwenTensorParallelMTPDecoder.exactDraftProjection(linear, x[$0 ..< $0 + 1])
                    }, axis: 0)
                    let head = try #require(QwenTensorParallelMTPProjection.exactProduct(linear, x))
                    eval(together, alone, head)
                    #expect(together.shape == [rows, 1, shape.outputs])
                    #expect(together.asData(access: .copy).data == alone.asData(access: .copy).data,
                        "\(shape) rows=\(rows): an exact draft projection changed a row")
                    #expect(head.asData(access: .copy).data == together.asData(access: .copy).data)
                }
            }
        }
    }
}
