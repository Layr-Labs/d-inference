import Foundation
import MLX
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

@Suite("Bonsai registered FP32 row arithmetic receipt")
struct BonsaiRowArithmeticTests {
    /// A single Mac's loader (the SDK's `PrismHadamardCheckpoint.install`)
    /// builds the 27B's packed projections with exactly this call, without
    /// `independentRows`, so their calls of three or more rows batch. Only the pair's
    /// stage builder asks for the per-row arithmetic the receipt below names
    /// (`BonsaiStagePreparationTests`). Fails if the default ever flips.
    @Test func aSingleMacLoaderBuildsBatchedProjections() throws {
        let width = 1024, rows = 32
        let scales = MLXArray.zeros([rows, width / 128], dtype: .float16)
        let transform = try SignedBlockHadamard(blockSize: 1024, signs: [Float](repeating: 1, count: width))
        let layer = try HadamardQuantizedLinear(weight: MLXArray.zeros([rows, width / 16], dtype: .uint32),
            scales: scales, biases: scales, groupSize: 128, bits: 2, transform: transform)
        #expect(!layer.independentRows)
    }

    @Test func rowExactBonsai27ReceiptDiffersWhileNineBRetainsItsOriginalReceipt() throws {
        let environment = QwenResidentArithmeticPolicy.prismHadamard.requiredValues
        let prior = try QwenResidentArithmeticPolicy.prismHadamard.admit(environment)
        let candidate = try QwenResidentModelDefinition(model: .ternaryBonsai2TwentySevenB).arithmetic.admit(environment)
        let nine = try QwenResidentModelDefinition(model: .ternaryBonsai2NineB).arithmetic.admit(environment)
        #expect(nine == prior)
        #expect(candidate.contract == prior.contract) // Stable family name, exact receipt changes.
        #expect(candidate.requiredValues == prior.requiredValues)
        #expect(candidate.requiredAbsentNames == prior.requiredAbsentNames)
        #expect(candidate.defaultBindings["bonsai-fp32-row-arithmetic-v2"] != nil)
        #expect(sha256(try canonicalJSONData(candidate)) != sha256(try canonicalJSONData(prior)))
        #expect(sha256(try canonicalJSONData(nine)) == sha256(try canonicalJSONData(prior)))
    }

}
