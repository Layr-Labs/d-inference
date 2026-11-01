import Foundation
import MLX
import Testing

/// MLX's steel affine quantized matmul computes a prompt-sized product in
/// larger output tiles than 32 x 32 on a GPU without neural accelerators
/// (`qmm` in mlx/backend/metal/quantized.cpp, `MLX_QMM_STEEL_TILE`, the
/// default and every tile code): every element must keep its bits, for BF16 and FP32
/// inputs (the tensor-parallel row-parallel partials are FP32), aligned and
/// partial row tiles. Inputs whose width is not a multiple of 64 stay off the
/// NAX kernel, so the steel kernel runs on every Mac (`QWEN_TP_BATCH_GPU=1`).
@Suite(.serialized)
struct QuantizedMatmulSteelTileTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"))
    func bothTilesGiveTheSameBytes() throws {
        try Device.withDefaultDevice(.gpu) {
            // (outputs, inputs, group size): the steel path everywhere (inputs % 64 == 32), and
            // a 27B-like row-parallel shape (on a NAX GPU both tiles take the NAX kernel).
            for (outputs, inputs, groupSize) in [(1024, 2080, 32), (5120, 3104, 32), (1280, 6144, 64)] {
                let dense = (MLXRandom.normal([outputs, inputs], key: MLXRandom.key(UInt64(outputs * 7 + inputs))) * 0.02)
                    .asType(.bfloat16)
                let packed = MLX.quantized(dense, groupSize: groupSize, bits: 4, mode: .affine)
                let scales32 = packed.scales.asType(.float32), biases32 = packed.biases!.asType(.float32)
                eval(packed.wq, packed.scales, packed.biases!, scales32, biases32)
                for rows in [64, 100, 512, 1000] {
                    let x = (MLXRandom.normal([1, rows, inputs], key: MLXRandom.key(UInt64(rows))) * 0.5).asType(.bfloat16)
                    eval(x)
                    for float32 in [false, true] {
                        func product() -> MLXArray {
                            float32
                                ? quantizedMM(x.asType(.float32), packed.wq, scales: scales32, biases: biases32,
                                    transpose: true, groupSize: groupSize, bits: 4, mode: .affine)
                                : quantizedMM(x, packed.wq, scales: packed.scales, biases: packed.biases,
                                    transpose: true, groupSize: groupSize, bits: 4, mode: .affine)
                        }
                        let small = GPU.withQuantizedMatmulSteelTile(32) { () -> Data in
                            let y = product(); eval(y); return y.asData(access: .copy).data
                        }
                        // The process default (0: 64 x 32 for BF16, 32 x 64 for FP32, from 256
                        // rows), 64 x 64, 64 x 32, 32 x 64, and 64 x 64 with a K depth of 64.
                        for tile in [0, 64, 6432, 3264, 6464] {
                            let large = GPU.withQuantizedMatmulSteelTile(tile) { () -> Data in
                                let y = product(); eval(y); return y.asData(access: .copy).data
                            }
                            #expect(small == large,
                                "tile \(tile) outputs \(outputs) inputs \(inputs) rows \(rows) float32 \(float32)")
                        }
                    }
                }
            }
        }
    }
}
