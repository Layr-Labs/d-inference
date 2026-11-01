import Foundation
import MLX
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

@Suite("Qwen3.5 MoE tensor-parallel loading (CPU)")
struct QwenMoETensorParallelTests {
    @Test func onlyRegisteredRoutedArtifactsAndEqualSharesAreAdmitted() throws {
        for model in [QwenRegisteredDenseModel.qwen35ThirtyFiveBA3B, .qwen36ThirtyFiveBA3B] {
            let supported = try QwenResidentModelDefinition(model: model)
            for shares in [[1, 1], [2, 2], [64, 64]] {
                try QwenTensorParallelVerifiedLoad.requireSupportedProduct(supported, shares: shares)
            }
            for shares in [[], [1], [1, 2], [0, 0], [65, 65], [1, 1, 1]] {
                #expect(throws: ProbeError.self) {
                    try QwenTensorParallelVerifiedLoad.requireSupportedProduct(supported, shares: shares)
                }
            }
        }
        for model in [QwenRegisteredDenseModel.ternaryBonsai2TwentySevenB, .nemotron35Lightning] {
            #expect(throws: ProbeError.self) {
                try QwenTensorParallelVerifiedLoad.requireSupportedProduct(QwenResidentModelDefinition(model: model), shares: [1, 1])
            }
        }
        for model in [QwenRegisteredDenseModel.qwen35NineB, .qwen38TwentySevenB] {
            for shares in [[1, 1], [1, 3]] {
                try QwenTensorParallelVerifiedLoad.requireSupportedProduct(QwenResidentModelDefinition(model: model), shares: shares)
            }
        }
    }

    @Test func canonicalBanksMatchCuttingTheStoredHalvesBeforeFusion() throws {
        try Device.withDefaultDevice(.cpu) {
            for (leaf, dtype) in [("weight", DType.uint32), ("scales", .bfloat16), ("biases", .float32)] {
                let source = MLXArray((0..<(3 * 1024 * 4)).map { UInt32($0 % 127) }).reshaped([3, 1024, 4]).asType(dtype)
                for rank in 0..<2 {
                    let range = (rank * 256)..<((rank + 1) * 256)
                    let fused = try QwenTensorParallelSlicer.cut(source,
                        .expertRowRanges([range, (512 + range.lowerBound)..<(512 + range.upperBound)]),
                        leaf: leaf, groupSize: 64, bits: 4)
                    let gate = try QwenTensorParallelSlicer.cut(source[0..., 0..<512, 0...], .expertRows(range),
                        leaf: leaf, groupSize: 64, bits: 4)
                    let up = try QwenTensorParallelSlicer.cut(source[0..., 512..<1024, 0...], .expertRows(range),
                        leaf: leaf, groupSize: 64, bits: 4)
                    let prefix = "language_model.model.layers.0.mlp.switch_mlp."
                    let fusedName = prefix + "gate_up_proj." + leaf
                    let expected = try #require(qwen35FuseSwitchMLPGateUp(weights: [
                        prefix + "gate_proj." + leaf: gate, prefix + "up_proj." + leaf: up
                    ])[fusedName])
                    let canonical = try #require(qwen35FuseSwitchMLPGateUp(weights: [fusedName: fused])[fusedName])
                    eval(fused, expected, canonical)
                    #expect(arrayEqual(fused, canonical).item(Bool.self))
                    #expect(fused.shape == [3, 512, 4] && fused.dtype == dtype)
                    #expect(arrayEqual(fused, expected).item(Bool.self))
                }
            }
        }
    }

    @Test func malformedFusedRangesAreRefused() throws {
        try Device.withDefaultDevice(.cpu) {
            let source = MLXArray.zeros([2, 16, 4])
            for ranges: [Range<Int>] in [[], [0..<4], [0..<4, 8..<12, 12..<16],
                [-1..<3, 8..<12], [0..<4, 14..<18], [0..<4, 2..<6], [0..<4, 8..<10], [0..<0, 8..<8]] {
                #expect(throws: ProbeError.self) {
                    try QwenTensorParallelSlicer.cut(source, .expertRowRanges(ranges), leaf: "weight", groupSize: 64, bits: 4)
                }
            }
            #expect(throws: ProbeError.self) {
                try QwenTensorParallelSlicer.cut(MLXArray.zeros([16, 4]), .expertRowRanges([0..<4, 8..<12]),
                    leaf: "weight", groupSize: 64, bits: 4)
            }
        }
    }
}
