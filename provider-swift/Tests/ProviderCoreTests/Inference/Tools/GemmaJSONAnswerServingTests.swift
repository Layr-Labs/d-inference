import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

@Suite("Gemma JSON answer request policy")
struct GemmaJSONAnswerPolicyTests {
    private typealias F = GemmaAnswerFixture
    /// One verified handle, so its vocabulary is built once for the suite.
    private static let handle = TokenizerHandle(GemmaPieceTestTokenizer(), toolConstraintContractVerified: true)

    static func request(format: String?, tools: String? = nil, choice: String? = nil, parser: String? = "gemma4",
                        stop: String? = nil, maxTokens: Int = 64, image: Bool = false) throws
        -> OpenAIChatCompletionRequest {
        let content = image
            ? #"[{"type":"text","text":"hi"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]"#
            : #""hi""#
        var body = #"{"model":"gemma-4-26b-qat-4bit","messages":[{"role":"user","content":"# + content
            + #"}],"max_tokens":\#(maxTokens)"#
        if let format { body += #","response_format":"# + format }
        if let tools { body += #","tools":"# + tools }
        if let choice { body += #","tool_choice":"# + choice }
        if let parser { body += #","reasoning_parser":""# + parser + #"""# }
        if let stop { body += #","stop":"# + stop }
        return try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data((body + "}").utf8))
    }

    private func make(_ request: OpenAIChatCompletionRequest, modelType: String? = "gemma4",
                      thinking: Bool = false, prompt: String? = nil, handle: TokenizerHandle = Self.handle,
                      stops: Set<Int> = F.stops) throws -> (any CBv2TokenConstraint)? {
        let tokens = F.tokenizer.encode(text: prompt ?? GemmaPieceTestTokenizer.prompt(thinking: thinking),
                                        addSpecialTokens: false)
        return try ToolConstraintFactory.make(prepared: ToolChoicePromptPolicy.prepare(request, modelType: modelType),
            request: request, tokenizer: handle, modelContext: .init(modelId: request.model, modelType: modelType),
            defaultMaxTokens: 100, stopTokenIDs: stops, nativePromptTokens: tokens)
    }

    @Test func eligibleRequestsStartWhereThePromptLeavesTheModel() throws {
        for format in [F.jsonObject, F.schemaFormat(F.schema)] {
            for (thinking, phase) in [(false, GemmaJSONAnswerBoundary.Phase.answer), (true, .opening)] {
                for modelType in ["gemma4", "gemma4_text"] {
                    let constraint = try #require(try make(Self.request(format: format), modelType: modelType,
                        thinking: thinking) as? GemmaJSONAnswerConstraint)
                    #expect(constraint.initialPhase == phase && constraint.format.family == "Gemma")
                    #expect(constraint.maxTokens == 64 && constraint.fallbackTokenID == 106)
                }
            }
        }
        // A tool-free `auto` is the same request.
        #expect(try make(Self.request(format: F.jsonObject, choice: #""auto""#)) is GemmaJSONAnswerConstraint)
        var unbounded = try Self.request(format: F.jsonObject)
        unbounded.maxTokens = nil
        #expect((try make(unbounded) as? GemmaJSONAnswerConstraint)?.maxTokens == 100)
    }

    @Test func theSwitchRestoresPromptOnlyAnswers() throws {
        for (value, on) in [(nil, true), ("", true), ("1", true), ("on", true), ("off", false), (" OFF ", false),
                            ("0", false), ("false", false), ("no", false)] as [(String?, Bool)] {
            #expect(GemmaJSONAnswerPolicy.isEnabled(value) == on, "\(value ?? "unset")")
        }
        let request = try Self.request(format: F.jsonObject)
        let tokens = F.tokenizer.encode(text: GemmaPieceTestTokenizer.prompt(thinking: false), addSpecialTokens: false)
        #expect(GemmaJSONAnswerPolicy.constraint(request: request, tokenizer: Self.handle, modelType: "gemma4",
            defaultMaxTokens: 100, stopTokenIDs: F.stops, promptTokens: tokens, enabled: false) == nil)
        #expect(GemmaJSONAnswerPolicy.constraint(request: request, tokenizer: Self.handle, modelType: "gemma4",
            defaultMaxTokens: 100, stopTokenIDs: F.stops, promptTokens: tokens, enabled: true) != nil)
    }

    @Test func requestsOutOfScopeKeepTodaysBehaviorWithoutAnError() throws {
        let tools = #"[{"type":"function","function":{"name":"weather","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}]"#
        let format = F.jsonObject
        let out: [OpenAIChatCompletionRequest] = try [
            Self.request(format: format, tools: tools), Self.request(format: format, tools: tools, choice: #""auto""#),
            Self.request(format: format, choice: #""none""#), Self.request(format: format, stop: #"["END"]"#),
            Self.request(format: format, image: true), Self.request(format: format, parser: "qwen3"),
            Self.request(format: format, parser: nil), Self.request(format: format, maxTokens: 0),
            Self.request(format: #"{"type":"text"}"#), Self.request(format: nil),
        ]
        // Tools and `tool_choice` keep their own Gemma paths; the rest stay unconstrained.
        for request in out { #expect(!(try make(request) is GemmaJSONAnswerConstraint)) }
        let request = try Self.request(format: format)
        for type in ["qwen3_5", "gpt_oss", "diffusion_gemma", "gemma3", "Gemma4", nil] as [String?] {
            #expect(try make(request, modelType: type) == nil, "\(type ?? "nil")")
        }
        // An unpinned template, another prompt end, another tokenizer, or
        // stops without `<turn|>` decline too.
        #expect(try make(request, handle: TokenizerHandle(GemmaPieceTestTokenizer())) == nil)
        #expect(try make(request, prompt: "<bos><|turn>user\nhi<turn|>\n<|turn>model\n{\"pre") == nil)
        var moved = GemmaPieceTestTokenizer()
        moved.specials[101] = nil
        moved.specials[102] = "<channel|>"
        #expect(try make(request, handle: TokenizerHandle(moved, toolConstraintContractVerified: true)) == nil)
        #expect(try make(request, stops: [1, 50]) == nil)
    }

    @Test func schemasOutsideTheSubsetFallBackToAnObjectOrToPromptOnly() throws {
        let objectRoots = [
            ##"{"type":"object","properties":{"a":{"$ref":"#/$defs/A"}},"$defs":{"A":{"type":"string"}}}"##,
            #"{"type":"object","properties":{"a":{"type":"string","pattern":"^x"}}}"#,
            ##"{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{}}"##,
            #"{"type":"object","properties":{"a":{"anyOf":[{"type":"string"},{"type":"null"}]}}}"#,
            #"{"type":"object","properties":{"a":{"type":"string","enum":["ok","<eos>"]}}}"#,
        ]
        for schema in objectRoots {
            let constraint = try #require(try make(Self.request(format: F.schemaFormat(schema)))
                as? GemmaJSONAnswerConstraint, "\(schema)")
            #expect(constraint.format.schema == nil, "held to a JSON object")
            #expect(F.walk(F.ids(#"{"anything": [1]}"#), constraint) != nil)
            #expect(!F.allows(constraint, 0, GemmaPieceTestTokenizer.id("[")))
        }
        let otherRoots = [
            ##"{"$ref":"#/$defs/A","type":"object","$defs":{"A":{"type":"string"}}}"##,
            #"{"anyOf":[{"type":"string"},{"type":"integer"}]}"#, #"{"type":"string","pattern":"^a"}"#,
            #"{"type":["object","array"],"items":{"type":"string"}}"#, "{}", #"{"type":"string","enum":["<eos>"]}"#,
        ]
        for schema in otherRoots { #expect(try make(Self.request(format: F.schemaFormat(schema))) == nil, "\(schema)") }
        #expect(try make(Self.request(format: #"{"type":"json_schema"}"#)) == nil)
        // A supported schema is enforced as written.
        let exact = try #require(try make(Self.request(format: F.schemaFormat(F.schema))) as? GemmaJSONAnswerConstraint)
        #expect(exact.format.schema != nil)
    }

    private final class OtherConstraint: CBv2TokenConstraint, @unchecked Sendable {
        let mode = CBv2TokenConstraintMode.required
        let maxTokens = 1, initialState = 0, fallbackTokenID = 1
        func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] { [1] }
        func nextState(state: Int, tokenID: Int) -> Int? { -1 }
    }

    @Test func anEngineWithoutConstraintsServesTheAnswerPromptOnly() throws {
        let gemma = try F.constraint()
        let other = OtherConstraint()
        for (pair, native) in [(true, false), (false, true), (true, true)] {
            #expect(EngineV2Bridge.admittedConstraint(gemma, servesDistributedPair: pair,
                tracksNativeShutdown: native) == nil)
            // Every other constraint keeps today's typed refusal there.
            #expect(EngineV2Bridge.admittedConstraint(other, servesDistributedPair: pair,
                tracksNativeShutdown: native) === other)
        }
        #expect(EngineV2Bridge.admittedConstraint(gemma, servesDistributedPair: false,
            tracksNativeShutdown: false) === gemma)
        #expect(EngineV2Bridge.admittedConstraint(nil, servesDistributedPair: true, tracksNativeShutdown: true) == nil)
    }

    @Test func theSwitchReachesTheLaunchdJob() {
        let key = GemmaJSONAnswerPolicy.environmentKey
        #expect(key == "DARKBLOOM_GEMMA_JSON_ANSWERS")
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "off"])[key] == "off")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }
}

