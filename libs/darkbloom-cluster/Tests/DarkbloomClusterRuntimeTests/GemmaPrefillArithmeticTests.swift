import Foundation
import DarkbloomClusterProtocol
import Testing
@testable import DarkbloomClusterRuntime

@Suite("Registered Gemma prefill projection identity")
struct GemmaPrefillArithmeticTests {
    @Test func projectionPolicyChangesExactReceiptAndKeepsEnvironmentContract() throws {
        let receipt = try Gemma4ArithmeticEnvironment.admit(Gemma4ArithmeticEnvironment.requiredValues)
        let data = try canonicalJSONData(receipt)
        var denseOnly = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(denseOnly.removeValue(forKey: "prefillExpertPolicy") as? String
            == "gemma4-bf16-token-expert-reduction-v1")
        #expect(sha256(data) != sha256(try JSONSerialization.data(withJSONObject: denseOnly,
            options: [.sortedKeys, .withoutEscapingSlashes])))
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(old.removeValue(forKey: "prefillProjectionPolicy") as? String
            == "gemma4-bf16-affine4-8-group64-token-m1-v1")
        #expect(old.removeValue(forKey: "prefillExpertPolicy") as? String
            == "gemma4-bf16-token-expert-reduction-v1")
        #expect(receipt.contract == ClusterRuntimeAdapter.gemma4LayerStage.arithmeticPolicyID)
        #expect(receipt.requiredValues == Gemma4ArithmeticEnvironment.requiredValues)
        #expect(receipt.requiredAbsentNames == Gemma4ArithmeticEnvironment.requiredAbsentNames)
        #expect(receipt.prefixFramePolicy == "gemma4-original-chunk-grid-v1")
        #expect(receipt.finalLayerTailRows == 1 && receipt.finalLayerTailMinimumChunk == 128 && receipt.finalLayerLastQuery)
        #expect(sha256(data) != sha256(try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys, .withoutEscapingSlashes])))
        #expect(!receipt.numericalOrPerformanceQualificationEstablished)
    }
}
