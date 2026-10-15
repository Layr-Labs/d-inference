// Copyright © 2026 Eigen Labs.
//
// DecisionRunner through the real scheduler and bridge over a scripted CBv2
// engine: the engine plays the 255-row decision head by emitting the
// reference `engine_logprobs` as its first token's top-k list.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Emits one delta whose top-k list is every head row of `headLogprobs`,
/// ranked as the engine does (descending), then a `length` terminal.
private final class DecisionHeadEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private let headLogprobs: [Float]
    private let promptTokens: Int
    private var _submitted: [CBv2Request] = []

    init(headLogprobs: [Float], promptTokens: Int = 37) {
        self.headLogprobs = headLogprobs
        self.promptTokens = promptTokens
    }

    var submitted: [CBv2Request] { lock.withLock { _submitted } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { _submitted.append(request) }
        let ranked = headLogprobs.enumerated().sorted { $0.element > $1.element }
            .prefix(request.sampling.topLogprobs)
            .map { (token: $0.offset, logprob: $0.element) }
        let best = ranked.first?.token ?? 0
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        continuation.yield(.delta(
            text: "c", tokens: [best],
            logprobs: [CBv2TokenLogprob(token: best, logprob: headLogprobs[best], topLogprobs: ranked)]))
        continuation.yield(.finished(
            reason: .length, usage: CBv2Usage(promptTokens: promptTokens, completionTokens: 1)))
        continuation.finish()
        return stream
    }

    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func updateKVBytesCapacity(_ bytes: Int) {}
    func shutdown() async {}
}

/// Records what the scheduler hands the chat template.
private final class TemplateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [[[String: any Sendable]]] = []
    private var _contexts: [[String: any Sendable]?] = []

    func record(_ messages: [[String: any Sendable]], _ context: [String: any Sendable]?) {
        lock.withLock {
            _messages.append(messages)
            _contexts.append(context)
        }
    }

    var messages: [[[String: any Sendable]]] { lock.withLock { _messages } }
    var contexts: [[String: any Sendable]?] { lock.withLock { _contexts } }
}

private struct RecordingTokenizer: MLXLMCommon.Tokenizer {
    let recorder: TemplateRecorder
    var promptTokens: [Int] = Array(repeating: 7, count: 12)

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { "r\($0)" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        recorder.record(messages, additionalContext)
        return promptTokens
    }
}

@Suite("DecisionRunner over the v2 engine path")
struct DecisionRunnerTests {
    private struct Harness {
        let engine: DecisionHeadEngine
        let recorder: TemplateRecorder
        let runner: DecisionRunner
        let configuration: PplxDeciderConfiguration
    }

    private static let modelID = "pplx-decider-v1-27b"

