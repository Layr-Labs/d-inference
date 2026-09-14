import Foundation
import MLX
import XCTest

final class SDPAPartialPrecisionTests: XCTestCase {
    private func withBlocks(_ blocks: Int, body: () -> Void) {
        let previous = getenv("MLX_SDPA_BLOCKS").map { String(cString: $0) }
        setenv("MLX_SDPA_BLOCKS", String(blocks), 1)
        defer {
            if let previous { setenv("MLX_SDPA_BLOCKS", previous, 1) }
            else { unsetenv("MLX_SDPA_BLOCKS") }
        }
        body()
    }

    func testPartialCancellation() {
        let length = 8192
        for dtype in [DType.bfloat16, .float16, .float32] {
            for dimension in [64, 128, 256] {
                for blocks in [32, 128] {
                    for masked in [false, true] {
                        let amplitude: Float = dtype == .float16 ? 2048 : 256
                        var values = [Float](repeating: 0, count: length * dimension)
                        let gqa = dimension != 256 && !masked
                        let residualToken = gqa ? 1 : blocks
                        let negativeToken = gqa ? length - 1 : 1
                        for channel in 0 ..< dimension {
                            values[channel] = amplitude
                            values[residualToken * dimension + channel] = 1
                            values[negativeToken * dimension + channel] = -amplitude
                        }
                        let q = MLXArray.zeros([1, 8, 1, dimension], dtype: dtype)
                        let k = MLXArray.zeros([1, 1, length, dimension], dtype: dtype)
                        let v = MLXArray(values, [1, 1, length, dimension]).asType(dtype)
                        let mask: MLXFast.ScaledDotProductAttentionMaskMode = masked
                            ? .array(MLXArray.ones([length], dtype: .bool)) : .none
                        withBlocks(blocks) {
                            let result = MLXFast.scaledDotProductAttention(
                                queries: q, keys: k, values: v, scale: 1, mask: mask)
                            eval(result)
                            XCTAssertEqual(result.dtype, dtype)
                            XCTAssertTrue(result.asArray(Float.self).allSatisfy { $0 == 1 / Float(length) },
                                "dtype=\(dtype) dimension=\(dimension) blocks=\(blocks) masked=\(masked)")
                        }
                    }
                }
            }
        }
    }

    func testMultiQueryMasksAndSinks() {
        let length = 8192
        let dimension = 256
        let dtype = DType.bfloat16
        let blocks = 128
        var values = [Float](repeating: 0, count: 2 * length * dimension)
        for head in 0 ..< 2 {
            for channel in 0 ..< dimension {
                let start = head * length * dimension + channel
                values[start] = 256
                values[start + blocks * dimension] = 1
                values[start + dimension] = -256
            }
        }
        let k = MLXArray.zeros([1, 2, length, dimension], dtype: dtype)
        let v = MLXArray(values, [1, 2, length, dimension]).asType(dtype)
        for transposed in [false, true] {
            let shape = transposed ? [1, 2, 16, dimension] : [1, 16, 2, dimension]
            let raw = MLXArray([Float](repeating: 0, count: 32 * dimension), shape).asType(dtype)
            eval(raw)
            let q = transposed ? raw.swappedAxes(1, 2) : raw
            for boolean in [false, true] {
                let mask = boolean
                    ? MLXArray.ones([2, length], dtype: .bool)
                    : MLXArray.zeros([2, length], dtype: dtype)
                for withSinks in [false, true] {
                    let sinks = withSinks ? MLXArray.zeros([16], dtype: dtype) : nil
                    let expected = MLXArray(1 / Float(length + (withSinks ? 1 : 0)))
                        .asType(dtype).item(Float.self)
                    withBlocks(blocks) {
                        let result = MLXFast.scaledDotProductAttention(
                            queries: q, keys: k, values: v, scale: 1,
                            mask: .array(mask), sinks: sinks)
                        eval(result)
                        XCTAssertEqual(result.shape, [1, 16, 2, dimension])
                        XCTAssertEqual(result.dtype, dtype)
                        XCTAssertTrue(result.asArray(Float.self).allSatisfy { $0 == expected },
                            "transposed=\(transposed) boolean=\(boolean) sinks=\(withSinks)")
                    }
                }
            }
        }
    }

    func testPartialOverflow() {
        let length = 8192
        for dimension in [64, 128, 256] {
            for blocks in [32, 128] {
                let q = MLXArray.zeros([1, 8, 1, dimension], dtype: .float16)
                let k = MLXArray.zeros([1, 1, length, dimension], dtype: .float16)
                let v = MLXArray.full([1, 1, length, dimension], values: MLXArray(32768)).asType(.float16)
                withBlocks(blocks) {
                    let result = MLXFast.scaledDotProductAttention(
                        queries: q, keys: k, values: v, scale: 1, mask: .none)
                    eval(result)
                    XCTAssertTrue(result.asArray(Float.self).allSatisfy { $0.isFinite && $0 == 32768 },
                        "dimension=\(dimension) blocks=\(blocks)")
                }
            }
        }
    }
}
