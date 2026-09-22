import Foundation
import Testing

@testable import ProviderBenchmark

struct ModelBenchmarkDispatchTests {
    @Test func diffusionHasItsOwnNativeBlockDispatch() {
        #expect(ModelBenchmark.usesNativeBlockGeneration(modelType: "diffusion_gemma"))
        for modelType in [nil, "qwen4_exp", "gemma4", "diffusion_gemma_text", "prism_hadamard_qwen35"] {
            #expect(!ModelBenchmark.usesNativeBlockGeneration(modelType: modelType))
        }
    }
    @Test func nativePackedFamiliesUseTheNativeBenchmark() {
        #expect(ModelBenchmark.usesNativeGeneration(modelType: "qwen4_exp"))
        #expect(ModelBenchmark.usesNativeGeneration(modelType: "qwen4_exp_text"))
        #expect(ModelBenchmark.usesNativeGeneration(modelType: "prism_hadamard_qwen35"))
        for modelType in [nil, "qwen3_5", "qwen3_5_text", "gemma4", "nemotron_h"] {
            #expect(!ModelBenchmark.usesNativeGeneration(modelType: modelType))
        }
    }

    @Test func durationIncludesWholeSeconds() {
        #expect(ModelBenchmark.milliseconds(.seconds(7) + .milliseconds(250)) == 7250)
        #expect(ModelBenchmark.milliseconds(.milliseconds(250)) == 250)
        #expect(ModelBenchmark.milliseconds(.zero) == 0)
    }

    @Test func dispatchPreservesFactoryJSON5Support() throws {
        let json5 = Data("{\"model_type\":\"gemma4\", // checkpoint comment\n}".utf8)
        #expect(try ModelBenchmark.decodedModelType(from: json5) == "gemma4")
        let standard = Data(#"{"model_type":"qwen4_exp"}"#.utf8)
        #expect(try ModelBenchmark.decodedModelType(from: standard) == "qwen4_exp")
    }

    @Test func nativeBaselineUsesExplicitOrdinarySampling() throws {
        let data = try ModelBenchmark.nativeRequestBody(modelID: "fixture", prompt: "hello", maxTokens: 8)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["temperature"] as? Double == 0.6)
        #expect(body["top_p"] as? Double == 1)
        #expect(body["top_k"] as? Int == 0)
        #expect(body["min_p"] as? Double == 0)
        #expect(body["max_tokens"] as? Int == 8)
    }

    @Test func invalidIterationAndOutputBudgetsFailBeforeLoad() throws {
        try ModelBenchmark.validateArguments(iterations: 1, maxTokens: 1)
        for (iterations, tokens) in [(0, 1), (-1, 1), (1, 0), (1, -1)] {
            #expect(throws: ModelBenchmark.Failure.invalidArguments) {
                try ModelBenchmark.validateArguments(iterations: iterations, maxTokens: tokens)
            }
        }
    }
}