/// Client view of one Gemma stream: raw `.content` text passes the service's
/// Gemma 4 channel parser, as it does downstream of the scheduler.
private struct GemmaAnswerOutcome {
    var content = ""
    var contentDeltas: [String] = []
    var reasoning = ""
    var info: ServerGenerationInfo?
    var error: (any Error)?
    private var parser = StreamingReasoningParser(format: .gemma4)

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

/// Samples a fixed script through the submitted constraint, like a model
/// that honors the masks: the script's next token when allowed; a refused
/// token is skipped, as a sampler moves to the best allowed token; at the
/// script's end an allowed stop. Records each submission.
private final class GemmaScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let script: [Int]
    private let lock = NSLock()
    private var requests: [CBv2Request] = []

    init(script: [Int]) { self.script = script }

    var submitted: [CBv2Request] { lock.withLock { requests } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        if let constraint = request.tokenConstraint, constraint.maxTokens != request.maxTokens {
            throw CBv2SchedulerError.tokenConstraintBudgetMismatch(
                request: request.maxTokens, constraint: constraint.maxTokens)
        }
        lock.withLock { requests.append(request) }
        var tokens: [Int] = []
        var finish = CBv2FinishReason.length
        var state = request.tokenConstraint?.initialState ?? 0
        var remaining = script[...]
        while tokens.count < request.maxTokens {
            let budget = request.maxTokens - tokens.count
            var token: Int?
            if let constraint = request.tokenConstraint {
                let allowed = Set(constraint.allowedTokenIDs(state: state, remainingTokens: budget))
                while let next = remaining.first, !allowed.contains(next) { remaining = remaining.dropFirst() }
                token = remaining.popFirst() ?? allowed.filter(request.stopTokens.contains).min()
                if let token { state = constraint.nextState(state: state, tokenID: token) ?? state }
            } else {
                token = remaining.popFirst() ?? request.stopTokens.min()
            }
            guard let token else { break }
            if request.stopTokens.contains(token) {
                finish = .stop
                break
            }
            tokens.append(token)
        }
        let tokenizer = GemmaPieceTestTokenizer()
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        for token in tokens {
            continuation.yield(.delta(text: tokenizer.decode(tokenIds: [token], skipSpecialTokens: false),
                                      tokens: [token], logprobs: nil))
        }
        continuation.yield(.finished(reason: finish,
            usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: tokens.count)))
        continuation.finish()
        return stream
    }

    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

