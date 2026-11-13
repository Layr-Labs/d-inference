import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Samples a fixed script through the submitted constraint, like a model that
/// honors the masks: the script's next token when allowed, otherwise the first
/// allowed stop, else the request stops there (a natural stop, never the
/// token limit). Records each submission.
private final class HarmonyScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let script: [Int]
    private let lock = NSLock()
    private var requests: [CBv2Request] = []

    init(script: String) { self.script = HarmonyByteTestTokenizer.tokens(script) }

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
            guard let token else {
                finish = .stop
                break
            }
            if request.stopTokens.contains(token) {
                deltas.append(("", token))
                finish = .stop
                break
            }
            deltas.append((HarmonyByteTestTokenizer().decode(tokenIds: [token], skipSpecialTokens: false), token))
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

/// What a client receives: the Harmony analysis as reasoning, visible content,
/// the calls, the terminal info, and the error that ended the stream, if any.
private struct HarmonyOutcome {
    var reasoning = ""
    var content = ""
    var calls: [ToolCall] = []
    var info: ServerGenerationInfo?
    var error: (any Error)?
    private var parser = StreamingReasoningParser(format: .harmony)

    mutating func record(_ event: MLXServerGenerationEvent) {
        switch event {
        case .content(let text): parser.parse(text).forEach { apply($0) }
        case .parsed(let parsed): apply(parsed)
        case .toolCall(let call): calls.append(call)
        case .info(let info): self.info = info
        case .toolCallDelta, .logprobs: break
        }
    }

    mutating func finish() { parser.finish().forEach { apply($0) } }

    private mutating func apply(_ parsed: ParsedReasoning) {
        content += parsed.content
        reasoning += parsed.reasoningContent ?? ""
    }
}

@Suite("GPT-OSS forced tool calls through the scheduler and bridge")
struct GPTOSSForcedToolServingTests {
    private typealias F = GPTOSSForcedFixture
    private typealias T = HarmonyByteTestTokenizer
    /// One handle, so its vocabulary is built once for the suite.
    private static let tokenizer = TokenizerHandle(HarmonyByteTestTokenizer())

    private func serve(_ engine: HarmonyScriptedEngine, choice: Any?, maxTokens: Int = 400) async throws
        -> HarmonyOutcome {
        let bridge = EngineV2Bridge(engine: engine, modelId: "gpt-oss-20b", tokenizer: Self.tokenizer,
            eosTokenIds: T.stops, defaultMaxTokens: maxTokens, maxConcurrentRequests: 1)
        let tokenizer = Self.tokenizer
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            ["gpt-oss-20b": .init(tokenizer: tokenizer, modelType: "gpt_oss", engineV2Bridge: bridge)]
        })
        var outcome = HarmonyOutcome()
        do {
            for try await event in try await scheduler.streamChatCompletion(
                request: F.request(choice: choice, maxTokens: maxTokens)) {
                outcome.record(event)
            }
        } catch { outcome.error = error }
        outcome.finish()
        await bridge.shutdown()
        return outcome
    }

    @Test("a forced request submits the Harmony constraint and serves one validated call")
    func forcedCallIsServed() async throws {
        for choice in ["required", F.namedWeather] as [Any] {
            let engine = HarmonyScriptedEngine(script: F.analysis("The user wants Paris.")
                + F.call("get_weather", #"{"city":"Paris"}"#) + "<|call|>")
            let outcome = try await serve(engine, choice: choice)
            let request = try #require(engine.submitted.first)
            let constraint = try #require(request.tokenConstraint as? GPTOSSForcedToolConstraint)
            #expect(constraint.maxTokens == request.maxTokens)
            #expect(outcome.error == nil)
            #expect(outcome.calls.map(\.function.name) == ["get_weather"])
            #expect(outcome.calls.first?.function.arguments == ["city": .string("Paris")])
            #expect(outcome.reasoning == "The user wants Paris.")
            #expect(outcome.content.isEmpty)
        }
    }

    @Test("a forced response that stops in the call header fails closed, showing nothing")
    func stopBeforeTheCallFailsClosed() async throws {
        let engine = HarmonyScriptedEngine(script: F.analysis("No tool is needed.")
            + "<|start|>assistant<|channel|>final<|message|>It is sunny.<|return|>")
        let outcome = try await serve(engine, choice: F.namedWeather)
        #expect(outcome.content.isEmpty && outcome.calls.isEmpty)
        let error = try #require(outcome.error)
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 422)
    }

    @Test("auto submits no constraint")
    func autoIsUnconstrained() async throws {
        let engine = HarmonyScriptedEngine(script: "<|channel|>final<|message|>Sunny.<|return|>")
        let outcome = try await serve(engine, choice: "auto")
        let submitted = try #require(engine.submitted.first)
        #expect(submitted.tokenConstraint == nil)
        #expect(outcome.error == nil && outcome.content == "Sunny.")
    }
}

#if DEBUG
/// A forced GPT-OSS response the token limit cuts before its call is whole
/// (`TokenLimitCutPolicy`): a normal `length` finish with nothing of the call
/// shown, or the refusal again with `DARKBLOOM_LENGTH_FINISH_AT_LIMIT` off.
@Suite("GPT-OSS forced calls cut at the token limit")
struct GPTOSSForcedToolCutTests {
    private typealias F = GPTOSSForcedFixture

    private func serve(_ output: String, endsAtLength: Bool) async throws -> HarmonyOutcome {
        let request = try F.request(choice: "required")
        var prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
        prepared.cutAnswersEndAtLength = endsAtLength
        let handler = try #require(try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
            modelType: "gpt_oss"))
        let upstream = AsyncStream<GenerationEvent> { continuation in
            continuation.yield(.chunk(output))
            continuation.yield(.info(promptTokens: 1, completionTokens: 40, tokensPerSecond: 0,
                finishReason: "length"))
            continuation.finish()
        }
        let stream = try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
            upstream: upstream, cancelUpstream: {}, prepared: prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: "gpt-oss-20b"), toolHandler: handler)
        var outcome = HarmonyOutcome()
        do {
            for try await event in stream { outcome.record(event) }
        } catch { outcome.error = error }
        outcome.finish()
        return outcome
    }

    @Test("a cut in the call header or its arguments ends as length", arguments: [
        GPTOSSForcedFixture.analysis("Paris.") + "<|start|>assistant<|channel|>commentary to=functions.get_wea",
        GPTOSSForcedFixture.analysis("Paris.") + GPTOSSForcedFixture.call("get_weather", #"{"city":"Par"#),
    ])
    func cutCallEndsAsLength(output: String) async throws {
        let cut = try await serve(output, endsAtLength: true)
        #expect(cut.error == nil, "\(String(describing: cut.error))")
        #expect(cut.info?.stopReason == "length")
        #expect(cut.calls.isEmpty && cut.content.isEmpty)
        #expect(cut.reasoning == "Paris.")
        let refused = try await serve(output, endsAtLength: false)
        #expect(refused.error.map { ProviderLoop.mapInferenceErrorToStatus($0) } == 422)
        #expect(refused.calls.isEmpty && refused.content.isEmpty)
    }
}
#endif
