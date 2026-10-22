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

    private static func request(
        _ choice: OpenAIToolChoice? = nil, parallel: Bool? = nil, deltas: Bool = true
    ) throws -> OpenAIChatCompletionRequest {
        var request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: .user, content: .text("Weather in Paris?"))],
            tools: try JSONDecoder().decode([OpenAITool].self, from: Data(tools.utf8)),
            toolChoice: choice, parallelToolCalls: parallel, stream: true,
            streamOptions: .init(includeUsage: true))
        request.streamToolCallDeltas = deltas
        return request
    }

    private static func router(
        _ request: OpenAIChatCompletionRequest, modelType: String = "gemma4"
    ) throws -> NativeToolStreamRouter {
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
        let handler = try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: modelType, streamToolCalls: true)
        #expect(handler?.streamsCalls == true)
        return NativeToolStreamRouter(handler: handler, requiresToolCall: false, nativePrefix: nil,
            streamedCalls: prepared)
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
        // Forced calls keep validate-then-expose.
        #expect(try !streams(Self.request(.mode(.required))))
        #expect(try !streams(Self.request(.function(name: "get_weather"))))
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

    @Test func schemaViolationIsRefusedWhenTheFrameCloses() throws {
        var router = try Self.router(Self.request())
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

        // Harmony parses any name: the call completes unexposed and fails validation.
        var harmony = try Self.router(Self.request(), modelType: "gpt_oss")
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
    }

    @Test func secondCallIsRefusedWhenParallelCallsAreDisabled() throws {
        var router = try Self.router(Self.request(parallel: false))
        let first = Self.gemmaCall(#"location:<|"|>Paris<|"|>"#)
        var exposed: [ServerToolCallDelta] = []
        for character in Self.characters(first) { exposed += Self.deltas(try router.process(character)) }
        #expect(exposed.last?.completed != nil)
        var thrown: Error?
        for character in Self.characters(first) {
            do { _ = try router.process(character) } catch { thrown = error; break }
        }
        #expect(thrown is MultiModelBatchSchedulerEngineError)
    }

    @Test func truncatedCallEndsQuietlyOnlyAtTheTokenLimit() throws {
        let partial = #"<|tool_call>call:write_file{path:<|"|>a.py<|"|>,content:<|"|>print("#
        var lengthRouter = try Self.router(Self.request())
        for character in Self.characters(partial) { _ = try lengthRouter.process(character) }
        #expect(try lengthRouter.finishToolCalls(truncated: true).isEmpty)
        #expect(lengthRouter.completedToolCalls.isEmpty)

        var stopRouter = try Self.router(Self.request())
        for character in Self.characters(partial) { _ = try stopRouter.process(character) }
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try stopRouter.finishToolCalls(truncated: false)
        }
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

    @Test func plainQwenPromptTailStartsInContent() {
        func prefix(_ tail: String, parser: ReasoningParserFormat = .qwen3, modelType: String?,
                    seeds: Bool = true) -> String? {
            ReasoningPromptProbe.streamingPrefix(reasoningParser: parser, stream: true, promptTokens: [1],
                modelType: modelType, seedsPlainTailContent: seeds, decodeTail: { _ in tail })
        }
        let plain = "<|im_start|>assistant\n"
        #expect(prefix(plain, modelType: "qwen3_vl_moe") == "<think></think>")
        #expect(prefix(plain, modelType: "qwen3_5") == "<think></think>")
        // Marker-bearing tails are unchanged.
        #expect(prefix(plain + "<think>\n", modelType: "qwen3_5") == "<think>")
        #expect(prefix(plain + "<think>\n\n</think>\n\n", modelType: "qwen3_5") == "<think></think>")
        // Close-only DeepSeek parsing, other families and the kill switch keep undecided parsing.
        #expect(prefix(plain, parser: .deepseekR1, modelType: "qwen3_5") == nil)
        #expect(prefix(plain, modelType: "llama") == nil)
        #expect(prefix(plain, modelType: nil) == nil)
        #expect(prefix(plain, modelType: "qwen3_vl_moe", seeds: false) == nil)
    }

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
            reasoningPrefix: reasoningPrefix, toolHandler: handler)
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
