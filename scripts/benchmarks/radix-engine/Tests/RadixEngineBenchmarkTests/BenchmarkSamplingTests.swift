import Foundation
import MLXLMCommon
import Testing
@testable import radix_engine

struct BenchmarkSamplingTests {
    @Test func defaultsRemainGreedy() {
        let input = Input(name: "default", kind: "test", tokens: [1], maxTokens: 8)
        #expect(input.sampling.temperature == 0)
        #expect(input.sampling.seed == nil)
        #expect(BenchmarkSampling.record(input.sampling)["seed"] is NSNull)
    }

    @Test func concurrentCopyAndEvidencePreserveEverySamplingKnob() throws {
        let sampling = CBv2SamplingParams(
            temperature: 0.7, topP: 0.9, topK: 32, minP: 0.1,
            repetitionPenalty: 1.1, repetitionContextSize: 27,
            frequencyPenalty: 0.2, presencePenalty: 0.3,
            seed: 42, logitBias: [11: 0.5], topLogprobs: 3)
        let original = Input(name: "original", kind: "test", tokens: [1, 2], maxTokens: 8,
                             promptRenderDate: "2026-09-08", sampling: sampling)
        let copy = original.renamed("batch-0")
        #expect(copy.name == "batch-0")
        #expect(copy.tokens == original.tokens)
        #expect(copy.promptRenderDate == original.promptRenderDate)
        let encoded = try JSONSerialization.data(withJSONObject: BenchmarkSampling.record(copy.sampling), options: .sortedKeys)
        let expected = try JSONSerialization.data(withJSONObject: BenchmarkSampling.record(original.sampling), options: .sortedKeys)
        #expect(encoded == expected)
        let evidence = BenchmarkSampling.record(copy.sampling)
        #expect(evidence["temperature"] as? Float == 0.7)
        #expect(evidence["top_p"] as? Float == 0.9)
        #expect(evidence["top_k"] as? Int == 32)
        #expect(evidence["min_p"] as? Float == 0.1)
        #expect(evidence["seed"] as? UInt64 == 42)
        #expect(evidence["logit_bias"] as? [String: Float] == ["11": 0.5])
    }

    @Test func diagnosticsRejectSampledAndTransformedInputsButThroughputAllowsThem() throws {
        let greedy = Input(name: "greedy", kind: "test", tokens: [1], maxTokens: 8)
        try BenchmarkSampling.requireGreedyDiagnostics([greedy], enabled: true)
        for sampling in [CBv2SamplingParams(temperature: 0.7),
            CBv2SamplingParams(temperature: 0, repetitionPenalty: 1.1),
            CBv2SamplingParams(temperature: 0, logitBias: [1: 2]),
            CBv2SamplingParams(temperature: 0, topLogprobs: 1)] {
            let input = Input(name: "sampled", kind: "test", tokens: [1], maxTokens: 8, sampling: sampling)
            #expect(throws: (any Error).self) {
                try BenchmarkSampling.requireGreedyDiagnostics([input], enabled: true)
            }
            try BenchmarkSampling.requireGreedyDiagnostics([input], enabled: false)
        }
    }
}
