import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Samples a fixed script through the submitted constraint, like a model that
/// honors the masks: the script's next token when allowed, otherwise the
/// first allowed id (a model steered by the mask), and a stop ends the row.
/// Records each submission and the tokens it produced.
private final class AutoScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let script: [Int]
    private let tokenizer: HarmonyByteTestTokenizer
    private let lock = NSLock()
    private var requests: [CBv2Request] = []
    private var outputs: [[Int]] = []

    init(script: String, tokenizer: HarmonyByteTestTokenizer = .init()) {
        self.script = HarmonyByteTestTokenizer.tokens(script, controls: tokenizer.controls)
        self.tokenizer = tokenizer
    }

    var submitted: [CBv2Request] { lock.withLock { requests } }
    var produced: [[Int]] { lock.withLock { outputs } }

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
        lock.withLock {
            requests.append(request)
            outputs.append(deltas.map(\.token))
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

/// What a client receives.
private struct AutoOutcome {
    var reasoning = ""
    var content = ""
    var calls: [ToolCall] = []
    var streamedNames: [String] = []
    var streamedArguments = ""
    var info: ServerGenerationInfo?
    var error: (any Error)?
    private var parser = StreamingReasoningParser(format: .harmony)

    mutating func record(_ event: MLXServerGenerationEvent) {
        switch event {
        case .content(let text): parser.parse(text).forEach { apply($0) }
        case .parsed(let parsed): apply(parsed)
        case .toolCall(let call): calls.append(call)
        case .toolCallDelta(let delta):
            if let name = delta.name { streamedNames.append(name) }
            streamedArguments += delta.arguments
            if let call = delta.completed { calls.append(call) }
        case .info(let info): self.info = info
        case .logprobs: break
        }
    }

    mutating func finish() { parser.finish().forEach { apply($0) } }

    private mutating func apply(_ parsed: ParsedReasoning) {
        content += parsed.content
        reasoning += parsed.reasoningContent ?? ""
    }
}

/// The scheduler reads `DARKBLOOM_HARMONY_AUTO_TOOL_GRAMMAR` at launch; with
/// it off these requests are served as before (`StreamedToolCallTests`'
/// `killSwitchReturnsUndeclaredCallsAsGenerated`).
@Suite("GPT-OSS auto tool calls through the scheduler and bridge", .enabled(if: GPTOSSAutoToolGrammar.enabled))
struct GPTOSSAutoToolServingTests {
    private typealias F = GPTOSSForcedFixture
    private typealias T = HarmonyByteTestTokenizer
    private static let tokenizer = TokenizerHandle(HarmonyByteTestTokenizer())

    private func serve(_ engine: AutoScriptedEngine, choice: Any? = "auto", maxTokens: Int = 400,
                       stream: Bool = false, parallel: Bool? = nil,
                       tokenizer: TokenizerHandle = Self.tokenizer,
                       logitsWidth: Int? = GPTOSSAutoFixture.vocabularySize) async throws -> AutoOutcome {
        let bridge = EngineV2Bridge(engine: engine, modelId: "gpt-oss-20b", tokenizer: tokenizer,
            eosTokenIds: T.stops, defaultMaxTokens: maxTokens, maxConcurrentRequests: 1, logitsWidth: logitsWidth)
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            ["gpt-oss-20b": .init(tokenizer: tokenizer, modelType: "gpt_oss", engineV2Bridge: bridge)]
        })
        var request = try F.request(choice: choice, maxTokens: maxTokens)
        if stream {
            request.stream = true
            request.streamToolCallDeltas = true
        }
        if let parallel { request.parallelToolCalls = parallel }
        var outcome = AutoOutcome()
        do {
            for try await event in try await scheduler.streamChatCompletion(request: request) {
                outcome.record(event)
            }
        } catch { outcome.error = error }
        outcome.finish()
        await bridge.shutdown()
        return outcome
    }

    @Test("auto submits the grammar; a call is served, streamed name first, then its arguments")
    func autoCallIsServed() async throws {
        for (stream, parallel) in [(false, nil), (true, nil), (true, false), (false, false)] as [(Bool, Bool?)] {
            let engine = AutoScriptedEngine(script: F.analysis("The user wants Paris.")
                + F.call("get_weather", #"{"city":"Paris"}"#) + "<|call|>")
            let outcome = try await serve(engine, stream: stream, parallel: parallel)
            let request = try #require(engine.submitted.first)
            let constraint = try #require(request.tokenConstraint as? GPTOSSAutoToolConstraint)
            #expect(constraint.maxTokens == request.maxTokens)
            #expect(outcome.error == nil, "\(String(describing: outcome.error))")
            #expect(outcome.calls.map(\.function.name) == ["get_weather"])
            #expect(outcome.calls.first?.function.arguments == ["city": .string("Paris")])
            #expect(outcome.reasoning == "The user wants Paris.")
            #expect(outcome.content.isEmpty)
            // The service turns a response with calls into `finish_reason: tool_calls`.
            #expect(outcome.info?.stopReason == "stop")
            if stream {
                #expect(outcome.streamedNames == ["get_weather"])
                #expect(outcome.streamedArguments == #"{"city":"Paris"}"#)
            }
        }
    }

    @Test("a response without a call samples exactly the tokens it would without the grammar")
    func noCallIsExact() async throws {
        let script = F.analysis("Just a greeting; no tool needed. to=functions.get_weather is not wanted.")
            + "<|start|>assistant<|channel|>commentary<|message|>Thinking aloud.<|end|>"
            + "<|start|>assistant<|channel|>final<|message|>Hello! {\"city\": 1}<|return|>"
        let engine = AutoScriptedEngine(script: script)
        let outcome = try await serve(engine)
        #expect(engine.submitted.first?.tokenConstraint is GPTOSSAutoToolConstraint)
        #expect(engine.produced.first == T.tokens(script))
        #expect(outcome.error == nil && outcome.calls.isEmpty)
        #expect(outcome.content == #"Hello! {"city": 1}"#)
    }

    @Test("an undeclared function or off-schema arguments are steered by the grammar, never served")
    func grammarSteersTheCall() async throws {
        let engine = AutoScriptedEngine(script: F.analysis("Delete.")
            + F.call("get_weather", #"{"city":7}"#) + "<|call|>")
        let outcome = try await serve(engine)
        let produced = try #require(engine.produced.first)
        let text = T().decode(tokenIds: produced, skipSpecialTokens: false)
        // The scripted `7` was refused; whatever followed is the schema's.
        #expect(!text.contains(#""city":7"#))
        #expect(outcome.calls.allSatisfy { $0.function.name == "get_weather" })
        let undeclared = AutoScriptedEngine(script: F.analysis("x") + F.call("delete_everything", "{}") + "<|call|>")
        _ = try await serve(undeclared)
        let steered = T().decode(tokenIds: try #require(undeclared.produced.first), skipSpecialTokens: false)
        #expect(!steered.contains("to=functions.d"))
    }

    @Test("forced choice keeps the forced Harmony constraint")
    func forcedChoiceUnchanged() async throws {
        let engine = AutoScriptedEngine(script: F.analysis("x") + F.call("get_weather", #"{"city":"Paris"}"#)
            + "<|call|>")
        let outcome = try await serve(engine, choice: "required")
        #expect(engine.submitted.first?.tokenConstraint is GPTOSSForcedToolConstraint)
        #expect(outcome.calls.map(\.function.name) == ["get_weather"])
    }

    @Test("without the grammar (a tokenizer it cannot verify), an undeclared call is refused, never returned")
    func undeclaredCallWithoutTheGrammarIsRefused() async throws {
        var unverified = T()
        unverified.controls.removeAll { $0.0 == "<|constrain|>" }
        let handle = TokenizerHandle(unverified)
        for stream in [false, true] {
            let engine = AutoScriptedEngine(script: F.analysis("Deleting.")
                + F.call("delete_everything", #"{"path":"/"}"#) + "<|call|>", tokenizer: unverified)
            let outcome = try await serve(engine, stream: stream, tokenizer: handle)
            #expect(engine.submitted.first?.tokenConstraint == nil)
            #expect(outcome.calls.isEmpty && outcome.streamedNames.isEmpty, "stream \(stream)")
            // The typed refusal a `strict` request gets: 422 model
            // noncompliance, `tool_check` `undeclared_name`.
            let refusal = try #require(outcome.error, "stream \(stream)")
            guard case .toolChoiceViolation? = refusal as? MultiModelBatchSchedulerEngineError else {
                Issue.record("expected a tool_choice violation, got \(refusal)"); continue
            }
            #expect(classifyToolNoncomplianceCheck(refusal) == .undeclaredName, "stream \(stream)")
            #expect(ProviderLoop.mapInferenceErrorToStatus(refusal) == 422)
            // A declared call still is one.
            let declared = AutoScriptedEngine(script: F.analysis("x") + F.call("get_time", #"{"timezone":"CET"}"#)
                + "<|call|>", tokenizer: unverified)
            let served = try await serve(declared, stream: stream, tokenizer: handle)
            #expect(served.error == nil, "\(String(describing: served.error))")
            #expect(served.calls.map(\.function.name) == ["get_time"], "stream \(stream)")
        }
    }

    @Test("logits narrower or wider than the vocabulary, or unknown: the grammar is declined")
    func logitsWidthMismatchDeclines() async throws {
        for width in [nil, GPTOSSAutoFixture.vocabularySize - 1] as [Int?] {
            let engine = AutoScriptedEngine(script: F.analysis("x") + F.call("get_weather", #"{"city":"Paris"}"#)
                + "<|call|>")
            let outcome = try await serve(engine, logitsWidth: width)
            #expect(engine.submitted.first.map { $0.tokenConstraint == nil } == true, "\(String(describing: width))")
            #expect(outcome.error == nil && outcome.calls.map(\.function.name) == ["get_weather"])
        }
    }

    @Test("a call the budget cuts still ends as length, unfinished")
    func budgetCutEndsAsLength() async throws {
        let script = F.analysis("x") + F.call("get_weather", #"{"city":"Paris"}"#) + "<|call|>"
        let budget = T.tokens(F.analysis("x") + F.call("get_weather", #"{"city":"Pa"#)).count
        for stream in [false, true] {
            let engine = AutoScriptedEngine(script: script)
            let outcome = try await serve(engine, maxTokens: budget, stream: stream)
            #expect(outcome.error == nil, "\(String(describing: outcome.error))")
            #expect(outcome.info?.stopReason == "length", "stream \(stream)")
            #expect(outcome.calls.isEmpty, "stream \(stream)")
        }
    }
}
