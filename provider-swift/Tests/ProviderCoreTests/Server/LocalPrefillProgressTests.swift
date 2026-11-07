import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

/// A long prompt on the local API shows progress: from the moment this Mac's engine accepts a streamed request until
/// its first token, an SSE comment every 5 s (`: prefill <done>/<total> tokens`, which OpenAI clients ignore), through
/// the local router unchanged. Before, a 255K-token prompt streamed nothing for 9 minutes after its first chunk. The
/// timer runs only during the prefill, never for a request that is not streamed, and writes nothing for a prompt done
/// within 5 s. The clock is the test's and the engine a gate the test opens.
@Suite("The local API says a streamed request's prompt progress", .timeLimit(.minutes(1)))
struct LocalPrefillProgressTests {
    private static let model = "prefill/model"
    private static let key = "synthetic-prefill-fixture-token"
    private static let promptTokens = 8

    /// This Mac's local API over a bridge on `engine`, its prompts commented on with `clock`.
    private static func app(_ engine: PrefillGateEngine, clock: PrefillTestClock,
                            router: LocalRouterConfig? = nil) -> LocalInferenceApplication {
        let tokenizer = TokenizerHandle(PrefillTokenizer(count: promptTokens))
        let bridge = EngineV2Bridge(engine: engine, modelId: model, tokenizer: tokenizer, eosTokenIds: [],
            defaultMaxTokens: 32_768, defaultMaxTokensContextLimit: 262_144, maxConcurrentRequests: 4,
            kvBudget: GlobalKVCacheBudget(memorySnapshot: {
                .init(total: 256 << 30, active: 0, cache: 0, systemAvailable: 256 << 30)
            }))
        return makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: key, router: router),
            defaultMaxTokens: StandaloneServer.slotDefaultMaxTokens,
            acquire: { id in
                .init(tokenizer: tokenizer, releaseToken: OneShotRelease(release: { _ in }, modelId: id),
                      modelType: nil, container: nil, isVLM: false, engineV2Bridge: bridge,
                      visionGate: VisionMemoryGate(kvBudget: nil, fp16KVBytesPerToken: 0, contextLength: 0))
            },
            tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: nil) },
            availableModels: { [model] }, mtpSlots: { [] },
            prefillTicker: clock.ticker)
    }

    private static let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer \(key)"]

    private static func chat(stream: Bool) -> ByteBuffer {
        ByteBuffer(string: #"{"model":"\#(model)","messages":[{"role":"user","content":"hi"}],"stream":\#(stream)}"#)
    }

    /// The SSE body's events and comments, in order.
    private static func events(_ body: ByteBuffer) -> [String] {
        String(buffer: body).components(separatedBy: "\n\n").filter { !$0.isEmpty }
    }

    @Test func aStreamedPromptIsSaidEveryFiveSecondsUntilItsFirstToken() async throws {
        let engine = PrefillGateEngine(), clock = PrefillTestClock()
        let response = try await Self.app(engine, clock: clock).test(.router) { client in
            async let answer = client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                              body: Self.chat(stream: true))
            // Accepted: the request's one timer waits 5 s.
            #expect(await clock.eventually { $0.sleeps == 1 && $0.sleeping == 1 })
            #expect(clock.intervals == [.seconds(5)])
            clock.tick()
            #expect(await clock.eventually { $0.sleeps == 2 && $0.sleeping == 1 })
            // The engine reports the prompt done; the next comment says so.
            engine.completePrompts()
            clock.tick()
            #expect(await clock.eventually { $0.sleeps == 3 && $0.sleeping == 1 })
            // The first token ends the timer at once.
            engine.answer()
            return try await answer
        }
        #expect(response.status == .ok)
        #expect(clock.sleeping == 0 && clock.cancelled == 1)
        let events = Self.events(response.body)
        let comments = events.filter { $0.hasPrefix(":") }
        #expect(comments == [": prefill 0/8 tokens", ": prefill 8/8 tokens"])
        // After the role chunk and before the first content, and only there.
        let role = try #require(events.firstIndex { $0.contains(#""role":"assistant""#) })
        let content = try #require(events.firstIndex { $0.contains(#""content":"Hi""#) })
        let said = events.indices.filter { events[$0].hasPrefix(":") }
        #expect(said.allSatisfy { role < $0 && $0 < content }, "\(events)")
        #expect(events.last == "data: [DONE]")
    }

    @Test func aPromptDoneWithinFiveSecondsWritesNothing() async throws {
        let engine = PrefillGateEngine(), clock = PrefillTestClock()
        let response = try await Self.app(engine, clock: clock).test(.router) { client in
            async let answer = client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                              body: Self.chat(stream: true))
            #expect(await clock.eventually { _ in engine.submitted == 1 })
            engine.answer()
            return try await answer
        }
        #expect(response.status == .ok)
        #expect(!String(buffer: response.body).contains(": prefill"))
        #expect(clock.sleeping == 0, "no timer outlives the prefill")
    }

    @Test func aRequestThatIsNotStreamedHasNoTimer() async throws {
        let engine = PrefillGateEngine(), clock = PrefillTestClock()
        let response = try await Self.app(engine, clock: clock).test(.router) { client in
            async let answer = client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                              body: Self.chat(stream: false))
            #expect(await clock.eventually { _ in engine.submitted == 1 })
            #expect(clock.sleeps == 0)
            engine.answer()
            return try await answer
        }
        #expect(response.status == .ok)
        #expect(clock.sleeps == 0)
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
        #expect(json?["object"] as? String == "chat.completion")
    }

    @Test func aStreamedResponsesRequestIsSaidToo() async throws {
        let engine = PrefillGateEngine(), clock = PrefillTestClock()
        let response = try await Self.app(engine, clock: clock).test(.router) { client in
            async let answer = client.execute(uri: "/v1/responses", method: .post, headers: Self.headers,
                body: ByteBuffer(string: #"{"model":"\#(Self.model)","input":"hi","stream":true}"#))
            #expect(await clock.eventually { $0.sleeping == 1 })
            clock.tick()
            #expect(await clock.eventually { $0.sleeps == 2 && $0.sleeping == 1 })
            engine.answer()
            return try await answer
        }
        #expect(response.status == .ok)
        let events = Self.events(response.body)
        #expect(events.filter { $0.hasPrefix(":") } == [": prefill 0/8 tokens"])
        let comment = try #require(events.firstIndex(of: ": prefill 0/8 tokens"))
        let delta = try #require(events.firstIndex { $0.contains("response.output_text.delta") })
        #expect(comment < delta)
    }

    /// The local router returns this Mac's streamed answer as it is: the comments pass through unchanged.
    @Test func theCommentsPassThroughTheLocalRouterUnchanged() async throws {
        let engine = PrefillGateEngine(), clock = PrefillTestClock()
        let upstream = RouterStubUpstream { _ in .json(500, "{}") }
        let factory = RouterTransportFactory(upstream)
        var router = LocalRouterConfig(
            settings: LocalSettings(route: .myMacs), upstreamBaseURL: RouterFixture.upstreamBase,
            takesCoordinatorWork: false, accountKeys: CountingAccountKeyStore(RouterFixture.accountKey),
            makeTransport: { factory.make() }, log: { _ in }, timing: .init())
        router.keyChangeNotification = "io.darkbloom.test.route-key-changed." + UUID().uuidString
        let response = try await Self.app(engine, clock: clock, router: router).test(.router) { client in
            async let answer = client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                              body: Self.chat(stream: true))
            #expect(await clock.eventually { $0.sleeping == 1 })
            clock.tick()
            #expect(await clock.eventually { $0.sleeps == 2 && $0.sleeping == 1 })
            engine.answer()
            return try await answer
        }
        #expect(response.status == .ok)
        #expect(response.headers[LocalRouterPolicy.servedByHeader] == LocalRouterPolicy.thisMac)
        #expect(String(buffer: response.body).contains("\n\n: prefill 0/8 tokens\n\ndata: "))
        #expect(upstream.requests.isEmpty)
    }

    /// A pair's API (`cluster local`) already probes its stream every 500 ms while it waits: until the first token,
    /// the probe says the prompt instead, on the probes' own timer.
    @Test func aPairsAPISaysThePromptInPlaceOfItsKeepAlive() async throws {
        let control = DistributedHTTPResponse(), capture = HTTPDeliveryCapture()
        try control.bind(deadline: nil, cancel: capture.cancel)
        let prefill = LocalPrefillProgress(ticker: LocalPrefillTicker(interval: .zero, sleep: { _ in }))
        prefill.accept(promptTokens: Self.promptTokens)
        let (frames, source) = AsyncThrowingStream<String, Error>.makeStream()
        let response = DistributedHTTPEventStream.response(frames, control: control, prefill: prefill)
        let writing = Task { try await response.body.write(HTTPDeliveryWriter(capture: capture)) }
        source.yield(try httpDeliveryFrame(role: "assistant"))
        #expect(try await httpDeliveryEventually { capture.values.contains(": prefill 0/8 tokens\n\n") })
        #expect(!capture.values.contains(": keep-alive\n\n"))
        prefill.end()
        let said = capture.values.count
        #expect(try await httpDeliveryEventually { capture.values.count > said })
        #expect(capture.values[said...].allSatisfy { $0 == ": keep-alive\n\n" })
        control.recordTerminal(.init(promptTokens: Self.promptTokens, completionTokens: 1, cause: nil))
        for frame in [try httpDeliveryFrame(content: "Hi"), try httpDeliveryFrame(finish: "stop"),
                      ServerSentEventEncoder.done] { source.yield(frame) }
        source.finish()
        try await writing.value
        #expect(capture.values.last == ServerSentEventEncoder.done && capture.finishCount == 1)
    }

    @Test func theCommentSaysWhatTheEngineReported() {
        let prefill = LocalPrefillProgress()
        #expect(prefill.comment == nil, "nothing before the engine accepts the request")
        prefill.advance(to: 3)
        prefill.accept(promptTokens: 255_000)
        #expect(prefill.comment == ": prefill 0/255000 tokens\n\n")
        prefill.advance(to: 128_000)
        prefill.advance(to: 1_000)
        #expect(prefill.comment == ": prefill 128000/255000 tokens\n\n", "never backwards")
        prefill.advance(to: 300_000)
        #expect(prefill.comment == ": prefill 255000/255000 tokens\n\n", "never past the prompt")
        prefill.end()
        #expect(prefill.comment == nil, "nothing after the first token")
        prefill.accept(promptTokens: 9)
        #expect(prefill.comment == nil)
    }
}

