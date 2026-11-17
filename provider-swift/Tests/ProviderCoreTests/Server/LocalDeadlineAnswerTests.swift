import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

/// A local request that reaches its overall deadline (the engine's safety ceiling or its legacy total wall on one Mac,
/// a pair's request deadline) is answered busy: a 503 with `Retry-After` before any SSE header, or, once its stream
/// started, an error chunk in the busy words with code `capacity_busy`. Before, the client got "Response generation
/// failed" (streamed) or a 500 "Inference generation failed." (not streamed). Any other engine end keeps today's answer.
/// The engine here is one queue the test admits and ends; no tensors.
@Suite("A local request at its deadline is answered busy", .timeLimit(.minutes(1)))
struct LocalDeadlineAnswerTests {
    private static let model = "deadline/model"
    private static let key = "synthetic-deadline-token"
    private static let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer \(key)"]

    private static func app(_ engine: HeadHoldEngine) async -> LocalInferenceApplication {
        let tokenizer = TokenizerHandle(DeadlineTokenizer())
        let bridge = EngineV2Bridge(engine: engine, modelId: model, tokenizer: tokenizer, eosTokenIds: [],
            defaultMaxTokens: 32_768, defaultMaxTokensContextLimit: 262_144, maxConcurrentRequests: 4,
            kvBudget: GlobalKVCacheBudget(memorySnapshot: {
                .init(total: 256 << 30, active: 0, cache: 0, systemAvailable: 256 << 30)
            }))
        await bridge.setQueuePollIntervalForTesting(.milliseconds(5))
        return makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: key),
            defaultMaxTokens: StandaloneServer.slotDefaultMaxTokens,
            acquire: { id in
                .init(tokenizer: tokenizer, releaseToken: OneShotRelease(release: { _ in }, modelId: id),
                      modelType: nil, container: nil, isVLM: false, engineV2Bridge: bridge,
                      visionGate: VisionMemoryGate(kvBudget: nil, fp16KVBytesPerToken: 0, contextLength: 0))
            },
            tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: nil) },
            availableModels: { [model] }, mtpSlots: { [] }, prefillTicker: nil, memoryWaitLimit: nil)
    }

    /// The request admitted, then ended by the engine with `end` and no token.
    private static func answer(_ end: CBv2FinishReason, stream: Bool) async throws
        -> (status: HTTPResponse.Status, retryAfter: String?, body: String) {
        let engine = HeadHoldEngine()
        engine.admit()
        return try await Self.app(engine).test(.router) { client in
            async let answer = client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                body: ByteBuffer(string: #"{"model":"\#(Self.model)","messages":[{"role":"user","content":"hi"}],"#
                    + #""stream":\#(stream)}"#))
            for _ in 0 ..< 400 where engine.submitted == 0 { try await Task.sleep(for: .milliseconds(5)) }
            #expect(engine.submitted == 1)
            engine.end(end)
            let response = try await answer
            return (response.status, response.headers[.retryAfter], String(buffer: response.body))
        }
    }

    static let deadlineEnds: [CBv2FinishReason] = [
        .terminal(cause: .safetyDeadline, message: "request exceeded its absolute safety ceiling"),
        .error("request exceeded 120s deadline"),
    ]

    @Test(arguments: deadlineEnds)
    func aStreamedRequestAtItsDeadlineEndsWithTheBusyWords(end: CBv2FinishReason) async throws {
        let answer = try await Self.answer(end, stream: true)
        #expect(answer.status == .ok, "its head went out at admission")
        #expect(answer.body.contains(LocalMemoryRefusal.deadline), "\(answer.body.suffix(400))")
        #expect(answer.body.contains(#""code":"capacity_busy""#), "\(answer.body.suffix(400))")
        #expect(!answer.body.contains("Response generation failed"), "\(answer.body.suffix(400))")
        #expect(answer.body.contains(#""finish_reason":"error""#) && !answer.body.contains("[DONE]"))
    }

    @Test(arguments: deadlineEnds)
    func aRequestThatIsNotStreamedAtItsDeadlineIsABusy503(end: CBv2FinishReason) async throws {
        let answer = try await Self.answer(end, stream: false)
        #expect(answer.status == .serviceUnavailable, "\(answer.body.prefix(300))")
        #expect(answer.retryAfter == String(LocalMemoryRefusal.retryAfterSeconds))
        #expect(answer.body.contains(LocalMemoryRefusal.deadline), "\(answer.body.prefix(300))")
        #expect(answer.body.contains(#""code":"capacity_busy""#), "\(answer.body.prefix(300))")
    }

    /// Any other engine end keeps today's answer: the request's deadline is the only one answered busy.
    @Test(arguments: [false, true])
    func anyOtherEngineEndKeepsItsAnswer(stream: Bool) async throws {
        let answer = try await Self.answer(.terminal(cause: .watchdog, message: "step wedged"), stream: stream)
        #expect(!answer.body.contains(LocalMemoryRefusal.deadline), "\(answer.body.suffix(300))")
        #expect(!answer.body.contains("capacity_busy"), "\(answer.body.suffix(300))")
        if stream { #expect(answer.body.contains("Response generation failed")) }
        else { #expect(answer.status.code >= 500 && answer.status != .serviceUnavailable) }
    }

    /// `cluster local`: a pair's stream whose request ended at its request deadline ends with the busy words in
    /// place of the shared pipeline's failure frame; the chunk keeps its identity and the attempt's usage.
    @Test func aPairsStreamAtItsRequestDeadlineEndsWithTheBusyWords() async throws {
        let control = DistributedHTTPResponse(), capture = HTTPDeliveryCapture()
        try control.bind(deadline: nil, cancel: capture.cancel)
        control.recordTerminal(.init(promptTokens: 3, completionTokens: 1, cause: .safetyDeadline))
        let failure = #"data: {"choices":[{"delta":{"content":""},"finish_reason":"error","index":0}],"#
            + #""created":7,"error":{"code":"server_error","message":"Response generation failed","#
            + #""type":"server_error"},"id":"chatcmpl-deadline","model":"m","object":"chat.completion.chunk"}"#
            + "\n\n"
        let values = [try httpDeliveryFrame(role: "assistant"), try httpDeliveryFrame(content: "fixture"), failure]
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for value in values { continuation.yield(value) }; continuation.finish()
        }
        let response = DistributedHTTPEventStream.response(stream, control: control)
        try await response.body.write(HTTPDeliveryWriter(capture: capture))
        let last = try #require(capture.values.last)
        #expect(last.contains(LocalMemoryRefusal.deadline) && last.contains(#""code":"capacity_busy""#), "\(last)")
        #expect(!capture.values.joined().contains("Response generation failed"))
        #expect(!capture.values.contains(ServerSentEventEncoder.done))
    }

    /// Only the shared pipeline's failure frame is rewritten, in place: the same chunk with its error in the busy words.
    @Test func onlyAFailureFrameIsRewritten() throws {
        #expect(LocalDeadlineOutcome.busyFrame(replacing: try httpDeliveryFrame(content: "fixture")) == nil)
        #expect(LocalDeadlineOutcome.busyFrame(replacing: ServerSentEventEncoder.done) == nil)
        let failure = #"data: {"choices":[{"delta":{"content":""},"finish_reason":"error","index":0}],"created":7,"#
            + #""error":{"code":"server_error","message":"Response generation failed","type":"server_error"},"#
            + #""id":"chatcmpl-x","model":"m","object":"chat.completion.chunk","usage":{"completion_tokens":1,"#
            + #""prompt_tokens":3,"total_tokens":4}}"# + "\n\n"
        let busy = try #require(LocalDeadlineOutcome.busyFrame(replacing: failure))
        #expect(busy.hasPrefix("data: ") && busy.hasSuffix("\n\n"))
        #expect(busy.contains(LocalMemoryRefusal.deadline) && busy.contains(#""code":"capacity_busy""#))
        #expect(busy.contains(#""id":"chatcmpl-x""#) && busy.contains(#""prompt_tokens":3"#))
        #expect(!busy.contains("Response generation failed"))
    }
}

/// Renders every conversation to 8 tokens.
private struct DeadlineTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Array(repeating: 1, count: 8) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }; var eosToken: String? { nil }; var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { Array(repeating: 1, count: 8) }
}
