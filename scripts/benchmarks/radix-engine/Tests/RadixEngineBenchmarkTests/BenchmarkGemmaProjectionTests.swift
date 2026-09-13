#if RADIX_CANDIDATE
import MLX
import Testing
@testable import radix_engine

struct BenchmarkGemmaProjectionTests {
    @Test func countsEveryDifferingElementInACompleteOutput() {
        let single = MLXArray([Float(1), -0.0, 4, 9]).reshaped([1, 1, 4]).asType(.bfloat16)
        let rectangular = MLXArray([Float(1), 0.0, 3, 11, 8, 8, 8, 8]).reshaped([1, 2, 4]).asType(.bfloat16)
        let result = BenchmarkGemmaProjection.compare(single, rectangular[0..., 0..<1, 0...])
        #expect(result["element_count"] as? Int == 4)
        #expect(result["bitwise_mismatch_count"] as? Int == 3)
        #expect(result["max_absolute_error"] as? Double == 2)
        #expect(result["mean_absolute_error"] as? Double == 0.75)
        #expect(result["identical"] as? Bool == false)
    }
}
#endif
