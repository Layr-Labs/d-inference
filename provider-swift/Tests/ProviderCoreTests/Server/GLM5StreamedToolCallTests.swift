#if DEBUG
import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// GLM-5.3-Flash tool calls to a client that streams, through the production
/// coordinator handler from scripted engine output (not a model-quality
/// assertion). The prompt opens the thought, as GLM's template does.
@Suite("GLM-5.3-Flash streamed tool calls", .serialized)
struct GLM5StreamedToolCallTests {
    static let modelID = "test/glm5-streamed-tools"

    static let writeTool = #"{"type":"function","function":{"name":"write_file","parameters":{"type":"object","#
        + #""properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}}"#
    static let storeTool = #"{"type":"function","function":{"name":"store","parameters":{"type":"object","#
        + #""properties":{"doc":{"type":"object"},"path":{"type":"string"}},"required":["doc"]}}}"#

    static let auto = #""auto""#
    static let required = #""required""#
    static let named = #"{"type":"function","function":{"name":"write_file"}}"#

    static func write(_ path: String, _ content: String) -> String {
        "<tool_call>write_file<arg_key>path</arg_key><arg_value>\(path)</arg_value>"
            + "<arg_key>content</arg_key><arg_value>\(content)</arg_value></tool_call>"
    }

    /// One engine delta per frame tag, value and line.
    static func pieces(_ output: String) -> [String] {
        GLM5NextToolCallRelayTests.pieces(output).flatMap { piece in
            piece.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
                index == 0 ? String(line) : "\n" + line
            }.filter { !$0.isEmpty }
        }
    }

    typealias Script = (AsyncStream<CBv2Event>.Continuation, ScriptedCoordinatorRelay.Progress) async throws -> Void

    static func relay(choice: String, stream: Bool = true, tools: [String] = [writeTool],
                      parallel: Bool? = nil, extra: [String] = [], script: Script)
        async throws -> GLM5NextToolCallRelayTests.RelayRun
    {
        var fields = [
            #""model":"\#(modelID)""#,
            #""messages":[{"role":"user","content":"Write long.py now."}]"#,
            #""max_tokens":2000"#, #""stream":\#(stream)"#,
            #""tools":["# + tools.joined(separator: ",") + "]",
            #""tool_choice":"# + choice,
        ] + extra
        if let parallel { fields.append(#""parallel_tool_calls":\#(parallel)"#) }
        let tokenizer = TokenizerHandle(try GLM5NextThinkingTokenizer(base: GLMVisibilityTokenizer()))
        let output = try await ScriptedCoordinatorRelay.run(modelID: modelID, modelType: "glm5_next",
            tokenizer: tokenizer, containerTokenizer: GLMVisibilityTokenizer(),
            eosTokenIds: GLM5NextReasoningVisibilityTests.stops, requestID: "glm-streamed-tools",
            fields: fields, script: script)
        return try GLM5NextToolCallRelayTests.parse(output)
    }

    /// The whole output in one script: one delta per piece, then the finish.
    static func relay(choice: String, stream: Bool = true, tools: [String] = [writeTool], parallel: Bool? = nil,
                      output: [String], finish: CBv2FinishReason = .stop)
        async throws -> GLM5NextToolCallRelayTests.RelayRun
    {
        try await relay(choice: choice, stream: stream, tools: tools, parallel: parallel) { continuation, _ in
            for chunk in output { continuation.yield(.delta(text: chunk, tokens: [5], logprobs: nil)) }
            continuation.yield(.finished(reason: finish, usage: .init(promptTokens: 1, completionTokens: 300)))
            continuation.finish()
        }
    }

    static func arguments(_ call: (name: String, arguments: String)) throws -> [String: MLXLMCommon.JSONValue] {
        try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(call.arguments.utf8))
    }

    // MARK: - Red: a long tool answer had no first content before the end

    /// GLM held every tool answer back until generation ended (`.glm5` was
    /// not a streamed format, and forced calls were withheld), so a long one
    /// missed the coordinator's first-content deadline. The call's name must
    /// reach the wire while its arguments are still being generated, in every
    /// tool_choice mode, and the call a client rebuilds is the whole call.
    @Test(arguments: [auto, required, named])
    func longGLMCallsReachTheWireBeforeTheirFrameCloses(choice: String) async throws {
        let content = String(repeating: "print('long answer')\n", count: 40)
        let call = Self.write("long.py", content)
        let head = "<tool_call>write_file<arg_key>path</arg_key><arg_value>long.py</arg_value>"
            + "<arg_key>content</arg_key><arg_value>print("
        var early = false
        let run = try await Self.relay(choice: choice) { continuation, progress in
            for chunk in ["Plan.", "</think>"] + Self.pieces(head) {
                continuation.yield(.delta(text: chunk, tokens: [5], logprobs: nil))
            }
            // Most of the answer has not been generated yet.
            try await progress.wait { $0.contains { $0.contains("\"tool_calls\"") } }
            early = try progress.frames().contains { $0.contains("\"tool_calls\"") }
            for chunk in Self.pieces(String(call.dropFirst(head.count))) {
                continuation.yield(.delta(text: chunk, tokens: [5], logprobs: nil))
            }
            continuation.yield(.finished(reason: .stop, usage: .init(promptTokens: 1, completionTokens: 300)))
            continuation.finish()
        }
        #expect(early, "\(choice): the call's first content must leave before its frame closes")
        #expect(run.errors.isEmpty, "\(choice): \(run.errors)")
        #expect(run.finishReason == "tool_calls", "\(choice)")
        #expect(run.calls.map(\.name) == ["write_file"], "\(choice)")
        #expect(try run.calls.map(Self.arguments) == [["path": .string("long.py"), "content": .string(content)]],
            "\(choice)")
        #expect(run.content.isEmpty, "\(choice)")
        #expect(run.reasoning == "Plan.", "\(choice)")
    }

    // MARK: - Eligibility and the switch

    @Test func onlyStreamingClientsGetStreamedGLMCalls() throws {
        func streams(_ choice: OpenAIToolChoice?, stream: Bool = true, deltas: Bool = true, modelType: String = "glm5_next",
                     master: Bool = true, glm: Bool = true, json: Bool = false) throws -> Bool {
            var request = OpenAIChatCompletionRequest(model: Self.modelID,
                messages: [.init(role: .user, content: .text("Write it."))],
                tools: try JSONDecoder().decode([OpenAITool].self, from: Data(("[" + Self.writeTool + "]").utf8)),
                toolChoice: choice, stream: stream)
            request.streamToolCallDeltas = deltas
            if json {
                request.responseFormat = try JSONDecoder().decode(OpenAIResponseFormat.self,
                    from: Data(#"{"type":"json_object"}"#.utf8))
            }
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
            return ToolStreamPreparation.streamsGLMCalls(request: request, prepared: prepared, modelType: modelType,
                streamToolCalls: master, streamGLMToolCalls: glm)
        }
        #expect(try streams(nil))
        #expect(try streams(.mode(.required)))
        #expect(try streams(.function(name: "write_file")))
        #expect(try !streams(.mode(.none)))
        #expect(try !streams(nil, stream: false), "a client that does not stream keeps the complete call")
        #expect(try !streams(nil, deltas: false))
        #expect(try !streams(nil, modelType: "gemma4"))
        #expect(try !streams(nil, master: false))
        #expect(try !streams(nil, glm: false))
        #expect(try !streams(nil, json: true), "a withheld JSON answer keeps the complete-call path")
        #expect(ToolStreamPreparation.streamGLMToolCallsEnvironmentKey == "DARKBLOOM_TTFT_STREAM_GLM_TOOL_CALLS")
        for off in ["0", "off", "false", "no", " OFF "] {
            #expect(!ToolStreamPreparation.streamsGLMToolCalls(
                environment: [ToolStreamPreparation.streamGLMToolCallsEnvironmentKey: off]))
        }
        #expect(ToolStreamPreparation.streamsGLMToolCalls(environment: [:]))
        #expect(ToolStreamPreparation.streamsGLMToolCalls(
            environment: [ToolStreamPreparation.streamGLMToolCallsEnvironmentKey: "1"]))
        let key = ToolStreamPreparation.streamGLMToolCallsEnvironmentKey
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0", "UNRELATED": "x"]) == [key: "0"])
        // Outside the SSD checkpoint identity's folded prefixes.
        for prefix in ["DARKBLOOM_GLM", "DARKBLOOM_MIMO_", "DARKBLOOM_NEMOTRON35_", "DARKBLOOM_QWEN", "DARKBLOOM_CBV2_"] {
            #expect(!key.hasPrefix(prefix))
        }
    }

    // MARK: - Non-streamed identity

    /// A client that does not stream gets the complete-call output: one
    /// delta per call at the end, as before. The calls and the finish are the
    /// ones a streaming client rebuilds from its fragments.
    @Test(arguments: [auto, required, named])
    func clientsThatDoNotStreamKeepTheCompleteCall(choice: String) async throws {
        let output = ["Plan.", "</think>"] + Self.pieces(Self.write("a.py", "print(1)\nprint(2)\n"))
        let whole = try await Self.relay(choice: choice, stream: false, output: output)
        let streamed = try await Self.relay(choice: choice, output: output)
        #expect(whole.errors.isEmpty && streamed.errors.isEmpty, "\(whole.errors) \(streamed.errors)")
        #expect(whole.toolFrames == 1, "\(choice)")
        #expect(streamed.toolFrames > 2, "\(choice)")
        for run in [whole, streamed] {
            #expect(run.calls.map(\.name) == ["write_file"])
            #expect(try run.calls.map(Self.arguments) == [["path": .string("a.py"),
                "content": .string("print(1)\nprint(2)\n")]])
            #expect(run.finishReason == "tool_calls")
            #expect(run.reasoning == "Plan." && run.content.isEmpty)
        }
    }

    /// With the switch off, a streaming client gets the complete call again.
    @Test func theSwitchOffWithholdsGLMCallsAgain() async throws {
        let output = ["</think>"] + Self.pieces(Self.write("a.py", "x"))
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        for chunk in output { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 9, completionTokens: 30, tokensPerSecond: 0, finishReason: nil))
        upstream.continuation.finish()
        var request = OpenAIChatCompletionRequest(model: Self.modelID,
            messages: [.init(role: .user, content: .text("Write it."))],
            tools: try JSONDecoder().decode([OpenAITool].self, from: Data(("[" + Self.writeTool + "]").utf8)),
            stream: true)
        request.streamToolCallDeltas = true
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
        let handler = try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
            modelType: "glm5_next", streamToolCalls: true)
        let streams = ToolStreamPreparation.streamsGLMCalls(request: request, prepared: prepared,
            modelType: "glm5_next", streamGLMToolCalls: false)
        #expect(!streams)
        var events: [MLXServerGenerationEvent] = []
        for try await event in try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
            upstream: upstream.stream, cancelUpstream: {}, prepared: prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: request.model),
            toolHandler: handler, nativeReasoningPrefix: "<think>", streamsGLMCalls: streams) {
            events.append(event)
        }
        #expect(!events.contains { if case .toolCallDelta = $0 { true } else { false } })
        let calls = events.compactMap { if case .toolCall(let call) = $0 { call } else { nil } }
        #expect(calls.map(\.function.name) == ["write_file"])
    }

    // MARK: - Fail-clean, forced rules, cuts

    /// A call that fails after it started is refused with its check and never
    /// finished, `auto` included: only the part already sent left.
    @Test(arguments: [auto, required])
    func aCallFailingAfterItStartedIsRefused(choice: String) async throws {
        let head = "<tool_call>write_file<arg_key>path</arg_key><arg_value>a.py</arg_value>"
        for (tail, check) in [
            ("<arg_key>content</arg_key><arg_value>print(", ToolNoncomplianceCheck.unterminated),
            ("<arg_key>content</arg_key><arg_value>x<arg_key>y</arg_value></tool_call>", .malformed),
            ("<arg_key>path</arg_key><arg_value>b.py</arg_value></tool_call>", .malformed),
            ("stray</tool_call>", .malformed),
        ] {
            let run = try await Self.relay(choice: choice, output: ["</think>"] + Self.pieces(head + tail))
            #expect(run.calls.map(\.name) == ["write_file"], "\(choice) \(tail): it had started streaming")
            #expect(run.errors.first?.toolCheck == check, "\(choice) \(tail): \(run.errors)")
            #expect(run.finishReason == nil, "\(choice) \(tail)")
        }
    }

    /// A forced answer stays calls only while it streams: text is refused,
    /// framing whitespace is not an answer, an answer without a call is
    /// refused, and a call to another function is never exposed.
    @Test func forcedGLMStreamsKeepTheForcedRules() async throws {
        let call = Self.write("a.py", "x")
        let text = try await Self.relay(choice: Self.required, output: ["</think>", "Sure! "] + Self.pieces(call))
        #expect(text.errors.first?.toolCheck == .forcedChoice, "\(text.errors)")
        #expect(text.content.isEmpty && text.calls.isEmpty)
        let spaced = try await Self.relay(choice: Self.required, output: ["</think>", "\n"] + Self.pieces(call) + ["\n"])
        #expect(spaced.errors.isEmpty && spaced.finishReason == "tool_calls", "\(spaced.errors)")
        #expect(spaced.content.isEmpty)
        let none = try await Self.relay(choice: Self.required, output: ["</think>", "\n"])
        #expect(!none.errors.isEmpty && none.finishReason == nil)
        let other = #"{"type":"function","function":{"name":"store"}}"#
        let named = try await Self.relay(choice: other, tools: [Self.writeTool, Self.storeTool],
            output: ["</think>"] + Self.pieces(call))
        #expect(!named.errors.isEmpty && named.calls.isEmpty, "another function is never exposed")
    }

    /// A cut at the token limit ends `length`: the exposed call stays open
    /// with the fragments it sent, never refused, in every mode.
    @Test(arguments: [auto, required, named])
    func aCutEndsLength(choice: String) async throws {
        let run = try await Self.relay(choice: choice, output: ["</think>"] + Self.pieces(
            "<tool_call>write_file<arg_key>path</arg_key><arg_value>a.py</arg_value><arg_key>content</arg_key><arg_value>pri"),
            finish: .length)
        #expect(run.errors.isEmpty, "\(choice): \(run.errors)")
        #expect(run.finishReason == "length", "\(choice)")
        #expect(run.calls.map(\.name) == ["write_file"], "\(choice)")
    }

    // MARK: - Reasoning, text and calls

    /// Reasoning is split before tool parsing: a frame drafted in the thought
    /// stays reasoning, never a call, and the real call after it streams.
    /// An `auto` call from a thought that never closed is still a call.
    @Test func reasoningComesFirstAndDraftsStayReasoning() async throws {
        let draft = "<tool_call>write_file<arg_key>path</arg_key><arg_value>draft.py</arg_value></tool_call>"
        let call = Self.write("a.py", "x")
        let run = try await Self.relay(choice: Self.auto,
            output: Self.pieces("I'd do " + draft + " maybe.") + ["</think>"] + Self.pieces(call))
        #expect(run.errors.isEmpty, "\(run.errors)")
        #expect(run.reasoning == "I'd do " + draft + " maybe.")
        #expect(try run.calls.map(Self.arguments) == [["path": .string("a.py"), "content": .string("x")]])
        #expect(run.content.isEmpty && run.finishReason == "tool_calls")

        let unclosed = try await Self.relay(choice: Self.auto, output: ["Need it.\n"] + Self.pieces(call))
        #expect(unclosed.errors.isEmpty, "\(unclosed.errors)")
        #expect(unclosed.calls.map(\.name) == ["write_file"])
        #expect(unclosed.finishReason == "tool_calls")
    }

    /// `auto` text before and after a call is content; a mentioned
    /// `<tool_call>` is text; two calls stream as two indices, and
    /// `parallel_tool_calls: false` keeps only the first.
    @Test func autoTextAroundCallsAndTwoCalls() async throws {
        let first = Self.write("a.py", "x")
        let second = Self.write("b.py", "y")
        let around = try await Self.relay(choice: Self.auto,
            output: ["</think>", "Writing <tool_call> files.\n"] + Self.pieces(first) + ["\nDone."])
        #expect(around.errors.isEmpty, "\(around.errors)")
        #expect(around.content == "Writing <tool_call> files.\n\nDone.")
        #expect(around.calls.map(\.name) == ["write_file"] && around.finishReason == "tool_calls")

        let two = try await Self.relay(choice: Self.auto, output: ["</think>"] + Self.pieces(first + "\n" + second))
        #expect(two.errors.isEmpty, "\(two.errors)")
        #expect(try two.calls.map(Self.arguments) == [["path": .string("a.py"), "content": .string("x")],
            ["path": .string("b.py"), "content": .string("y")]])
        #expect(two.finishReason == "tool_calls")

        let single = try await Self.relay(choice: Self.auto, parallel: false,
            output: ["</think>"] + Self.pieces(first + "\n" + second))
        #expect(single.errors.isEmpty, "\(single.errors)")
        #expect(try single.calls.map(Self.arguments) == [["path": .string("a.py"), "content": .string("x")]])
    }

    /// A JSON-typed value may quote the frame's own tags: the name streams
    /// first, the rest leaves when the parse closes the frame.
    @Test func typedValuesQuotingFrameTagsCompleteAtTheParse() async throws {
        let output = "<tool_call>store<arg_key>path</arg_key><arg_value>s.json</arg_value><arg_key>doc</arg_key>"
            + #"<arg_value>{"x":"</arg_value></tool_call><tool_call>store"}</arg_value></tool_call>"#
        for choice in [Self.auto, Self.required] {
            let whole = try await Self.relay(choice: choice, stream: false, tools: [Self.storeTool],
                output: ["</think>"] + Self.pieces(output))
            #expect(whole.errors.isEmpty, "complete-call path \(choice): \(whole.errors)")
            let run = try await Self.relay(choice: choice, tools: [Self.storeTool],
                output: ["</think>"] + Self.pieces(output))
            #expect(run.errors.isEmpty, "\(choice): \(run.errors)")
            #expect(try run.calls.map(Self.arguments) == [["path": .string("s.json"),
                "doc": .object(["x": .string("</arg_value></tool_call><tool_call>store")])]], "\(choice)")
            #expect(run.toolFrames > 1, "\(choice): the name left first")
            #expect(run.finishReason == "tool_calls", "\(choice)")
        }
    }
}
#endif
