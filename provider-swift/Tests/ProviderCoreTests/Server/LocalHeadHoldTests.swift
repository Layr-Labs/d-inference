import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import NIOCore
import Testing
@testable import ProviderCore

/// A streamed request to this Mac's API sends its response head only once the engine has admitted it. One the engine
/// queued and then couldn't admit, because its 120 s admission lease ran out or a full paged pool outlasted its
/// requeues, gets the plain 503 with words about this Mac's memory, before any SSE header, as a refusal at submission
/// does. Before, it got HTTP 200 and then "Response generation failed". The prompt progress comments start at admission,
/// so a queued request says nothing. A request that isn't streamed says the same memory words after the lease. A
/// request the engine admits at once isn't held back: its head goes out within a few milliseconds. The engine here
/// is one queue the test opens or ends, or one that steps on its own; the clock is the test's.
@Suite("This Mac's API holds a streamed response's head until the engine admits it", .timeLimit(.minutes(1)))
struct LocalHeadHoldTests {
    private static let model = "head-hold/model"
    private static let key = "synthetic-head-hold-token"
    private static let memoryWords = "This Mac's memory can't hold this request right now."

    /// This Mac's local API over a bridge on `engine`, its prompts commented on with `clock`, looking whether a request
    /// still waits every `pollInterval` (nil: the production interval).
    private static func app(_ engine: any CBv2Engine, clock: PrefillTestClock,
                            pollInterval: Duration? = .milliseconds(5)) async -> LocalInferenceApplication {
        let tokenizer = TokenizerHandle(HeadHoldTokenizer())
        let bridge = EngineV2Bridge(engine: engine, modelId: model, tokenizer: tokenizer, eosTokenIds: [],
            defaultMaxTokens: 32_768, defaultMaxTokensContextLimit: 262_144, maxConcurrentRequests: 4,
            kvBudget: GlobalKVCacheBudget(memorySnapshot: {
                .init(total: 256 << 30, active: 0, cache: 0, systemAvailable: 256 << 30)
            }))
        if let pollInterval { await bridge.setQueuePollIntervalForTesting(pollInterval) }
        return makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: key),
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

    static let queueEnds: [CBv2FinishReason] = [
        .terminal(cause: .admissionTimeout, message: "admission lease expired"),
        .error(CBv2KVError.capacityExhaustedFinishPrefix + "pool full"),
    ]

    /// A streamed request the engine queues and then can't admit gets the memory 503, never a 200 SSE stream.
    @Test(arguments: queueEnds)
    func aStreamedRequestTheEngineCantAdmitIsA503BeforeAnySSEHeader(end: CBv2FinishReason) async throws {
        let engine = HeadHoldEngine(), clock = PrefillTestClock()
        let response = try await Self.app(engine, clock: clock).test(.router) { client in
            async let answer = client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                              body: Self.chat(stream: true))
            #expect(await clock.eventually { _ in engine.submitted == 1 })
            engine.end(end)
            return try await answer
        }
        #expect(response.status == .serviceUnavailable, "\(String(buffer: response.body))")
        #expect(response.headers[.contentType]?.hasPrefix("application/json") == true)
        let body = String(buffer: response.body)
        #expect(body.contains(Self.memoryWords), "\(body)")
        #expect(!body.contains("data:"), "no SSE frame")
        #expect(clock.sleeps == 0, "a queued request says nothing about its prompt")
    }

    /// The head and the prompt progress start when the engine admits the request; then it streams as before.
    @Test func aStreamedRequestAdmittedAfterAWaitStreamsFromItsAdmission() async throws {
        let engine = HeadHoldEngine(), clock = PrefillTestClock()
        let response = try await Self.app(engine, clock: clock).test(.router) { client in
            async let answer = client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                              body: Self.chat(stream: true))
            #expect(await clock.eventually { _ in engine.submitted == 1 })
            try await Task.sleep(for: .milliseconds(100))
            #expect(clock.sleeps == 0, "queued: no head, no prompt progress")
            engine.admit()
            #expect(await clock.eventually { $0.sleeps == 1 && $0.sleeping == 1 }, "admitted: the prompt's timer runs")
            engine.answer()
            return try await answer
        }
        #expect(response.status == .ok)
        let body = String(buffer: response.body)
        #expect(body.contains(#""content":"Hi""#), "\(body)")
        #expect(body.hasSuffix("data: [DONE]\n\n"))
    }

    /// A streamed request the engine admits at once gets its head, here its whole one-token answer, within a few
    /// milliseconds, at the production look interval. The engine counts it as waiting from its submit until a step
    /// admits it, as EngineV2's published counts do, so the hold's first look, right after the submit, reads waiting.
    @Test func aStreamedRequestTheEngineAdmitsAtOnceGetsItsHeadWithinAFewMilliseconds() async throws {
        let engine = SteppingHeadHoldEngine()
        defer { engine.stop() }
        let times = try await Self.app(engine, clock: PrefillTestClock(), pollInterval: nil).test(.router) { client in
            var times: [Duration] = []
            for _ in 0 ..< 5 {
                let start = ContinuousClock.now
                let response = try await client.execute(uri: "/v1/chat/completions", method: .post,
                                                        headers: Self.headers, body: Self.chat(stream: true))
                times.append(ContinuousClock.now - start)
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains(#""content":"Hi""#))
            }
            return times
        }
        #expect(times.sorted()[times.count / 2] < .milliseconds(50), "each request's whole answer took \(times)")
    }

    /// A request that isn't streamed and outlasts the admission lease in the queue says this Mac's memory too.
    @Test func aRequestThatIsNotStreamedAndOutlastsTheAdmissionLeaseSaysThisMacsMemory() async throws {
        let engine = HeadHoldEngine(), clock = PrefillTestClock()
        let response = try await Self.app(engine, clock: clock).test(.router) { client in
            async let answer = client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                              body: Self.chat(stream: false))
            #expect(await clock.eventually { _ in engine.submitted == 1 })
            engine.end(.terminal(cause: .admissionTimeout, message: "admission lease expired"))
            return try await answer
        }
        #expect(response.status == .serviceUnavailable)
        #expect(String(buffer: response.body).contains(Self.memoryWords), "\(String(buffer: response.body))")
    }
}

