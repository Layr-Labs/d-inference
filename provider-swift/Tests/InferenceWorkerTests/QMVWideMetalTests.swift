import MLX
import Testing

@Suite("QMV wide Metal")
struct QMVWideMetalTests {
    @Test("Gemma BF16 W4/W8 M=1, wide, and QMM routes match dequantized matmul")
    func gemmaSmallBatchParity() {
        Device.setDefault(device: .gpu)
        MLXRandom.seed(0)

        let groupSize = 64
        let inputDimensions = 512
        let outputDimensions = 96
        let normalization = Float(inputDimensions).squareRoot()

        for bits in [4, 8] {
            for batch in [1, 3] {
                for rows in [1, 2, 4, 8, 12] {
                    let xShape = batch == 1
                        ? [rows, inputDimensions]
                        : [batch, rows, inputDimensions]
                    let weightShape = batch == 1
                        ? [outputDimensions, inputDimensions]
                        : [batch, outputDimensions, inputDimensions]
                    let x = (MLXRandom.normal(xShape) / normalization).asType(.bfloat16)
                    let weights =
                        (MLXRandom.normal(weightShape) / normalization).asType(.bfloat16)
                    let (packed, scales, biases) = quantized(
                        weights,
                        groupSize: groupSize,
                        bits: bits,
                        mode: .affine
                    )
                    let actual = quantizedMM(
                        x,
                        packed,
                        scales: scales,
                        biases: biases,
                        transpose: true,
                        groupSize: groupSize,
                        bits: bits,
                        mode: .affine
                    )
                    let referenceWeights = dequantized(
                        packed,
                        scales: scales,
                        biases: biases,
                        groupSize: groupSize,
                        bits: bits,
                        mode: .affine
                    )
                    let expected = matmul(x, referenceWeights.swappedAxes(-1, -2))

                    eval(actual, expected)
                    let maximumError = (actual - expected).abs().max().item(Float.self)
                    #expect(actual.shape == expected.shape)
                    #expect(
                        maximumError < 0.1,
                        "W\(bits) B=\(batch) M=\(rows) max error \(maximumError)"
                    )
                    Memory.clearCache()
                }
            }
        }
    }
}
