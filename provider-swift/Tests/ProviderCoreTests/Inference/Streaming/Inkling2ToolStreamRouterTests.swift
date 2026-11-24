import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Inkling 2's channels on the scheduler's router (`NativeToolStreamRouter`
/// with `nativeInklingChannels`): reasoning, answer and calls classified by
/// the model's own message tokens, calls checked before they leave, forced
/// choices refusing text, malformed frames refused and declined thinking
/// withheld.
@Suite("Inkling 2 tool stream routing")
struct Inkling2ToolStreamRouterTests {
    static let type = "inkling2_loop"
    static let tools = """
        [{"type":"function","function":{"name":"get_weather","parameters":{"type":"object",
          "properties":{"location":{"type":"string"},"days":{"type":"integer"}},"required":["location"]}}},
         {"type":"function","function":{"name":"write_file","parameters":{"type":"object",
          "properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}}]
        """

    static func prepared(_ choice: OpenAIToolChoice? = nil, parallel: Bool? = nil, clientStreams: Bool = true)
        throws -> (OpenAIChatCompletionRequest, ToolChoicePromptPolicy.Prepared)
    {
        var request = OpenAIChatCompletionRequest(
            model: "thinkingmachines/Inkling-2-Mini",
            messages: [.init(role: .user, content: .text("Weather in Paris?"))],
            tools: try JSONDecoder().decode([OpenAITool].self, from: Data(tools.utf8)),
            toolChoice: choice, parallelToolCalls: parallel, stream: clientStreams,
            streamOptions: clientStreams ? .init(includeUsage: true) : nil)
        request.streamToolCallDeltas = clientStreams
        return (request, try ToolChoicePromptPolicy.prepare(request, modelType: type))
    }

    static func router(_ prepared: ToolChoicePromptPolicy.Prepared, streams: Bool, withhold: Bool = false,
                       undeclaredCallsAreText: Bool = true)
        -> NativeToolStreamRouter
    {
        NativeToolStreamRouter(handler: nil, requiresToolCall: prepared.requiresToolCall, nativePrefix: nil,
            tools: prepared.tools?.map { $0.toolSpec() }, withholdReasoning: withhold, streamedCalls: prepared,
            nativeInklingChannels: true, inklingStreamsCalls: streams,
            inklingUndeclaredCallsAreText: undeclaredCallsAreText)
    }

    static let call = #"<|message_model|>get_weather<|content_invoke_tool_json|>{"name":"get_weather","args":{"location":"Paris"}}<|end_message|>"#
    static let thought = "<|message_model|><|content_thinking|>Need the weather.<|end_message|>"

    struct Routed {
        var reasoning = ""
        var content = ""
        var deltas: [MLXServerGenerationEvent] = []

        init(_ events: [MLXServerGenerationEvent]) {
            for event in events {
                switch event {
                case .parsed(let piece):
                    reasoning += piece.reasoningContent ?? ""
                    content += piece.content
                case .toolCallDelta:
                    deltas.append(event)
                default:
                    Issue.record("unexpected event \(event)")
                }
            }
        }
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

    @Test func autoCallsHeldToTheEndForAClientThatDoesNotStream() throws {
        let (_, prepared) = try Self.prepared(clientStreams: false)
        for width in [1, 5, 4096] {
            var router = Self.router(prepared, streams: false)
            #expect(router.usesNativeChannels)
            #expect(!router.streamsToolCalls)
            let routed = Routed(try Self.feed(&router, Self.thought + Self.call, width: width))
            #expect(routed.reasoning == "Need the weather.")
            #expect(routed.content.isEmpty)
            #expect(routed.deltas.isEmpty)
            let finished = try router.finishCompleteCalls(truncated: false)
            #expect(finished.residual == nil)
            #expect(finished.calls.map(\.function.name) == ["get_weather"])
            #expect(finished.calls.first?.function.arguments == ["location": .string("Paris")])
            try ToolConstraintValidation.validate(finished.calls, prepared: prepared)
        }
    }

    /// A request that declares tools reads a call the model wrote as an
    /// answer message (`NAME<|content_invoke_tool_json|>{...}`) as that call.
    @Test func callWrittenAsAnAnswerMessageIsACall() throws {
        let (_, prepared) = try Self.prepared(clientStreams: false)
        let wrapped = #"<|message_model|><|content_text|>get_weather<|content_invoke_tool_json|>{"name":"get_weather","args":{"location":"Paris"}}<|end_message|>"#
        for width in [1, 5, 4096] {
            var router = Self.router(prepared, streams: false)
            let routed = Routed(try Self.feed(&router, Self.thought + wrapped, width: width))
            #expect(routed.reasoning == "Need the weather.")
            #expect(routed.content.isEmpty)
            let finished = try router.finishCompleteCalls(truncated: false)
            #expect(finished.calls.map(\.function.name) == ["get_weather"])
            #expect(finished.calls.first?.function.arguments == ["location": .string("Paris")])
        }
    }

    /// To a client that streams, each call leaves complete when its frame closes.
    @Test func callsLeaveWhenTheirFrameCloses() throws {
        let (request, prepared) = try Self.prepared()
        #expect(ToolStreamPreparation.streamsInklingCalls(request: request, prepared: prepared,
            streamToolCalls: true, streamNativeToolCalls: true, streamForcedToolCalls: .all))
        #expect(!ToolStreamPreparation.streamsInklingCalls(request: request, prepared: prepared,
            streamToolCalls: true, streamNativeToolCalls: false, streamForcedToolCalls: .all))
        var router = Self.router(prepared, streams: true)
        #expect(router.streamsToolCalls)
        var events = try router.process(Self.thought + String(Self.call.dropLast(4)))
        #expect(Routed(events).deltas.isEmpty)
        events = try router.process(String(Self.call.suffix(4)))
        guard case .toolCallDelta(let delta)? = events.first else {
            Issue.record("expected the call when its frame closed"); return
        }
        #expect(delta.index == 0)
        #expect(delta.name == "get_weather")
        #expect(delta.completed?.function.arguments == ["location": .string("Paris")])
        #expect(router.completedToolCalls.count == 1)
        _ = try router.finishText()
        #expect(try router.finishToolCalls(truncated: false).isEmpty)
    }

    @Test func answerTextIsContent() throws {
        let (_, prepared) = try Self.prepared(clientStreams: false)
        var router = Self.router(prepared, streams: false)
        let routed = Routed(try Self.feed(&router,
            Self.thought + "<|message_model|><|content_text|>It is sunny.<|end_message|>", width: 3))
        #expect(routed.content == "It is sunny.")
        #expect(try router.finishCompleteCalls(truncated: false).calls.isEmpty)
    }

    /// A forced choice answers with calls only: framing whitespace and
    /// reasoning pass, answer text is refused.
    @Test func forcedChoiceRefusesAnswerText() throws {
        let (_, prepared) = try Self.prepared(.mode(.required), clientStreams: false)
        var router = Self.router(prepared, streams: false)
        let routed = Routed(try Self.feed(&router, Self.thought + Self.call, width: 7))
        #expect(routed.reasoning == "Need the weather.")
        let calls = try router.finishCompleteCalls(truncated: false).calls
        #expect(calls.count == 1)
        try ToolConstraintValidation.validate(calls, prepared: prepared)

        var refusing = Self.router(prepared, streams: false)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try refusing.process("<|message_model|><|content_text|>I won't call it.<|end_message|>")
        }
    }

    /// A named choice refuses a call to another declared function.
    @Test func namedChoiceRefusesAnotherFunction() throws {
        let (_, prepared) = try Self.prepared(.function(name: "write_file"), clientStreams: true)
        var router = Self.router(prepared, streams: true)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try router.process(Self.call)
        }
    }

    /// A malformed call frame is native noncompliance: refused before any
    /// later text leaves, as the forced or `auto` failure of its family.
    @Test func malformedFrameIsRefused() throws {
        let broken = #"<|message_model|>get_weather<|content_invoke_tool_json|>{"name":"get_weather","args":[]}<|end_message|>"#
        for choice in [nil, OpenAIToolChoice.mode(.required)] {
            let (_, prepared) = try Self.prepared(choice, clientStreams: false)
            var router = Self.router(prepared, streams: false)
            do {
                _ = try router.process(broken + "<|message_model|><|content_text|>after<|end_message|>")
                Issue.record("a malformed frame was accepted")
            } catch let error as MultiModelBatchSchedulerEngineError {
                switch (choice, error) {
                case (nil, .generationFailed(let message)): #expect(message.contains("Inkling"))
                case (.some, .toolChoiceViolation(let message)): #expect(message.contains("Inkling"))
                default: Issue.record("unexpected refusal \(error)")
                }
            }
            #expect(router.hasNativeToolFailure)
            #expect(router.inklingToolFailure == .wrongShape)
        }
    }

    /// A call frame cut off by the output limit is no failure at a cut;
    /// at a stop it is.
    @Test func unterminatedFrameFailsOnlyWithoutACut() throws {
        let open = #"<|message_model|>get_weather<|content_invoke_tool_json|>{"name":"get_weather","args":{"loc"#
        let (_, prepared) = try Self.prepared(clientStreams: false)
        var cut = Self.router(prepared, streams: false)
        _ = try cut.process(Self.thought + open)
        cut.outputReachedTokenLimit()
        #expect(try cut.finishText(cutAtLimit: true).isEmpty)
        #expect(cut.hasNativeToolFailure)
        #expect(try cut.finishCompleteCalls(truncated: true, cutAtLimit: true).calls.isEmpty)

        var stopped = Self.router(prepared, streams: false)
        _ = try stopped.process(Self.thought + open)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) { _ = try stopped.finishText() }
    }

    /// Declined thinking: classified like visible reasoning, counted, never sent.
    @Test func withheldReasoningNeverLeaves() throws {
        let (_, prepared) = try Self.prepared(clientStreams: false)
        var router = Self.router(prepared, streams: false, withhold: true)
        let routed = Routed(try Self.feed(&router,
            Self.thought + "<|message_model|><|content_text|>Sunny.<|end_message|>", width: 2))
        #expect(routed.reasoning.isEmpty)
        #expect(routed.content == "Sunny.")
        #expect(router.takeWithheldReasoning() == "Need the weather.")
    }

    /// `parallel_tool_calls: false` returns the first call; later ones are
    /// dropped (`ParallelToolCallPolicy`), streamed or held to the end.
    @Test func disabledParallelismKeepsTheFirstCall() throws {
        let (_, streamed) = try Self.prepared(parallel: false)
        var router = Self.router(streamed, streams: true)
        #expect(Routed(try router.process(Self.call)).deltas.count == 1)
        #expect(Routed(try router.process(Self.call)).deltas.isEmpty)
        #expect(router.completedToolCalls.count == 1)

        let (_, held) = try Self.prepared(parallel: false, clientStreams: false)
        var holding = Self.router(held, streams: false)
        _ = try Self.feed(&holding, Self.call + Self.call, width: 9)
        let calls = try holding.finishCompleteCalls(truncated: false).calls
        #expect(ParallelToolCallPolicy.admitted(calls, prepared: held).count == 1)
    }

    /// The tool handler is Inkling's own channel reader: no SDK text parser
    /// reads its output, for any choice that is valid for it.
    @Test func noTextToolParserIsMade() throws {
        for choice in [nil, OpenAIToolChoice.mode(.required), .function(name: "get_weather"), .mode(.none)] {
            let (request, prepared) = try Self.prepared(choice)
            #expect(try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
                modelType: Self.type) == nil)
        }
    }

    // MARK: - No `tools` field (#200 `tools-described-no-tools-field`)

    /// A request that describes a tool in its prompt but sends no `tools`:
    /// the template renders no `tool_declare`, and its calls never stream.
    static func preparedWithoutTools(clientStreams: Bool) throws -> ToolChoicePromptPolicy.Prepared {
        var request = OpenAIChatCompletionRequest(
            model: "thinkingmachines/Inkling-2-Mini",
            messages: [
                .init(role: .system, content: .text("You can call the function get_weather(city: string) by replying "
                    + #"with a JSON tool call {"name": "get_weather", "arguments": {"city": ...}}."#)),
                .init(role: .user, content: .text("What is the weather in Paris? Use the tool.")),
            ],
            stream: clientStreams, streamOptions: clientStreams ? .init(includeUsage: true) : nil)
        request.streamToolCallDeltas = clientStreams
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: type)
        #expect(prepared.mode == .auto)
        #expect(prepared.tools == nil)
        #expect(!ToolStreamPreparation.streamsInklingCalls(request: request, prepared: prepared))
        return prepared
    }

    /// Frames the model writes when no tool is declared, and the text each
    /// one answers with: a call in the template's shape, the shape the prompt
    /// asked for (`arguments`, which does not parse as Inkling's call), and
    /// arguments alone.
    static let undeclaredFrames: [(frame: String, text: String)] = [
        (call, #"{"name":"get_weather","args":{"location":"Paris"}}"#),
        (#"<|message_model|>get_weather<|content_invoke_tool_json|>{"name":"get_weather","arguments":{"city":"Paris"}}<|end_message|>"#,
         #"{"name":"get_weather","arguments":{"city":"Paris"}}"#),
        (#"<|content_invoke_tool_json|>{"city":"Paris"}<|end_message|>"#, #"{"city":"Paris"}"#),
    ]

    /// No call can be valid without declared tools, so a call frame is the
    /// answer's text, streamed or not: never a 422 `undeclared_name` nor a
    /// 500 `generation_failure` (#200).
    @Test func callFrameWithoutToolsIsAnswerText() throws {
        for (frame, text) in Self.undeclaredFrames {
            for clientStreams in [false, true] {
                let prepared = try Self.preparedWithoutTools(clientStreams: clientStreams)
                for width in [1, 7, 4096] {
                    var router = Self.router(prepared, streams: false)
                    let routed = Routed(try Self.feed(&router,
                        Self.thought + frame + "<|content_model_end_sampling|>", width: width))
                    #expect(routed.reasoning == "Need the weather.")
                    #expect(routed.content == text)
                    #expect(routed.deltas.isEmpty)
                    #expect(!router.hasNativeToolFailure)
                    var calls = try router.finishCompleteCalls(truncated: false).calls
                    #expect(calls.isEmpty)
                    try ToolConstraintValidation.validateWithheld(&calls, prepared: prepared, cutAtLimit: false)
                }
            }
        }
    }

    /// A frame a stop token ends before it closes is text too.
    @Test func openCallFrameWithoutToolsIsAnswerText() throws {
        let prepared = try Self.preparedWithoutTools(clientStreams: false)
        var router = Self.router(prepared, streams: false)
        let routed = Routed(try Self.feed(&router,
            Self.thought + #"<|message_model|>get_weather<|content_invoke_tool_json|>{"name":"get_weather","args":{"loc"#,
            width: 3))
        #expect(routed.content == #"{"name":"get_weather","args":{"loc"#)
        #expect(!router.hasNativeToolFailure)
        #expect(try router.finishCompleteCalls(truncated: false).calls.isEmpty)
    }

    /// Only `auto` without tools changes: `tool_choice: none` (its tools are
    /// not rendered either) still refuses a call, and declared tools keep
    /// their calls (above).
    @Test func noneStillRefusesACall() throws {
        let (_, prepared) = try Self.prepared(.mode(.none), clientStreams: false)
        #expect(prepared.tools == nil)
        var router = Self.router(prepared, streams: false)
        _ = try Self.feed(&router, Self.call, width: 4096)
        var calls = try router.finishCompleteCalls(truncated: false).calls
        #expect(calls.count == 1)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validateWithheld(&calls, prepared: prepared, cutAtLimit: false)
        }
    }

    /// `DARKBLOOM_INKLING_UNDECLARED_CALL_TEXT=0` restores D2 (19b0784d69):
    /// a call that parses is refused as undeclared (422), one that does not
    /// fails generation (500). This is the #200 failure.
    @Test func switchOffRestoresTheRefusals() throws {
        #expect(Inkling2OutputChannels.undeclaredCallTextEnvironmentKey == "DARKBLOOM_INKLING_UNDECLARED_CALL_TEXT")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(Inkling2OutputChannels.undeclaredCallTextEnvironmentKey))
        let prepared = try Self.preparedWithoutTools(clientStreams: false)

        var parsed = Self.router(prepared, streams: false, undeclaredCallsAreText: false)
        _ = try Self.feed(&parsed, Self.thought + Self.undeclaredFrames[0].frame, width: 4096)
        var calls = try parsed.finishCompleteCalls(truncated: false).calls
        #expect(calls.map(\.function.name) == ["get_weather"])
        do {
            try ToolConstraintValidation.validateWithheld(&calls, prepared: prepared, cutAtLimit: false)
            Issue.record("an undeclared call was accepted")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .toolChoiceViolation(let message) = error else { Issue.record("unexpected \(error)"); return }
            #expect(message == ToolNoncomplianceCheck.undeclaredNameViolation)
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 422)
        }

        var unparsed = Self.router(prepared, streams: false, undeclaredCallsAreText: false)
        do {
            _ = try Self.feed(&unparsed, Self.thought + Self.undeclaredFrames[1].frame, width: 4096)
            Issue.record("an unparsed frame was accepted")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .generationFailed(let message) = error else { Issue.record("unexpected \(error)"); return }
            #expect(message.contains("Inkling"))
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 500)
        }
        #expect(unparsed.inklingToolFailure == .wrongShape)
    }
}