/// A clock the test moves: every sleep waits for the next `tick`.
final class PrefillTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var begun = 0
    private var cancellations = 0
    private var asked: [Duration] = []

    var sleeps: Int { lock.withLock { begun } }
    var sleeping: Int { lock.withLock { waiting.count } }
    var cancelled: Int { lock.withLock { cancellations } }
    var intervals: [Duration] { lock.withLock { asked } }

    var ticker: LocalPrefillTicker {
        LocalPrefillTicker(interval: .seconds(5), sleep: { [self] in try await sleep($0) })
    }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelledAlready = lock.withLock { () -> Bool in
                    begun += 1
                    asked.append(duration)
                    if Task.isCancelled { cancellations += 1; return true }
                    waiting[id] = continuation
                    return false
                }
                if cancelledAlready { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let continuation = waiting.removeValue(forKey: id) else { return nil }
                cancellations += 1
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Five seconds pass: every sleeper wakes.
    func tick() {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        for continuation in woken { continuation.resume() }
    }

    /// Whether `condition` holds within 2 s of real time, polled.
    func eventually(_ condition: @Sendable (PrefillTestClock) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(self) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// An engine that holds each request in its prompt until the test lets its first token go. No tensors.
final class PrefillGateEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [(request: CBv2Request, events: AsyncStream<CBv2Event>.Continuation)] = []

    var submitted: Int { lock.withLock { held.count } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock { held.append((request, continuation)) }
        return stream
    }

    /// The engine has computed every prompt (`CBv2Request.onPrefillCompleted`).
    func completePrompts() {
        for (request, _) in lock.withLock({ held }) {
            request.onPrefillCompleted?(CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: 0))
        }
    }

    /// Each request's first token, then its end.
    func answer() {
        for (request, events) in lock.withLock({ held }) {
            events.yield(.delta(text: "Hi", tokens: [1], logprobs: nil))
            events.yield(.finished(reason: .stop,
                                   usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: 1)))
            events.finish()
        }
    }

    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

/// Renders every conversation to `count` tokens.
private struct PrefillTokenizer: MLXLMCommon.Tokenizer {
    let count: Int
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Array(repeating: 1, count: count) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }; var eosToken: String? { nil }; var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { Array(repeating: 1, count: count) }
}
