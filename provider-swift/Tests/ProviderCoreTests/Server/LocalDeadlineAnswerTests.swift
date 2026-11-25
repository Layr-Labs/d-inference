import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import MLXLMCommon
import MLXLMServer
import NIOCore
import NIOEmbedded
import Testing
@testable import ProviderCore

/// A local request that reaches its overall deadline (the engine's safety ceiling or its legacy total wall on one Mac,
/// a pair's request deadline) is answered busy: a 503 with `Retry-After` before any SSE header, or, once its stream
/// started, its failure event in the busy words with code `capacity_busy`, on every streamed API (chat, Responses,
/// completions). It is this Mac's answer: the local router never passes it on. Before, the client got "Response
/// generation failed" (streamed) or a 504 or 500 (not streamed). Any other engine end keeps today's answer. The engine
/// here is one queue the test admits and ends; no tensors.
@Suite("A local request at its deadline is answered busy", .timeLimit(.minutes(1)))
struct LocalDeadlineAnswerTests {
    private static let model = "deadline/model"
    private static let key = "synthetic-deadline-token"
    private static let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer \(key)"]

    private static func app(_ engine: HeadHoldEngine, router: LocalRouterConfig? = nil) async -> LocalInferenceApplication {
        let tokenizer = TokenizerHandle(DeadlineTokenizer())
        let bridge = EngineV2Bridge(engine: engine, modelId: model, tokenizer: tokenizer, eosTokenIds: [],
            defaultMaxTokens: 32_768, defaultMaxTokensContextLimit: 262_144, maxConcurrentRequests: 4,
            kvBudget: GlobalKVCacheBudget(memorySnapshot: {
                .init(total: 256 << 30, active: 0, cache: 0, systemAvailable: 256 << 30)
            }))
        await bridge.setQueuePollIntervalForTesting(.milliseconds(5))
        return makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: key, router: router),
            defaultMaxTokens: StandaloneServer.slotDefaultMaxTokens,
            acquire: { id in
                .init(tokenizer: tokenizer, releaseToken: OneShotRelease(release: { _ in }, modelId: id),
                      modelType: nil, container: nil, isVLM: false, engineV2Bridge: bridge,
                      visionGate: VisionMemoryGate(kvBudget: nil, fp16KVBytesPerToken: 0, contextLength: 0))
            },
            tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: nil) },
            availableModels: { [model] }, mtpSlots: { [] }, prefillTicker: nil, memoryWaitLimit: nil)
    }

    /// The request admitted, then ended by the engine with `end` and no token. `path`: a chat request by default, else
    /// a Responses (`/v1/responses`) or completions (`/v1/completions`) one.
    private static func answer(_ end: CBv2FinishReason, stream: Bool, path: String = "/v1/chat/completions",
                               router: LocalRouterConfig? = nil) async throws
        -> (status: HTTPResponse.Status, retryAfter: String?, body: String) {
        let engine = HeadHoldEngine()
        engine.admit()
        let input = switch path {
        case "/v1/responses": #""input":"hi""#
        case "/v1/completions": #""prompt":"hi""#
        default: #""messages":[{"role":"user","content":"hi"}]"#
        }
        return try await Self.app(engine, router: router).test(.router) { client in
            async let answer = client.execute(uri: path, method: .post, headers: Self.headers,
                body: ByteBuffer(string: #"{"model":"\#(Self.model)",\#(input),"stream":\#(stream)}"#))
            for _ in 0 ..< 2000 where engine.submitted == 0 { try await Task.sleep(for: .milliseconds(5)) }
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

    /// A streamed Responses or completions request at its deadline ends with its failure event in the busy words.
    @Test(arguments: ["/v1/responses", "/v1/completions"])
    func everyStreamedAPIEndsWithTheBusyWords(path: String) async throws {
        let answer = try await Self.answer(Self.deadlineEnds[0], stream: true, path: path)
        #expect(answer.status == .ok, "its head went out at admission")
        #expect(answer.body.contains(LocalMemoryRefusal.deadline), "\(answer.body.suffix(400))")
        #expect(answer.body.contains(#""code":"capacity_busy""#), "\(answer.body.suffix(400))")
        #expect(!answer.body.contains("Response generation failed"), "\(answer.body.suffix(400))")
        let notStreamed = try await Self.answer(Self.deadlineEnds[0], stream: false, path: path)
        #expect(notStreamed.status == .serviceUnavailable, "\(notStreamed.body.prefix(300))")
        #expect(notStreamed.retryAfter == String(LocalMemoryRefusal.retryAfterSeconds))
    }

    /// A request that ran to its deadline here is this Mac's answer: the local router never passes it on, where it would
    /// start over (on the paid network, with `my-macs-first`).
    @Test(arguments: [LocalSettings.Route.myMacsFirst, .myMacs])
    func theRouterNeverPassesOnARequestAtItsDeadline(route: LocalSettings.Route) async throws {
        let upstream = RouterStubUpstream { _ in .json(200, #"{"id":"chatcmpl-up","object":"chat.completion","choices":[]}"#) }
        let router = LocalRouterConfig(settings: LocalSettings(route: route),
            upstreamBaseURL: URL(string: "http://coordinator.invalid")!, takesCoordinatorWork: false,
            accountKeys: InMemoryLocalRouterAccountKeyStore("sk-synthetic-deadline-fixture"),
            makeTransport: { upstream }, log: { _ in })
        let answer = try await Self.answer(Self.deadlineEnds[1], stream: false, router: router)
        #expect(answer.status == .serviceUnavailable, "\(answer.body.prefix(300))")
        #expect(answer.body.contains(LocalMemoryRefusal.deadline), "\(answer.body.prefix(300))")
        #expect(upstream.posts.isEmpty, "passed on: \(upstream.posts.map(\.route))")
    }

    /// An error of any type after the engine marked the deadline is answered busy, before any header.
    @Test func anyErrorAfterTheDeadlineIsBusy() async throws {
        struct MarksThenFails: HTTPResponder {
            func respond(to request: Request, context: BasicRequestContext) async throws -> Response {
                LocalDeadlineOutcome.current?.markReached()
                throw MLXOpenAIServiceError.multipleToolCallsNotAllowed
            }
        }
        let request = Request(head: .init(method: .post, scheme: "http", authority: "localhost",
                                          path: "/v1/chat/completions"), body: .init(buffer: ByteBuffer()))
        let context = BasicRequestContext(source: ApplicationRequestContextSource(
            channel: EmbeddedChannel(), logger: Logger(label: #function)))
        let response = try await CORSResponder(inner: MarksThenFails()).respond(to: request, context: context)
        #expect(response.status == .serviceUnavailable)
        #expect(response.headers[.retryAfter] == String(LocalMemoryRefusal.retryAfterSeconds))
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
        // A Responses stream's failure event: its response's error, in the same words and code.
        let failed = "event: response.failed\n" + #"data: {"response":{"error":{"code":"server_error","#
            + #""message":"Response generation failed"},"id":"resp_x","status":"failed"},"sequence_number":4,"#
            + #""type":"response.failed"}"# + "\n\n"
        let event = try #require(LocalDeadlineOutcome.busyFrame(replacing: failed))
        #expect(event.hasPrefix("event: response.failed\ndata: ") && event.hasSuffix("\n\n"))
        #expect(event.contains(LocalMemoryRefusal.deadline) && event.contains(#""code":"capacity_busy""#))
        #expect(event.contains(#""id":"resp_x""#) && event.contains(#""sequence_number":4"#))
        #expect(!event.contains("Response generation failed"))
        #expect(LocalDeadlineOutcome.busyFrame(replacing: "event: response.completed\n" + #"data: {"response":{}}"#
            + "\n\n") == nil)
    }

    /// The engine's legacy total wall, in its own words (`EngineLoopV2`: "request exceeded Ns deadline").
    @Test func theLegacyWallIsReadInTheEnginesWords() {
        #expect(LocalDeadlineOutcome.isLegacyDeadline("request exceeded 120s deadline"))
        #expect(LocalDeadlineOutcome.isLegacyDeadline("request exceeded 3600s deadline"))
        #expect(!LocalDeadlineOutcome.isLegacyDeadline("request queue full: engine is shutting down"))
        #expect(LocalDeadlineOutcome.isDeadline(.safetyDeadline) && !LocalDeadlineOutcome.isDeadline(.watchdog))
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
