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
}