@Suite("Gemma JSON answers through the scheduler and bridge")
struct GemmaJSONAnswerServingTests {
    private typealias F = GemmaAnswerFixture
    private let modelID = "gemma-4-26b-qat-4bit"
    private static let tokenizer = TokenizerHandle(GemmaPieceTestTokenizer(), toolConstraintContractVerified: true)

    private func serve(_ engine: GemmaScriptedEngine, fields: String) async throws -> GemmaAnswerOutcome {
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: Self.tokenizer,
            eosTokenIds: [1, 50, 106], defaultMaxTokens: 64, maxConcurrentRequests: 1)
        let id = modelID
        let tokenizer = Self.tokenizer
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            [id: .init(tokenizer: tokenizer, modelType: "gemma4", engineV2Bridge: bridge)]
        })
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
        {"model":"\(modelID)","messages":[{"role":"user","content":"hi"}],"reasoning_parser":"gemma4",\(fields)}
        """.utf8))
        var outcome = GemmaAnswerOutcome()
        do {
            for try await event in try await scheduler.streamChatCompletion(request: request) { outcome.record(event) }
        } catch { outcome.error = error }
        outcome.finish()
        await bridge.shutdown()
        return outcome
    }

    private let objectFormat = #""response_format":{"type":"json_object""# + "}"

    @Test func aConstrainedAnswerStreamsWithoutItsFence() async throws {
        // The scripted model wraps its answer in a fence; the masks admit only the value.
        let engine = GemmaScriptedEngine(script: F.pieces("```json") + F.ids("\n{\"a\": [1, \"b\"]}\n") + F.pieces("```"))
        let outcome = try await serve(engine, fields: #""max_tokens":64,"# + objectFormat)
        let constraint = try #require(engine.submitted.first?.tokenConstraint as? GemmaJSONAnswerConstraint)
        #expect(constraint.initialPhase == .answer, "the JSON default renders the closed empty thought")
        #expect(outcome.error == nil && outcome.reasoning.isEmpty)
        #expect(outcome.content == "\n{\"a\": [1, \"b\"]}")
        #expect(outcome.contentDeltas.count > 1, "content streams as generated")
        #expect(outcome.info?.stopReason == "stop")
    }

    @Test func aRequestedThoughtStaysFreeAndTheAnswerFollows() async throws {
        let script = [F.thoughtOpen] + F.ids("thought\nplan {\"draft\":") + [F.thoughtClose] + F.ids("{\"ok\": true}")
        let engine = GemmaScriptedEngine(script: script)
        let outcome = try await serve(engine, fields: #""max_tokens":64,"reasoning":{"enabled":true},"# + objectFormat)
        #expect((engine.submitted.first?.tokenConstraint as? GemmaJSONAnswerConstraint)?.initialPhase == .opening)
        #expect(outcome.error == nil)
        #expect(outcome.reasoning == "plan {\"draft\":")
        #expect(outcome.content == "{\"ok\": true}")
    }

    @Test func aSchemaAnswerKeepsOnlyDeclaredKeys() async throws {
        let schema = #""response_format":"# + F.schemaFormat(F.schema)
        // The scripted model adds an undeclared key; the masks skip it.
        let engine = GemmaScriptedEngine(script: F.ids(#"{"name": "Rex", "zz": 1, "owner": {"id": 7}}"#))
        let outcome = try await serve(engine, fields: #""max_tokens":96,"# + schema)
        #expect(outcome.error == nil && outcome.info?.stopReason == "stop")
        #expect(outcome.content == #"{"name": "Rex", "owner": {"id": 7}}"#)
    }

    @Test func aBudgetCutStaysLengthWithoutAnError() async throws {
        let engine = GemmaScriptedEngine(script: F.ids(#"{"a": "a long answer"}"#))
        let outcome = try await serve(engine, fields: #""max_tokens":6,"# + objectFormat)
        #expect(outcome.error == nil, "unlike Qwen's validated answers, a cut is not a refusal")
        #expect(outcome.content == #"{"a": "#)
        #expect(outcome.info?.stopReason == "length")
    }

    @Test func requestsWithoutAJSONFormatAreUnconstrained() async throws {
        let engine = GemmaScriptedEngine(script: F.ids("plain text"))
        let outcome = try await serve(engine, fields: #""max_tokens":64"#)
        #expect(engine.submitted.first?.tokenConstraint == nil)
        #expect(outcome.content == "plain text")
    }
}
