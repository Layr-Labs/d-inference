// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Inkling 2 with reasoning withheld: one empty answer delta when withholding
/// starts (`InklingWithheldReasoningHeartbeat`), and nothing else changes.
@Suite("Inkling withheld-reasoning heartbeat")
struct InklingWithheldReasoningHeartbeatTests {
    static let thought = "<|message_model|><|content_thinking|>The user wants a short greeting. Think it over.<|end_message|>"
    static let answer = "<|message_model|><|content_text|>Hello there.<|end_message|><|content_model_end_sampling|>"
    static let call = #"<|message_model|>get_weather<|content_invoke_tool_json|>{"name":"get_weather","args":{"location":"Paris"}}<|end_message|>"#

    static func router(withhold: Bool, heartbeat: Bool, inkling: Bool = true,
                       prepared: ToolChoicePromptPolicy.Prepared? = nil) -> NativeToolStreamRouter {
        NativeToolStreamRouter(handler: nil, requiresToolCall: false, nativePrefix: inkling ? nil : "<think>",
            tools: prepared?.tools?.map { $0.toolSpec() }, withholdReasoning: withhold, streamedCalls: prepared,
            nativeInklingChannels: inkling, inklingStreamsCalls: false, withheldReasoningHeartbeat: heartbeat)
    }

    static func feed(_ router: inout NativeToolStreamRouter, _ text: String, width: Int) throws
        -> [MLXServerGenerationEvent]
    {
        let characters = Array(text)
        var events: [MLXServerGenerationEvent] = []
        for start in stride(from: 0, to: characters.count, by: width) {
            events += try router.process(String(characters[start..<min(start + width, characters.count)]))
        }
        return events + (try router.finishText())
    }

    static let heartbeat = InklingWithheldReasoningHeartbeat.event

    // MARK: - The router

    @Test(arguments: [1, 7, 4096])
    func aWithheldThoughtStartsWithExactlyOneEmptyAnswerDelta(width: Int) throws {
        var router = Self.router(withhold: true, heartbeat: true)
        let events = try Self.feed(&router, Self.thought + Self.answer, width: width)
        #expect(events.filter { $0 == Self.heartbeat }.count == 1)
        #expect(events.first == Self.heartbeat)
        // The withheld text is counted, never emitted; the answer is unchanged.
        #expect(router.takeWithheldReasoning() == "The user wants a short greeting. Think it over.")
        var plain = Self.router(withhold: true, heartbeat: false)
        let without = try Self.feed(&plain, Self.thought + Self.answer, width: width)
        #expect(events.filter { $0 != Self.heartbeat } == without)
        #expect(!without.contains(Self.heartbeat))
    }

    @Test func noThoughtNoHeartbeat() throws {
        var router = Self.router(withhold: true, heartbeat: true)
        let events = try Self.feed(&router, Self.answer, width: 4096)
        #expect(!events.contains(Self.heartbeat))
    }

    /// Reasoning on, other models, and paths that do not ask for it stream as before.
    @Test func everyOtherStreamIsUnchanged() throws {
        // Reasoning on: the thought streams as before, with the flag or without.
        var on = Self.router(withhold: false, heartbeat: true)
        var off = Self.router(withhold: false, heartbeat: false)
        let output = Self.thought + Self.answer
        let streamed = try Self.feed(&on, output, width: 3)
        #expect(streamed == (try Self.feed(&off, output, width: 3)))
        #expect(!streamed.contains(Self.heartbeat))
        // A Qwen-style thought withheld with the flag on: no heartbeat (Inkling only).
        let qwen = "Let me think.</think>\n\nHello there."
        var qwenOn = Self.router(withhold: true, heartbeat: true, inkling: false)
        var qwenOff = Self.router(withhold: true, heartbeat: false, inkling: false)
        let withFlag = try Self.feed(&qwenOn, qwen, width: 5)
        #expect(withFlag == (try Self.feed(&qwenOff, qwen, width: 5)))
        #expect(!withFlag.contains(Self.heartbeat))
    }

