import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Native Qwen4 execution policy")
struct Qwen4ExecutionPolicyTests {
    @Test func singleRowDefaultCannotBeRaisedByGlobalConcurrency() {
        for requested in [-1, 0, 1, 2, 8, 64, Int.max] {
            #expect(EngineV2Factory.nativeConcurrentRequestLimit(
                requested: requested, qwen4: true, environment: [:]) == 1)
            #expect(EngineV2Factory.nativeConcurrentRequestLimit(
                requested: requested, qwen4: false, environment: [:]) == max(1, requested))
        }
    }

    @Test func experimentalBatchingRequiresExactExplicitOptIn() {
        for value in ["", "0", "true", "yes", "on", "01", " 1", "1 ", "1\n"] {
            let environment = [EngineV2Factory.qwen4BatchedQSAEnvKey: value]
            #expect(EngineV2Factory.nativeConcurrentRequestLimit(
                requested: 4, qwen4: true, environment: environment) == 1)
        }
        let environment = [EngineV2Factory.qwen4BatchedQSAEnvKey: "1"]
        #expect(EngineV2Factory.nativeConcurrentRequestLimit(
            requested: Int.max, qwen4: true, environment: environment)
            == CBv2Qwen4BatchPolicy.maximumCandidateRows)
        // Explicit candidate selection is not a concurrent-serving qualification.
    }
}