/// One queue: each request waits until the test admits it, then answers or ends as the test says. Each read of its
/// capacity is one engine step. No tensors.
final class HeadHoldEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [(request: CBv2Request, events: AsyncStream<CBv2Event>.Continuation)] = []
    private var admitted = false
    private var steps = 0

    var submitted: Int { lock.withLock { held.count } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock { held.append((request, continuation)) }
        return stream
    }

    /// The engine admits every request it holds.
    func admit() { lock.withLock { admitted = true } }

    /// Each request's first token, then its end.
    func answer() {
        for (request, events) in lock.withLock({ held }) {
            events.yield(.delta(text: "Hi", tokens: [1], logprobs: nil))
            events.yield(.finished(reason: .stop,
                                   usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: 1)))
            events.finish()
        }
    }

    /// Each request ends with `reason` and no token, as the engine ends one it couldn't admit.
    func end(_ reason: CBv2FinishReason) {
        for (request, events) in lock.withLock({ held }) {
            events.yield(.finished(reason: reason,
                                   usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: 0)))
            events.finish()
        }
    }

    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            steps += 1
            let waiting = admitted ? 0 : held.count
            return .init(activeRequests: held.count - waiting, waitingRequests: waiting, kvBytesInUse: 0,
                         kvBytesCapacity: 0, activeTokens: 0, stepsExecuted: steps)
        }
    }
    func shutdown() async {}
}

/// Counts a request as waiting from its submit until a step admits it, as EngineV2's published counts do, and steps
/// every millisecond on its own queue, as EngineV2's idle recheck does. Each step admits every waiting request, which
/// answers "Hi" at once and ends. No tensors.
final class SteppingHeadHoldEngine: CBv2Engine, @unchecked Sendable {
    private typealias Held = (request: CBv2Request, events: AsyncStream<CBv2Event>.Continuation)
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "local-head-hold.stepping-engine")
    private var waiting: [Held] = []
    private var steps = 0
    private var stopped = false

    init() { queue.async { [self] in step() } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock { waiting.append((request, continuation)) }
        return stream
    }

    /// One step, then the next a millisecond later, until `stop()`.
    private func step() {
        let admitted = lock.withLock { () -> [Held]? in
            guard !stopped else { return nil }
            steps += 1
            defer { waiting.removeAll() }
            return waiting
        }
        guard let admitted else { return }
        for (request, events) in admitted {
            events.yield(.delta(text: "Hi", tokens: [1], logprobs: nil))
            events.yield(.finished(reason: .stop,
                                   usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: 1)))
            events.finish()
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [self] in step() }
    }

    func stop() { lock.withLock { stopped = true } }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            .init(activeRequests: 0, waitingRequests: waiting.count, kvBytesInUse: 0, kvBytesCapacity: 0,
                  activeTokens: 0, stepsExecuted: steps)
        }
    }
    func shutdown() async { stop() }
}

/// Renders every conversation to 8 tokens.
private struct HeadHoldTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Array(repeating: 1, count: 8) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }; var eosToken: String? { nil }; var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { Array(repeating: 1, count: 8) }
}
