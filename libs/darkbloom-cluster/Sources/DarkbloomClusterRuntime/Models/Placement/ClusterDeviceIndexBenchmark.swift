import DarkbloomClusterPlacement
import Foundation
import MLX

/// A model-free index of this Mac: about a second of the operation a dense
/// quantized model spends most of its time in, at a prefill shape and at a
/// decode shape. No model, no artifact and no table; only ratios between two
/// Macs running the same benchmark on the same binary mean anything.
///
/// It is an experiment. It is kept only if it orders a pair the way real
/// measurements do for both shapes; until then nothing ranks by it.
public enum ClusterDeviceIndexBenchmark {
    public static let name = "qmm_h4096_b4_g64_x16_v1"
    static let hidden = 4096, bits = 4, group = 64, chained = 16

    public static func measure(secondsPerShape: Double = 0.5) throws -> ClusterDeviceIndex {
        let profile = try ClusterDeviceProfileSampler.sample()
        // A fixed, non-degenerate 4-bit weight with its scales and biases.
        var words = [UInt32](repeating: 0, count: hidden * hidden * bits / 32)
        var state: UInt32 = 0x9E37_79B9
        for index in words.indices { state = state &* 1_664_525 &+ 1_013_904_223; words[index] = state }
        let weight = MLXArray(words, [hidden, hidden * bits / 32])
        let groups = hidden / group
        let scales = MLXArray([Float](repeating: 1.0 / 512, count: hidden * groups), [hidden, groups]).asType(.bfloat16)
        let biases = MLXArray([Float](repeating: -1.0 / 64, count: hidden * groups), [hidden, groups]).asType(.bfloat16)
        eval(weight, scales, biases)

        func rate(tokens: Int) -> Double {
            let input = MLXArray([Float](repeating: 0.01, count: tokens * hidden), [1, tokens, hidden]).asType(.bfloat16)
            eval(input)
            func pass() {
                var x = input
                for _ in 0..<chained {
                    x = quantizedMatmul(x, weight, scales: scales, biases: biases, transpose: true, groupSize: group, bits: bits)
                }
                // Reading a value waits for the GPU.
                _ = x.sum().asType(.float32).item(Float.self)
            }
            pass(); pass()
            var passes = 0
            let start = DispatchTime.now().uptimeNanoseconds
            var elapsed = 0.0
            repeat {
                pass(); passes += 1
                elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            } while elapsed < secondsPerShape
            return Double(passes * tokens * chained) / elapsed
        }
        let prefill = rate(tokens: 512), decode = rate(tokens: 1)
        return .init(chip: profile.chip, osBuild: profile.osBuild, benchmark: name, prefillIndex: prefill, decodeIndex: decode)
    }
}
