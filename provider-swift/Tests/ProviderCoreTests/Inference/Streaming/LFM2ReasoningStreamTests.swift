// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// LFM2.5 is reasoning-only: the template's generation prompt ends in
/// `<think>`, so generated text starts inside reasoning. These tests compose
/// the production pieces in `makeEventStream` order (prompt-tail probe ->
/// NativeToolStreamRouter -> tool handler finish -> MLXOpenAIService SSE) and
/// assert the consumer-visible fields.
@Suite("LFM2.5 reasoning and tool streaming")
struct LFM2ReasoningStreamTests {
    static let modelType = "lfm2_moe"
    static let context = ChatTemplateFixContext(modelId: "lfm2.5-24b-a2b", modelType: modelType)
    static let promptTail = "<|im_end|>\n<|im_start|>assistant\n<think>"

    struct Outcome {
        var reasoning = ""
        var content = ""
        var reasoningDeltas = 0
        var toolCalls: [(name: String, arguments: String)] = []
        var finishReason: String?
        var rawFrames = ""
    }

    private struct ScriptedEngine: MLXServerEngine {
        let events: [MLXServerGenerationEvent]
        func availableModels() async throws -> [MLXServerModel] { [] }
        func streamChatCompletion(request: OpenAIChatCompletionRequest) async throws
            -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
            AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
        func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { .init(tokens: []) }
        func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { .init(text: "") }
        func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { .init(tokens: []) }
    }