    @Test func callsAndStopsAreUnaffected() throws {
        let request = OpenAIChatCompletionRequest(
            model: "thinkingmachines/Inkling-2-Mini", messages: [.init(role: .user, content: .text("Weather?"))],
            tools: try JSONDecoder().decode([OpenAITool].self, from: Data(#"""
                [{"type":"function","function":{"name":"get_weather","parameters":{"type":"object",
                  "properties":{"location":{"type":"string"}},"required":["location"]}}}]
                """#.utf8)))
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "inkling2_loop")
        var on = Self.router(withhold: true, heartbeat: true, prepared: prepared)
        var off = Self.router(withhold: true, heartbeat: false, prepared: prepared)
        let events = try Self.feed(&on, Self.thought + Self.call, width: 4)
        #expect(events.filter { $0 == Self.heartbeat }.count == 1)
        #expect(events.filter { $0 != Self.heartbeat } == (try Self.feed(&off, Self.thought + Self.call, width: 4)))
        #expect(try on.finishCompleteCalls(truncated: false).calls.map(\.function.name) == ["get_weather"])
        #expect(try off.finishCompleteCalls(truncated: false).calls.map(\.function.name) == ["get_weather"])
    }

    // MARK: - The frame

    /// The SDK's encoding of the event (`MLXOpenAIService.emitParsed`: empty
    /// content is omitted, the reasoning fields are written).
    static func encoded(content: String?, reasoning: String?, role: String? = nil, finish: String? = nil,
                        usage: OpenAIUsage? = nil) throws -> String {
        try ServerSentEventEncoder.encode(OpenAIChatCompletionChunk(
            id: "chatcmpl-1", model: "thinkingmachines/Inkling-2-Mini",
            choices: [.init(index: 0, delta: .init(role: role, content: content, reasoningContent: reasoning,
                                                   toolCalls: nil), finishReason: finish)],
            usage: usage, created: 1_795_550_000))
    }

    @Test func theFrameIsAPlainEmptyContentChunk() throws {
        let rewritten = try #require(InklingWithheldReasoningHeartbeat.frame(
            rewriting: try Self.encoded(content: nil, reasoning: "")))
        #expect(rewritten == #"data: {"choices":[{"delta":{"content":""},"index":0}],"created":1795550000,"#
            + #""id":"chatcmpl-1","model":"thinkingmachines/Inkling-2-Mini","object":"chat.completion.chunk"}"#
            + "\n\n")
        // The coordinator holds a chunk only when its line says "role".
        #expect(!rewritten.contains("role"))
        #expect(!rewritten.contains("reasoning"))
        #expect(!rewritten.contains("usage"))
        #expect(!rewritten.contains("finish_reason"))
    }

    @Test func everyOtherFrameIsLeftAlone() throws {
        for frame in [
            try Self.encoded(content: nil, reasoning: "a thought"),
            try Self.encoded(content: "Hello", reasoning: nil),
            try Self.encoded(content: "", reasoning: nil, role: "assistant"),
            try Self.encoded(content: nil, reasoning: "", finish: "stop"),
            try Self.encoded(content: nil, reasoning: "", usage: .init(promptTokens: 1, completionTokens: 1)),
            ServerSentEventEncoder.done,
        ] {
            #expect(InklingWithheldReasoningHeartbeat.frame(rewriting: frame) == nil, "\(frame)")
        }
    }

    // MARK: - Through the SDK's stream encoder

    private struct Fixture: MLXServerEngine {
        func availableModels() async throws -> [MLXServerModel] { [.init(id: "fixture")] }
        func streamChatCompletion(request: OpenAIChatCompletionRequest) async throws
            -> AsyncThrowingStream<MLXServerGenerationEvent, Error>
        {
            AsyncThrowingStream { continuation in
                continuation.yield(InklingWithheldReasoningHeartbeat.event)
                continuation.yield(.parsed(.init(content: "Hello there.", reasoningContent: nil)))
                continuation.finish()
            }
        }
        func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { .init(tokens: [1]) }
        func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { .init(text: "ok") }
        func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { .init(tokens: [1]) }
    }

    @Test func theSDKStreamCarriesExactlyOneHeartbeatFrame() async throws {
        let request = OpenAIChatCompletionRequest(
            model: "fixture", messages: [.init(role: .user, content: .text("Hi"))], stream: true)
        var frames: [String] = []
        for try await frame in try await MLXOpenAIService(engine: Fixture()).streamChatCompletionFrames(request: request) {
            frames.append(frame)
        }
        let rewritten = frames.compactMap(InklingWithheldReasoningHeartbeat.frame(rewriting:))
        #expect(rewritten.count == 1)
        #expect(rewritten.allSatisfy { !$0.contains("role") && $0.contains(#""delta":{"content":""}"#) })
    }
}
