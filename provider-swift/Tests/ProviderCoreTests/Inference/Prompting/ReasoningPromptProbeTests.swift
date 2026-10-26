import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Reasoning prompt probe")
struct ReasoningPromptProbeTests {
    @Test("open prompt blocks initialize reasoning", arguments: [
        "<|im_start|>assistant\n<think>\n", "<think>", "<think> \t\n",
    ])
    func openBlock(tail: String) {
        #expect(ReasoningPromptProbe.streamingPrefix(forPromptTail: tail) == "<think>")
    }

    @Test("closed prompt blocks initialize content", arguments: [
        "<|im_start|>assistant\n<think>\n\n</think>\n\n",
        "</think>", "<think>prompt-side reasoning</think> \t\n",
    ])
    func closedBlock(tail: String) {
        #expect(ReasoningPromptProbe.streamingPrefix(forPromptTail: tail) == "<think></think>")
    }

    @Test("unknown or incomplete tails retain the parser's default state", arguments: [
        "", "<|im_start|>assistant\n", "<think>\nalready reasoning",
        "<think>\n</thi", "quoted </think> followed by text",
    ])
    func unknownTail(tail: String) {
        #expect(ReasoningPromptProbe.streamingPrefix(forPromptTail: tail) == nil)
    }

    private func prefix(
        parser: ReasoningParserFormat?, stream: Bool? = true,
        tokens: [Int] = [1, 2, 3], tail: String = "<think>\n"
    ) -> String? {
        ReasoningPromptProbe.streamingPrefix(
            reasoningParser: parser, stream: stream, promptTokens: tokens,
            decodeTail: { _ in tail })
    }

    @Test("collected and streaming think parsers receive a prefix", arguments: ["<think>\n", "</think>\n"])
    func gates(tail: String) {
        #expect(prefix(parser: .qwen3, tail: tail) != nil)
        #expect(prefix(parser: .deepseekR1, tail: tail) != nil)
        for parser: ReasoningParserFormat? in [nil, .some(.none), .harmony, .gemma4] {
            #expect(prefix(parser: parser, tail: tail) == nil)
        }
        #expect(prefix(parser: .qwen3, stream: false, tail: tail) != nil)
        #expect(prefix(parser: .qwen3, stream: nil, tail: tail) != nil)
        #expect(prefix(parser: .qwen3, tokens: [], tail: tail) == nil)
    }

    private func plainTailPrefix(
        _ tail: String = "<|im_start|>assistant\n", parser: ReasoningParserFormat = .qwen3,
        modelType: String?, seeds: Bool = true
    ) -> String? {
        ReasoningPromptProbe.streamingPrefix(
            reasoningParser: parser, stream: true, promptTokens: [1], modelType: modelType,
            seedsPlainTailContent: seeds, decodeTail: { _ in tail })
    }

    @Test("a plain Qwen3-VL tail starts in content; a Qwen3-VL think tail still opens reasoning")
    func plainQwen3VLTailSeedsContent() {
        #expect(plainTailPrefix(modelType: "qwen3_vl_moe") == "<think></think>")
        #expect(plainTailPrefix(modelType: " Qwen3_VL_MoE\n") == "<think></think>")
        #expect(plainTailPrefix("<|im_start|>assistant\n<think>\n", modelType: "qwen3_vl_moe") == "<think>")
    }

    @Test("close-only and other model types keep undecided parsing after a plain tail",
          arguments: ["qwen3_next", "qwen3_5", "qwen3_5_moe", "qwen4_exp", "qwen4_exp_text", "llama"])
    func plainTailWithoutSeed(modelType: String) {
        #expect(plainTailPrefix(modelType: modelType) == nil)
        // A close-only reasoner after a pre-opened tail is unchanged.
        #expect(plainTailPrefix("<|im_start|>assistant\n<think>\n", modelType: modelType) == "<think>")
    }

    @Test("the plain-tail seed needs the qwen3 parser, a model type and the switch")
    func plainTailSeedGates() {
        #expect(plainTailPrefix(parser: .deepseekR1, modelType: "qwen3_vl_moe") == nil)
        #expect(plainTailPrefix(modelType: nil) == nil)
        #expect(plainTailPrefix(modelType: "qwen3_vl_moe", seeds: false) == nil)
    }

    @Test("the probe decodes only a bounded prompt tail")
    func boundedTailDecode() {
        let tokens = Array(0..<4096)
        var seen: [Int]?
        let result = ReasoningPromptProbe.streamingPrefix(
            reasoningParser: .qwen3, stream: true, promptTokens: tokens,
            decodeTail: { ids in
                seen = ids
                return "</think>\n"
            })
        #expect(seen == Array(tokens.suffix(ReasoningPromptProbe.tailTokenCount)))
        #expect(result == "<think></think>")
    }
    @Test("prompt-open truncation preserves collected response and continuation channels",
          arguments: [ReasoningParserFormat.qwen3, .deepseekR1])
    func collectedTruncation(parser: ReasoningParserFormat) async throws {
        let prefix = try #require(ReasoningPromptProbe.streamingPrefix(
            reasoningParser: parser, stream: false, promptTokens: [1],
            decodeTail: { _ in "assistant\n<think>\n" }))
        let service = MLXOpenAIService(engine: PromptReasoningEngine(prefix: prefix))
        let response = try await service.createResponse(request: .init(
            model: "fixture", input: .text("hi"), reasoning: .init(parser: parser)))
        #expect(response.status == .incomplete)
        #expect(response.usage?.outputTokens == 8)
        #expect(response.output.allSatisfy { $0.type != "message" })
        #expect(response.output.first?.summary?.first?.text == "Still thinking")
        let history = LocalResponseConversationStore()
        history.record(responseID: response.id, output: response.output,
                       inputItems: Data(#"[{"role":"user","content":"hi"}]"#.utf8))
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "fixture", "previous_response_id": response.id, "input": "continue",
        ])
        guard case .prepared(let rewritten?, _) = LocalResponseConversation.prepare(
            body: body, conversation: history.conversation(for:)) else {
            Issue.record("Expected continued conversation")
            return
        }
        let continued = try JSONDecoder().decode(OpenAIResponseRequest.self, from: rewritten)
        let assistant = try #require(continued.chatCompletionRequest.messages.first { $0.role == .assistant })
        #expect(assistant.textContent.isEmpty)
        #expect(assistant.reasoningContent == "Still thinking")
    }

}


private struct PromptReasoningEngine: MLXServerEngine {
    let prefix: String
    func availableModels() async throws -> [MLXServerModel] { [] }
    func streamChatCompletion(request: OpenAIChatCompletionRequest) async throws
        -> AsyncThrowingStream<MLXServerGenerationEvent, Error>
    {
        AsyncThrowingStream { continuation in
            continuation.yield(.content(prefix))
            continuation.yield(.content("Still thinking"))
            continuation.yield(.info(.init(promptTokens: 10, completionTokens: 8,
                promptTime: 0, generationTime: 0, stopReason: "length")))
            continuation.finish()
        }
    }
    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { .init(tokens: []) }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { .init(text: "") }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { .init(tokens: []) }
}
