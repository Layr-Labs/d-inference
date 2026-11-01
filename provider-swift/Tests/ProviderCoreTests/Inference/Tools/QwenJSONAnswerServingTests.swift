import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

@Suite("Qwen JSON answer request policy")
struct QwenJSONAnswerPolicyTests {
    private typealias F = QwenAnswerFixture
    /// One handle, so its vocabulary is built once for the suite.
    private static let handle = TokenizerHandle(QwenByteTestTokenizer())

    private func make(_ request: OpenAIChatCompletionRequest, modelType: String? = "qwen3_5",
                      prompt: String = QwenByteTestTokenizer.prompt(thinking: false),
                      handle: TokenizerHandle = Self.handle, stops: Set<Int> = F.stops) throws
        -> (any CBv2TokenConstraint)? {
        try ToolConstraintFactory.make(prepared: ToolChoicePromptPolicy.prepare(request, modelType: modelType),
            request: request, tokenizer: handle, modelContext: .init(modelId: request.model, modelType: modelType),
            defaultMaxTokens: 100, stopTokenIDs: stops, nativePromptTokens: QwenByteTestTokenizer.tokens(prompt))
    }

    @Test func eligibleRequestsStartInThePromptsPhase() throws {
        for format in [F.jsonObject, F.schemaFormat(F.schema), F.schemaFormat(#"{"type":"string","enum":["<arg_key>"]}"#)] {
            for (thinking, phase) in [(false, JSONAnswerPhase.answer), (true, .reasoning)] {
                for modelType in ["qwen3_5", "qwen3_5_moe"] {
                    let constraint = try #require(try make(F.request(format: format), modelType: modelType,
                        prompt: QwenByteTestTokenizer.prompt(thinking: thinking)) as? JSONAnswerConstraint)
                    #expect(constraint.initialPhase == phase && constraint.format.family == "Qwen")
                    #expect(constraint.maxTokens == 64 && constraint.fallbackTokenID == F.imEnd)
                }
            }
        }
        // The budget is the request's, or the engine default when omitted.
        let defaulted = try F.request(format: F.jsonObject)
        var unbounded = defaulted
        unbounded.maxTokens = nil
        #expect((try make(unbounded) as? JSONAnswerConstraint)?.maxTokens == 100)
    }

    @Test func unsupportedSchemasKeepPromptOnlySteeringWithoutAnError() throws {
        let schemas = [
            "{}", #"{"description":"anything"}"#, #"{"type":"string","pattern":"^a"}"#,
            #"{"anyOf":[{"type":"string"},{"type":"integer"}]}"#,
            #"{"type":"array","items":{"type":"string"},"maxItems":64}"#,
            #"{"type":"string","enum":["<think>"]}"#, #"{"type":"string","enum":["say <|im_end|>"]}"#,
            #"{"type":"number","enum":[1.5]}"#,
        ]
        for format in schemas.map(F.schemaFormat) + [#"{"type":"json_schema"}"#] {
            let request = try F.request(format: format)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "qwen3_5")
            #expect(prepared.responseFormat == nil && prepared.messages == request.messages)
            #expect(try make(request) == nil, "\(format)")
        }
    }

    @Test func toolsOrAToolChoiceKeepTodaysBehavior() throws {
        let shapes: [(String?, String?)] = [(F.tools, nil), (F.tools, #""auto""#), (F.tools, #""required""#),
            (F.tools, #"{"type":"function","function":{"name":"weather"}}"#), (nil, #""none""#), (nil, #""auto""#)]
        for (tools, choice) in shapes {
            let request = try F.request(format: F.jsonObject, tools: tools, choice: choice)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "qwen3_5")
            let unformatted = try ToolChoicePromptPolicy.prepare(
                F.request(format: #"{"type":"text"}"#, tools: tools, choice: choice), modelType: "qwen3_5")
            // No Flint-style precedence: the format changes neither tools nor choice.
            #expect(prepared.mode == unformatted.mode && prepared.tools == unformatted.tools)
            #expect(prepared.messages == unformatted.messages && prepared.responseFormat == nil)
            #expect(try make(request) == nil, "\(tools ?? "no tools") \(choice ?? "no choice")")
        }
    }

    @Test func otherFamiliesFormatsAndShapesAreNotConstrained() throws {
        let request = try F.request(format: F.jsonObject)
        for type in ["qwen4_exp", "prism_hadamard_qwen35", "qwen3_vl_moe", "gemma4", "gpt_oss", "Qwen3_5",
                     " qwen3_5", nil] as [String?] {
            #expect(try make(request, modelType: type) == nil, "\(type ?? "nil")")
        }
        #expect(try make(F.request(format: #"{"type":"text"}"#)) == nil)
        #expect(try make(F.request(format: nil)) == nil)
        for parser in [nil, "none", "deepseek_r1"] as [String?] {
            #expect(try make(F.request(format: F.jsonObject, parser: parser)) == nil, "\(parser ?? "nil")")
        }
        #expect(try make(F.request(format: F.jsonObject, image: true)) == nil)
        #expect(try make(F.request(format: F.jsonObject, maxTokens: 0)) == nil)
        #expect(try make(request, prompt: "<|im_start|>assistant\n") == nil)
        let moved = QwenByteTestTokenizer.pinned.map { $0.0 == "</think>" ? ($0.0, 248_070) : $0 }
        #expect(try make(request, handle: TokenizerHandle(QwenByteTestTokenizer(markers: moved))) == nil)
        #expect(try make(request, stops: [F.endOfText]) == nil)
    }
}

/// Client view of one stream. Raw `.content` text passes the service's qwen3
/// think parser, as it does downstream of the scheduler; native `.parsed`
/// channels arrive already split.
private struct QwenAnswerOutcome {
    var content = ""
    var contentDeltas: [String] = []
    var reasoning = ""
    var info: ServerGenerationInfo?
    var error: (any Error)?
    private var parser = StreamingReasoningParser(format: .qwen3)

    mutating func record(_ event: MLXServerGenerationEvent) {
        switch event {
        case .content(let text): parser.parse(text).forEach { apply($0) }
        case .parsed(let parsed): apply(parsed)
        case .info(let info): self.info = info
        case .toolCall, .toolCallDelta, .logprobs: break
        }
    }

    mutating func finish() { parser.finish().forEach { apply($0) } }

    private mutating func apply(_ parsed: ParsedReasoning) {
        if !parsed.content.isEmpty {
            content += parsed.content
            contentDeltas.append(parsed.content)
        }
        reasoning += parsed.reasoningContent ?? ""
    }
}

#if DEBUG
@Suite("Qwen JSON answer output validation")
struct QwenJSONAnswerOutputTests {
    private typealias F = QwenAnswerFixture

    private func run(_ format: String, output: [String], finish: String, prefix: String? = "<think></think>",
                     constrained: Bool = true) async throws -> QwenAnswerOutcome {
        let request = try F.request(format: format)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "qwen3_5")
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [:] })
        let upstream = AsyncStream<GenerationEvent> { continuation in
            for chunk in output { continuation.yield(.chunk(chunk)) }
            continuation.yield(.info(promptTokens: 1, completionTokens: output.count, tokensPerSecond: 0,
                finishReason: finish))
            continuation.finish()
        }
        let stream = try scheduler._testMakeEventStream(upstream: upstream, cancelUpstream: {},
            prepared: prepared, releaseBox: OneShotRelease(release: { _ in }, modelId: "fixture"),
            nativeReasoningPrefix: constrained ? prefix : nil,
            answerFormat: constrained ? try F.answerFormat(format) : nil)
        var outcome = QwenAnswerOutcome()
        do {
            for try await event in stream { outcome.record(event) }
        } catch { outcome.error = error }
        outcome.finish()
        return outcome
    }

    @Test func validAnswersStreamAndSucceedInBothPhases() async throws {
        let direct = try await run(F.schemaFormat(F.schema), output: [#"{"tables_used":["a"],"#, #""count":3}"#],
            finish: "stop")
        #expect(direct.error == nil && direct.reasoning.isEmpty)
        #expect(direct.content == #"{"tables_used":["a"],"count":3}"#)
        let thought = try await run(F.jsonObject, output: ["pl", "an</think>", "\n\n{\"a\":", "1}"], finish: "stop",
            prefix: "<think>")
        #expect(thought.error == nil && thought.reasoning == "plan")
        #expect(thought.content == "\n\n{\"a\":1}")
        #expect(try await run(F.schemaFormat(#"{"type":"integer"}"#), output: ["12"], finish: "stop").error == nil)
    }

    @Test(arguments: [
        (["PRIVATE not json"], "stop"), ([#"{"tables_used":["PRIVATE"]}"#], "stop"),
        ([#"{"tables_used":["PRIVATE"],"#], "length"), ([#"{"count":12}"#, " trailing PRIVATE"], "stop"),
    ])
    func invalidOrTruncatedAnswersAreTyped422s(output: [String], finish: String) async throws {
        let outcome = try await run(F.schemaFormat(F.schema), output: output, finish: finish)
        let error = try #require(outcome.error as? MLXOpenAIServiceError)
        guard case .invalidResponseFormatOutput(let message) = error else {
            Issue.record("unexpected \(error)"); return
        }
        #expect(message.hasPrefix("Qwen ") && !message.contains("PRIVATE"), "errors never quote generated content")
        #expect(finish != "length" || message.contains("budget"))
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 422)
    }

    @Test func reasoningThatSpendsTheBudgetIsATyped422() async throws {
        let outcome = try await run(F.jsonObject, output: ["still thinking"], finish: "length", prefix: "<think>")
        #expect(outcome.reasoning == "still thinking" && outcome.content.isEmpty)
        #expect(outcome.error.map { ProviderLoop.mapInferenceErrorToStatus($0) } == 422)
    }

    @Test func unconstrainedRequestsKeepTodaysPassThrough() async throws {
        let outcome = try await run(F.schemaFormat(F.schema), output: ["prose, not JSON"], finish: "length",
            constrained: false)
        #expect(outcome.error == nil && outcome.content == "prose, not JSON")
    }
}
#endif

/// Samples a fixed script through the submitted constraint, like a model that
/// honors the masks: the script's next token when allowed, otherwise an
/// allowed stop. Records each submission.
private final class QwenScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let script: [Int]
    private let lock = NSLock()
    private var requests: [CBv2Request] = []

    init(script: String) { self.script = QwenByteTestTokenizer.tokens(script) }

    var submitted: [CBv2Request] { lock.withLock { requests } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        // Mirror EngineV2's admission check: a constraint shares the request's budget.
        if let constraint = request.tokenConstraint, constraint.maxTokens != request.maxTokens {
            throw CBv2SchedulerError.tokenConstraintBudgetMismatch(
                request: request.maxTokens, constraint: constraint.maxTokens)
        }
        lock.withLock { requests.append(request) }
        var deltas: [(text: String, token: Int)] = []
        var finish = CBv2FinishReason.length
        var state = request.tokenConstraint?.initialState ?? 0
        var remaining = script.makeIterator()
        while deltas.count < request.maxTokens {
            let wanted = remaining.next()
            let token: Int?
            if let constraint = request.tokenConstraint {
                let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: request.maxTokens - deltas.count)
                token = wanted.flatMap { allowed.contains($0) ? $0 : nil } ?? allowed.first(where: request.stopTokens.contains)
                if let token { state = constraint.nextState(state: state, tokenID: token) ?? state }
            } else {
                token = wanted ?? request.stopTokens.min()
            }
            guard let token else { break }
            if request.stopTokens.contains(token) {
                deltas.append(("", token))
                finish = .stop
                break
            }
            deltas.append((String(decoding: QwenByteTestTokenizer.piece(token), as: UTF8.self), token))
        }
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        for delta in deltas { continuation.yield(.delta(text: delta.text, tokens: [delta.token], logprobs: nil)) }
        continuation.yield(.finished(reason: finish,
            usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: deltas.count)))
        continuation.finish()
        return stream
    }

    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

@Suite("Qwen JSON answers through the scheduler and bridge")
struct QwenJSONAnswerServingTests {
    private let modelID = "EigenLabs/Qwen3.5-9B-MLX-4bit-mtp"
    private static let tokenizer = TokenizerHandle(QwenByteTestTokenizer())

    private func serve(_ engine: QwenScriptedEngine, modelType: String = "qwen3_5", fields: String) async throws
        -> QwenAnswerOutcome {
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: Self.tokenizer,
            eosTokenIds: [248046, 248044], defaultMaxTokens: 64, maxConcurrentRequests: 1)
        let id = modelID
        let tokenizer = Self.tokenizer
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            [id: .init(tokenizer: tokenizer, modelType: modelType, engineV2Bridge: bridge)]
        })
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
        {"model":"\(modelID)","messages":[{"role":"user","content":"hi"}],"reasoning_parser":"qwen3",\(fields)}
        """.utf8))
        var outcome = QwenAnswerOutcome()
        do {
            for try await event in try await scheduler.streamChatCompletion(request: request) { outcome.record(event) }
        } catch { outcome.error = error }
        outcome.finish()
        await bridge.shutdown()
        return outcome
    }

    private let schemaFormat = #""response_format":"# + QwenAnswerFixture.schemaFormat(QwenAnswerFixture.schema)

    @Test func aConstrainedAnswerStreamsAndKeepsEngineStops() async throws {
        let engine = QwenScriptedEngine(script: #"{"tables_used":["orders"],"count":12}"#)
        let outcome = try await serve(engine, fields: #""max_tokens":64,"stop":["END"],"# + schemaFormat)
        let request = try #require(engine.submitted.first)
        let constraint = try #require(request.tokenConstraint as? JSONAnswerConstraint)
        // The JSON default renders the closed block, so output starts in the answer.
        #expect(constraint.initialPhase == .answer && constraint.maxTokens == request.maxTokens)
        #expect(request.stopStrings == ["END"])
        #expect(outcome.error == nil && outcome.reasoning.isEmpty)
        #expect(outcome.content == #"{"tables_used":["orders"],"count":12}"#)
        #expect(outcome.contentDeltas.count > 1, "content streams as generated")
        #expect(outcome.info?.stopReason == "stop")
    }

    @Test func anOmittedMaxTokensUsesTheBridgeDefaultBudget() async throws {
        // The scheduler's default (4096) differs from the bridge's (64). The
        // engine resolves an omitted max_tokens with the bridge default, so the
        // constraint must use the same budget or the engine refuses it.
        let engine = QwenScriptedEngine(script: #"{"tables_used":["orders"],"count":12}"#)
        let outcome = try await serve(engine, fields: schemaFormat)
        let request = try #require(engine.submitted.first)
        let constraint = try #require(request.tokenConstraint as? JSONAnswerConstraint)
        #expect(request.maxTokens == 64 && constraint.maxTokens == 64)
        #expect(outcome.error == nil)
        #expect(outcome.content == #"{"tables_used":["orders"],"count":12}"#)
    }

    @Test func aTruncatedAnswerStreamsThenFailsWithATyped422() async throws {
        let engine = QwenScriptedEngine(script: #"{"tables_used":["orders"],"count":12}"#)
        let outcome = try await serve(engine, fields: #""max_tokens":10,"# + schemaFormat)
        #expect(outcome.content == #"{"tables_u"#, "the prefix streamed before the failure")
        let error = try #require(outcome.error as? MLXOpenAIServiceError)
        guard case .invalidResponseFormatOutput(let message) = error else {
            Issue.record("unexpected \(error)"); return
        }
        #expect(message == "Qwen output budget ended before the JSON value was complete")
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 422)
    }

    @Test func requestedThinkingIsSplitBeforeTheAnswerIsValidated() async throws {
        let engine = QwenScriptedEngine(script: "plan {\"draft\":</think>\n\n{\"tables_used\":[],\"count\":0}")
        let outcome = try await serve(engine, fields: #""max_tokens":64,"reasoning":{"enabled":true},"# + schemaFormat)
        #expect((engine.submitted.first?.tokenConstraint as? JSONAnswerConstraint)?.initialPhase == .reasoning)
        #expect(outcome.error == nil)
        #expect(outcome.reasoning == "plan {\"draft\":")
        #expect(outcome.content == "\n\n{\"tables_used\":[],\"count\":0}")
    }

    @Test func aWrongKeyIsNeverEmitted() async throws {
        // The scripted model reaches for "tables" instead of "tables_used". The
        // masks admit only "_" there, so the stand-in, which follows its script
        // or stops, ends early and the unfinished value fails as truncated.
        let engine = QwenScriptedEngine(script: #"{"tables":["orders"],"count":1}"#)
        let outcome = try await serve(engine, fields: #""max_tokens":64,"# + schemaFormat)
        #expect(outcome.content == #"{"tables"#)
        #expect(outcome.error.map { ProviderLoop.mapInferenceErrorToStatus($0) } == 422)
    }

    @Test func toolsAndOtherFamiliesKeepTheirUnconstrainedPaths() async throws {
        let tools = #""tools":[{"type":"function","function":{"name":"weather","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}],"#
        let withTools = QwenScriptedEngine(script: "not json")
        let outcome = try await serve(withTools, fields: #""max_tokens":64,"# + tools + schemaFormat)
        #expect(withTools.submitted.first?.tokenConstraint == nil)
        #expect(outcome.error == nil && outcome.content == "not json")
        let other = QwenScriptedEngine(script: "not json")
        _ = try await serve(other, modelType: "qwen4_exp", fields: #""max_tokens":64,"# + schemaFormat)
        #expect(other.submitted.first?.tokenConstraint == nil)
    }
}
