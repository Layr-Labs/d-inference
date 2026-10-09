import Foundation
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("Model prefix benchmark diagnostics")
struct ModelPrefixBenchmarkDiagnosticsTests {
    @Test("explicit stripe reaches the actual fixture factory environment; nil preserves defaults")
    func stripeEnvironment() {
        let root = URL(fileURLWithPath: "/tmp/synthetic-prefix-diagnostic")
        let ordinary = ModelPrefixBenchmarkFixture.checkpointEnvironment(
            root: root, soloPrefillStripeTokens: nil)
        #expect(ordinary[EngineV2Factory.soloPrefillStripeKey] == nil)
        let diagnostic = ModelPrefixBenchmarkFixture.checkpointEnvironment(
            root: root, soloPrefillStripeTokens: 1_024)
        #expect(diagnostic[EngineV2Factory.soloPrefillStripeKey] == "1024")
        #expect(diagnostic["DARKBLOOM_PREFIX_CACHE_MEMORY"] == "0")
        #expect(diagnostic["DARKBLOOM_PREFIX_CACHE_TEST_ROOT"] == root.path)
    }

    @Test("reported policy geometry comes from the actual scheduler configuration")
    func resolvedPolicyGeometry() throws {
        var config = CBv2SchedulerConfig()
        config.demandedShortCheckpointMinimumTokens = 1_024
        config.demandedCheckpointPartitionIncludesLongPrompts = true
        let observation = ModelPrefixBenchmarkSchedulerConfiguration(config)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(observation))
            as? [String: Any])
        #expect(object["demandedShortCheckpointMinimumTokens"] as? Int == 1_024)
        #expect(object["demandedCheckpointPartitionIncludesLongPrompts"] as? Bool == true)
        #expect(ModelPrefixBenchmarkSchedulerConfiguration(CBv2SchedulerConfig())
            .demandedShortCheckpointMinimumTokens == nil)
        #expect(!ModelPrefixBenchmarkSchedulerConfiguration(CBv2SchedulerConfig())
            .demandedCheckpointPartitionIncludesLongPrompts)
    }

    @Test("diagnostic positions preserve actual IDs and sorted top-two margins")
    func observedTokenMargins() throws {
        let result = try ModelPrefixBenchmarkTokenDiagnostics(tokens: [9, 8], logprobs: [
            .init(token: 9, logprob: -1, topLogprobs: [(8, -1.01), (9, -1)]),
            .init(token: 8, logprob: -0.5, topLogprobs: [(8, -0.5), (7, -.infinity)]),
        ])
        #expect(result.generatedTokenIDs == [9, 8])
        #expect(result.positions.map(\.index) == [0, 1])
        #expect(result.positions[0].topTokens.map(\.token) == [9, 8])
        #expect(abs((result.positions[0].topTwoLogprobGap ?? 0) - 0.01) < 1e-6)
        #expect(result.positions[1].hasNonFiniteLogprob)
        #expect(result.positions[1].topTokens[1].logprob == nil)
        #expect(result.positions[1].topTwoLogprobGap == nil)
        // Invalid model numerics stay explicit and remain JSON-encodable.
        _ = try JSONEncoder().encode(result)
    }

    @Test("missing or misaligned logprob observations cannot manufacture a margin")
    func invalidObservation() {
        #expect(throws: ModelPrefixBenchmarkTokenDiagnostics.Failure.incompleteLogprobs) {
            try ModelPrefixBenchmarkTokenDiagnostics(tokens: [9], logprobs: [])
        }
        #expect(throws: ModelPrefixBenchmarkTokenDiagnostics.Failure.tokenMismatch) {
            try ModelPrefixBenchmarkTokenDiagnostics(tokens: [9], logprobs: [.init(token: 8, logprob: -1)])
        }
    }
}
