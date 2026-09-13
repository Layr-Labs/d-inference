import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

/// Pins the SSE contract the synthetic `<think>` injection relies on
/// (Qwen3.6 TTFT fix): once the streaming think parser has seen an
/// opening tag, every reasoning delta streams the moment it arrives —
/// as `reasoning_content` — instead of buffering until `</think>`.
///
/// This is the ProviderCore-side guard: the parser itself lives in the
/// mlx-swift-lm submodule, so a pin here fails loudly if a submodule
/// bump ever regresses incremental reasoning streaming.
@Suite("Think streaming latency contract")
struct ThinkStreamingLatencyTests {

    /// Minimal engine emitting a scripted event sequence.
    private struct ScriptedEngine: MLXServerEngine {
        let events: [MLXServerGenerationEvent]

        func availableModels() async throws -> [MLXServerModel] { [] }
        func streamChatCompletion(
            request: OpenAIChatCompletionRequest
        ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
            AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
        func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse {
            TokenizeResponse(tokens: [])
        }
        func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse {
            DetokenizeResponse(text: "")
        }
        func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse {
            TokenizeResponse(tokens: [])
        }
    }

    private func collectFrames(
        events: [MLXServerGenerationEvent]
    ) async throws -> [String] {
        let service = MLXOpenAIService(engine: ScriptedEngine(events: events))
        var request = OpenAIChatCompletionRequest(
            model: "qwen3.6-test",
            messages: [OpenAIChatMessage(role: .user, content: .text("hi"))]
        )
        request.stream = true
        request.streamOptions = .init(includeUsage: true)
        request.reasoningParser = .qwen3
        var frames: [String] = []
        for try await frame in try await service.streamChatCompletionFrames(request: request) {
            frames.append(frame)
        }
        return frames
    }

    @Test("after a synthetic <think> open, each reasoning delta streams as it arrives")
    func reasoningStreamsIncrementally() async throws {
        // The injected marker, then the model's close-only thinking output
        // split across chunks — exactly what the engine emits for a
        // Qwen3.6 request whose template pre-opened the think block.
        let frames = try await collectFrames(events: [
            .content("<think>"),
            .content("step one "),
            .content("step two "),
            .content("step three</think>Answer"),
            .info(.init(
                promptTokens: 5, completionTokens: 4,
                promptTime: 0, generationTime: 0, stopReason: "stop")),
        ])

        // Reasoning must arrive across MULTIPLE frames (incremental), not
        // one buffered flush after the close.
        let reasoningFrames = frames.filter { $0.contains("\"reasoning_content\"") }
        #expect(reasoningFrames.count >= 2)
        // The first reasoning delta precedes the visible answer.
        let firstReasoning = frames.firstIndex { $0.contains("\"reasoning_content\"") }
        let answer = frames.firstIndex { $0.contains("Answer") }
        #expect(firstReasoning != nil && answer != nil)
        if let firstReasoning, let answer {
            #expect(firstReasoning < answer)
        }
        // Neither marker ever reaches a consumer.
        let joined = frames.joined()
        #expect(!joined.contains("<think>"))
        #expect(!joined.contains("</think>"))
    }

    @Test("a pre-closed prompt streams ordinary chunks without adding content or usage")
    func nonThinkingAnswerStreamsIncrementally() async throws {
        let prefix = try #require(ReasoningPromptProbe.streamingPrefix(
            reasoningParser: .qwen3, stream: true, promptTokens: [1, 2, 3],
            decodeTail: { _ in "<|im_start|>assistant\n<think>\n\n</think>\n\n" }))
        let frames = try await collectFrames(events: [
            .content(prefix),
            .content("A person "), .content("walks across "), .content("the room."),
            .info(.init(promptTokens: 5, completionTokens: 3,
                        promptTime: 0, generationTime: 0, stopReason: "stop")),
        ])
        let payloads = try frames.compactMap { frame -> [String: Any]? in
            guard let data = frame.split(separator: "\n").first,
                  data.hasPrefix("data:"), !data.contains("[DONE]") else { return nil }
            return try JSONSerialization.jsonObject(
                with: Data(data.dropFirst(5).utf8)) as? [String: Any]
        }
        let deltas = payloads.flatMap { $0["choices"] as? [[String: Any]] ?? [] }
            .compactMap { $0["delta"] as? [String: Any] }
        #expect(deltas.compactMap { $0["content"] as? String }
            == ["A person ", "walks across ", "the room."])
        #expect(deltas.compactMap { $0["reasoning_content"] as? String }.isEmpty)
        let usage = try #require(payloads.compactMap { $0["usage"] as? [String: Any] }.last)
        #expect(usage["prompt_tokens"] as? Int == 5)
        #expect(usage["completion_tokens"] as? Int == 3)
        #expect(!frames.joined().contains("<think>"))
        #expect(!frames.joined().contains("</think>"))
    }

    @Test("without an opening tag, close-only reasoning buffers until the close (the bug the injection fixes)")
    func closeOnlyStillBuffersWithoutOpen() async throws {
        // Documents WHY the engine injects: this is upstream's behavior
        // when no opening tag is ever seen. If a submodule bump makes the
        // parser stream close-only output incrementally on its own, this
        // fails and the injection (ReasoningPromptProbe) can be removed.
        let frames = try await collectFrames(events: [
            .content("step one "),
            .content("step two "),
            .content("step three</think>Answer"),
            .info(.init(
                promptTokens: 5, completionTokens: 4,
                promptTime: 0, generationTime: 0, stopReason: "stop")),
        ])

        let reasoningFrames = frames.filter { $0.contains("\"reasoning_content\"") }
        #expect(reasoningFrames.count == 1)
    }
}
