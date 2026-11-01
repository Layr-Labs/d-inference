import Foundation
import Testing
@testable import DarkbloomClusterRuntime

@Suite("Bonsai registered FP32 row arithmetic receipt")
struct BonsaiRowArithmeticTests {
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
