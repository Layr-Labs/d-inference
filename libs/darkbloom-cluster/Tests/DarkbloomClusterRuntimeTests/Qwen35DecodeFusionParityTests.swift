import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import MLXNN
import Testing

/// The SDK's Qwen 3.5 decode fusions keep the unfused chain's bits: one
/// compiled SwiGLU product equals `silu(gate) * up`, and the cached Gated
/// DeltaNet scale constants equal the per-forward ones. The kernel tests are
/// GPU-gated (`QWEN_TP_AQV_GPU=1` or `QWEN_TP_MTP_GPU=1`); the residual step's
/// dtype rule runs on the CPU.
@Suite(.serialized)
struct Qwen35DecodeFusionParityTests {
    static var gpu: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["QWEN_TP_AQV_GPU"] == "1" || environment["QWEN_TP_MTP_GPU"] == "1"
    }

    private static func bytes(_ value: MLXArray) -> Data { eval(value); return value.asData(access: .copy).data }

    @Test(.enabled(if: Self.gpu)) func siluMultiplyEqualsTheUnfusedChain() throws {
        try Device.withDefaultDevice(.gpu) {
            for (index, shape) in [[1, 1, 7168], [1, 4, 10240], [3, 5, 2048], [8, 1, 96]].enumerated() {
                for dtype in [DType.bfloat16, .float16, .float32] {
                    let (gate, up) = withRandomState(MLXRandom.RandomState(seed: UInt64(10 + index))) {
                        ((MLXRandom.normal(shape) * 4).asType(dtype), (MLXRandom.normal(shape) * 2).asType(dtype))
                    }
                    let fused = Qwen35DecodeFusions.siluMultiply(gate, up)
                    let unfused = silu(gate) * up
                    #expect(fused.dtype == unfused.dtype && Self.bytes(fused) == Self.bytes(unfused),
                        "\(shape) \(dtype) SwiGLU differs from silu(gate) * up")
                }
            }
        }
    }

    /// The residual step as one kernel (`ResidualRMSNorm`) equals MLX's cast,
    /// add and RMSNorm byte for byte: rows up to 4096 wide (MLX's single-row
    /// kernel) and wider (its looped kernel), widths off the four-value read,
    /// bf16/f16/f32 activations, a bf16 or FP32 (tensor-parallel sum) residual.
    @Test(.enabled(if: Self.gpu)) func residualRMSNormEqualsTheUnfusedOps() throws {
        try Device.withDefaultDevice(.gpu) {
            for (index, width) in [5120, 4096, 2048, 3072, 1000, 6002, 128, 8192].enumerated() {
                for rows in [1, 3, 8, 40] {
                    for (dtype, residualType) in [(DType.bfloat16, DType.bfloat16), (.bfloat16, .float32),
                                                  (.float16, .float16), (.float32, .float32)] {
                        let (x, residual, weight) = withRandomState(MLXRandom.RandomState(seed: UInt64(100 + index))) {
                            ((MLXRandom.normal([rows, width]) * 3).asType(dtype),
                             (MLXRandom.normal([rows, width]) * 2).asType(residualType),
                             MLXRandom.uniform(low: Float(0.5), high: Float(1.5), [width]).asType(dtype))
                        }
                        guard let fused = ResidualRMSNorm.apply(x, residual, weight: weight, eps: 1e-6) else {
                            Issue.record("width \(width) \(dtype) not covered on \(AffineQuantizedVectors.architecture)")
                            continue
                        }
                        let sum = x + residual.asType(dtype)
                        let norm = MLXFast.rmsNorm(sum, weight: weight, eps: 1e-6)
                        #expect(Self.bytes(fused.sum) == Self.bytes(sum),
                            "width \(width) rows \(rows) \(dtype)+\(residualType) residual sum differs")
                        #expect(Self.bytes(fused.norm) == Self.bytes(norm),
                            "width \(width) rows \(rows) \(dtype)+\(residualType) norm differs")
                    }
                }
            }
        }
    }

    /// A residual stream narrower than its norm (Bonsai: the packed
    /// embedding's FP16 rows, FP32 norms and projections) takes the unfused
    /// sum, which promotes it to FP32, and the norm of that sum; a wider
    /// (tensor-parallel FP32) sum under a norm of the stream's own dtype is
    /// still rounded to the stream's dtype first. CPU, so no fused kernel.
    @Test func residualStepKeepsTheUnfusedPromotion() throws {
        try Device.withDefaultDevice(.cpu) {
            let (x, wide) = withRandomState(MLXRandom.RandomState(seed: 7)) {
                ((MLXRandom.normal([2, 3, 64]) * 3).asType(.float16), MLXRandom.normal([2, 3, 64]) * 2)
            }
            let promoting = RMSNorm(dimensions: 64)
            #expect(promoting.weight.dtype == .float32)
            let (sum, normalized) = Qwen35DecoderLayer.residualNorm(x, wide, promoting)
            let unfused = x + wide
            #expect(sum.dtype == .float32 && Self.bytes(sum) == Self.bytes(unfused))
            #expect(Self.bytes(normalized) == Self.bytes(promoting(unfused)))
            let stream = x.asType(.bfloat16), own = RMSNorm(dimensions: 64)
            try own.update(parameters: ModuleParameters.unflattened(["weight": MLXArray.ones([64], dtype: .bfloat16)]),
                           verify: .noUnusedKeys)
            let (rounded, roundedNorm) = Qwen35DecoderLayer.residualNorm(stream, wide, own)
            let expected = stream + wide.asType(.bfloat16)
            #expect(rounded.dtype == .bfloat16 && Self.bytes(rounded) == Self.bytes(expected))
            #expect(Self.bytes(roundedNorm) == Self.bytes(own(expected)))
        }
    }

    /// The Gated DeltaNet convolution step as one kernel equals MLX's
    /// concatenate, depthwise conv1d and compiled silu byte for byte, with the
    /// state and the inputs as strided slices (as the forward passes them).
    @Test(.enabled(if: Self.gpu)) func gatedDeltaConvolutionEqualsTheUnfusedOps() throws {
        try Device.withDefaultDevice(.gpu) {
            for (index, (batch, steps, channels)) in [(1, 1, 5120), (1, 4, 5120), (1, 5, 10240), (3, 1, 2048),
                                                     (2, 6, 1536), (8, 4, 256)].enumerated() {
                for dtype in [DType.bfloat16, .float16, .float32] {
                    let (wide, stateSource, weight) = withRandomState(MLXRandom.RandomState(seed: UInt64(300 + index))) {
                        ((MLXRandom.normal([batch, steps, channels + 64]) * 2).asType(dtype),
                         (MLXRandom.normal([batch, 3 + steps, channels]) * 2).asType(dtype),
                         (MLXRandom.normal([channels, 4, 1]) * 0.3).asType(dtype))
                    }
                    // A column slice of a wider projection and the tail rows of a previous concatenation.
                    let inputs = wide[0..., 0..., 0 ..< channels]
                    let state = stateSource[0..., steps ..< (steps + 3), 0...]
                    guard let fused = GatedDeltaConvolution.apply(state: state, inputs: inputs, weight: weight) else {
                        Issue.record("[\(batch), \(steps), \(channels)] \(dtype) not covered on \(AffineQuantizedVectors.architecture)")
                        continue
                    }
                    let convInput = concatenated([state, inputs], axis: 1)
                    let output = silu(conv1d(convInput, weight, stride: 1, padding: 0, dilation: 1, groups: channels))
                    #expect(Self.bytes(fused.convInput) == Self.bytes(convInput),
                        "[\(batch), \(steps), \(channels)] \(dtype) concatenation differs")
                    #expect(Self.bytes(fused.output) == Self.bytes(output),
                        "[\(batch), \(steps), \(channels)] \(dtype) convolution differs")
                }
            }
        }
    }

    /// The Gated DeltaNet q/k normalization as one kernel equals MLX's
    /// rmsNorm (no weight) and scale multiply per head, byte for byte.
    @Test(.enabled(if: Self.gpu)) func gatedDeltaQKNormEqualsTheUnfusedOps() throws {
        try Device.withDefaultDevice(.gpu) {
            for (index, (batch, steps, heads, dim)) in [(1, 1, 8, 128), (1, 4, 8, 128), (1, 5, 16, 128), (3, 2, 4, 64),
                                                       (8, 1, 2, 128), (2, 6, 4, 32)].enumerated() {
                for dtype in [DType.bfloat16, .float16, .float32] {
                    let channels = 2 * heads * dim + heads * dim * 3
                    let convOut = withRandomState(MLXRandom.RandomState(seed: UInt64(400 + index))) {
                        (MLXRandom.normal([batch, steps, channels]) * 1.5).asType(dtype)
                    }
                    let scales = Qwen35DecodeFusions.qkScales(headDim: dim, dtype: dtype)
                    guard let fused = GatedDeltaQKNorm.apply(convOut: convOut, heads: heads, dim: dim,
                        qScale: scales.q, kScale: scales.k, eps: 1e-6) else {
                        Issue.record("[\(batch), \(steps), \(heads)x\(dim)] \(dtype) not covered")
                        continue
                    }
                    let split = MLX.split(convOut, indices: [heads * dim, 2 * heads * dim], axis: -1)
                    let q = scales.q * MLXFast.rmsNorm(split[0].reshaped(batch, steps, heads, dim),
                        weight: MLXArray.mlxNone, eps: 1e-6)
                    let k = scales.k * MLXFast.rmsNorm(split[1].reshaped(batch, steps, heads, dim),
                        weight: MLXArray.mlxNone, eps: 1e-6)
                    #expect(Self.bytes(fused.q) == Self.bytes(q), "[\(batch), \(steps), \(heads)x\(dim)] \(dtype) q differs")
                    #expect(Self.bytes(fused.k) == Self.bytes(k), "[\(batch), \(steps), \(heads)x\(dim)] \(dtype) k differs")
                }
            }
        }
    }

    @Test(.enabled(if: Self.gpu)) func sigmoidGateEqualsTheUnfusedChain() throws {
        try Device.withDefaultDevice(.gpu) {
            for (index, shape) in [[1, 1, 3072], [1, 4, 6144], [8, 1, 1024], [2, 5, 96]].enumerated() {
                for dtype in [DType.bfloat16, .float16, .float32] {
                    let (x, gate) = withRandomState(MLXRandom.RandomState(seed: UInt64(500 + index))) {
                        ((MLXRandom.normal(shape) * 2).asType(dtype), (MLXRandom.normal(shape) * 3).asType(dtype))
                    }
                    #expect(Self.bytes(Qwen35DecodeFusions.sigmoidGate(x, gate)) == Self.bytes(sigmoidMultiply(x, gate)),
                        "\(shape) \(dtype) sigmoid gate differs")
                }
            }
        }
    }

    @Test(.enabled(if: Self.gpu)) func cachedGatedDeltaScalesEqualFreshOnes() throws {
        try Device.withDefaultDevice(.gpu) {
            for headDim in [64, 128, 192, 256] {
                for dtype in [DType.bfloat16, .float16, .float32] {
                    let invScale = pow(Float(headDim), -0.5)
                    let cached = Qwen35DecodeFusions.qkScales(headDim: headDim, dtype: dtype)
                    let again = Qwen35DecodeFusions.qkScales(headDim: headDim, dtype: dtype)
                    #expect(cached.q === again.q && cached.k === again.k)
                    #expect(Self.bytes(cached.q) == Self.bytes(MLXArray(pow(invScale, 2)).asType(dtype)))
                    #expect(Self.bytes(cached.k) == Self.bytes(MLXArray(invScale).asType(dtype)))
                }
            }
        }
    }
}
