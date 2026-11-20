import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Samples a fixed script through the submitted constraint, like a model that
/// honors the masks: the script's next token when allowed, otherwise the
/// first allowed id, and a stop ends the row. Records each submission.
private final class JSONScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let script: [Int]
    private let tokenizer = HarmonyByteTestTokenizer()
    private let lock = NSLock()
    private var requests: [CBv2Request] = []

    init(script: String) {
        self.script = HarmonyByteTestTokenizer.tokens(script)
    }

    var submitted: [CBv2Request] { lock.withLock { requests } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        if let constraint = request.tokenConstraint, constraint.maxTokens != request.maxTokens {
            throw CBv2SchedulerError.tokenConstraintBudgetMismatch(
                request: request.maxTokens, constraint: constraint.maxTokens)
        }
        var deltas: [(text: String, token: Int)] = []
        var finish = CBv2FinishReason.length
        var state = request.tokenConstraint?.initialState ?? 0
        var remaining = script.makeIterator()
        while deltas.count < request.maxTokens {
            let wanted = remaining.next() ?? request.stopTokens.min()!
            var token = wanted
            if let constraint = request.tokenConstraint {
                let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: request.maxTokens - deltas.count)
                if !allowed.contains(wanted) { token = allowed.first ?? constraint.fallbackTokenID }
                state = constraint.nextState(state: state, tokenID: token) ?? state
            }
            if request.stopTokens.contains(token) {
                deltas.append(("", token))
                finish = .stop
                break
            }
            deltas.append((tokenizer.decode(tokenIds: [token], skipSpecialTokens: false), token))
        }
        lock.withLock { requests.append(request) }
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

/// What a client receives.
private struct JSONOutcome {
    var reasoning = ""
    var content = ""
    var info: ServerGenerationInfo?
    var error: (any Error)?
    private var parser = StreamingReasoningParser(format: .harmony)

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
        content += parsed.content
        reasoning += parsed.reasoningContent ?? ""
    }
}

/// The scheduler reads `DARKBLOOM_HARMONY_JSON_ANSWERS` at launch.
@Suite("GPT-OSS JSON answers through the scheduler and bridge", .enabled(if: GPTOSSJSONAnswers.enabled))
struct GPTOSSJSONAnswerServingTests {
    private typealias J = GPTOSSJSONFixture
    private typealias T = HarmonyByteTestTokenizer

    private func serve(_ engine: JSONScriptedEngine, request: OpenAIChatCompletionRequest,
                       stream: Bool = false) async throws -> JSONOutcome {
        let tokenizer = TokenizerHandle(T())
        let bridge = EngineV2Bridge(engine: engine, modelId: "gpt-oss-20b", tokenizer: tokenizer,
            eosTokenIds: T.stops, defaultMaxTokens: 400, maxConcurrentRequests: 1,
            logitsWidth: GPTOSSAutoFixture.vocabularySize)
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            ["gpt-oss-20b": .init(tokenizer: tokenizer, modelType: "gpt_oss", engineV2Bridge: bridge)]
        })
        var request = request
        request.stream = stream
        var outcome = JSONOutcome()
        do {
            for try await event in try await scheduler.streamChatCompletion(request: request) {
                outcome.record(event)
            }
        } catch { outcome.error = error }
        outcome.finish()
        await bridge.shutdown()
        return outcome
    }

    @Test("a JSON answer is served under the grammar: reasoning split off, the content one JSON value")
    func jsonAnswerIsServed() async throws {
        for (format, answer) in [(J.schemaFormat(J.schema), #"{"city":"Paris","temp":21}"#),
                                 (J.jsonObject, #"{"ok":true}"#)] {
            for (stream, header) in [(false, J.final), (true, J.final), (false, J.finalJSON), (true, J.finalJSON)] {
                let engine = JSONScriptedEngine(script: J.analysis("The user wants Paris.") + header + answer
                    + "<|return|>")
                let outcome = try await serve(engine, request: try J.request(format: format), stream: stream)
                let submitted = try #require(engine.submitted.first)
                let constraint = try #require(submitted.tokenConstraint as? GPTOSSJSONAnswerConstraint)
                #expect(constraint.maxTokens == submitted.maxTokens)
                #expect(outcome.error == nil, "\(String(describing: outcome.error))")
                #expect(outcome.content == answer, "\(format) stream \(stream) \(header)")
                #expect(outcome.reasoning == "The user wants Paris.")
            }
        }
    }

    @Test("a script that adds an undeclared key is held to the schema")
    func deviationsAreSteered() async throws {
        let engine = JSONScriptedEngine(script: J.analysis("ok") + J.final + #"{"city":"Rome","extra":1}"#
            + "<|return|>")
        let outcome = try await serve(engine, request: try J.request(format: J.schemaFormat(J.schema)))
        #expect(outcome.error == nil, "\(String(describing: outcome.error))")
        // `"extra"` cannot be written under `additionalProperties: false`: the
        // object closes or stays within the declared keys.
        #expect(!outcome.content.contains("extra"))
        #expect(outcome.content.hasPrefix(#"{"city":"Rome""#))
    }

    @Test("with tools the request keeps the tool grammar, not the JSON answer")
    func toolsKeepTheToolGrammar() async throws {
        let tools = #"[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]"#
        let engine = JSONScriptedEngine(script: J.analysis("x") + J.final + #"{"city":"Rome"}"# + "<|return|>")
        _ = try await serve(engine, request: try J.request(format: J.jsonObject, tools: tools))
        let submitted = try #require(engine.submitted.first)
        #expect(submitted.tokenConstraint is GPTOSSAutoToolConstraint)
    }
}
