import Foundation
import Testing
@testable import ProviderBenchmark
@_spi(Benchmarking) import ProviderCore

@Suite("Quality observations use production serving content")
struct KVQualityServingContentTests {
    @Test func verifiedDeclarationSelectsTheProductionParser() throws {
        let declaration = try JSONDecoder().decode(TeacherForcedBenchmarkInput.Declaration.self,
            from: Data(#"{"model_type":"gpt_oss","vocab_size":200000}"#.utf8))
        #expect(declaration.modelType == "gpt_oss")
        #expect(BenchmarkServingContent.parserFormat(modelType: declaration.modelType) == "harmony")
        let raw = "<|channel|>analysis<|message|>work<|end|><|channel|>final<|message|>2"
        #expect(BenchmarkServingContent.parse(chunks: [raw], modelType: declaration.modelType) == "2")
        // A different declared architecture must not be forced through a
        // Harmony-specific cleanup simply because its text contains tags.
        #expect(BenchmarkServingContent.parse(chunks: [raw], modelType: "qwen3") == raw)
    }

    @Test func harmonySplitBoundariesPreserveFinalWhitespaceAndRawGrades() {
        let raw = "<|channel|>analysis<|message|>work<|end|><|start|>assistant<|channel|>final<|message|> 2\n<|return|>"
        let whole = BenchmarkServingContent.parse(chunks: [raw], modelType: "gpt_oss")
        let split = BenchmarkServingContent.parse(chunks: raw.map { String($0) }, modelType: "gpt_oss")
        #expect(whole == " 2\n" && split == whole)
        let rawMatches = KVQualityEventCollector.matches(raw, expected: "2")
        let servingMatches = KVQualityEventCollector.matches(split, expected: "2")
        #expect(rawMatches.exact == false && rawMatches.outerWhitespace == false)
        #expect(servingMatches.exact == false && servingMatches.outerWhitespace == true)
    }

    @Test func truncatedAnalysisIsUnansweredAndMissingExpectationRemainsUngraded() {
        let raw = "<|channel|>analysis<|message|>Need to compute"
        let content = BenchmarkServingContent.parse(chunks: [raw], modelType: "gpt_oss")
        #expect(content.isEmpty)
        let expected = KVQualityEventCollector.matches(content, expected: "2")
        #expect(expected.exact == false && expected.outerWhitespace == false)
        let ungraded = KVQualityEventCollector.matches(content, expected: nil)
        #expect(ungraded.exact == nil && ungraded.outerWhitespace == nil)
    }

    @Test func ordinaryContentPassesThroughWithoutTrimming() {
        let raw = "  ordinary answer\n"
        #expect(BenchmarkServingContent.parse(chunks: [raw], modelType: "gpt_oss") == raw)
    }
}
