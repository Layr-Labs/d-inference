import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// #200 `tools-described-no-tools-field`: a prompt that describes a tool in
/// text, with no `tools` field. The template renders no `tool_declare`, yet
/// the model writes its native call frame. Such a frame is the answer's text:
/// never a 422 (`undeclared_name`) nor a 500 (`generation_failure`), never an
/// executable call, and reasoning stays reasoning. Uses only the router's
/// existing interface and the scheduler's terminal order (complete-call path:
/// no tools, so `streamsInklingCalls` is false for every client).
@Suite("Inkling 2 calls without declared tools")
struct Inkling2UndeclaredCallTextTests {
    static let type = "inkling2_loop"
    static let thought = "<|message_model|><|content_thinking|>The user wants the weather.<|end_message|>"
    static let eos = "<|content_model_end_sampling|>"

    static func request(clientStreams: Bool, choice: OpenAIToolChoice? = nil, tools: [OpenAITool]? = nil)
        -> OpenAIChatCompletionRequest
    {
        var request = OpenAIChatCompletionRequest(
            model: "thinkingmachines/Inkling-2-Mini",
            messages: [
                .init(role: .system, content: .text("You can call the function get_weather(city: string) by replying "
                    + #"with a JSON tool call {"name": "get_weather", "arguments": {"city": ...}}."#)),
                .init(role: .user, content: .text("What is the weather in Paris? Use the tool.")),
            ],
            tools: tools, toolChoice: choice,
            stream: clientStreams, streamOptions: clientStreams ? .init(includeUsage: true) : nil)
        request.streamToolCallDeltas = clientStreams
        return request
    }

    static func declared() throws -> [OpenAITool] {
        try JSONDecoder().decode([OpenAITool].self, from: Data(#"""
            [{"type":"function","function":{"name":"get_weather","parameters":{"type":"object",
              "properties":{"city":{"type":"string"}},"required":["city"]}}}]
            """#.utf8))
    }

    /// What the scheduler would send: visible content, reasoning, executable calls.
    struct Outcome {
        var content = ""
        var reasoning = ""
        var deltas = 0
        var calls: [ToolCall] = []
        var refusal: String?
    }

    /// The scheduler's forwarder for the complete-call path
    /// (`MultiModelBatchSchedulerEngine`, `makeDeadlineCheckedEventStream`):
    /// chunks through `process`, then `finishText`, `finishCompleteCalls`,
    /// `checkNativeToolFailure`, `ParallelToolCallPolicy.admitted` and
    /// `ToolConstraintValidation.validateWithheld`. A throw is the refusal the
    /// client would get, with its HTTP status.
    static func serve(_ output: String, request: OpenAIChatCompletionRequest, width: Int, cutAtLimit: Bool = false)
        throws -> Outcome
    {
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: type)
        let streams = ToolStreamPreparation.streamsInklingCalls(request: request, prepared: prepared)
        var router = NativeToolStreamRouter(handler: nil, requiresToolCall: prepared.requiresToolCall,
            nativePrefix: nil, tools: prepared.tools?.map { $0.toolSpec() }, streamedCalls: prepared,
            nativeInklingChannels: true, inklingStreamsCalls: streams)
        var outcome = Outcome()
        func take(_ events: [MLXServerGenerationEvent]) {
            for event in events {
                switch event {
                case .parsed(let piece):
                    outcome.content += piece.content
                    outcome.reasoning += piece.reasoningContent ?? ""
                case .content(let text): outcome.content += text
                case .toolCallDelta: outcome.deltas += 1
                default: Issue.record("unexpected event \(event)")
                }
            }
        }
        let characters = Array(output)
        do {
            for start in stride(from: 0, to: characters.count, by: width) {
                take(try router.process(String(characters[start..<min(start + width, characters.count)])))
            }
            if cutAtLimit { router.outputReachedTokenLimit() }
            take(try router.finishText(cutAtLimit: cutAtLimit))
            if router.streamsToolCalls {
                take(try router.finishToolCalls(truncated: cutAtLimit, cutAtLimit: cutAtLimit))
                if !cutAtLimit { try router.checkNativeToolFailure() }
                try ToolConstraintValidation.validate(router.completedToolCalls, prepared: prepared,
                    responseStarted: router.responseStarted)
                outcome.calls = router.completedToolCalls
                return outcome
            }
            let finished = try router.finishCompleteCalls(truncated: cutAtLimit, cutAtLimit: cutAtLimit)
            if !cutAtLimit { try router.checkNativeToolFailure() }
            var calls = ParallelToolCallPolicy.admitted(finished.calls, prepared: prepared)
            try ToolConstraintValidation.validateWithheld(&calls, prepared: prepared, truncated: cutAtLimit,
                cutAtLimit: cutAtLimit, responseStarted: !outcome.content.isEmpty || !outcome.reasoning.isEmpty)
            if prepared.mode == .auto, let residual = finished.residual, !residual.isEmpty,
                !router.hasNativeToolFailure
            {
                outcome.content += residual
            }
            outcome.calls = calls
        } catch {
            outcome.refusal = "\(error) -> HTTP \(ProviderLoop.mapInferenceErrorToStatus(error))"
        }
        return outcome
    }

    /// The frames, and the text each answers with.
    static let frames: [(name: String, frame: String, text: String)] = [
        ("parses (template shape)",
         #"<|message_model|>get_weather<|content_invoke_tool_json|>{"name":"get_weather","args":{"city":"Paris"}}<|end_message|>"#,
         #"{"name":"get_weather","args":{"city":"Paris"}}"#),
        ("malformed (the prompt's `arguments` shape)",
         #"<|message_model|>get_weather<|content_invoke_tool_json|>{"name":"get_weather","arguments":{"city":"Paris"}}<|end_message|>"#,
         #"{"name":"get_weather","arguments":{"city":"Paris"}}"#),
        ("malformed (not JSON)",
         #"<|message_model|>search<|content_invoke_tool_json|>search(pattern="cart")<|end_message|>"#,
         #"search(pattern="cart")"#),
        ("arguments only, no header",
         #"<|content_invoke_tool_json|>{"city":"Paris"}<|end_message|>"#, #"{"city":"Paris"}"#),
        ("truncated by a stop token",
         #"<|message_model|>get_weather<|content_invoke_tool_json|>{"name":"get_weather","args":{"ci"#,
         #"{"name":"get_weather","args":{"ci"#),
    ]

    @Test("a call frame without declared tools is answer text", arguments: [false, true])
    func callFrameIsAnswerText(clientStreams: Bool) throws {
        for (name, frame, text) in Self.frames {
            for width in [1, 7, 4096] {
                let outcome = try Self.serve(Self.thought + frame + Self.eos,
                    request: Self.request(clientStreams: clientStreams), width: width)
                #expect(outcome.refusal == nil, "\(name), width \(width): \(outcome.refusal ?? "")")
                #expect(outcome.content == text, "\(name), width \(width)")
                #expect(outcome.reasoning == "The user wants the weather.", "\(name)")
                #expect(!outcome.content.contains("The user wants"), "\(name): reasoning leaked into content")
                #expect(outcome.calls.isEmpty && outcome.deltas == 0, "\(name): an executable call")
            }
        }
    }

    /// Text around the frame stays in order; the frame's markers never show.
    @Test func answerAroundTheFrameKeepsItsOrder() throws {
        let outcome = try Self.serve(Self.thought + "<|message_model|><|content_text|>Checking.<|end_message|>"
            + Self.frames[0].frame + Self.eos, request: Self.request(clientStreams: true), width: 3)
        #expect(outcome.refusal == nil, "\(outcome.refusal ?? "")")
        #expect(outcome.content == "Checking." + Self.frames[0].text)
        #expect(!outcome.content.contains("<|"))
        #expect(outcome.calls.isEmpty)
    }

    /// Cut at `max_tokens` inside the frame: the text so far, ending `length`.
    @Test func frameCutAtTheTokenLimitIsText() throws {
        let outcome = try Self.serve(Self.thought + Self.frames[4].frame,
            request: Self.request(clientStreams: false), width: 5, cutAtLimit: true)
        #expect(outcome.refusal == nil, "\(outcome.refusal ?? "")")
        #expect(outcome.content == Self.frames[4].text)
        #expect(outcome.calls.isEmpty)
    }

    // MARK: - Unchanged paths (controls)

    /// Declared tools, `auto`: the frame is a call, as before.
    @Test("declared tools keep their calls", arguments: [false, true])
    func declaredToolsKeepTheirCalls(clientStreams: Bool) throws {
        let outcome = try Self.serve(Self.thought + Self.frames[0].frame + Self.eos,
            request: Self.request(clientStreams: clientStreams, tools: Self.declared()), width: 7)
        #expect(outcome.refusal == nil, "\(outcome.refusal ?? "")")
        #expect(outcome.calls.map(\.function.name) == ["get_weather"])
        #expect(outcome.calls.first?.function.arguments == ["city": .string("Paris")])
        #expect(outcome.content.isEmpty)
    }

    /// Declared tools, malformed frame: still refused (native noncompliance).
    @Test func declaredToolsStillRefuseAMalformedFrame() throws {
        let outcome = try Self.serve(Self.thought + Self.frames[1].frame + Self.eos,
            request: Self.request(clientStreams: false, tools: Self.declared()), width: 7)
        #expect(outcome.refusal?.contains("HTTP 500") == true)
        #expect(outcome.calls.isEmpty)
    }

    /// Explicit `tool_choice: none` (with or without tools): a call is still refused.
    @Test func explicitNoneStillRefusesACall() throws {
        for tools in [nil, try Self.declared()] {
            let outcome = try Self.serve(Self.thought + Self.frames[0].frame + Self.eos,
                request: Self.request(clientStreams: false, choice: .mode(.none), tools: tools), width: 7)
            #expect(outcome.refusal?.contains("HTTP 422") == true, "\(outcome.refusal ?? "nil")")
            #expect(outcome.calls.isEmpty)
        }
    }

    /// Plain answers without tools: unchanged.
    @Test func plainAnswerIsUnchanged() throws {
        let outcome = try Self.serve(Self.thought + "<|message_model|><|content_text|>Sunny.<|end_message|>" + Self.eos,
            request: Self.request(clientStreams: true), width: 2)
        #expect(outcome.refusal == nil)
        #expect(outcome.content == "Sunny.")
        #expect(outcome.reasoning == "The user wants the weather.")
    }
}