    private func configuration(maxInputTokens: Int = 8192) throws -> PplxDeciderConfiguration {
        let vectors = try DecisionReferenceVectors.load()
        let block = DecisionJSON.object([
            .init(key: "format_version", value: .integer("1")),
            .init(key: "options", value: .integer("255")),
            .init(key: "temperature", value: try #require(vectors["temperature"])),
            .init(key: "codes", value: try #require(vectors["codes"])),
            .init(key: "token_ids", value: try #require(vectors["token_ids"])),
            .init(key: "max_input_tokens", value: .integer(String(maxInputTokens))),
        ])
        return try JSONDecoder().decode(PplxDeciderConfiguration.self, from: Data(block.compactJSON.utf8))
    }

    private func harness(
        headLogprobs: [Float], modelType: String = "pplx_decider_qwen35",
        promptTokens: Int = 12, maxInputTokens: Int = 8192
    ) throws -> Harness {
        let engine = DecisionHeadEngine(headLogprobs: headLogprobs)
        let recorder = TemplateRecorder()
        let tokenizer = TokenizerHandle(RecordingTokenizer(
            recorder: recorder, promptTokens: Array(repeating: 7, count: promptTokens)))
        let bridge = EngineV2Bridge(
            engine: engine, modelId: Self.modelID, tokenizer: tokenizer, eosTokenIds: [248_046])
        let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(
            tokenizer: tokenizer, modelType: modelType, engineV2Bridge: bridge)
        let configuration = try configuration(maxInputTokens: maxInputTokens)
        let runner = DecisionRunner(configuration: configuration) { submission in
            MultiModelBatchSchedulerEngine(
                registryProvider: { [Self.modelID: entry] },
                engineV2Logprobs: submission.logprobs,
                decisionInputTokenLimit: submission.inputTokenLimit)
        }
        return Harness(engine: engine, recorder: recorder, runner: runner, configuration: configuration)
    }

    private func request(_ questions: String, state: String = #""My Stripe integration keeps failing.""#) throws
        -> DecisionRequest
    {
        try DecisionRequest.parse(Data(
            #"{"model": "\#(Self.modelID)", "state": \#(state), "questions": {\#(questions)}}"#.utf8))
    }

    private func headLogprobs(count: Int) throws -> (logprobs: [Float], probabilities: [Double]) {
        let cases = try #require(DecisionReferenceVectors.load()["probabilities"]?.array)
        let item = try #require(cases.first { $0["count"]?.number == Double(count) })
        let logprobs = try DecisionReferenceVectors.probabilities(item["engine_logprobs"]).map(Float.init)
        return (logprobs, try DecisionReferenceVectors.probabilities(item["probabilities"]))
    }

    @Test("readout probabilities equal the reference forward/predict math", arguments: [2, 3, 5, 30])
    func readoutMatchesReference(count: Int) async throws {
        let (logprobs, expected) = try headLogprobs(count: count)
        let question: String
        switch count {
        case 2:
            question = #""q": {"type": "noul"}"#
        case 5:
            question = #""q": {"type": "score", "criteria": ["a", "b", "c", "d", "e"]}"#
        default:
            let options = (0 ..< count).map { #""o\#($0)": null"# }.joined(separator: ", ")
            question = #""q": {"type": "choice", "criteria": {\#(options)}}"#
        }
        let harness = try harness(headLogprobs: logprobs)
        let outcome = try await harness.runner.run(try request(question))
        let answer = try #require(outcome.response["answers"]?["q"])
        let got: [Double]
        if count == 2 {
            got = [1 - (answer["noul"]?.number ?? .nan), answer["noul"]?.number ?? .nan]
        } else {
            got = try #require(answer["probabilities"]?.members).map { try #require($0.value.number) }
        }
        #expect(got.count == expected.count)
        for (value, reference) in zip(got, expected) {
            #expect(abs(value - reference) <= 1e-5, "\(value) vs \(reference)")
        }
        #expect(outcome.inputTokens == 37)
        #expect(outcome.outputTokens == 1)
    }

    @Test("each question submits one greedy token with the full head and no-op sampling")
    func submissionShape() async throws {
        let (logprobs, _) = try headLogprobs(count: 3)
        let harness = try harness(headLogprobs: logprobs)
        let outcome = try await harness.runner.run(try request(
            #""team": {"type": "choice", "criteria": {"billing": "b", "technical_support": "t", "sales": "s"}}, "#
                + #""urgent": {"type": "noul", "instructions": "Does this message express urgency?"}"#))
        #expect(outcome.response["answers"]?.members?.map(\.key) == ["team", "urgent"])
        #expect(outcome.inputTokens == 74)
        #expect(outcome.outputTokens == 2)
        #expect(outcome.response["usage"] == .object([
            .init(key: "input_tokens", value: .integer("74")),
            .init(key: "output_tokens", value: .integer("2")),
        ]))
        #expect(outcome.response["object"] == .string("decision"))
        let submitted = harness.engine.submitted
        #expect(submitted.count == 2)
        for request in submitted {
            #expect(request.maxTokens == 1)
            #expect(request.sampling.topLogprobs == 255)
            #expect(request.sampling.temperature == 0)
            #expect(request.sampling.topP == 1)
            #expect(request.sampling.topK == 0)
            #expect(request.sampling.repetitionPenalty == 1)
            #expect(request.sampling.frequencyPenalty == 0)
            #expect(request.sampling.presencePenalty == 0)
            #expect(request.sampling.logitBias.isEmpty)
        }
        // The rendered conversation is the reference message shape with
        // thinking disabled.
        let first = try #require(harness.recorder.messages.first)
        #expect(first.count == 2)
        #expect(first[0]["role"] as? String == "system")
        #expect(first[0]["content"] as? String == DecisionPrompt.systemPrompt)
        #expect(first[1]["role"] as? String == "user")
        #expect((first[1]["content"] as? String)?.hasPrefix("State:\nMy Stripe integration keeps failing.") == true)
        let context = try #require(harness.recorder.contexts.first ?? nil)
        #expect(context["enable_thinking"] as? Bool == false)
    }

    @Test("a prompt over max_input_tokens is refused before engine admission")
    func inputLimit() async throws {
        let (logprobs, _) = try headLogprobs(count: 2)
        let harness = try harness(headLogprobs: logprobs, promptTokens: 9, maxInputTokens: 8)
        await #expect(throws: DecisionRequestError.inputTooLong(limit: 8)) {
            try await harness.runner.run(try request(#""q": {"type": "noul"}"#))
        }
        #expect(harness.engine.submitted.isEmpty)
    }

    @Test("a decision engine view refuses a non-decision model")
    func decisionToChatModel() async throws {
        let (logprobs, _) = try headLogprobs(count: 2)
        let harness = try harness(headLogprobs: logprobs, modelType: "qwen3_5")
        await #expect(throws: DecisionRequestError.notADecisionModel) {
            try await harness.runner.run(try request(#""q": {"type": "noul"}"#))
        }
        #expect(harness.engine.submitted.isEmpty)
    }

    @Test("chat to a decision model is refused before any work")
    func chatToDecisionModel() async throws {
        let engine = DecisionHeadEngine(headLogprobs: [0])
        let tokenizer = TokenizerHandle(RecordingTokenizer(recorder: TemplateRecorder()))
        let bridge = EngineV2Bridge(
            engine: engine, modelId: Self.modelID, tokenizer: tokenizer, eosTokenIds: [248_046])
        let chat = MultiModelBatchSchedulerEngine(registryProvider: {
            [Self.modelID: .init(tokenizer: tokenizer, modelType: "pplx_decider_qwen35", engineV2Bridge: bridge)]
        })
        await #expect(throws: DecisionRequestError.decisionModelRequiresDecisionRequest) {
            _ = try await chat.streamChatCompletion(request: OpenAIChatCompletionRequest(
                model: Self.modelID, messages: [OpenAIChatMessage(role: .user, content: .text("hi"))]))
        }
        #expect(engine.submitted.isEmpty)
        #expect(ProviderLoop.mapInferenceErrorToStatus(DecisionRequestError.decisionModelRequiresDecisionRequest) == 400)
        #expect(ProviderLoop.sanitizedInferenceFailure(
            from: DecisionRequestError.inputTooLong(limit: 8), phase: .streamStart).code == .invalidRequest)
    }

    @Test("logprob alternatives carry head rows in-process but never on the wire")
    func tokenIDIsNotEncoded() throws {
        let entries = EngineV2Translation.sseTokenLogprobs(
            [CBv2TokenLogprob(token: 3, logprob: -0.5, topLogprobs: [(token: 3, logprob: -0.5), (token: 9, logprob: -1)])],
            decodeToken: { "t\($0)" })
        #expect(entries[0].topLogprobs.map(\.tokenID) == [3, 9])
        let encoded = try JSONEncoder().encode(entries[0].topLogprobs[1])
        let wire = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(wire.keys) == ["token", "logprob", "bytes"])
        #expect(EngineV2Translation.topLogprobs(logprobs: true, topLogprobs: 255) == 20)
        #expect(EngineV2Translation.topLogprobs(logprobs: true, topLogprobs: 255, maximum: 255) == 255)
        #expect(EngineV2Translation.topLogprobs(logprobs: true, topLogprobs: 300, maximum: 255) == 255)
        #expect(EngineV2Translation.topLogprobs(logprobs: false, topLogprobs: 255, maximum: 255) == 0)
    }
}
