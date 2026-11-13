import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// An answer the engine cut at the token limit ends as a normal `length`
/// completion, as generated (`TokenLimitCutPolicy`). A streamed response that
/// has started returns a `strict` call that fails its check as generated
/// (`StrictToolCallPolicy`). Each has a kill switch that reaches launchd.
@Suite("Answers cut at the token limit and strict calls after the response started")
struct ToolOutputLeniencyTests {
    private typealias Value = MLXLMCommon.JSONValue

    // MARK: - Switches

    @Test(arguments: [TokenLimitCutPolicy.environmentKey, StrictToolCallPolicy.environmentKey])
    func eachSwitchIsOnUnlessTurnedOffAndReachesTheProviderJob(key: String) {
        func enabled(_ environment: [String: String]) -> Bool {
            key == TokenLimitCutPolicy.environmentKey
                ? TokenLimitCutPolicy.enabled(environment: environment)
                : StrictToolCallPolicy.enabled(environment: environment)
        }
        #expect(enabled([:]) && enabled([key: "1"]) && enabled([key: "on"]))
        for off in ["0", "off", "false", "no", " OFF "] { #expect(!enabled([key: off]), "\(off)") }
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0", "UNRELATED": "x"]) == [key: "0"])
    }

    @Test func switchNames() {
        #expect(TokenLimitCutPolicy.environmentKey == "DARKBLOOM_LENGTH_FINISH_AT_LIMIT")
        #expect(StrictToolCallPolicy.environmentKey == "DARKBLOOM_STRICT_CALLS_AS_GENERATED")
    }

    /// The coordinator path serves every request as a stream, so whether the
    /// client streams is read from the body.
    @Test func theClientsStreamFlagComesFromTheBody() {
        func controls(_ fields: String) -> ChatTemplateControls {
            ProviderLoop.extractChatTemplateControls(from: Data(
                (#"{"model":"m","messages":[{"role":"user","content":"q"}]"# + fields + "}").utf8))
        }
        #expect(controls(#","stream":true"#).clientStreams == true)
        #expect(controls(#","stream":false"#).clientStreams == false)
        #expect(controls("").clientStreams == false)
        #expect(ChatTemplateControls().clientStreams == nil)
    }

    // MARK: - Strict calls: the call-set check

    private static func tools(strict: Bool) -> String {
        #"[{"type":"function","function":{"name":"write_file","# + (strict ? #""strict":true,"# : "")
            + #""parameters":{"type":"object","properties":{"path":{"type":"string"},"#
            + #""content":{"type":"string"}},"required":["path","content"]}}}]"#
    }

    /// The production ingress, with the strict switch as the serving path sets it.
    private static func prepared(_ fields: String = "", asGenerated: Bool = true) throws
        -> ToolChoicePromptPolicy.Prepared
    {
        let body = #"{"model":"m","messages":[{"role":"user","content":"Write it."}],"stream":true,"tools":"#
            + tools(strict: true) + fields + "}"
        let inbound = try ProviderLoop.decodeInboundChatRequest(Data(body.utf8))
        var prepared = try ToolChoicePromptPolicy.prepare(inbound.request, modelType: "qwen3_5")
        prepared.declaredTools = inbound.extensions.templateControls.declaredTools
        prepared.strictCallsAsGenerated = asGenerated
        return prepared
    }

    private static func call(_ arguments: [String: Value], name: String = "write_file") -> ToolCall {
        ToolCall(function: .init(name: name, arguments: arguments))
    }

    private static func check(_ body: () throws -> Void) -> ToolNoncomplianceCheck? {
        do {
            try body()
            return nil
        } catch {
            return classifyToolNoncomplianceCheck(error) ?? .other
        }
    }

    private static let missingContent = call(["path": .string("a.py")])
    private static let undeclared = call(["path": .string("/")], name: "delete_everything")

    @Test func aStrictCallLeavesAsGeneratedOnlyOnceTheResponseStarted() throws {
        let streamed = try Self.prepared()
        try ToolConstraintValidation.validate([Self.missingContent], prepared: streamed, responseStarted: true)
        try ToolConstraintValidation.validate([Self.undeclared], prepared: streamed, responseStarted: true)
        // Before anything left, the refusal is a status the router can still fail over on.
        #expect(Self.check {
            try ToolConstraintValidation.validate([Self.missingContent], prepared: streamed)
        } == .schema)
        #expect(Self.check {
            try ToolConstraintValidation.validate([Self.undeclared], prepared: streamed)
        } == .undeclaredName)
        // A client that does not stream, or the switch off.
        let refusing = try Self.prepared(asGenerated: false)
        #expect(Self.check {
            try ToolConstraintValidation.validate([Self.missingContent], prepared: refusing, responseStarted: true)
        } == .schema)
    }

    @Test func forcedChoicesAndTheCallLimitStayValidated() throws {
        for choice in [#""required""#, #"{"type":"function","function":{"name":"write_file"}}"#] {
            let forced = try Self.prepared(#","tool_choice":"# + choice)
            #expect(Self.check {
                try ToolConstraintValidation.validate([Self.missingContent], prepared: forced, responseStarted: true)
            } == .schema, "\(choice)")
        }
        let single = try Self.prepared(#","parallel_tool_calls":false"#)
        let whole = Self.call(["path": .string("a.py"), "content": .string("x")])
        #expect(Self.check {
            try ToolConstraintValidation.validate([whole, whole], prepared: single, responseStarted: true)
        } == .parallel)
    }

    // MARK: - Qwen through the service

    /// A Qwen chat stream: the generated text one character at a time (or in
    /// one chunk), then the engine's finish. Frames sent before any error, and the error.
    private static func serveQwen(
        _ text: String, finish: String, strict: Bool = true, choice: OpenAIToolChoice? = nil, parallel: Bool? = nil,
        reasoning: Bool = true, oneChunk: Bool = false, engine: (inout LenientRoutedEngine) -> Void = { _ in }
    ) async throws -> (chunks: [ProviderLoop.StreamChunkExtract], error: Error?) {
        var request = OpenAIChatCompletionRequest(
            model: "EigenLabs/Qwen3.5-9B-MLX-4bit-mtp", messages: [.init(role: .user, content: .text("Write it."))],
            tools: try JSONDecoder().decode([OpenAITool].self, from: Data(tools(strict: strict).utf8)),
            toolChoice: choice, parallelToolCalls: parallel, stream: true, streamOptions: .init(includeUsage: true))
        if reasoning { request.reasoningParser = .qwen3 }
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        for chunk in oneChunk ? [text] : text.map(String.init) { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 9, completionTokens: 30, tokensPerSecond: 0,
            finishReason: finish))
        upstream.continuation.finish()
        var routed = LenientRoutedEngine(upstream: upstream.stream, reasoningPrefix: reasoning ? "<think>" : nil)
        engine(&routed)
        var frames: [String] = []
        do {
            for try await frame in try await MLXOpenAIService(engine: routed).streamChatCompletionFrames(
                request: request)
            {
                frames.append(frame)
            }
        } catch {
            return (frames.compactMap(ProviderLoop.parseStreamChunk), error)
        }
        return (frames.compactMap(ProviderLoop.parseStreamChunk), nil)
    }

    private static func streamedCall(_ chunks: [ProviderLoop.StreamChunkExtract]) -> (name: String?, arguments: String) {
        let deltas = chunks.flatMap { $0.toolCallsDelta ?? [] }
        return (deltas.compactMap { $0.function?.name }.first, deltas.compactMap { $0.function?.arguments }.joined())
    }

    private static let thought = "Need it.</think>\n\n"
    private static let pathOnly = "<tool_call>\n<function=write_file>\n<parameter=path>\nfib.py\n</parameter>\n"
    private static let pathOnlyCall = pathOnly + "</function>\n</tool_call>"
    /// Cut before its end tag: the end-of-generation parse completes the call
    /// without the required `content`.
    private static let pathOnlyUnclosed = pathOnly + "</function>\n"

    @Test func aStrictCallFailingItsCheckLeavesAsGeneratedOnceTheResponseStarted() async throws {
        let served = try await Self.serveQwen(Self.thought + Self.pathOnlyCall, finish: "stop")
        #expect(served.error == nil, "\(String(describing: served.error))")
        let call = Self.streamedCall(served.chunks)
        #expect(call.name == "write_file")
        #expect(try JSONDecoder().decode([String: Value].self, from: Data(call.arguments.utf8))
            == ["path": .string("fib.py")])
        #expect(served.chunks.contains { $0.finishReason == "tool_calls" })
    }

    /// Nothing left before the call failed its check: still refused, so the
    /// router can fail over. The switch off refuses after the start too.
    @Test func aStrictCallIsRefusedBeforeAnythingLeftOrWithTheSwitchOff() async throws {
        let first = try await Self.serveQwen(Self.pathOnlyCall, finish: "stop", reasoning: false, oneChunk: true)
        #expect(classifyToolNoncomplianceCheck(try #require(first.error)) == .schema)
        #expect(first.chunks.allSatisfy { $0.toolCallsDelta == nil })
        let off = try await Self.serveQwen(Self.thought + Self.pathOnlyCall, finish: "stop") {
            $0.strictCallsAsGenerated = false
        }
        #expect(classifyToolNoncomplianceCheck(try #require(off.error)) == .schema)
        #expect(!off.chunks.contains { $0.finishReason != nil })
    }

    /// Calls withheld until the end (no streamed fragments) follow the same rule.
    @Test func aWithheldStrictCallLeavesAsGeneratedOnceReasoningLeft() async throws {
        let served = try await Self.serveQwen(Self.thought + Self.pathOnlyCall, finish: "stop") {
            $0.streamToolCalls = false
        }
        #expect(served.error == nil, "\(String(describing: served.error))")
        #expect(Self.streamedCall(served.chunks).name == "write_file")
        #expect(served.chunks.contains { $0.finishReason == "tool_calls" })
    }

    /// The budget ended the call: its fragments as generated, the call left
    /// open, and the stream ends `length` with usage, as an OpenAI stream does.
    @Test(arguments: [true, false])
    func aCallCutAtTheLimitEndsAsLength(strict: Bool) async throws {
        let served = try await Self.serveQwen(Self.thought + Self.pathOnlyUnclosed, finish: "length",
            strict: strict)
        #expect(served.error == nil, "\(String(describing: served.error))")
        let call = Self.streamedCall(served.chunks)
        #expect(call.name == "write_file")
        // Fragments stop where generation did: the provider closes nothing, so
        // a client cannot parse (and run) a call the limit cut.
        #expect((try? JSONDecoder().decode([String: Value].self, from: Data(call.arguments.utf8))) == nil)
        #expect(try JSONDecoder().decode([String: Value].self, from: Data((call.arguments + "}").utf8))
            == ["path": .string("fib.py")])
        #expect(served.chunks.compactMap(\.finishReason) == ["length"])
        #expect(served.chunks.contains { $0.usage?.completionTokens == 30 })
        // `DARKBLOOM_LENGTH_FINISH_AT_LIMIT=0`: the call is held to the
        // declarations and refused, as before.
        let off = try await Self.serveQwen(Self.thought + Self.pathOnlyUnclosed, finish: "length", strict: strict) {
            $0.cutAnswersEndAtLength = false
        }
        #expect(classifyToolNoncomplianceCheck(try #require(off.error)) == .schema)
        // A frame the parse cannot complete already stopped quietly.
        let unterminated = try await Self.serveQwen(Self.thought + Self.pathOnly, finish: "length", strict: strict)
        #expect(unterminated.error == nil && unterminated.chunks.compactMap(\.finishReason) == ["length"])
    }

    /// The limit cut inside a string value: the fragments stop with what was
    /// generated, the value and the object left unclosed, and the call open.
    @Test func aCallCutInsideAStringValueStaysOpenAndUnclosed() async throws {
        let served = try await Self.serveQwen(Self.thought + Self.pathOnly + "<parameter=content>\nprint(1",
            finish: "length")
        #expect(served.error == nil, "\(String(describing: served.error))")
        let call = Self.streamedCall(served.chunks)
        #expect(call.name == "write_file")
        #expect((try? JSONDecoder().decode([String: Value].self, from: Data(call.arguments.utf8))) == nil)
        #expect(call.arguments.hasSuffix(#""content":"print(1"#), "\(call.arguments)")
        #expect(served.chunks.compactMap(\.finishReason) == ["length"])
    }

    /// A withheld forced call the budget cut: none parsed (the required call
    /// it prevented), or one the parse completed without `content`.
    @Test(arguments: [pathOnly, pathOnlyUnclosed])
    func aForcedCallCutAtTheLimitEndsAsLength(text: String) async throws {
        let served = try await Self.serveQwen(text, finish: "length", choice: .mode(.required), reasoning: false)
        #expect(served.error == nil, "\(String(describing: served.error))")
        #expect(served.chunks.compactMap(\.finishReason) == ["length"])
        #expect(served.chunks.allSatisfy { $0.toolCallsDelta == nil && ($0.contentDelta ?? "").isEmpty })
        let off = try await Self.serveQwen(text, finish: "length", choice: .mode(.required), reasoning: false) {
            $0.cutAnswersEndAtLength = false
        }
        #expect(off.error.map { ProviderLoop.mapInferenceErrorToStatus($0) } == 422)
    }

    /// Withheld calls at a cut are checked one by one: the whole ones leave,
    /// and only the one the limit cut is dropped.
    @Test func wholeWithheldCallsLeaveBesideOneTheLimitCut() async throws {
        let whole = "<tool_call>\n<function=write_file>\n<parameter=path>\na.py\n</parameter>\n"
            + "<parameter=content>\nx\n</parameter>\n</function>\n</tool_call>\n"
        let served = try await Self.serveQwen(whole + whole + Self.pathOnlyUnclosed, finish: "length",
            choice: .mode(.required), reasoning: false)
        #expect(served.error == nil, "\(String(describing: served.error))")
        #expect(served.chunks.flatMap { $0.toolCallsDelta ?? [] }.compactMap { $0.function?.name }
            == ["write_file", "write_file"])
        #expect(served.chunks.compactMap(\.finishReason) == ["tool_calls"])
    }

    /// Nothing left during generation: a withheld strict call that fails its
    /// check is refused before the text the end of generation flushes leaves,
    /// so the router can still fail over.
    @Test func aWithheldStrictCallIsRefusedBeforeTheFlushedTextLeaves() async throws {
        let served = try await Self.serveQwen(Self.pathOnlyCall + "<to", finish: "stop", reasoning: false) {
            $0.streamToolCalls = false
        }
        #expect(classifyToolNoncomplianceCheck(try #require(served.error)) == .schema)
        #expect(served.chunks.allSatisfy { ($0.contentDelta ?? "").isEmpty && $0.toolCallsDelta == nil })
    }

    /// More calls than `parallel_tool_calls: false` allows are the model's,
    /// cut or not.
    @Test func aSecondWithheldCallIsStillRefusedAtTheLimit() async throws {
        let second = Self.pathOnlyCall + "\n" + Self.pathOnlyUnclosed
        let served = try await Self.serveQwen(second, finish: "length", choice: .mode(.required), parallel: false,
            reasoning: false)
        #expect(classifyToolNoncomplianceCheck(try #require(served.error)) == .parallel)
    }

    // MARK: - Withheld answers at the forwarder

    private struct Forwarded {
        var content = "", reasoning = "", calls = 0
        var stopReason: String?
        var error: (any Error)?
    }

    /// The production forwarder over scripted chunks and an engine finish.
    private static func forward(
        _ prepared: ToolChoicePromptPolicy.Prepared, _ output: [String], finish: String,
        handler: BatchedToolStreamHandler? = nil, nativePrefix: String? = nil
    ) async throws -> Forwarded {
        let upstream = AsyncStream<GenerationEvent> { continuation in
            for chunk in output { continuation.yield(.chunk(chunk)) }
            continuation.yield(.info(promptTokens: 1, completionTokens: output.count, tokensPerSecond: 0,
                finishReason: finish))
            continuation.finish()
        }
        let stream = try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
            upstream: upstream, cancelUpstream: {}, prepared: prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: "fixture"),
            toolHandler: handler, nativeReasoningPrefix: nativePrefix)
        var forwarded = Forwarded()
        do {
            for try await event in stream {
                switch event {
                case .parsed(let parsed):
                    forwarded.content += parsed.content
                    forwarded.reasoning += parsed.reasoningContent ?? ""
                case .content(let text): forwarded.content += text
                case .toolCall: forwarded.calls += 1
                case .toolCallDelta(let delta): if delta.completed != nil { forwarded.calls += 1 }
                case .info(let info): forwarded.stopReason = info.stopReason
                case .logprobs: break
                }
            }
        } catch { forwarded.error = error }
        return forwarded
    }

    /// GLM's withheld JSON answer leaves as generated when the budget cut it.
    @Test func aGLMAnswerCutAtTheLimitLeavesAsGenerated() async throws {
        let request = OpenAIChatCompletionRequest(model: "m", messages: [], responseFormat: .jsonObject())
        var prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
        #expect(prepared.glmResponseFormat != nil)
        prepared.cutAnswersEndAtLength = true
        let cut = try await Self.forward(prepared, [#"{"items":["#, #"1,"#], finish: "length")
        #expect(cut.error == nil, "\(String(describing: cut.error))")
        #expect(cut.content == #"{"items":[1,"# && cut.stopReason == "length")
        prepared.cutAnswersEndAtLength = false
        let off = try await Self.forward(prepared, [#"{"items":["#, #"1,"#], finish: "length")
        #expect(off.error is MLXOpenAIServiceError && off.content.isEmpty)
        // A natural stop keeps its check (out of this switch's scope).
        prepared.cutAnswersEndAtLength = true
        #expect(try await Self.forward(prepared, ["not json"], finish: "stop").error is MLXOpenAIServiceError)
    }

    /// A cut GLM answer that already holds a whole value leaves normalized, as
    /// the candidate extraction always gave it; otherwise as generated.
    @Test func aCutGLMAnswerWithAWholeValueLeavesNormalized() async throws {
        let request = OpenAIChatCompletionRequest(model: "m", messages: [], responseFormat: .jsonObject())
        var prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
        prepared.cutAnswersEndAtLength = true
        let fenced = try await Self.forward(prepared, ["```json\n{\"city\": \"Paris\"}\n```\n", "This object lists"],
            finish: "length")
        #expect(fenced.error == nil && fenced.stopReason == "length", "\(String(describing: fenced.error))")
        #expect(fenced.content == #"{"city": "Paris"}"#)
    }

    /// A Flint call frame the budget cut is the limit's, not a native frame
    /// failure; its raw frame is never published as text.
    @Test func aNativeFlintFrameCutAtTheLimitEndsAsLength() async throws {
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data(
            (#"{"model":"RecursiveSI/flint","messages":[{"role":"user","content":"hi"}],"max_tokens":64,"#
                + #""tools":[{"type":"function","function":{"name":"weather","parameters":{"type":"object","#
                + #""properties":{"city":{"type":"string"}}}}}]}"#).utf8))
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "flint")
        let output = ["Checking.", "<tool_call>weather<arg_key>city</arg_key><arg_value>Par"]
        func run(_ endsAtLength: Bool) async throws -> Forwarded {
            var policy = prepared
            policy.cutAnswersEndAtLength = endsAtLength
            let handler = try ToolStreamPreparation.makeHandler(request: request, prepared: policy,
                modelType: "flint")
            return try await Self.forward(policy, output, finish: "length", handler: handler, nativePrefix: "")
        }
        let cut = try await run(true)
        #expect(cut.error == nil, "\(String(describing: cut.error))")
        #expect(cut.content == "Checking." && cut.calls == 0 && cut.stopReason == "length")
        #expect(try await run(false).error != nil)
    }

    // MARK: - Super

    private static let superWeather = #""tools":[{"type":"function","function":{"name":"get_weather","#
        + #""parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]"#

    private static func superOutput(_ fields: String, streaming: Bool = true) throws -> NemotronSuperLocalOutput {
        try .init(plan: .init(body: Data(("{\"model\":\"" + NemotronSuperLocalBinding.modelID
            + "\",\"messages\":[{\"role\":\"user\",\"content\":\"q\"}]," + fields + "}").utf8)),
            streaming: streaming)
    }

    @Test func aSuperAnswerCutAtTheLimitEndsAsGenerated() throws {
        let noThinking = #","enable_thinking":false"#
        let json = #""response_format":{"type":"json_object"}"# + noThinking
        /// The output after `chunk`, finished with or without the cut; nil when refused.
        func finish(_ fields: String, _ chunk: String, cutAtLimit: Bool)
            -> (events: [MLXServerGenerationEvent], result: NemotronSuperLocalOutput.Result)?
        {
            guard var output = try? Self.superOutput(fields), (try? output.append(chunk)) != nil else { return nil }
            return try? output.finish(cutAtLimit: cutAtLimit)
        }
        let frame = "a<tool_call>\n<function=get_weather>"
        let required = Self.superWeather + #","tool_choice":"required""# + noThinking
        // An unterminated call frame: the text before it already streamed;
        // the frame is never published.
        #expect(finish(Self.superWeather + noThinking, frame, cutAtLimit: true)?.result
            == NemotronSuperLocalOutput.Result(content: "a", reasoning: nil, calls: []))
        // A forced call the budget cut.
        #expect(finish(required, "<tool_call>\n<function=get_weather>", cutAtLimit: true)?.result.calls == [])
        // A withheld structured answer the budget cut leaves as generated.
        let partial = finish(json, #"{"a":"#, cutAtLimit: true)
        #expect(partial?.result.content == #"{"a":"#)
        #expect(partial?.events.contains {
            if case .parsed(let parsed) = $0 { parsed.content == #"{"a":"# } else { false }
        } == true)
        // Without the cut (or with the switch off) each stays refused.
        #expect(finish(Self.superWeather + noThinking, frame, cutAtLimit: false) == nil)
        #expect(finish(required, "<tool_call>\n<function=get_weather>", cutAtLimit: false) == nil)
        #expect(finish(json, #"{"a":"#, cutAtLimit: false) == nil)
    }

    /// `force_nonempty_content` makes an unterminated thought the answer at a
    /// natural end; a thought the limit cut is not an answer, so nothing is
    /// promoted (no copy of the streamed reasoning, no forced-text refusal).
    @Test func aSuperThoughtCutAtTheLimitIsNotPromoted() throws {
        let force = #""chat_template_kwargs":{"force_nonempty_content":true}"#
        var json = try Self.superOutput(force + #","response_format":{"type":"json_object"}"#)
        _ = try json.append("still thinking")
        let cut = try json.finish(cutAtLimit: true)
        #expect(cut.result.content.isEmpty && cut.result.reasoning == "still thinking")
        var forced = try Self.superOutput(force + "," + Self.superWeather + #","tool_choice":"required""#)
        _ = try forced.append("still thinking")
        var failure: (any Error)?
        do { #expect(try forced.finish(cutAtLimit: true).result.calls.isEmpty) } catch { failure = error }
        #expect(failure == nil, "\(String(describing: failure))")
    }

    /// The relay's terminal decides: a cut answer ends `length` as generated;
    /// at a natural stop the held answer still fails, and none of it leaks.
    @Test(arguments: ["length", "stop"])
    func theSuperRelayEndsACutAnswerAsLength(finish: String) async throws {
        let pair = AsyncThrowingStream<MLXServerGenerationEvent, Error>.makeStream()
        let relay = SuperImageHTTPRelay(continuation: pair.continuation,
            output: try Self.superOutput(#""response_format":{"type":"json_object"},"enable_thinking":false"#))
        await relay.accept(.chunk(#"{"a":"#))
        await relay.accept(.info(promptTokens: 1, completionTokens: 2, tokensPerSecond: 0, finishReason: finish))
        await relay.complete()
        var content = ""
        var stopReason: String?
        var failure: (any Error)?
        do {
            for try await event in pair.stream {
                switch event {
                case .parsed(let parsed): content += parsed.content
                case .info(let info): stopReason = info.stopReason
                default: break
                }
            }
        } catch { failure = error }
        if finish == "length" {
            #expect(failure == nil && content == #"{"a":"# && stopReason == "length")
        } else {
            #expect(failure != nil && content.isEmpty && stopReason == nil)
        }
    }
}

/// The production prompt policy, parser resolution and forwarder over a
/// scripted engine row, with each switch as the serving path sets it.
private struct LenientRoutedEngine: MLXServerEngine {
    let upstream: AsyncStream<GenerationEvent>
    var reasoningPrefix: String?
    var modelType = "qwen3_5"
    var strictCallsAsGenerated = true
    var cutAnswersEndAtLength = true
    var streamToolCalls = true

    func availableModels() async throws -> [MLXServerModel] { [] }

    func streamChatCompletion(
        request: OpenAIChatCompletionRequest
    ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        var prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
        prepared.strictCallsAsGenerated = strictCallsAsGenerated
        prepared.cutAnswersEndAtLength = cutAnswersEndAtLength
        let handler = try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: modelType, streamToolCalls: streamToolCalls)
        return try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
            upstream: upstream, cancelUpstream: {}, prepared: prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: request.model),
            reasoningPrefix: reasoningPrefix, toolHandler: handler)
    }

    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { .init(tokens: []) }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { .init(text: "") }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { .init(tokens: []) }
}
