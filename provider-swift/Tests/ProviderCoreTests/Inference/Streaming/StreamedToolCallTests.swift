import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// `auto` tool calls leave as OpenAI `tool_calls` fragments while they are
/// generated, so a tool-call-first response's first content frame is the call
/// name, not the engine terminal.
@Suite("Streamed auto tool calls")
struct StreamedToolCallTests {
    private static let tools = """
        [{"type":"function","function":{"name":"get_weather","parameters":{"type":"object",
          "properties":{"location":{"type":"string"},"unit":{"type":"string","enum":["celsius","fahrenheit"]},
          "days":{"type":"integer"}},"required":["location"]}}},
         {"type":"function","function":{"name":"write_file","parameters":{"type":"object",
          "properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}}]
        """

    /// `strict` marks every declared function `strict: true`, which keeps
    /// automatic calls validated.
    private static func request(
        _ choice: OpenAIToolChoice? = nil, parallel: Bool? = nil, deltas: Bool = true, strict: Bool = false
    ) throws -> OpenAIChatCompletionRequest {
        var request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: .user, content: .text("Weather in Paris?"))],
            tools: try JSONDecoder().decode([OpenAITool].self, from: Data(tools.utf8)).map { tool in
                var tool = tool
                if strict { tool.function.strict = true }
                return tool
            },
            toolChoice: choice, parallelToolCalls: parallel, stream: true,
            streamOptions: .init(includeUsage: true))
        request.streamToolCallDeltas = deltas
        return request
    }

    /// `harmonyAutoToolGrammar`: `DARKBLOOM_HARMONY_AUTO_TOOL_GRAMMAR` as
    /// read at launch, unless a test sets it. `streamToolCalls: false` keeps
    /// the complete-call path. `strictCallsAsGenerated`: `StrictToolCallPolicy`.
    private static func router(
        _ request: OpenAIChatCompletionRequest, modelType: String = "gemma4",
        harmonyAutoToolGrammar: Bool = GPTOSSAutoToolGrammar.enabled, streamToolCalls: Bool = true,
        strictCallsAsGenerated: Bool = false
    ) throws -> NativeToolStreamRouter {
        var prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
        prepared.strictCallsAsGenerated = strictCallsAsGenerated
        let handler = try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: modelType, streamToolCalls: streamToolCalls)
        #expect(handler?.streamsCalls == streamToolCalls)
        return NativeToolStreamRouter(handler: handler, requiresToolCall: false, nativePrefix: nil,
            streamedCalls: prepared, harmonyAutoToolGrammar: harmonyAutoToolGrammar)
    }

    private static func gemmaCall(_ arguments: String, name: String = "get_weather") -> String {
        "<|tool_call>call:\(name){\(arguments)}<tool_call|>"
    }

    private static func characters(_ text: String) -> [String] { text.map(String.init) }

    private static func deltas(_ events: [MLXServerGenerationEvent]) -> [ServerToolCallDelta] {
        events.compactMap { if case .toolCallDelta(let delta) = $0 { delta } else { nil } }
    }

    // MARK: - Eligibility

    @Test func onlyAutoChatStreamsExposeCallsEarly() throws {
        func streams(_ request: OpenAIChatCompletionRequest, modelType: String = "gemma4",
                     enabled: Bool = true) throws -> Bool {
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
            return try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
                modelType: modelType, streamToolCalls: enabled)?.streamsCalls == true
        }
        #expect(try streams(Self.request()))
        #expect(try streams(Self.request(.mode(.auto)), modelType: "qwen3_5"))
        #expect(try streams(Self.request(), modelType: "gpt_oss"))
        // Qwen3-VL resolves to the framed-JSON format.
        #expect(try streams(Self.request(), modelType: "qwen3_vl_moe"))
        // Forced calls stream to a client that streams on Gemma 4 (grammar-
        // constrained), Qwen 3.5–3.8 (prompt-forced, checked when each frame
        // closes) and GPT-OSS (Harmony-framed by the sampler); a client that
        // does not stream keeps validate-then-expose.
        var whole = try Self.request(.mode(.required))
        whole.stream = false
        for modelType in ["gemma4", "qwen3_5", "qwen3_5_moe", "gpt_oss"] {
            #expect(try streams(Self.request(.mode(.required)), modelType: modelType), "\(modelType)")
            #expect(try streams(Self.request(.function(name: "get_weather")), modelType: modelType), "\(modelType)")
            #expect(try !streams(whole, modelType: modelType), "\(modelType)")
        }
        // Qwen's XML function parser has no incremental argument renderer:
        // its forced calls stay complete.
        var xml = try Self.request(.mode(.required))
        xml.toolCallParser = "xml_function"
        #expect(try ToolStreamPreparation.makeHandler(request: xml,
            prepared: ToolChoicePromptPolicy.prepare(xml, modelType: "qwen3_5"), modelType: "qwen3_5") != nil)
        #expect(try !streams(xml, modelType: "qwen3_5"))
        // Each family's switch withholds its forced calls again, the forced
        // switch every family's; auto calls are unchanged.
        func streamsForced(_ request: OpenAIChatCompletionRequest, modelType: String = "gemma4",
                           _ forced: ToolStreamPreparation.ForcedCalls) throws -> Bool {
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
            return try ToolStreamPreparation.makeHandler(request: request, prepared: prepared, modelType: modelType,
                streamToolCalls: true, streamForcedToolCalls: forced)?.streamsCalls == true
        }
        let families: [(modelType: String, off: ToolStreamPreparation.ForcedCalls)] = [
            ("gemma4", .init(gemma: false)), ("qwen3_5", .init(qwen: false)), ("qwen3_5_moe", .init(qwen: false)),
            ("gpt_oss", .init(gptOSS: false)),
        ]
        for (modelType, off) in families {
            #expect(try !streamsForced(Self.request(.mode(.required)), modelType: modelType, off), "\(modelType)")
            #expect(try !streamsForced(Self.request(.mode(.required)), modelType: modelType, .none), "\(modelType)")
            #expect(try streamsForced(Self.request(), modelType: modelType, .none), "\(modelType)")
            for (other, otherOff) in families where other != modelType && otherOff != off {
                #expect(try streamsForced(Self.request(.mode(.required)), modelType: modelType, otherOff),
                    "\(modelType) under \(other)'s switch")
            }
        }
        #expect(ToolStreamPreparation.streamForcedToolCallsEnvironmentKey == "DARKBLOOM_TTFT_STREAM_FORCED_TOOL_CALLS")
        #expect(ToolStreamPreparation.streamForcedQwenToolCallsEnvironmentKey
            == "DARKBLOOM_TTFT_STREAM_FORCED_QWEN_TOOL_CALLS")
        #expect(ToolStreamPreparation.streamForcedGPTOSSToolCallsEnvironmentKey
            == "DARKBLOOM_TTFT_STREAM_FORCED_GPTOSS_TOOL_CALLS")
        for off in ["0", "off", "false", "no", " OFF "] {
            #expect(!ToolStreamPreparation.streamsForcedToolCalls(
                environment: [ToolStreamPreparation.streamForcedToolCallsEnvironmentKey: off]))
            #expect(ToolStreamPreparation.ForcedCalls(
                environment: [ToolStreamPreparation.streamForcedToolCallsEnvironmentKey: off]) == .none)
            #expect(ToolStreamPreparation.ForcedCalls(
                environment: [ToolStreamPreparation.streamForcedQwenToolCallsEnvironmentKey: off]) == .init(qwen: false))
            #expect(ToolStreamPreparation.ForcedCalls(
                environment: [ToolStreamPreparation.streamForcedGPTOSSToolCallsEnvironmentKey: off])
                == .init(gptOSS: false))
        }
        #expect(ToolStreamPreparation.streamsForcedToolCalls(environment: [:]))
        #expect(ToolStreamPreparation.ForcedCalls(environment: [:]) == .all)
        #expect(ToolStreamPreparation.ForcedCalls(environment: [
            ToolStreamPreparation.streamForcedQwenToolCallsEnvironmentKey: "1",
            ToolStreamPreparation.streamForcedGPTOSSToolCallsEnvironmentKey: "on"]) == .all)
        // Surfaces that do not render fragments, and the kill switch.
        #expect(try !streams(Self.request(deltas: false)))
        #expect(try !streams(Self.request(), enabled: false))
        // Native channel families keep their own withheld framing.
        #expect(try !streams(Self.request(), modelType: "nemotron_h"))
        #expect(ToolStreamPreparation.streamToolCallsEnvironmentKey == "DARKBLOOM_TTFT_STREAM_TOOL_CALLS")
    }

    /// Both behaviors are on by default; each rollback only works if it
    /// reaches the launchd-managed provider job.
    @Test func rollbacksReachTheProviderJob() {
        let keys = [ToolStreamPreparation.streamToolCallsEnvironmentKey,
                    ToolStreamPreparation.streamForcedToolCallsEnvironmentKey,
                    ToolStreamPreparation.streamForcedQwenToolCallsEnvironmentKey,
                    ToolStreamPreparation.streamForcedGPTOSSToolCallsEnvironmentKey,
                    ReasoningPromptProbe.plainTailContentSeedEnvironmentKey]
        #expect(keys.allSatisfy { LaunchAgent.inferencePassthroughEnvKeys.contains($0) })
        let rollback = Dictionary(uniqueKeysWithValues: keys.map { ($0, "0") })
        #expect(LaunchAgent.passthroughEnvironment(from: rollback.merging(["UNRELATED": "x"]) { a, _ in a })
            == rollback)
    }

    // MARK: - Router

    @Test func gemmaCallStreamsNameFirstThenArguments() throws {
        let text = Self.gemmaCall(#"location:<|"|>Paris, France<|"|>,unit:<|"|>celsius<|"|>"#)
        var router = try Self.router(Self.request())
        var events: [[MLXServerGenerationEvent]] = []
        for character in Self.characters(text) { events.append(try router.process(character)) }
        events.append(try router.finishText())
        events.append(try router.finishToolCalls(truncated: false))
        let flat = events.flatMap { $0 }
        let deltas = Self.deltas(flat)
        #expect(flat.count == deltas.count, "no visible text around the call")
        // The name is exposed as soon as `{` fixes it, long before the frame closes.
        let nameStep = try #require(events.firstIndex { Self.deltas($0).contains { $0.name != nil } })
        #expect(nameStep == Self.characters("<|tool_call>call:get_weather{").count - 1)
        #expect(deltas.first?.name == "get_weather")
        #expect(deltas.allSatisfy { $0.index == 0 })
        #expect(deltas.dropLast().allSatisfy { $0.completed == nil })
        let completed = try #require(deltas.last?.completed)
        let arguments = deltas.map(\.arguments).joined()
        #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(arguments.utf8))
            == completed.function.arguments)
        #expect(router.completedToolCalls == [completed])
    }

    /// Unconstrained Gemma output sometimes drops a string's markers; the
    /// complete parse then reads every value as a raw string. A typed value
    /// exposed before that point would contradict the parse, so only marker
    /// strings stream and this call completes instead of diverging.
    @Test func gemmaCallLeavingTheStrictGrammarStillCompletes() throws {
        var request = try Self.request()
        request.tools = try JSONDecoder().decode([OpenAITool].self, from: Data("""
            [{"type":"function","function":{"name":"get_weather","parameters":{"type":"object",
              "properties":{"days":{},"location":{"type":"string"},"unit":{"type":"string"}}}}}]
            """.utf8))
        var router = try Self.router(request)
        var events: [MLXServerGenerationEvent] = []
        for character in Self.characters(Self.gemmaCall(#"days:3,location:Paris,unit:<|"|>celsius<|"|>"#)) {
            events += try router.process(character)
        }
        events += try router.finishText()
        events += try router.finishToolCalls(truncated: false)
        let deltas = Self.deltas(events)
        #expect(deltas.first?.name == "get_weather")
        let completed = try #require(deltas.last?.completed)
        #expect(completed.function.arguments
            == ["days": .string("3"), "location": .string("Paris"), "unit": .string("celsius")])
        let arguments = deltas.map(\.arguments).joined()
        #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(arguments.utf8))
            == completed.function.arguments)
    }

    @Test func strictSchemaViolationIsRefusedWhenTheFrameCloses() throws {
        var router = try Self.router(Self.request(strict: true))
        let text = Self.gemmaCall(#"location:<|"|>Paris<|"|>,unit:<|"|>kelvin<|"|>"#)
        var thrown: Error?
        var exposed: [ServerToolCallDelta] = []
        for character in Self.characters(text) {
            do { exposed += Self.deltas(try router.process(character)) } catch { thrown = error; break }
        }
        #expect(exposed.first?.name == "get_weather")
        #expect(exposed.allSatisfy { $0.completed == nil })
        guard case .toolChoiceViolation? = thrown as? MultiModelBatchSchedulerEngineError else {
            Issue.record("expected a tool_choice violation, got \(String(describing: thrown))"); return
        }
    }

    @Test func undeclaredCallIsNeverExposed() throws {
        // Gemma's parser rejects undeclared names itself: historical text fallback.
        var gemma = try Self.router(Self.request())
        let gemmaText = Self.gemmaCall(#"path:<|"|>/<|"|>"#, name: "delete_everything")
        var events: [MLXServerGenerationEvent] = []
        for character in Self.characters(gemmaText) { events += try gemma.process(character) }
        #expect(Self.deltas(events).isEmpty)
        #expect(events.compactMap { if case .content(let text) = $0 { text } else { nil } }.joined() == gemmaText)

        // Harmony parses any name: under `strict` the call completes
        // unexposed and fails validation.
        var harmony = try Self.router(Self.request(strict: true), modelType: "gpt_oss")
        let harmonyText = "<|start|>assistant to=functions.delete_everything<|channel|>commentary json"
            + #"<|message|>{"path":"/"}<|call|>"#
        var exposed: [ServerToolCallDelta] = []
        var thrown: Error?
        for character in Self.characters(harmonyText) {
            do { exposed += Self.deltas(try harmony.process(character)) } catch { thrown = error; break }
        }
        #expect(exposed.isEmpty)
        guard case .toolChoiceViolation? = thrown as? MultiModelBatchSchedulerEngineError else {
            Issue.record("expected a tool_choice violation, got \(String(describing: thrown))"); return
        }
        let refusal = try #require(thrown)
        #expect(classifyToolNoncomplianceCheck(refusal) == .undeclaredName)

        // Without `strict` it is refused the same way while the GPT-OSS `auto`
        // grammar is on (`undeclaredHarmonyCallsAreRefused`); with it off it
        // leaves in one piece, as generated (`killSwitchReturnsUndeclaredCallsAsGenerated`).
    }

    private static let undeclaredHarmonyCall = "<|start|>assistant to=functions.delete_everything"
        + #"<|channel|>commentary json<|message|>{"path":"/"}<|call|>"#

    /// Feeds `text` one character at a time, then ends the stream (streamed
    /// calls) or flushes the complete calls. The events before any error, and the error.
    private static func run(_ router: inout NativeToolStreamRouter, _ text: String, streamed: Bool)
        -> (events: [MLXServerGenerationEvent], calls: [ToolCall], error: Error?)
    {
        var events: [MLXServerGenerationEvent] = []
        var calls: [ToolCall] = []
        do {
            for character in characters(text) { events += try router.process(character) }
            events += try router.finishText()
            if streamed {
                events += try router.finishToolCalls(truncated: false)
            } else {
                calls = try router.finishCompleteCalls(truncated: false).calls
            }
        } catch { return (events, calls, error) }
        return (events, calls, nil)
    }

    /// A GPT-OSS `auto` call to an undeclared function, where the grammar did
    /// not prevent it (a cluster pair, a native engine, a declined request),
    /// is refused as `strict` refuses it: never returned, never text. Both
    /// paths, and a `strict` request after its response started.
    @Test func undeclaredHarmonyCallsAreRefused() throws {
        let cases: [(request: OpenAIChatCompletionRequest, streamed: Bool, started: Bool)] = [
            (try Self.request(), true, false),
            (try Self.request(), false, false),
            (try Self.request(), true, true),
            (try Self.request(strict: true), true, true),
            (try Self.request(strict: true), false, true),
        ]
        for (request, streamed, started) in cases {
            var router = try Self.router(request, modelType: "gpt_oss", harmonyAutoToolGrammar: true,
                streamToolCalls: streamed, strictCallsAsGenerated: true)
            router.responseStarted = started
            let run = Self.run(&router, Self.undeclaredHarmonyCall, streamed: streamed)
            let label = "streamed \(streamed), started \(started)"
            #expect(Self.deltas(run.events).isEmpty && run.calls.isEmpty, "\(label)")
            let text = run.events.compactMap { if case .content(let text) = $0 { text } else { nil } }.joined()
            #expect(!text.contains("delete_everything"), "\(label)")
            guard case .toolChoiceViolation? = run.error as? MultiModelBatchSchedulerEngineError else {
                Issue.record("\(label): expected a tool_choice violation, got \(String(describing: run.error))")
                continue
            }
            #expect(classifyToolNoncomplianceCheck(try #require(run.error)) == .undeclaredName, "\(label)")
            #expect(router.strictCallsReturnedAsGenerated == 0, "\(label)")
        }
        // A declared call is unchanged.
        for streamed in [true, false] {
            var router = try Self.router(Self.request(), modelType: "gpt_oss", harmonyAutoToolGrammar: true,
                streamToolCalls: streamed)
            let run = Self.run(&router, "<|start|>assistant to=functions.write_file<|channel|>commentary json"
                + #"<|message|>{"path":"a"}<|call|>"#, streamed: streamed)
            #expect(run.error == nil, "\(String(describing: run.error))")
            let names = streamed ? Self.deltas(run.events).compactMap(\.name) : run.calls.map(\.function.name)
            #expect(names == ["write_file"])
        }
    }

    /// `DARKBLOOM_HARMONY_AUTO_TOOL_GRAMMAR` off restores calls as generated,
    /// an undeclared one included, on both paths.
    @Test func killSwitchReturnsUndeclaredCallsAsGenerated() throws {
        for streamed in [true, false] {
            var router = try Self.router(Self.request(), modelType: "gpt_oss", harmonyAutoToolGrammar: false,
                streamToolCalls: streamed)
            let run = Self.run(&router, Self.undeclaredHarmonyCall, streamed: streamed)
            #expect(run.error == nil, "\(String(describing: run.error))")
            if streamed {
                let call = try #require(Self.deltas(run.events).first)
                #expect(Self.deltas(run.events).count == 1)
                #expect(call.name == "delete_everything")
                #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(call.arguments.utf8))
                    == ["path": .string("/")])
                #expect(call.completed?.function.name == "delete_everything")
            } else {
                #expect(run.calls.map(\.function.name) == ["delete_everything"])
                #expect(run.calls.first?.function.arguments == ["path": .string("/")])
            }
        }
    }

    /// `parallel_tool_calls: false` returns the first call, as OpenAI and vLLM
    /// do. The calls the model makes after it, valid or not, are consumed and
    /// dropped; none fails the stream after the first call already left.
    @Test func laterCallsAreDroppedWhenParallelCallsAreDisabled() throws {
        for strict in [false, true] {
            let request = try Self.request(parallel: false, strict: strict)
            var router = try Self.router(request)
            let text = Self.gemmaCall(#"location:<|"|>Paris<|"|>"#)
                + Self.gemmaCall(#"location:<|"|>Rome<|"|>,days:3"#)
                + Self.gemmaCall(#"path:<|"|>a.py<|"|>,content:<|"|>x<|"|>"#, name: "write_file")
                // Off the schema: `strict` would refuse it if it were returned.
                + Self.gemmaCall(#"location:<|"|>Oslo<|"|>,unit:<|"|>kelvin<|"|>"#)
            var events: [MLXServerGenerationEvent] = []
            for character in Self.characters(text) { events += try router.process(character) }
            events += try router.finishText()
            events += try router.finishToolCalls(truncated: false)
            let deltas = Self.deltas(events)
            #expect(events.count == deltas.count, "strict \(strict): no visible text from a dropped frame")
            #expect(deltas.allSatisfy { $0.index == 0 }, "strict \(strict)")
            #expect(deltas.compactMap(\.name) == ["get_weather"], "strict \(strict)")
            #expect(deltas.compactMap(\.completed).map(\.function.arguments) == [["location": .string("Paris")]],
                "strict \(strict)")
            #expect(router.completedToolCalls.map(\.function.arguments) == [["location": .string("Paris")]])
            try ToolConstraintValidation.validate(router.completedToolCalls,
                prepared: ToolChoicePromptPolicy.prepare(request, modelType: "gemma4"))
        }
    }

    /// A later call that completes without being exposed (Harmony parses an
    /// undeclared name, which `strict` refuses) is dropped too, before
    /// validation could refuse it.
    @Test func laterUnexposedCallIsDroppedUnvalidated() throws {
        var router = try Self.router(Self.request(parallel: false, strict: true), modelType: "gpt_oss")
        let text = "<|start|>assistant to=functions.get_weather<|channel|>commentary json"
            + #"<|message|>{"location":"Paris"}<|call|>"#
            + "<|start|>assistant to=functions.delete_everything<|channel|>commentary json"
            + #"<|message|>{"path":"/"}<|call|>"#
        var events: [MLXServerGenerationEvent] = []
        for character in Self.characters(text) { events += try router.process(character) }
        events += try router.finishText()
        events += try router.finishToolCalls(truncated: false)
        #expect(Self.deltas(events).compactMap(\.completed).map(\.function.name) == ["get_weather"])
        #expect(router.completedToolCalls.map(\.function.name) == ["get_weather"])
    }

    /// The complete-call paths (native channel families, required/named,
    /// surfaces that take calls in one piece, Nemotron Super's owner) keep
    /// the first call the same way.
    @Test func completeCallPathsKeepTheFirstCall() throws {
        let first = ToolCall(function: .init(name: "get_weather", arguments: ["location": "Paris"]))
        let second = ToolCall(function: .init(name: "get_weather", arguments: ["location": "Rome"]))
        for choice in [nil, OpenAIToolChoice.mode(.required), .function(name: "get_weather")] {
            let single = try ToolChoicePromptPolicy.prepare(Self.request(choice, parallel: false), modelType: "gemma4")
            let admitted = ParallelToolCallPolicy.admitted([first, second], prepared: single)
            #expect(admitted == [first])
            try ToolConstraintValidation.validate(admitted, prepared: single)
            let parallel = try ToolChoicePromptPolicy.prepare(Self.request(choice), modelType: "gemma4")
            #expect(ParallelToolCallPolicy.admitted([first, second], prepared: parallel) == [first, second])
        }
        let none = try ToolChoicePromptPolicy.prepare(Self.request(parallel: false), modelType: "gemma4")
        #expect(ParallelToolCallPolicy.admitted([], prepared: none).isEmpty)
    }

    /// A later frame that fails is dropped as quietly as one that parses: one
    /// that closes against what it streamed (a repeated key), one cut by the
    /// end of generation (unterminated or diverged), and one whose end tag is
    /// the stop token, at the token limit or not.
    @Test(arguments: [
        #"<|tool_call>call:get_weather{location:<|"|>Rome<|"|>,location:<|"|>Oslo<|"|>}<tool_call|>"#,
        #"<|tool_call>call:write_file{path:<|"|>a.py<|"|>,content:<|"|>print("#,
        #"<|tool_call>call:write_file{path:<|"|>a.py<|"|>,content:<|"|>def f(): return {"a": 1}"#,
        #"<|tool_call>call:get_weather{location:<|"|>Rome<|"|>}"#,
    ])
    func failedLaterFramesAreDroppedToo(later: String) throws {
        for strict in [false, true] {
            for truncated in [false, true] {
                var router = try Self.router(Self.request(parallel: false, strict: strict))
                var events: [MLXServerGenerationEvent] = []
                for character in Self.characters(Self.gemmaCall(#"location:<|"|>Paris<|"|>"#) + later) {
                    events += try router.process(character)
                }
                events += try router.finishText()
                events += try router.finishToolCalls(truncated: truncated)
                let deltas = Self.deltas(events)
                #expect(events.count == deltas.count, "strict \(strict) truncated \(truncated)")
                #expect(deltas.allSatisfy { $0.index == 0 }, "strict \(strict) truncated \(truncated)")
                #expect(deltas.compactMap(\.name) == ["get_weather"], "strict \(strict) truncated \(truncated)")
                #expect(router.completedToolCalls.map(\.function.arguments) == [["location": .string("Paris")]],
                    "strict \(strict) truncated \(truncated)")
            }
        }
    }

    /// At a cut that ends as `length` (`TokenLimitCutPolicy`) the same later
    /// frames are `parallel_tool_calls: false`'s to drop, as anywhere: nothing
    /// of them is exposed, and the cut counts none of them as its own.
    @Test(arguments: [
        #"<|tool_call>call:get_weather{location:<|"|>Rome<|"|>,location:<|"|>Oslo<|"|>}<tool_call|>"#,
        #"<|tool_call>call:write_file{path:<|"|>a.py<|"|>,content:<|"|>print("#,
        #"<|tool_call>call:write_file{path:<|"|>a.py<|"|>,content:<|"|>def f(): return {"a": 1}"#,
        #"<|tool_call>call:get_weather{location:<|"|>Rome<|"|>}"#,
    ])
    func laterFramesAtACutAreDroppedByTheFilterNotCounted(later: String) throws {
        var router = try Self.router(Self.request(parallel: false))
        var events: [MLXServerGenerationEvent] = []
        for character in Self.characters(Self.gemmaCall(#"location:<|"|>Paris<|"|>"#) + later) {
            events += try router.process(character)
        }
        events += try router.finishText(cutAtLimit: true)
        events += try router.finishToolCalls(truncated: true, cutAtLimit: true)
        let deltas = Self.deltas(events)
        #expect(deltas.allSatisfy { $0.index == 0 })
        #expect(deltas.compactMap(\.name) == ["get_weather"])
        #expect(router.completedToolCalls.map(\.function.arguments) == [["location": .string("Paris")]])
        #expect(router.callsDroppedAtCut == 0 && router.callsLeftOpenAtCut == 0)
    }

    /// The engine's complete-call terminal (here a forced choice, whose calls
    /// are withheld until generation ends) returns the first call as well.
    @Test func completeCallTerminalReturnsTheFirstCall() async throws {
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        let text = Self.gemmaCall(#"location:<|"|>Paris<|"|>"#) + Self.gemmaCall(#"location:<|"|>Rome<|"|>"#)
        for chunk in Self.characters(text) { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 9, completionTokens: 30, tokensPerSecond: 0,
            finishReason: nil))
        upstream.continuation.finish()
        var frames: [String] = []
        for try await frame in try await MLXOpenAIService(
            engine: RoutedEngine(upstream: upstream.stream, modelType: "gemma4")
        ).streamChatCompletionFrames(request: try Self.request(.mode(.required), parallel: false)) {
            frames.append(frame)
        }
        let parsed = frames.compactMap(ProviderLoop.parseStreamChunk)
        let deltas = parsed.flatMap { $0.toolCallsDelta ?? [] }
        #expect(deltas.allSatisfy { $0.index == 0 })
        #expect(deltas.compactMap { $0.function?.name } == ["get_weather"])
        let arguments = deltas.compactMap { $0.function?.arguments }.joined()
        #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(arguments.utf8))
            == ["location": .string("Paris")])
        #expect(parsed.contains { $0.finishReason == "tool_calls" })
    }

    /// The second partial holds a `}`, so Gemma's lenient EOS parse reads a
    /// garbled call that contradicts the exposed arguments.
    @Test(arguments: [
        #"<|tool_call>call:write_file{path:<|"|>a.py<|"|>,content:<|"|>print("#,
        #"<|tool_call>call:write_file{path:<|"|>a.py<|"|>,content:<|"|>def f(): return {"a": 1}"#,
    ])
    func truncatedCallEndsQuietlyOnlyAtTheTokenLimit(partial: String) throws {
        for strict in [false, true] {
            var lengthRouter = try Self.router(Self.request(strict: strict))
            for character in Self.characters(partial) { _ = try lengthRouter.process(character) }
            #expect(try lengthRouter.finishToolCalls(truncated: true).isEmpty)
            #expect(lengthRouter.completedToolCalls.isEmpty)
        }

        // Stopped inside the call before the limit, `strict` or not: refused
        // with its check, never closed with the arguments it streamed.
        for strict in [false, true] {
            var stopRouter = try Self.router(Self.request(strict: strict))
            var exposed: [ServerToolCallDelta] = []
            for character in Self.characters(partial) { exposed += Self.deltas(try stopRouter.process(character)) }
            #expect(exposed.first?.name == "write_file")
            #expect(exposed.allSatisfy { $0.completed == nil })
            do {
                _ = try stopRouter.finishToolCalls(truncated: false)
                Issue.record("strict \(strict): a call stopped inside must be refused")
            } catch {
                #expect(classifyToolNoncomplianceCheck(error) != nil, "strict \(strict)")
            }
            #expect(stopRouter.completedToolCalls.isEmpty, "a call that did not parse never counts as validated")
        }
    }

    // MARK: - GPT-OSS through the service

    /// `set_value.value` declares no type, so any JSON value is valid there;
    /// the ingress normalizer fills in `type: "string"` for the templates.
    private static let gptOSSBody = #"""
        {"model":"gpt-oss-20b","messages":[{"role":"user","content":"Store it."}],"stream":true,
         "tools":[{"type":"function","function":{"name":"set_value",STRICT"parameters":{"type":"object",
           "properties":{"value":{"description":"Any JSON value"}},"required":["value"]}}},
          {"type":"function","function":{"name":"write_file",STRICT"parameters":{"type":"object",
           "properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}}]}
        """#

    private static func harmonyCall(_ name: String, _ arguments: String) -> String {
        "<|channel|>analysis<|message|>Calling.<|end|>"
            + "<|start|>assistant<|channel|>commentary to=functions.\(name) <|constrain|>json"
            + "<|message|>" + arguments
    }

    /// One GPT-OSS chat stream: the generated text up to its `<|call|>` stop
    /// token, then the engine terminal. Frames sent before any error, and the error.
    private static func serveGPTOSS(_ text: String, strict: Bool) async throws
        -> (chunks: [ProviderLoop.StreamChunkExtract], error: Error?)
    {
        var request = try ProviderLoop.decodeOpenAIRequest(Data(gptOSSBody
            .replacingOccurrences(of: "STRICT", with: strict ? #""strict":true,"# : "").utf8))
        request.reasoningParser = .harmony
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        for chunk in Self.characters(text) { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 9, completionTokens: 30, tokensPerSecond: 0,
            finishReason: nil))
        upstream.continuation.finish()
        var frames: [String] = []
        do {
            for try await frame in try await MLXOpenAIService(
                engine: RoutedEngine(upstream: upstream.stream, modelType: "gpt_oss")
            ).streamChatCompletionFrames(request: request) {
                frames.append(frame)
            }
        } catch {
            return (frames.compactMap(ProviderLoop.parseStreamChunk), error)
        }
        return (frames.compactMap(ProviderLoop.parseStreamChunk), nil)
    }

    private static func streamedCall(_ chunks: [ProviderLoop.StreamChunkExtract]) -> (name: String?, arguments: String) {
        let deltas = chunks.flatMap { $0.toolCallsDelta ?? [] }
        return (deltas.compactMap { $0.function?.name }.first,
                deltas.compactMap { $0.function?.arguments }.joined())
    }

    /// Without `strict`, OpenAI and vLLM return GPT-OSS's call as generated:
    /// a value the normalizer's inferred type would refuse, arguments off the
    /// schema. A call to an undeclared function is refused while the GPT-OSS
    /// `auto` grammar is on (`undeclaredHarmonyCallsAreRefused`), and arguments
    /// that do not parse are refused (`gptOSSCallsThatDoNotParseAreRefused`).
    @Test(arguments: [
        ("set_value", #"{"value":42}"#),
        ("set_value", #"{"value":{"unit":"kg","amount":[1,2]}}"#),
        ("set_value", #"{"value":[1,"two",null]}"#),
        ("write_file", #"{"path":"fib.py"}"#),
        ("delete_everything", #"{"path":"/"}"#),
    ])
    func gptOSSAutoCallsReturnAsGenerated(name: String, arguments: String) async throws {
        let served = try await Self.serveGPTOSS(Self.harmonyCall(name, arguments), strict: false)
        let call = Self.streamedCall(served.chunks)
        if name == "delete_everything", GPTOSSAutoToolGrammar.enabled {
            // Never a call, never text: the typed refusal `strict` gets.
            #expect(call.name == nil && call.arguments.isEmpty)
            #expect(!served.chunks.contains { $0.finishReason == "tool_calls" })
            #expect(served.error.flatMap(classifyToolNoncomplianceCheck) == .undeclaredName,
                "\(String(describing: served.error))")
            return
        }
        #expect(served.error == nil, "\(String(describing: served.error))")
        #expect(call.name == name)
        #expect(call.arguments == arguments)
        #expect(served.chunks.contains { $0.finishReason == "tool_calls" })
    }

    /// A streamed call whose arguments do not parse when generation ends
    /// (cut short, or JSON followed by more text; the `<|call|>` stop token
    /// closes the frame, so both read as `unterminated`) is refused with its
    /// check, `strict` or not: its arguments are only what already left, and
    /// a `tool_calls` finish with arguments that do not parse is what
    /// OpenRouter counts against the endpoint (InvalidJson).
    @Test(arguments: [
        ("write_file", #"{"path":"fib.py","content":"print(1)""#, ToolNoncomplianceCheck.unterminated),
        ("write_file", #"{"path":"fib.py","content":"print(1)"}}"#, .unterminated),
    ])
    func gptOSSCallsThatDoNotParseAreRefused(name: String, arguments: String, check: ToolNoncomplianceCheck)
        async throws
    {
        for strict in [false, true] {
            let served = try await Self.serveGPTOSS(Self.harmonyCall(name, arguments), strict: strict)
            let error = try #require(served.error, "strict \(strict)")
            #expect(classifyToolNoncomplianceCheck(error) == check, "strict \(strict)")
            #expect(!served.chunks.contains { $0.finishReason != nil }, "strict \(strict)")
            #expect(Self.streamedCall(served.chunks).name == name, "strict \(strict): it had started streaming")
        }
    }

    /// One Qwen 3.5 chat stream (`get_weather`, `write_file`): the generated
    /// text, then the engine terminal. Frames sent before any error, and the error.
    private static func serveQwen(_ text: String, strict: Bool) async throws
        -> (chunks: [ProviderLoop.StreamChunkExtract], error: Error?)
    {
        var request = try Self.request(strict: strict)
        request.reasoningParser = .qwen3
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        for chunk in Self.characters(text) { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 9, completionTokens: 30, tokensPerSecond: 0,
            finishReason: nil))
        upstream.continuation.finish()
        var frames: [String] = []
        do {
            for try await frame in try await MLXOpenAIService(
                engine: RoutedEngine(upstream: upstream.stream, modelType: "qwen3_5")
            ).streamChatCompletionFrames(request: request) {
                frames.append(frame)
            }
        } catch {
            return (frames.compactMap(ProviderLoop.parseStreamChunk), error)
        }
        return (frames.compactMap(ProviderLoop.parseStreamChunk), nil)
    }

    /// A Qwen 3.5 XML call that fails after it started streaming: a repeated
    /// parameter with another value, text inside the frame, generation
    /// stopping inside a value. Each is refused with its check, `strict` or
    /// not; what already left never becomes a finished call.
    @Test(arguments: [
        ("<tool_call>\n<function=get_weather>\n<parameter=location>\nParis\n</parameter>\n"
            + "<parameter=location>\nRome\n</parameter>\n</function>\n</tool_call>", ToolNoncomplianceCheck.diverged),
        ("<tool_call>\n<function=get_weather>\n<parameter=location>\nParis\n</parameter>\n"
            + "oops</function>\n</tool_call>", .malformed),
        ("<tool_call>\n<function=write_file>\n<parameter=path>\nfib.py\n</parameter>\n"
            + "<parameter=content>\nprint(", .unterminated),
    ])
    func qwenCallsThatFailAfterStreamingAreRefused(text: String, check: ToolNoncomplianceCheck) async throws {
        for strict in [false, true] {
            let served = try await Self.serveQwen(text, strict: strict)
            let error = try #require(served.error, "strict \(strict)")
            #expect(classifyToolNoncomplianceCheck(error) == check, "strict \(strict)")
            #expect(!served.chunks.contains { $0.finishReason != nil }, "strict \(strict)")
            #expect(Self.streamedCall(served.chunks).name != nil, "strict \(strict): it had started streaming")
        }
    }

    /// `DARKBLOOM_REFUSE_FAILED_STREAMED_CALLS` off restores closing a failed
    /// call without `strict` with the arguments it sent.
    @Test func theSwitchOffClosesAFailedCallAsBefore() throws {
        let partial = "<tool_call>\n<function=write_file>\n<parameter=path>\nfib.py\n</parameter>\n"
            + "<parameter=content>\nprint("
        var router = try Self.router(Self.request(), modelType: "qwen3_5")
        router.refusesFailedStreamedCalls = false
        for character in Self.characters(partial) { _ = try router.process(character) }
        let closing = Self.deltas(try router.finishToolCalls(truncated: false))
        #expect(closing.count == 1 && closing.first?.completed != nil)
        #expect(router.completedToolCalls.isEmpty)
        // It still counts as a returned call that breaks the declaration.
        #expect(router.callsClosedUnparsed == 1)

        var strict = try Self.router(Self.request(strict: true), modelType: "qwen3_5")
        strict.refusesFailedStreamedCalls = false
        for character in Self.characters(partial) { _ = try strict.process(character) }
        #expect(throws: MultiModelBatchSchedulerEngineError.self) { _ = try strict.finishToolCalls(truncated: false) }
    }

    /// A repeated parameter with the same value reads as the streamed prefix
    /// (the parse keeps the last value), so the call completes.
    @Test func qwenRepeatedParameterWithTheSameValueCompletes() async throws {
        let text = "<tool_call>\n<function=get_weather>\n<parameter=location>\nParis\n</parameter>\n"
            + "<parameter=location>\nParis\n</parameter>\n</function>\n</tool_call>"
        let served = try await Self.serveQwen(text, strict: false)
        #expect(served.error == nil, "\(String(describing: served.error))")
        #expect(served.chunks.contains { $0.finishReason == "tool_calls" })
        #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self,
            from: Data(Self.streamedCall(served.chunks).arguments.utf8)) == ["location": .string("Paris")])
    }

    /// A Qwen 3.5 call that parses still streams and finishes `tool_calls`,
    /// and one the token limit cuts still ends `length`, open, unrefused.
    @Test func qwenCallsThatParseOrAreCutStillFinish() async throws {
        let complete = "<tool_call>\n<function=get_weather>\n<parameter=location>\nParis\n</parameter>\n"
            + "<parameter=days>\n3\n</parameter>\n</function>\n</tool_call>"
        let served = try await Self.serveQwen(complete, strict: false)
        #expect(served.error == nil, "\(String(describing: served.error))")
        #expect(served.chunks.contains { $0.finishReason == "tool_calls" })
        #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self,
            from: Data(Self.streamedCall(served.chunks).arguments.utf8))
            == ["location": .string("Paris"), "days": .int(3)])

        var router = try Self.router(Self.request(), modelType: "qwen3_5")
        for character in Self.characters("<tool_call>\n<function=write_file>\n<parameter=path>\nfib.py\n"
            + "</parameter>\n<parameter=content>\nprint(") {
            _ = try router.process(character)
        }
        #expect(try router.finishToolCalls(truncated: true, cutAtLimit: true).isEmpty)
        #expect(router.completedToolCalls.isEmpty && router.callsLeftOpenAtCut == 1)
    }

    /// `strict: true` keeps each a typed refusal that names its check
    /// (`AutoToolCallValidationTests` covers the typeless value under strict).
    @Test(arguments: [
        ("write_file", #"{"path":"fib.py"}"#, ToolNoncomplianceCheck.schema),
        ("write_file", #"{"path":"fib.py","content":"print(1)""#, .unterminated),
        ("delete_everything", #"{"path":"/"}"#, .undeclaredName),
    ])
    func gptOSSStrictCallsStayValidated(name: String, arguments: String, check: ToolNoncomplianceCheck)
        async throws
    {
        let served = try await Self.serveGPTOSS(Self.harmonyCall(name, arguments), strict: true)
        let error = try #require(served.error)
        #expect(classifyToolNoncomplianceCheck(error) == check)
        #expect(!served.chunks.contains { $0.finishReason != nil })
    }

    /// A turn without tools is unchanged: GPT-OSS's answer streams as content.
    @Test func gptOSSWithoutToolsIsUnchanged() async throws {
        var request = try ProviderLoop.decodeOpenAIRequest(Data(
            #"{"model":"gpt-oss-20b","messages":[{"role":"user","content":"Hi"}],"stream":true}"#.utf8))
        request.reasoningParser = .harmony
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        let text = "<|channel|>analysis<|message|>Greet.<|end|><|start|>assistant<|channel|>final<|message|>Hello!"
        for chunk in Self.characters(text) { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 9, completionTokens: 12, tokensPerSecond: 0,
            finishReason: nil))
        upstream.continuation.finish()
        var chunks: [ProviderLoop.StreamChunkExtract] = []
        for try await frame in try await MLXOpenAIService(
            engine: RoutedEngine(upstream: upstream.stream, modelType: "gpt_oss")
        ).streamChatCompletionFrames(request: request) {
            if let chunk = ProviderLoop.parseStreamChunk(frame) { chunks.append(chunk) }
        }
        #expect(chunks.compactMap(\.contentDelta).joined().contains("Hello!"))
        #expect(chunks.compactMap(\.reasoningDelta).joined().contains("Greet."))
        #expect(chunks.allSatisfy { $0.toolCallsDelta == nil })
        #expect(chunks.contains { $0.finishReason == "stop" })
    }

    // MARK: - Engine forwarder, service and provider frame parsing

    @Test func firstToolFrameLeavesBeforeTheEngineTerminal() async throws {
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        let service = MLXOpenAIService(engine: RoutedEngine(upstream: upstream.stream, modelType: "gemma4"))
        let log = FrameLog()
        var request = try Self.request()
        request.streamToolCallDeltas = false // set by the service itself
        let frames = try await service.streamChatCompletionFrames(request: request)
        let reader = Task {
            for try await frame in frames { await log.append(frame) }
        }
        let text = Self.gemmaCall(#"location:<|"|>Paris<|"|>,days:3"#)
        let head = Self.characters("<|tool_call>call:get_weather{location:<|\"|>Pa")
        for chunk in head { upstream.continuation.yield(.chunk(chunk)) }
        // Nothing past the open string has been generated yet.
        #expect(await log.waitForToolFrame(), "the call name must reach the wire before the frame closes")
        for chunk in Self.characters(text).dropFirst(head.count) { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 40, completionTokens: 21, tokensPerSecond: 0,
            finishReason: nil))
        upstream.continuation.finish()
        try await reader.value

        let parsed = await log.frames.compactMap(ProviderLoop.parseStreamChunk)
        let toolFrames = parsed.filter { $0.toolCallsDelta != nil }
        #expect(toolFrames.count > 2, "every fragment parses as a provider content frame")
        // Coordinator reconstruction: index-keyed, id/name from the first fragment.
        var accumulated: [Int: (id: String, name: String, arguments: String)] = [:]
        for delta in toolFrames.flatMap({ $0.toolCallsDelta ?? [] }) {
            let index = try #require(delta.index)
            var call = accumulated[index] ?? ("", "", "")
            if let id = delta.id { call.id = id }
            if let name = delta.function?.name { call.name = name }
            call.arguments += delta.function?.arguments ?? ""
            accumulated[index] = call
        }
        let call = try #require(accumulated[0])
        #expect(accumulated.count == 1)
        #expect(call.name == "get_weather" && call.id.hasPrefix("call_"))
        #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(call.arguments.utf8))
            == ["location": .string("Paris"), "days": .int(3)])
        #expect(parsed.contains { $0.finishReason == "tool_calls" })
        #expect(parsed.contains { $0.usage?.completionTokens == 21 })
    }

    /// A forced (`required` or named) Gemma call held its whole
    /// answer back until generation ended, so a long one missed the
    /// coordinator's first-content deadline. Its name must reach the wire
    /// while the arguments are still being generated, and the call a client
    /// rebuilds from the fragments is the one the complete-call path returned.
    @Test(arguments: [OpenAIToolChoice.mode(.required), .function(name: "write_file")])
    func forcedGemmaCallsReachTheWireBeforeTheirFrameCloses(choice: OpenAIToolChoice) async throws {
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        let service = MLXOpenAIService(engine: RoutedEngine(upstream: upstream.stream, modelType: "gemma4"))
        let log = FrameLog()
        var request = try Self.request(choice)
        request.streamToolCallDeltas = false // set by the service itself
        let frames = try await service.streamChatCompletionFrames(request: request)
        let reader = Task {
            for try await frame in frames { await log.append(frame) }
        }
        let content = String(repeating: "print('long answer')\n", count: 40)
        let text = Self.gemmaCall(#"path:<|"|>long.py<|"|>,content:<|"|>"# + content + #"<|"|>"#, name: "write_file")
        let head = Self.characters(#"<|tool_call>call:write_file{path:<|"|>long.py<|"|>,content:<|"|>print("#)
        for chunk in head { upstream.continuation.yield(.chunk(chunk)) }
        // Most of the answer has not been generated yet.
        #expect(await log.waitForToolFrame(), "a forced call's first content must leave before the frame closes")
        for chunk in Self.characters(text).dropFirst(head.count) { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 40, completionTokens: 300, tokensPerSecond: 0,
            finishReason: nil))
        upstream.continuation.finish()
        try await reader.value

        let parsed = await log.frames.compactMap(ProviderLoop.parseStreamChunk)
        let call = Self.streamedCall(parsed)
        #expect(call.name == "write_file")
        #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(call.arguments.utf8))
            == ["path": .string("long.py"), "content": .string(content)])
        #expect(parsed.contains { $0.finishReason == "tool_calls" })
        #expect(!parsed.contains { $0.contentDelta?.isEmpty == false }, "a forced answer shows no text")
    }

    /// One forced Gemma response through the service: frames, and the error.
    private static func serveForcedGemma(_ text: String, choice: OpenAIToolChoice = .mode(.required),
                                         clientStreams: Bool = true, finishReason: String? = nil,
                                         parallel: Bool? = nil) async throws
        -> (chunks: [ProviderLoop.StreamChunkExtract], error: Error?)
    {
        var request = try Self.request(choice, parallel: parallel)
        request.stream = clientStreams
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        for chunk in Self.characters(text) { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 9, completionTokens: 30, tokensPerSecond: 0,
            finishReason: finishReason))
        upstream.continuation.finish()
        var frames: [String] = []
        do {
            for try await frame in try await MLXOpenAIService(
                engine: RoutedEngine(upstream: upstream.stream, modelType: "gemma4")
            ).streamChatCompletionFrames(request: request) {
                frames.append(frame)
            }
        } catch {
            return (frames.compactMap(ProviderLoop.parseStreamChunk), error)
        }
        return (frames.compactMap(ProviderLoop.parseStreamChunk), nil)
    }

    /// A client that does not stream gets the complete-call output: one
    /// delta carrying the whole call, as before. The call itself is the one a
    /// streaming client rebuilds from its fragments.
    @Test func forcedGemmaCallsKeepTheirOutputForClientsThatDoNotStream() async throws {
        let text = Self.gemmaCall(#"location:<|"|>Paris<|"|>,days:3"#)
        let whole = try await Self.serveForcedGemma(text, clientStreams: false)
        let streamed = try await Self.serveForcedGemma(text)
        #expect(whole.error == nil && streamed.error == nil)
        #expect(whole.chunks.filter { $0.toolCallsDelta != nil }.count == 1)
        #expect(streamed.chunks.filter { $0.toolCallsDelta != nil }.count > 1)
        for served in [whole, streamed] {
            let call = Self.streamedCall(served.chunks)
            #expect(call.name == "get_weather")
            #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(call.arguments.utf8))
                == ["location": .string("Paris"), "days": .int(3)])
            #expect(served.chunks.contains { $0.finishReason == "tool_calls" })
        }
    }

    /// The forced rules hold while the call streams: text outside the call is
    /// refused, framing whitespace is not an answer, a call that fails after
    /// it started is refused with its check (never finished), a response
    /// without a call is refused, and a cut at the token limit ends `length`.
    @Test func forcedGemmaStreamsKeepTheForcedRules() async throws {
        let call = Self.gemmaCall(#"location:<|"|>Paris<|"|>"#)
        let text = try await Self.serveForcedGemma("Sure! " + call)
        #expect(text.error.map { "\($0)".contains("visible text") } == true, "\(String(describing: text.error))")
        let spaced = try await Self.serveForcedGemma("\n" + call + "\n")
        #expect(spaced.error == nil && spaced.chunks.contains { $0.finishReason == "tool_calls" })
        let open = try await Self.serveForcedGemma(#"<|tool_call>call:write_file{path:<|"|>a.py<|"|>,content:<|"|>print("#)
        #expect(open.error.flatMap(classifyToolNoncomplianceCheck) == .unterminated, "\(String(describing: open.error))")
        #expect(Self.streamedCall(open.chunks).name == "write_file", "it had started streaming")
        #expect(!open.chunks.contains { $0.finishReason != nil })
        let none = try await Self.serveForcedGemma("\n")
        #expect(none.error != nil)
        let named = try await Self.serveForcedGemma(Self.gemmaCall(#"path:<|"|>a.py<|"|>,content:<|"|>x<|"|>"#,
            name: "write_file"), choice: .function(name: "get_weather"))
        #expect(named.error != nil && Self.streamedCall(named.chunks).name == nil, "another function is never exposed")
        let cut = try await Self.serveForcedGemma(
            #"<|tool_call>call:write_file{path:<|"|>a.py<|"|>,content:<|"|>print("#, finishReason: "length")
        #expect(cut.error == nil, "\(String(describing: cut.error))")
        #expect(cut.chunks.contains { $0.finishReason == "length" })
    }

    /// The checks that can only fail after a forced call started streaming:
    /// its arguments miss the schema when the frame closes (refused with
    /// `schema`, never completed); a second call under
    /// `parallel_tool_calls: false` (dropped, the first one finishes).
    @Test func forcedGemmaStreamsRefuseLateFailuresAndKeepOneCall() async throws {
        let schema = try await Self.serveForcedGemma(Self.gemmaCall(#"unit:<|"|>celsius<|"|>"#))
        #expect(schema.error.flatMap(classifyToolNoncomplianceCheck) == .schema, "\(String(describing: schema.error))")
        #expect(Self.streamedCall(schema.chunks).name == "get_weather", "it had started streaming")
        #expect(!schema.chunks.contains { $0.finishReason != nil })

        let two = try await Self.serveForcedGemma(Self.gemmaCall(#"location:<|"|>Paris<|"|>"#)
            + Self.gemmaCall(#"location:<|"|>Rome<|"|>,days:3"#), parallel: false)
        #expect(two.error == nil, "\(String(describing: two.error))")
        #expect(Set(two.chunks.flatMap { $0.toolCallsDelta ?? [] }.compactMap(\.index)) == [0])
        #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self,
            from: Data(Self.streamedCall(two.chunks).arguments.utf8)) == ["location": .string("Paris")])
        #expect(two.chunks.contains { $0.finishReason == "tool_calls" })
    }

    /// A forced call is never returned as generated: with
    /// `DARKBLOOM_REFUSE_FAILED_STREAMED_CALLS` off and `strict` calls left as
    /// generated once a response started, a forced call that fails after it
    /// started is still refused with its check.
    @Test func forcedStreamedCallsIgnoreTheAutoLeniencySwitches() throws {
        let request = try Self.request(.mode(.required))
        var prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gemma4")
        prepared.strictCallsAsGenerated = true
        let handler = try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
            modelType: "gemma4", streamToolCalls: true, streamForcedToolCalls: .all)
        #expect(handler?.streamsCalls == true)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true, nativePrefix: nil,
            streamedCalls: prepared)
        router.refusesFailedStreamedCalls = false
        router.responseStarted = true
        var events: [MLXServerGenerationEvent] = []
        for character in Self.characters(#"<|tool_call>call:write_file{path:<|"|>a.py<|"|>,content:<|"|>print("#) {
            events += try router.process(character)
        }
        #expect(Self.deltas(events).first?.name == "write_file", "it had started streaming")
        do {
            _ = try router.finishToolCalls(truncated: false)
            Issue.record("a forced call that fails after it started must be refused")
        } catch {
            #expect(classifyToolNoncomplianceCheck(error) == .unterminated, "\(error)")
        }
        #expect(router.callsClosedUnparsed == 0 && router.completedToolCalls.isEmpty)
        #expect(router.strictCallsReturnedAsGenerated == 0)
    }

    // MARK: - Forced Qwen 3.5–3.8 and GPT-OSS calls

    /// The written file of `longForcedCall`: long enough that most of the
    /// answer is still to come when its head has been generated.
    private static let longContent = Array(repeating: "print('long answer')", count: 40).joined(separator: "; ")

    /// A forced `write_file` call in the family's format, and the part of it
    /// generated first: Qwen 3.5–3.8 XML, or GPT-OSS's analysis message and
    /// Harmony call (its `<|call|>` stop token is not text).
    private static func forcedCall(_ modelType: String, content: String = longContent)
        -> (text: String, head: String)
    {
        if modelType == "gpt_oss" {
            let text = "<|channel|>analysis<|message|>Writing it.<|end|>"
                + "<|start|>assistant<|channel|>commentary to=functions.write_file <|constrain|>json"
                + #"<|message|>{"path":"long.py","content":""# + content + #""}"#
            return (text, String(text.prefix(through: text.range(of: #""content":"pr"#)!.upperBound)))
        }
        let text = "<tool_call>\n<function=write_file>\n<parameter=path>\nlong.py\n</parameter>\n"
            + "<parameter=content>\n" + content + "\n</parameter>\n</function>\n</tool_call>"
        return (text, String(text.prefix(through: text.range(of: "<parameter=content>\npr")!.upperBound)))
    }

    /// A forced request to Qwen 3.5 (`get_weather`, `write_file`) or GPT-OSS
    /// (`set_value`, `write_file`), with each family's reasoning parser.
    private static func forcedRequest(_ modelType: String, _ choice: OpenAIToolChoice, clientStreams: Bool = true,
                                      parallel: Bool? = nil) throws -> OpenAIChatCompletionRequest
    {
        var request: OpenAIChatCompletionRequest
        if modelType == "gpt_oss" {
            request = try ProviderLoop.decodeOpenAIRequest(Data(gptOSSBody
                .replacingOccurrences(of: "STRICT", with: "").utf8))
            request.reasoningParser = .harmony
        } else {
            request = try Self.request()
            request.reasoningParser = .qwen3
        }
        request.toolChoice = choice
        request.parallelToolCalls = parallel
        request.stream = clientStreams
        return request
    }

    /// One forced Qwen or GPT-OSS response through the service: frames, and the error.
    private static func serveForced(_ modelType: String, _ text: String,
                                    choice: OpenAIToolChoice = .mode(.required), clientStreams: Bool = true,
                                    finishReason: String? = nil, parallel: Bool? = nil,
                                    thinking: Bool = false) async throws
        -> (chunks: [ProviderLoop.StreamChunkExtract], error: Error?)
    {
        let request = try Self.forcedRequest(modelType, choice, clientStreams: clientStreams, parallel: parallel)
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        for chunk in Self.characters(text) { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 9, completionTokens: 30, tokensPerSecond: 0,
            finishReason: finishReason))
        upstream.continuation.finish()
        // A thinking Qwen prompt opens the thought; production classifies its
        // reasoning before tool parsing (`Qwen35TemplateFix.routesReasoningBeforeTools`).
        let engine = thinking
            ? RoutedEngine(upstream: upstream.stream, modelType: modelType, reasoningPrefix: "<think>",
                nativeReasoningPrefix: "<think>", promotesTrailingReasoningCalls: true)
            : RoutedEngine(upstream: upstream.stream, modelType: modelType)
        var frames: [String] = []
        do {
            for try await frame in try await MLXOpenAIService(engine: engine)
                .streamChatCompletionFrames(request: request) {
                frames.append(frame)
            }
        } catch {
            return (frames.compactMap(ProviderLoop.parseStreamChunk), error)
        }
        return (frames.compactMap(ProviderLoop.parseStreamChunk), nil)
    }

    /// Forced (`required` or named) Qwen 3.5–3.8 and GPT-OSS calls were held
    /// back until generation ended, as Gemma's were, so a long one had no
    /// first content before then (GPT-OSS's analysis aside). Its name must
    /// reach the wire while the arguments are still being generated, and the
    /// call a client rebuilds from the fragments is the complete one.
    @Test(arguments: ["qwen3_5", "gpt_oss"], [OpenAIToolChoice.mode(.required), .function(name: "write_file")])
    func forcedQwenAndGPTOSSCallsReachTheWireBeforeTheirFrameCloses(modelType: String, choice: OpenAIToolChoice)
        async throws
    {
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        let service = MLXOpenAIService(engine: RoutedEngine(upstream: upstream.stream, modelType: modelType))
        let log = FrameLog()
        let frames = try await service.streamChatCompletionFrames(request: Self.forcedRequest(modelType, choice))
        let reader = Task {
            for try await frame in frames { await log.append(frame) }
        }
        let call = Self.forcedCall(modelType)
        for chunk in Self.characters(call.head) { upstream.continuation.yield(.chunk(chunk)) }
        // Most of the answer has not been generated yet.
        #expect(await log.waitForToolFrame(), "\(modelType): a forced call's first content must leave before the frame closes")
        for chunk in Self.characters(call.text).dropFirst(call.head.count) { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 40, completionTokens: 300, tokensPerSecond: 0,
            finishReason: nil))
        upstream.continuation.finish()
        try await reader.value

        let parsed = await log.frames.compactMap(ProviderLoop.parseStreamChunk)
        let streamed = Self.streamedCall(parsed)
        #expect(streamed.name == "write_file", "\(modelType)")
        #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(streamed.arguments.utf8))
            == ["path": .string("long.py"), "content": .string(Self.longContent)], "\(modelType)")
        #expect(parsed.contains { $0.finishReason == "tool_calls" }, "\(modelType)")
        #expect(!parsed.contains { $0.contentDelta?.isEmpty == false }, "\(modelType): a forced answer shows no text")
    }

    /// A client that does not stream gets the complete-call output: one delta
    /// carrying the whole call, as before. The call itself is the one a
    /// streaming client rebuilds from its fragments, and GPT-OSS's analysis is
    /// reasoning on both.
    @Test(arguments: ["qwen3_5", "gpt_oss"])
    func forcedQwenAndGPTOSSCallsKeepTheirOutputForClientsThatDoNotStream(modelType: String) async throws {
        let text = Self.forcedCall(modelType, content: "print(1)").text
        let whole = try await Self.serveForced(modelType, text, clientStreams: false)
        let streamed = try await Self.serveForced(modelType, text)
        #expect(whole.error == nil && streamed.error == nil,
            "\(modelType): \(String(describing: whole.error)) \(String(describing: streamed.error))")
        #expect(whole.chunks.filter { $0.toolCallsDelta != nil }.count == 1, "\(modelType)")
        #expect(streamed.chunks.filter { $0.toolCallsDelta != nil }.count > 1, "\(modelType)")
        for served in [whole, streamed] {
            let call = Self.streamedCall(served.chunks)
            #expect(call.name == "write_file", "\(modelType)")
            #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(call.arguments.utf8))
                == ["path": .string("long.py"), "content": .string("print(1)")], "\(modelType)")
            #expect(served.chunks.contains { $0.finishReason == "tool_calls" }, "\(modelType)")
            #expect(!served.chunks.contains { $0.contentDelta?.isEmpty == false }, "\(modelType)")
            #expect(served.chunks.compactMap(\.reasoningDelta).joined() == (modelType == "gpt_oss" ? "Writing it." : ""),
                "\(modelType)")
        }
    }

    /// The forced rules hold while a Qwen 3.5–3.8 call streams, with no
    /// sampler grammar behind it. Text before a call, a response without a
    /// call and a call to another function are refused before anything is
    /// exposed; framing whitespace is not an answer. A call that fails after
    /// it started (stopped inside, or missing its schema when the frame
    /// closes) and text after a call are refused with their checks, never
    /// finished. `parallel_tool_calls: false` keeps the first call, and a cut
    /// at the token limit ends `length`.
    @Test func forcedQwenStreamsKeepTheForcedRules() async throws {
        let call = "<tool_call>\n<function=get_weather>\n<parameter=location>\nParis\n</parameter>\n"
            + "</function>\n</tool_call>"
        let open = "<tool_call>\n<function=write_file>\n<parameter=path>\na.py\n</parameter>\n"
            + "<parameter=content>\nprint("
        func visibleText(_ served: (chunks: [ProviderLoop.StreamChunkExtract], error: Error?)) -> Bool {
            served.error.map { "\($0)".contains("visible text") } == true
        }

        let before = try await Self.serveForced("qwen3_5", "I will check.\n" + call)
        #expect(visibleText(before), "\(String(describing: before.error))")
        #expect(Self.streamedCall(before.chunks).name == nil, "nothing was exposed")
        let spaced = try await Self.serveForced("qwen3_5", "\n" + call + "\n")
        #expect(spaced.error == nil && spaced.chunks.contains { $0.finishReason == "tool_calls" },
            "\(String(describing: spaced.error))")
        let after = try await Self.serveForced("qwen3_5", call + "\nDone.")
        #expect(visibleText(after), "\(String(describing: after.error))")
        #expect(Self.streamedCall(after.chunks).name == "get_weather", "the call had left")
        #expect(!after.chunks.contains { $0.finishReason != nil })

        let stopped = try await Self.serveForced("qwen3_5", open)
        #expect(stopped.error.flatMap(classifyToolNoncomplianceCheck) == .unterminated,
            "\(String(describing: stopped.error))")
        #expect(Self.streamedCall(stopped.chunks).name == "write_file", "it had started streaming")
        #expect(!stopped.chunks.contains { $0.finishReason != nil })
        let schema = try await Self.serveForced("qwen3_5", "<tool_call>\n<function=get_weather>\n<parameter=unit>\n"
            + "celsius\n</parameter>\n</function>\n</tool_call>")
        #expect(schema.error.flatMap(classifyToolNoncomplianceCheck) == .schema, "\(String(describing: schema.error))")
        #expect(Self.streamedCall(schema.chunks).name == "get_weather", "it had started streaming")
        #expect(!schema.chunks.contains { $0.finishReason != nil })

        // Held to its generated text: a repeated parameter with another value
        // (the complete-call path kept the parse's last value) is refused, as
        // is text after the last parameter (refused on both paths), never a
        // call the model did not write.
        for (text, check) in [
            ("<tool_call>\n<function=get_weather>\n<parameter=location>\nParis\n</parameter>\n"
                + "<parameter=location>\nRome\n</parameter>\n</function>\n</tool_call>", ToolNoncomplianceCheck.diverged),
            ("<tool_call>\n<function=get_weather>\n<parameter=location>\nParis\n</parameter>\n"
                + "oops</function>\n</tool_call>", .malformed),
        ] {
            let served = try await Self.serveForced("qwen3_5", text)
            #expect(served.error.flatMap(classifyToolNoncomplianceCheck) == check, "\(String(describing: served.error))")
            #expect(Self.streamedCall(served.chunks).name == "get_weather", "it had started streaming")
            #expect(!served.chunks.contains { $0.finishReason != nil })
        }

        let none = try await Self.serveForced("qwen3_5", "\n")
        #expect(none.error != nil)
        let other = try await Self.serveForced("qwen3_5", call, choice: .function(name: "write_file"))
        #expect(other.error != nil && Self.streamedCall(other.chunks).name == nil, "another function is never exposed")

        let two = try await Self.serveForced("qwen3_5", call + "\n" + call.replacingOccurrences(of: "Paris", with: "Rome"),
            parallel: false)
        #expect(two.error == nil, "\(String(describing: two.error))")
        #expect(Set(two.chunks.flatMap { $0.toolCallsDelta ?? [] }.compactMap(\.index)) == [0])
        #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self,
            from: Data(Self.streamedCall(two.chunks).arguments.utf8)) == ["location": .string("Paris")])
        #expect(two.chunks.contains { $0.finishReason == "tool_calls" })
        let cut = try await Self.serveForced("qwen3_5", open, finishReason: "length")
        #expect(cut.error == nil, "\(String(describing: cut.error))")
        #expect(cut.chunks.contains { $0.finishReason == "length" })
    }

    /// Thinking-on Qwen: the reasoning streams first, then the forced call's
    /// fragments, in order; reasoning is not forced text. A client that does
    /// not stream gets the same reasoning and the call in one delta.
    @Test func forcedQwenReasoningThenCallStreamsInOrder() async throws {
        let text = "Need the weather.</think>\n\n<tool_call>\n<function=get_weather>\n"
            + "<parameter=location>\nParis\n</parameter>\n</function>\n</tool_call>"
        for clientStreams in [true, false] {
            let served = try await Self.serveForced("qwen3_5", text, clientStreams: clientStreams, thinking: true)
            #expect(served.error == nil, "\(String(describing: served.error))")
            #expect(served.chunks.compactMap(\.reasoningDelta).joined() == "Need the weather.")
            let lastReasoning = try #require(served.chunks.lastIndex { !($0.reasoningDelta ?? "").isEmpty })
            let firstTool = try #require(served.chunks.firstIndex { $0.toolCallsDelta != nil })
            #expect(lastReasoning < firstTool)
            #expect((served.chunks.filter { $0.toolCallsDelta != nil }.count > 1) == clientStreams)
            let call = Self.streamedCall(served.chunks)
            #expect(call.name == "get_weather")
            #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(call.arguments.utf8))
                == ["location": .string("Paris")])
            #expect(served.chunks.contains { $0.finishReason == "tool_calls" })
        }
    }

    /// Withheld reasoning (`reasoning.exclude`) on thinking-on Qwen: the
    /// thought is classified as reasoning and never emitted, and the forced
    /// call still streams.
    @Test func forcedQwenCallStreamsAfterWithheldReasoning() throws {
        let request = try Self.forcedRequest("qwen3_5", .mode(.required))
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "qwen3_5")
        let handler = try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
            modelType: "qwen3_5", streamToolCalls: true, streamForcedToolCalls: .all)
        #expect(handler?.streamsCalls == true)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true, nativePrefix: "<think>",
            promotesTrailingReasoningCalls: true, withholdReasoning: true, streamedCalls: prepared)
        var events: [MLXServerGenerationEvent] = []
        for character in Self.characters("Need the weather.</think>\n\n<tool_call>\n<function=get_weather>\n"
            + "<parameter=location>\nParis\n</parameter>\n</function>\n</tool_call>") {
            events += try router.process(character)
        }
        events += try router.finishText()
        events += try router.finishToolCalls(truncated: false)
        #expect(router.takeWithheldReasoning() == "Need the weather.")
        #expect(!events.contains { if case .parsed(let parsed) = $0 { parsed.reasoningContent?.isEmpty == false }
            else { false } })
        let deltas = Self.deltas(events)
        #expect(deltas.count > 1 && deltas.first?.name == "get_weather")
        #expect(deltas.last?.completed?.function.arguments == ["location": .string("Paris")])
        #expect(router.completedToolCalls.count == 1)
    }

    /// The forced rules hold while a GPT-OSS call streams. Its analysis is
    /// reasoning; any other message before the call is refused before
    /// anything is exposed, as is a call to another function. A call that
    /// fails after it started is refused with its check, never finished, and
    /// a cut in the analysis or the call ends `length`. (The sampler's
    /// framing prevents most of these; the router does not rely on it.)
    @Test func forcedGPTOSSStreamsKeepTheForcedRules() async throws {
        let final = try await Self.serveForced("gpt_oss", "<|channel|>analysis<|message|>No tool.<|end|>"
            + "<|start|>assistant<|channel|>final<|message|>It is done.")
        #expect(final.error.map { "\($0)".contains("visible text") } == true, "\(String(describing: final.error))")
        #expect(Self.streamedCall(final.chunks).name == nil && !final.chunks.contains { $0.contentDelta?.isEmpty == false })
        let other = try await Self.serveForced("gpt_oss", Self.harmonyCall("set_value", #"{"value":1}"#),
            choice: .function(name: "write_file"))
        #expect(other.error != nil && Self.streamedCall(other.chunks).name == nil, "another function is never exposed")

        let stopped = try await Self.serveForced("gpt_oss", Self.harmonyCall("write_file", #"{"path":"a.py","content":"pr"#))
        #expect(stopped.error.flatMap(classifyToolNoncomplianceCheck) == .unterminated,
            "\(String(describing: stopped.error))")
        #expect(Self.streamedCall(stopped.chunks).name == "write_file", "it had started streaming")
        #expect(!stopped.chunks.contains { $0.finishReason != nil })
        let schema = try await Self.serveForced("gpt_oss", Self.harmonyCall("write_file", #"{"path":"a.py"}"#))
        #expect(schema.error.flatMap(classifyToolNoncomplianceCheck) == .schema, "\(String(describing: schema.error))")
        #expect(Self.streamedCall(schema.chunks).name == "write_file", "it had started streaming")

        for partial in ["<|channel|>analysis<|message|>Writing the fi",
                        Self.harmonyCall("write_file", #"{"path":"a.py","content":"pr"#)] {
            let cut = try await Self.serveForced("gpt_oss", partial, finishReason: "length")
            #expect(cut.error == nil, "\(String(describing: cut.error))")
            #expect(cut.chunks.contains { $0.finishReason == "length" })
            #expect(!cut.chunks.contains { $0.contentDelta?.isEmpty == false })
        }
    }

    /// A forced call that misses its schema when its frame closes is refused
    /// there, by the per-frame check: its closing delta (the rest of the
    /// arguments and `completed`) never leaves, whatever the terminal's check
    /// of the whole set would do. GPT-OSS's frame closes at its `<|call|>`
    /// stop token, so at the end of generation.
    @Test(arguments: ["gemma4", "qwen3_5", "gpt_oss"])
    func forcedCallMissingItsSchemaIsRefusedWhenItsFrameCloses(modelType: String) throws {
        let request = try Self.request(.mode(.required))
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
        let handler = try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
            modelType: modelType, streamToolCalls: true, streamForcedToolCalls: .all)
        #expect(handler?.streamsCalls == true)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true, nativePrefix: nil,
            streamedCalls: prepared)
        let frame = switch modelType {
        case "gemma4": Self.gemmaCall(#"unit:<|"|>celsius<|"|>"#)
        case "qwen3_5": "<tool_call>\n<function=get_weather>\n<parameter=unit>\ncelsius\n</parameter>\n</function>\n"
            + "</tool_call>"
        default: "<|start|>assistant<|channel|>commentary to=functions.get_weather <|constrain|>json"
            + #"<|message|>{"unit":"celsius"}"#
        }
        var events: [MLXServerGenerationEvent] = []
        var thrown: Error?
        do {
            for character in Self.characters(frame) { events += try router.process(character) }
            if modelType == "gpt_oss" { events += try router.finishToolCalls(truncated: false) }
        } catch { thrown = error }
        #expect(classifyToolNoncomplianceCheck(try #require(thrown, "\(modelType)")) == .schema, "\(modelType)")
        #expect(Self.deltas(events).first?.name == "get_weather", "\(modelType): it had started")
        #expect(Self.deltas(events).allSatisfy { $0.completed == nil }, "\(modelType)")
        #expect(router.completedToolCalls.isEmpty, "\(modelType)")
    }

    @Test func qwenAndHarmonyCallsStreamThroughTheService() async throws {
        let qwen = "<tool_call>\n<function=write_file>\n<parameter=path>\nfib.py\n</parameter>\n"
            + "<parameter=content>\nprint(1)\n</parameter>\n</function>\n</tool_call>"
        let harmony = "<|channel|>analysis<|message|>Writing.<|end|>"
            + "<|start|>assistant<|channel|>commentary to=functions.write_file <|constrain|>json"
            + #"<|message|>{"path":"fib.py","content":"print(1)"}"#
        for (modelType, text, parser) in [("qwen3_5", qwen, ReasoningParserFormat.qwen3),
                                          ("gpt_oss", harmony, .harmony)] {
            let upstream = AsyncStream<GenerationEvent>.makeStream()
            for chunk in Self.characters(text) { upstream.continuation.yield(.chunk(chunk)) }
            upstream.continuation.yield(.info(promptTokens: 9, completionTokens: 30, tokensPerSecond: 0,
                finishReason: nil))
            upstream.continuation.finish()
            var request = try Self.request()
            request.reasoningParser = parser
            var frames: [String] = []
            for try await frame in try await MLXOpenAIService(
                engine: RoutedEngine(upstream: upstream.stream, modelType: modelType)
            ).streamChatCompletionFrames(request: request) {
                frames.append(frame)
            }
            let deltas = frames.compactMap(ProviderLoop.parseStreamChunk).flatMap { $0.toolCallsDelta ?? [] }
            #expect(deltas.count > 2, "\(modelType)")
            #expect(deltas.first?.function?.name == "write_file", "\(modelType)")
            let arguments = deltas.compactMap { $0.function?.arguments }.joined()
            #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(arguments.utf8))
                == ["path": .string("fib.py"), "content": .string("print(1)")], "\(modelType)")
        }
    }

    /// Without a GLM JSON format, streamed calls send the frames they sent
    /// before that format could sit beside tools, byte for byte and in order,
    /// whether the call's end tag was generated or the stop token ended it.
    @Test(arguments: [true, false])
    func streamedCallFramesWithoutAGLMJSONFormatAreUnchanged(endTagGenerated: Bool) async throws {
        let call = Self.gemmaCall(#"location:<|"|>Paris<|"|>,days:3"#)
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        upstream.continuation.yield(.chunk("Checking.\n"))
        upstream.continuation.yield(.chunk(endTagGenerated ? call : String(call.dropLast("<tool_call|>".count))))
        upstream.continuation.yield(.info(promptTokens: 9, completionTokens: 30, tokensPerSecond: 0,
            finishReason: nil))
        upstream.continuation.finish()
        var frames: [String] = []
        for try await frame in try await MLXOpenAIService(
            engine: RoutedEngine(upstream: upstream.stream, modelType: "gemma4")
        ).streamChatCompletionFrames(request: try Self.request()) {
            frames.append(frame
                .replacingOccurrences(of: #""id":"[^"]*""#, with: #""id":"ID""#, options: .regularExpression)
                .replacingOccurrences(of: #""created":[0-9]+"#, with: #""created":0"#, options: .regularExpression))
        }
        let chunk = #""created":0,"id":"ID","model":"gemma-4-26b-qat-4bit","object":"chat.completion.chunk""#
        #expect(frames == [
            #"data: {"choices":[{"delta":{"role":"assistant"},"index":0}],"# + chunk + "}",
            #"data: {"choices":[{"delta":{"content":"Checking.\n"},"index":0}],"# + chunk + "}",
            #"data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"","name":"get_weather"},"id":"ID","index":0,"type":"function"}]},"index":0}],"#
                + chunk + "}",
            #"data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\"location\":\"Paris\""},"index":0}]},"index":0}],"#
                + chunk + "}",
            #"data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":",\"days\":3}"},"index":0}]},"index":0}],"#
                + chunk + "}",
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls","index":0}],"# + chunk
                + #","usage":{"completion_tokens":30,"prompt_tokens":9,"total_tokens":39}}"#,
            "data: [DONE]",
        ].map { $0 + "\n\n" })
    }

    /// Thinking-on Qwen: reasoning streams first, then the call's fragments,
    /// in order and before the engine terminal's usage frame.
    @Test func qwenReasoningThenCallStreamsInOrder() async throws {
        let text = "Need the weather.</think>\n\n<tool_call>\n<function=get_weather>\n"
            + "<parameter=location>\nParis\n</parameter>\n</function>\n</tool_call>"
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        for chunk in Self.characters(text) { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 9, completionTokens: 30, tokensPerSecond: 0,
            finishReason: nil))
        upstream.continuation.finish()
        var request = try Self.request()
        request.reasoningParser = .qwen3
        var frames: [String] = []
        for try await frame in try await MLXOpenAIService(engine: RoutedEngine(
            upstream: upstream.stream, modelType: "qwen3_5", reasoningPrefix: "<think>")
        ).streamChatCompletionFrames(request: request) {
            frames.append(frame)
        }
        let parsed = frames.compactMap(ProviderLoop.parseStreamChunk)
        #expect(parsed.compactMap(\.reasoningDelta).joined() == "Need the weather.")
        let lastReasoning = try #require(parsed.lastIndex { !($0.reasoningDelta ?? "").isEmpty })
        let firstTool = try #require(parsed.firstIndex { $0.toolCallsDelta != nil })
        let usage = try #require(parsed.firstIndex { $0.usage != nil })
        #expect(lastReasoning < firstTool && firstTool < usage)
        let deltas = parsed.flatMap { $0.toolCallsDelta ?? [] }
        #expect(deltas.first?.function?.name == "get_weather")
        let arguments = deltas.compactMap { $0.function?.arguments }.joined()
        #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(arguments.utf8))
            == ["location": .string("Paris")])
        // Only the framing whitespace after `</think>` is ordinary content.
        let visible = parsed.compactMap(\.contentDelta).joined()
        #expect(visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(parsed.contains { $0.finishReason == "tool_calls" })
    }

    @Test func partialDeltaFramesCountAsContentAndHashInOrder() throws {
        let start = #"data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"","name":"f"},"id":"call_1","index":0,"type":"function"}]},"index":0}],"created":1,"id":"c","model":"m","object":"chat.completion.chunk"}"#
        let fragment = #"data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\"a\":1}"},"index":0}]},"index":0}],"created":1,"id":"c","model":"m","object":"chat.completion.chunk"}"#
        let first = try #require(ProviderLoop.parseStreamChunk(start)?.toolCallsDelta)
        let second = try #require(ProviderLoop.parseStreamChunk(fragment)?.toolCallsDelta)
        #expect(second == [.init(index: 0, function: .init(arguments: #"{"a":1}"#))])
        // A whole call keeps its historical hash encoding.
        let whole = OpenAIToolCall(id: "call_1", function: .init(name: "f", arguments: ""), index: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let legacy = "\u{1F}tool_call:" + String(decoding: try encoder.encode(whole), as: UTF8.self) + "\u{1F}"
        #expect(ProviderLoop.encodeToolCallsForHash(first) == legacy)
        #expect(ProviderLoop.encodeToolCallsForHash(second).hasPrefix("\u{1F}tool_call:"))
    }

    // MARK: - Think parser seed

    // Seed scope: ReasoningPromptProbeTests.
    @Test func plainTailSeedStreamsAnswersAndStillHonorsModelReasoning() async throws {
        let seed = try #require(ReasoningPromptProbe.streamingPrefix(reasoningParser: .qwen3, stream: true,
            promptTokens: [1], modelType: "qwen3_vl_moe", seedsPlainTailContent: true,
            decodeTail: { _ in "<|im_start|>assistant\n" }))
        for (chunks, content, reasoning) in [
            (["A cat ", "sits ", "here."], ["A cat ", "sits ", "here."], [String]()),
            (["<think>", "hmm", "</think>", "Yes."], ["Yes."], ["hmm"]),
        ] {
            let engine = ScriptedEvents(events: [.content(seed)] + chunks.map { .content($0) }
                + [.info(.init(promptTokens: 3, completionTokens: 3, promptTime: 0, generationTime: 0,
                    stopReason: "stop"))])
            var request = try Self.request()
            request.reasoningParser = .qwen3
            var frames: [String] = []
            for try await frame in try await MLXOpenAIService(engine: engine)
                .streamChatCompletionFrames(request: request) { frames.append(frame) }
            let parsed = frames.compactMap(ProviderLoop.parseStreamChunk)
            #expect(parsed.compactMap(\.contentDelta).filter { !$0.isEmpty } == content)
            #expect(parsed.compactMap(\.reasoningDelta).filter { !$0.isEmpty } == reasoning)
        }
    }
}

/// Production prompt policy, parser resolution and forwarder over a scripted
/// engine row; only tokenization and the bridge are replaced.
private struct RoutedEngine: MLXServerEngine {
    let upstream: AsyncStream<GenerationEvent>
    let modelType: String
    /// The prompt-tail seed the text path would forward (`ReasoningPromptProbe`).
    var reasoningPrefix: String? = nil
    /// The native reasoning split the text path would install, if any.
    var nativeReasoningPrefix: String? = nil
    var promotesTrailingReasoningCalls = false

    func availableModels() async throws -> [MLXServerModel] { [] }

    func streamChatCompletion(
        request: OpenAIChatCompletionRequest
    ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
        let handler = try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: modelType, streamToolCalls: true)
        return try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
            upstream: upstream, cancelUpstream: {}, prepared: prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: request.model),
            reasoningPrefix: reasoningPrefix, toolHandler: handler, nativeReasoningPrefix: nativeReasoningPrefix,
            promotesTrailingReasoningCalls: promotesTrailingReasoningCalls)
    }

    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { .init(tokens: []) }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { .init(text: "") }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { .init(tokens: []) }
}

private struct ScriptedEvents: MLXServerEngine {
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

    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { .init(tokens: []) }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { .init(text: "") }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { .init(tokens: []) }
}

private actor FrameLog {
    private(set) var frames: [String] = []

    func append(_ frame: String) { frames.append(frame) }

    /// Polls for a frame carrying `tool_calls`; false after about two seconds.
    func waitForToolFrame() async -> Bool {
        for _ in 0..<400 {
            if frames.contains(where: { $0.contains("\"tool_calls\"") }) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}