    static let weatherTool: [String: any Sendable] = [
        "type": "function",
        "function": [
            "name": "get_weather",
            "parameters": [
                "type": "object",
                "properties": ["location": ["type": "string"] as [String: any Sendable]],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    /// Routes `chunks` exactly like `makeEventStream`, then renders SSE.
    static func run(_ chunks: [String], tools: Bool = false, stopReason: String = "stop") async throws -> Outcome {
        #expect(ToolChoiceEnforcementPolicy.usesNativeTextChannels(context))
        let prefix = try #require(ReasoningPromptProbe.streamingPrefix(forPromptTail: promptTail))
        let handler = tools ? BatchedToolStreamHandler(format: try ServerToolParser.resolve(
            requested: nil, modelType: modelType), tools: [weatherTool]) : nil
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false,
            nativePrefix: prefix,
            preserveInnerReasoningSpans: ToolChoiceEnforcementPolicy.preservesInnerReasoningSpans(context),
            absorbStrayThinkClose: ToolChoiceEnforcementPolicy.absorbsStrayThinkClose(context))
        var events: [MLXServerGenerationEvent] = []
        for chunk in chunks { events += try router.process(chunk) }
        events += try router.finishText()
        for call in handler?.finish() ?? [] { events.append(.toolCall(call)) }
        events.append(.info(.init(promptTokens: 7, completionTokens: chunks.count,
            promptTime: 0, generationTime: 0, stopReason: stopReason)))

        var request = OpenAIChatCompletionRequest(
            model: "lfm2.5-24b-a2b", messages: [OpenAIChatMessage(role: .user, content: .text("hi"))])
        request.stream = true
        request.streamOptions = .init(includeUsage: true)
        request.reasoningParser = ProviderLoop.inferReasoningParser(for: modelType)
        var outcome = Outcome()
        let service = MLXOpenAIService(engine: ScriptedEngine(events: events))
        for try await frame in try await service.streamChatCompletionFrames(request: request) {
            outcome.rawFrames += frame
            guard let line = frame.split(separator: "\n").first, line.hasPrefix("data:"),
                  !line.contains("[DONE]"),
                  let payload = try JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))
                      as? [String: Any]
            else { continue }
            for choice in payload["choices"] as? [[String: Any]] ?? [] {
                if let reason = choice["finish_reason"] as? String { outcome.finishReason = reason }
                let delta = choice["delta"] as? [String: Any] ?? [:]
                if let text = delta["reasoning_content"] as? String {
                    outcome.reasoning += text
                    outcome.reasoningDeltas += 1
                }
                if let text = delta["content"] as? String { outcome.content += text }
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = call["function"] as? [String: Any] ?? [:]
                    outcome.toolCalls.append((function["name"] as? String ?? "",
                                              function["arguments"] as? String ?? ""))
                }
            }
        }
        return outcome
    }

    static func split(_ text: String, width: Int) -> [String] {
        let characters = Array(text)
        return stride(from: 0, to: characters.count, by: width).map {
            String(characters[$0..<min($0 + width, characters.count)])
        }
    }

    static func assertNoMarkers(_ outcome: Outcome) {
        for marker in ["<think>", "</think>", "<|tool_call_start|>", "<|tool_call_end|>"] {
            #expect(!outcome.content.contains(marker))
        }
        #expect(!outcome.rawFrames.contains("</think>"))
    }

    @Test func policyRoutesLFMThroughReasoningChannelsWithoutForcedToolChoice() throws {
        #expect(ProviderLoop.inferReasoningParser(for: Self.modelType) == .qwen3)
        #expect(ReasoningPromptProbe.streamingPrefix(forPromptTail: Self.promptTail) == "<think>")
        #expect(ToolChoiceEnforcementPolicy.usesLFM2ReasoningChannels(Self.context))
        #expect(ToolChoiceEnforcementPolicy.absorbsStrayThinkClose(Self.context))
        #expect(!ToolChoiceEnforcementPolicy.nativeStructuredTarget(Self.context))
        #expect(!ToolChoiceEnforcementPolicy.preservesInnerReasoningSpans(Self.context))
        #expect(try ServerToolParser.resolve(requested: nil, modelType: Self.modelType) == .lfm2)
        // Required/named tool choice has no sampler grammar or post-validation
        // admission for pythonic frames: it fails closed before submission.
        for mode in [ToolConstraintMode.required, .named("get_weather")] {
            #expect(throws: (any Error).self) {
                try ToolChoiceEnforcementPolicy.forcedStrategy(mode: mode, modelContext: Self.context)
            }
        }
        #expect(try ToolChoiceEnforcementPolicy.forcedStrategy(mode: .auto, modelContext: Self.context) == .none)
        // ...and the routing capability (tool constraint) is never advertised.
        for id in ["LiquidAI/LFM2.5-24B-A2B-MLX-4bit", "lfm2.5-24b-a2b"] {
            let info = ModelInfo(id: id, modelType: Self.modelType, sizeBytes: 1, estimatedMemoryGb: 1)
            #expect(!ToolChoiceEnforcementPolicy.advertisesCapability(for: info))
            #expect(!ToolChoiceEnforcementPolicy.advertisesNativeMediaTools(for: info))
        }
        // Other families keep their routing.
        for other in ["lfm2", "qwen3", "gpt_oss", "gemma4"] {
            let context = ChatTemplateFixContext(modelId: "x", modelType: other)
            #expect(!ToolChoiceEnforcementPolicy.usesLFM2ReasoningChannels(context))
            #expect(!ToolChoiceEnforcementPolicy.absorbsStrayThinkClose(context))
        }
    }

    @Test func closeMarkerSplitAcrossChunksAtEveryWidth() async throws {
        let text = "Let me think: 2+2 is 4.</think>The answer is 4."
        for width in [1, 2, 3, 5, 8, text.count] {
            let outcome = try await Self.run(Self.split(text, width: width))
            #expect(outcome.reasoning == "Let me think: 2+2 is 4.")
            #expect(outcome.content == "The answer is 4.")
            #expect(outcome.finishReason == "stop")
            Self.assertNoMarkers(outcome)
        }
    }

    @Test func reasoningStreamsBeforeTheCloseArrives() async throws {
        let outcome = try await Self.run(["step one ", "step two ", "step three", "</think>", "Done"])
        #expect(outcome.reasoningDeltas >= 3)
        #expect(outcome.reasoning == "step one step two step three")
        #expect(outcome.content == "Done")
    }

    @Test func multibyteTextAroundMarkersSurvivesSplits() async throws {
        let text = "東京は🌊です。</think>Ответ: café ✓"
        for width in [1, 2, 4] {
            let outcome = try await Self.run(Self.split(text, width: width))
            #expect(outcome.reasoning == "東京は🌊です。")
            #expect(outcome.content == "Ответ: café ✓")
            #expect(!outcome.rawFrames.contains("\u{FFFD}"))
        }
    }

    @Test func emptyReasoningEmitsOnlyContent() async throws {
        let outcome = try await Self.run(["</think>", "Hi there"])
        #expect(outcome.reasoning.isEmpty && outcome.reasoningDeltas == 0)
        #expect(outcome.content == "Hi there")
        Self.assertNoMarkers(outcome)
    }

    @Test func veryLongReasoningIsDeliveredExactly() async throws {
        let pieces = (0..<5_000).map { "r\($0) " }
        let outcome = try await Self.run(pieces + ["</think>", "ok"])
        #expect(outcome.reasoning == pieces.joined())
        #expect(outcome.content == "ok")
    }

    @Test func missingCloseAtMaxTokensIsAllReasoningWithLengthFinish() async throws {
        let outcome = try await Self.run(["Thinking about ", "the problem", " still </thi"], stopReason: "length")
        #expect(outcome.finishReason == "length")
        #expect(outcome.content.isEmpty)
        // A trailing partial marker is not a delimiter; it stays reasoning text.
        #expect(outcome.reasoning == "Thinking about the problem still </thi")
    }

    @Test func duplicatedAndReopenedMarkersNeverLeakIntoContent() async throws {
        var outcome = try await Self.run(["a</think>b</think>c"])
        #expect(outcome.reasoning == "a")
        #expect(outcome.content == "bc")
        Self.assertNoMarkers(outcome)
        outcome = try await Self.run(["a</think>b<think>c</think>d"])
        #expect(outcome.reasoning == "ac")
        #expect(outcome.content == "bd")
        Self.assertNoMarkers(outcome)
        // An opening marker echoed inside reasoning is ordinary reasoning text
        // (no nesting for LFM); the first close ends the span.
        outcome = try await Self.run(["x<think>y</think>z"])
        #expect(outcome.reasoning == "x<think>y")
        #expect(outcome.content == "z")
    }

    /// A consumer cancel stops forwarding mid-span: whatever was already
    /// routed is reasoning-only and a held-back marker prefix never surfaces.
    @Test func cancellationMidReasoningEmitsOnlySafeReasoning() throws {
        let prefix = try #require(ReasoningPromptProbe.streamingPrefix(forPromptTail: Self.promptTail))
        var router = NativeToolStreamRouter(handler: nil, requiresToolCall: false, nativePrefix: prefix,
            absorbStrayThinkClose: true)
        var events: [MLXServerGenerationEvent] = []
        for chunk in ["partial reasoning ", "then </th"] { events += try router.process(chunk) }
        // Cancelled here: makeEventStream finishes without finishText().
        var reasoning = ""
        for event in events {
            guard case .parsed(let piece) = event else { Issue.record("unexpected event"); continue }
            #expect(piece.content.isEmpty)
            reasoning += piece.reasoningContent ?? ""
        }
        #expect(reasoning == "partial reasoning then ")
    }

    @Test func reasoningThenPythonicCallBecomesToolCall() async throws {
        let text = "I need the weather.</think><|tool_call_start|>[get_weather(location='Paris, France')]<|tool_call_end|>"
        for width in [1, 3, 7, text.count] {
            let outcome = try await Self.run(Self.split(text, width: width), tools: true)
            #expect(outcome.reasoning == "I need the weather.")
            #expect(outcome.content.isEmpty)
            #expect(outcome.toolCalls.count == 1)
            #expect(outcome.toolCalls.first?.name == "get_weather")
            let arguments = try JSONSerialization.jsonObject(
                with: Data((outcome.toolCalls.first?.arguments ?? "").utf8)) as? [String: Any]
            #expect(arguments?["location"] as? String == "Paris, France")
            #expect(outcome.finishReason == "tool_calls")
            Self.assertNoMarkers(outcome)
        }
    }

    @Test func callWrittenInsideReasoningIsNotInvoked() async throws {
        let text = "Maybe <|tool_call_start|>[get_weather(location='X')]<|tool_call_end|>? No.</think>Answer"
        for width in [1, 4, text.count] {
            let outcome = try await Self.run(Self.split(text, width: width), tools: true)
            #expect(outcome.toolCalls.isEmpty)
            #expect(outcome.reasoning == "Maybe <|tool_call_start|>[get_weather(location='X')]<|tool_call_end|>? No.")
            #expect(outcome.content == "Answer")
            #expect(outcome.finishReason == "stop")
        }
    }

    @Test func reasoningMarkersInsideToolArgumentsStayOpaque() async throws {
        let text = "ok</think><|tool_call_start|>[get_weather(location='<think>Paris</think>')]<|tool_call_end|>"
        for width in [1, 5, text.count] {
            let outcome = try await Self.run(Self.split(text, width: width), tools: true)
            #expect(outcome.reasoning == "ok")
            #expect(outcome.toolCalls.count == 1)
            let arguments = try JSONSerialization.jsonObject(
                with: Data((outcome.toolCalls.first?.arguments ?? "").utf8)) as? [String: Any]
            #expect(arguments?["location"] as? String == "<think>Paris</think>")
        }
    }
}
