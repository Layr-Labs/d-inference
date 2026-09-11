import CryptoKit
import Foundation
import MLXLMCommon
import ProviderCoreFoundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("Benchmark production input contract")
struct BenchmarkProductionInputTests {
    @Test("request-owned date and late GPT instructions use the HTTP normalization pipeline")
    func normalizedPrompt() throws {
        let body = Data(#"""
        {"model":"opaque-gpt","max_tokens":8,"reasoning_effort":"high",
         "_darkbloom_prompt_date":"2024-02-29","chat_template_kwargs":{"enable_thinking":false},
         "messages":[{"role":"system","content":"first policy"},{"role":"user","content":"question"},
                     {"role":"system","content":"late policy"}]}
        """#.utf8)
        let tokenizer = BenchmarkInputTokenizer()
        let prompt = try EngineV2Factory.benchmarkPrompt(body: body, tokenizer: tokenizer,
            modelType: "gpt_oss", defaultDate: PromptRenderDate("2026-09-05")!)
        let production = try ProviderPromptContractPipeline.tokenizeProviderBody(
            body, tokenizer: tokenizer, modelType: "gpt_oss")
        #expect(prompt.tokens == production)
        #expect(prompt.renderDate == "2024-02-29")
        let rendered = tokenizer.decode(tokenIds: prompt.tokens, skipSpecialTokens: false)
        #expect(rendered.contains("first policy\\n\\nlate policy"))
        #expect(rendered.contains("\"reasoning_effort\":\"medium\""))
        #expect(rendered.contains("\"request_clock_present\":true"))
    }

    @Test("tool-history objects survive the benchmark input path")
    func toolHistory() throws {
        let body = Data(#"""
        {"model":"opaque-qwen","max_tokens":8,"_darkbloom_prompt_date":"2026-09-05",
         "messages":[{"role":"user","content":"look up"},
          {"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function",
           "function":{"name":"lookup","arguments":"{\"q\":\"test\"}"}}]},
          {"role":"tool","tool_call_id":"c1","content":"result"}],
         "tools":[{"type":"function","function":{"name":"lookup","description":"lookup",
          "parameters":{"type":"object","properties":{"q":{"type":"string"}}}}}]}
        """#.utf8)
        let tokenizer = BenchmarkInputTokenizer()
        let prompt = try EngineV2Factory.benchmarkPrompt(body: body, tokenizer: tokenizer,
            modelType: "qwen3_5", defaultDate: PromptRenderDate("2026-09-06")!)
        let production = try ProviderPromptContractPipeline.tokenizeProviderBody(
            body, tokenizer: tokenizer, modelType: "qwen3_5")
        #expect(prompt.tokens == production)
        let rendered = tokenizer.decode(tokenIds: prompt.tokens, skipSpecialTokens: false)
        #expect(rendered.contains("tool_call_id"))
        #expect(rendered.contains("lookup"))
        #expect(rendered.contains("\"tools\":[{"))
    }

    @Test("fallback date is captured once and media requires the HTTP gate")
    func dateAndMedia() throws {
        let tokenizer = BenchmarkInputTokenizer()
        let day = PromptRenderDate("2026-09-05")!
        let body = Data(#"{"model":"qwen","max_tokens":8,"messages":[{"role":"user","content":"hello"}]}"#.utf8)
        let prompt = try EngineV2Factory.benchmarkPrompt(body: body, tokenizer: tokenizer,
                                                        modelType: "qwen3_5", defaultDate: day)
        #expect(prompt.renderDate == day.value)
        let media = Data(#"""
        {"model":"qwen","messages":[{"role":"user","content":[{"type":"image_url",
         "image_url":{"url":"https://example.invalid/image.png"}}]}]}
        """#.utf8)
        #expect(throws: EngineV2Factory.BenchmarkPromptError.self) {
            try EngineV2Factory.benchmarkPrompt(body: media, tokenizer: tokenizer,
                                              modelType: "qwen3_5", defaultDate: day)
        }
    }

    @Test("benchmark preserves production sampling and raw-body seed and bias overlays")
    func productionSampling() throws {
        let body = Data(#"""
        {"model":"gemma-4-26b-qat-4bit","messages":[{"role":"user","content":"hello"}],
         "temperature":0.7,"top_p":0.9,"top_k":32,"min_p":0.15,"seed":12345,
         "repetition_penalty":1.1,"frequency_penalty":0.2,"presence_penalty":0.3,
         "logit_bias":{"42":2.5},"logprobs":true,"top_logprobs":4}
        """#.utf8)
        let prompt = try EngineV2Factory.benchmarkPrompt(
            body: body, tokenizer: BenchmarkInputTokenizer(), modelType: "gemma4",
            defaultDate: PromptRenderDate("2026-09-08")!)
        #expect(prompt.sampling.temperature == 0.7)
        #expect(prompt.sampling.topP == 0.9)
        #expect(prompt.sampling.topK == 32)
        // The serving translator does not expose min_p; do not invent a
        // benchmark-only API behavior for that unknown request field.
        #expect(prompt.sampling.minP == 0)
        #expect(prompt.sampling.seed == 12345)
        #expect(prompt.sampling.repetitionPenalty == 1.1)
        #expect(prompt.sampling.frequencyPenalty == 0.2)
        #expect(prompt.sampling.presencePenalty == 0.3)
        #expect(prompt.sampling.logitBias == [42: 2.5])
        #expect(prompt.sampling.topLogprobs == 4)
    }

    @Test("omitted sampling remains greedy with no transforms or seed")
    func defaultSampling() throws {
        let prompt = try EngineV2Factory.benchmarkPrompt(
            body: Data(#"{"model":"gemma","messages":[{"role":"user","content":"hello"}]}"#.utf8),
            tokenizer: BenchmarkInputTokenizer(), modelType: "gemma4",
            defaultDate: PromptRenderDate("2026-09-08")!)
        #expect(prompt.sampling.temperature == 0)
        #expect(prompt.sampling.topP == 1)
        #expect(prompt.sampling.topK == 0)
        #expect(prompt.sampling.minP == 0)
        #expect(prompt.sampling.seed == nil)
        #expect(prompt.sampling.repetitionPenalty == 1)
        #expect(prompt.sampling.frequencyPenalty == 0)
        #expect(prompt.sampling.presencePenalty == 0)
        #expect(prompt.sampling.logitBias.isEmpty)
        #expect(prompt.sampling.topLogprobs == 0)
    }

    @Test("native throughput inputs reject omitted HTTP output controls")
    func rejectsOutputControls() throws {
        for extra in [#""stop":"END""#, #""stop":["END"]"#,
                      #""response_format":{"type":"json_object"}"#] {
            let body = Data((#"{"model":"gemma","messages":[{"role":"user","content":"hello"}],"#
                + extra + "}").utf8)
            #expect(throws: EngineV2Factory.BenchmarkPromptError.self) {
                try EngineV2Factory.benchmarkPrompt(body: body, tokenizer: BenchmarkInputTokenizer(),
                    modelType: "gemma4", defaultDate: PromptRenderDate("2026-09-08")!)
            }
        }
        let forced = #"{"model":"gemma","messages":[{"role":"user","content":"call"}],"tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object","properties":{},"required":[],"additionalProperties":false}}}],"tool_choice":"required","temperature":TEMP}"#
        #expect(throws: EngineV2Factory.BenchmarkPromptError.self) {
            try EngineV2Factory.benchmarkPrompt(
                body: Data(forced.replacingOccurrences(of: "TEMP", with: "0.7").utf8),
                tokenizer: BenchmarkInputTokenizer(), modelType: "gemma4",
                defaultDate: PromptRenderDate("2026-09-08")!)
        }
        // Historical greedy tool-template probes remain available and do
        // not claim HTTP token-constraint enforcement.
        _ = try EngineV2Factory.benchmarkPrompt(
            body: Data(forced.replacingOccurrences(of: "TEMP", with: "0").utf8),
            tokenizer: BenchmarkInputTokenizer(), modelType: "gemma4",
            defaultDate: PromptRenderDate("2026-09-08")!)
    }

    @Test("offline Gemma override keeps ordinary file verification and no silent MTP fallback")
    func assistantPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assistant = root.appendingPathComponent("assistant")
        try FileManager.default.createDirectory(at: assistant, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"model_type":"gemma4"}"#.utf8).write(to: root.appendingPathComponent("config.json"))
        let config = Data(#"{"model_type":"gemma4_assistant"}"#.utf8)
        let weights = Data(repeating: 0x5a, count: 128)
        try config.write(to: assistant.appendingPathComponent("config.json"))
        try weights.write(to: assistant.appendingPathComponent("model.safetensors"))
        // Metadata-only preparation deliberately does not load these fixture
        // bytes as a model. The existing production loader still owns target
        // compatibility and digest revalidation before/after real model load.
        let prepared = try await EngineV2Factory.benchmarkAssistantPreparation(
            modelId: "gemma-4-26b", modelType: "gemma4", modelDirectory: root,
            enabled: true, assistantDirectory: assistant, environment: [:])
        let artifact = try #require(prepared.artifact)
        #expect(artifact.source == .local)
        let expectedWeight = SHA256.hash(data: weights).map { String(format: "%02x", $0) }.joined()
        let identity = EngineV2Factory.benchmarkAssistantIdentity(artifact)
        #expect(identity["weight_sha256.model.safetensors"] == expectedWeight)
        let disabled = try await EngineV2Factory.benchmarkAssistantPreparation(
            modelId: "gemma-4-26b", modelType: "gemma4", modelDirectory: root,
            enabled: false, assistantDirectory: assistant, environment: [:])
        #expect(disabled.artifact == nil)
        try Data("unreviewed cached manifest".utf8).write(to: assistant.appendingPathComponent("manifest.json"))
        await #expect(throws: EngineV2BenchmarkSession.Failure.self) {
            try await EngineV2Factory.benchmarkAssistantPreparation(
                modelId: "gemma-4-26b", modelType: "gemma4", modelDirectory: root,
                enabled: true, assistantDirectory: assistant, environment: [:])
        }
    }
}

/// Inspect normalized message/tool/scalar inputs without loading MLX or
/// pretending this tiny fixture is a served model's tokenizer oracle.
private struct BenchmarkInputTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.utf8.map(Int.init) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(decoding: tokenIds.map(UInt8.init), as: UTF8.self)
    }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        var value: [String: Any] = ["messages": messages, "tools": tools as Any? ?? NSNull(),
            "request_clock_present": additionalContext?["_darkbloom_request_clock"] != nil]
        for key in ["enable_thinking", "reasoning_effort"] {
            value[key] = additionalContext?[key]
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).map(Int.init)
    }
}
