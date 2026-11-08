import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

/// A long prompt on the local API shows progress: from the moment this Mac's engine accepts a streamed request until
/// its first token, an SSE comment every 5 s, which OpenAI clients ignore, through the local router unchanged:
/// `: prefill in progress, <total> prompt tokens` until the engine reports how much of the prompt it has computed, then
/// `: prefill <done>/<total> tokens`. Before, a 255K-token prompt streamed nothing for 9 minutes after its first chunk.
/// The timer runs only during the prefill, never for a request that is not streamed, and writes nothing for a prompt
/// done within 5 s. The clock is the test's and the engine a gate the test opens.
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
        #expect(comments == [": prefill in progress, 8 prompt tokens", ": prefill 8/8 tokens"])
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

    /// The first token stops the timer at once, not the end of the answer: nothing is said while a long answer streams.
    @Test func nothingIsSaidAfterTheFirstToken() async throws {
        let engine = PrefillGateEngine(), clock = PrefillTestClock()
        let response = try await Self.app(engine, clock: clock).test(.router) { client in
            async let answer = client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                              body: Self.chat(stream: true))
            #expect(await clock.eventually { $0.sleeping == 1 })
            engine.firstToken()
            #expect(await clock.eventually { $0.sleeping == 0 && $0.cancelled == 1 }, "stopped by the first token")
            clock.tick()
            engine.finish()
            return try await answer
        }
        #expect(response.status == .ok)
        #expect(!String(buffer: response.body).contains(": prefill"))
        #expect(clock.sleeps == 1)
    }

    /// A request that ends without a first token (an engine teardown): the pump's end stops the timer, and no comment
    /// follows the failure frame.
    @Test func aPromptThatFailsBeforeItsFirstTokenStopsTheTimer() async throws {
        let engine = PrefillGateEngine(), clock = PrefillTestClock()
        let response = try await Self.app(engine, clock: clock).test(.router) { client in
            async let answer = client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                              body: Self.chat(stream: true))
            #expect(await clock.eventually { $0.sleeping == 1 })
            clock.tick()
            #expect(await clock.eventually { $0.sleeps == 2 && $0.sleeping == 1 })
            engine.tearDown()
            #expect(await clock.eventually { $0.sleeping == 0 && $0.cancelled == 1 }, "the pump's end stopped the timer")
            return try await answer
        }
        let events = Self.events(response.body)
        let failure = try #require(events.firstIndex { $0.contains(#""finish_reason":"error""#) }, "\(events)")
        #expect(events.indices.filter { events[$0].hasPrefix(":") } == [failure - 1], "\(events)")
        #expect(clock.sleeps == 2)
    }

    /// The client goes away while the prompt is processed (the body's write fails on a comment): the stream ends
    /// with the dropped response, and that stops the timer and the frame task though the engine never answers.
    @Test func aClientThatLeavesDuringThePromptStopsTheTimer() async throws {
        let clock = PrefillTestClock()
        let progress = LocalPrefillProgress(ticker: clock.ticker)
        progress.accept(promptTokens: Self.promptTokens)
        let (frames, source) = AsyncThrowingStream<String, Error>.makeStream()
        let framesEnded = PrefillFlag()
        source.onTermination = { _ in framesEnded.set() }
        source.yield(try httpDeliveryFrame(role: "assistant"))
        do {
            let response = PrefillUpload.sseResponse(frames, prefillProgress: progress)
            let capture = HTTPDeliveryCapture()
            let writer = HTTPDeliveryWriter(capture: capture, beforeWrite: { text in
                if text.hasPrefix(": prefill") { throw ChannelError.ioOnClosedChannel }
            })
            let writing = Task { try await response.body.write(writer) }
            #expect(await clock.eventually { $0.sleeping == 1 }, "the timer started after the first frame")
            clock.tick()
            #expect((try? await writing.value) == nil, "the write failed on the comment")
            #expect(capture.values.count == 1)
        }
        #expect(await clock.eventually { $0.sleeping == 0 && $0.cancelled == 1 }, "no timer outlives the response")
        #expect(try await httpDeliveryEventually { framesEnded.isSet }, "the frame task was cancelled")
        #expect(progress.comment == nil)
    }

    /// The task writing the body is cancelled while the prompt is processed (a closed connection): that stops the
    /// timer and the frame task.
    @Test func aCancelledBodyDuringThePromptStopsTheTimer() async throws {
        let clock = PrefillTestClock()
        let progress = LocalPrefillProgress(ticker: clock.ticker)
        progress.accept(promptTokens: Self.promptTokens)
        let (frames, source) = AsyncThrowingStream<String, Error>.makeStream()
        let framesEnded = PrefillFlag()
        source.onTermination = { _ in framesEnded.set() }
        source.yield(try httpDeliveryFrame(role: "assistant"))
        let response = PrefillUpload.sseResponse(frames, prefillProgress: progress)
        let capture = HTTPDeliveryCapture()
        let writing = Task { try await response.body.write(HTTPDeliveryWriter(capture: capture)) }
        #expect(await clock.eventually { $0.sleeping == 1 })
        writing.cancel()
        _ = await writing.result
        #expect(await clock.eventually { $0.sleeping == 0 && $0.cancelled == 1 }, "the cancellation stopped the timer")
        #expect(try await httpDeliveryEventually { framesEnded.isSet })
        #expect(!capture.values.contains { $0.hasPrefix(": prefill") })
    }

    /// A model load that a streamed request starts also starts an idle calibration inside the request's scope, and
    /// that session inherits the request's task-locals. Its probes are no request's: they leave the request's progress
    /// alone, and the request still says its own prompt. Before, the probe's prompt was taken into the request's
    /// progress and its end ended it, so a long prompt after an on-demand load said nothing.
    @Test func aCalibrationStartedDuringARequestsLoadLeavesItsProgressAlone() async throws {
        let engine = PrefillGateEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: Self.model, tokenizer: TokenizerHandle(PrefillTokenizer(count: 3)),
            eosTokenIds: [], defaultMaxTokens: 32_768, defaultMaxTokensContextLimit: 262_144, maxConcurrentRequests: 4,
            kvBudget: GlobalKVCacheBudget(memorySnapshot: {
                .init(total: 256 << 30, active: 0, cache: 0, systemAvailable: 256 << 30)
            }))
        let request = LocalPrefillProgress(ticker: PrefillTestClock().ticker)
        let calibration = IdleCalibrationCoordinator()
        // As `finishModelLoad` starts it (`scheduleLoadedModelCalibration`) inside a local request's acquire.
        let session = LocalPrefillProgress.$current.withValue(request) {
            calibration.startIfIdle(isIdle: { true }) {
                _ = await bridge.runModelCalibrationCell(.init(promptTokens: 3, outputTokens: 4, width: 1),
                                                         tokens: [1, 2, 3], requireNominalPosture: false)
            }
        }
        #expect(session != nil)
        #expect(await PrefillTestClock().eventually { _ in engine.submitted == 1 }, "the probe reached the engine")
        #expect(request.comment == nil, "the probe's prompt is not the request's")
        engine.answer()
        await session?.value
        request.accept(promptTokens: Self.promptTokens)
        #expect(request.comment == ": prefill in progress, 8 prompt tokens\n\n", "the request still says its own prompt")
        await bridge.shutdown()
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
        #expect(events.filter { $0.hasPrefix(":") } == [": prefill in progress, 8 prompt tokens"])
        let comment = try #require(events.firstIndex(of: ": prefill in progress, 8 prompt tokens"))
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
        #expect(String(buffer: response.body).contains("\n\n: prefill in progress, 8 prompt tokens\n\ndata: "))
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
        let response = DistributedHTTPEventStream.response(frames, control: control, prefillProgress: prefill)
        let writing = Task { try await response.body.write(HTTPDeliveryWriter(capture: capture)) }
        source.yield(try httpDeliveryFrame(role: "assistant"))
        #expect(try await httpDeliveryEventually {
            capture.values.contains(": prefill in progress, 8 prompt tokens\n\n")
        })
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

    /// A pair's API says the prompt every 5 s, on its probes' clock: a probe goes 500 ms after the last line, so the
    /// comment takes the place of the 10th probe, then of every 10th after it, and the 9 between stay keep-alives. The
    /// clock is the test's (`ProbeTestClock`): it moves only to the probe the writer waits for, so no real time passes.
    @Test func aPairsAPISaysThePromptEveryFiveSecondsOnItsProbesClock() async throws {
        let control = DistributedHTTPResponse(), capture = HTTPDeliveryCapture(), clock = ProbeTestClock()
        try control.bind(deadline: nil, cancel: capture.cancel)
        let prefill = LocalPrefillProgress(ticker: LocalPrefillTicker(interval: .seconds(5), sleep: { _ in }))
        prefill.accept(promptTokens: Self.promptTokens)
        let (frames, source) = AsyncThrowingStream<String, Error>.makeStream()
        let response = DistributedHTTPEventStream.response(frames, control: control, prefillProgress: prefill,
                                                           clock: clock)
        let roleWritten = LocalHostLatch()
        let writer = HTTPDeliveryWriter(capture: capture, beforeWrite: { text in
            if text.contains(#""role":"assistant""#) { roleWritten.complete() }
        })
        let writing = Task { try await response.body.write(writer) }
        source.yield(try httpDeliveryFrame(role: "assistant"))
        await roleWritten.wait()
        // Each probe: the writer sleeps until 500 ms after the last line, and the clock moves there.
        for probe in 1...20 {
            let due = ProbeTestClock.Instant(offset: .milliseconds(500 * probe))
            await clock.sleeper(until: due)
            clock.advance(to: due)
        }
        // The 21st sleep begins once the 20th probe's line is written.
        await clock.sleeper(until: .init(offset: .milliseconds(500 * 21)))
        let keepAlive = ": keep-alive\n\n", comment = ": prefill in progress, 8 prompt tokens\n\n"
        let fiveSeconds = Array(repeating: keepAlive, count: 9) + [comment]
        #expect(Array(capture.values.dropFirst()) == fiveSeconds + fiveSeconds, "\(capture.values)")
        prefill.end()
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
        #expect(prefill.comment == ": prefill in progress, 255000 prompt tokens\n\n",
                "no count until the engine reports one, and none from before it accepted the request")
        prefill.advance(to: 128_000)
        prefill.advance(to: 1_000)
        #expect(prefill.comment == ": prefill 128000/255000 tokens\n\n", "never backwards")
        prefill.advance(to: 300_000)
        #expect(prefill.comment == ": prefill 255000/255000 tokens\n\n", "never past the prompt")
        prefill.end()
        #expect(prefill.comment == nil, "nothing after the first token")
        prefill.accept(promptTokens: 9)
        #expect(prefill.comment == nil)
        // A count the engine reports is said as it is, none computed yet included.
        let starting = LocalPrefillProgress()
        starting.accept(promptTokens: 10)
        starting.advance(to: 0)
        #expect(starting.comment == ": prefill 0/10 tokens\n\n")
    }
}

/// The upload responder whose `sseResponse` writes a streamed request's body.
private typealias PrefillUpload = LocalChatUploadResponder<RouterResponder<BasicRequestContext>>

/// A flag set once, from any thread.
private final class PrefillFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
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

/// A `Clock` the test moves: `now` changes only in `advance(to:)`, which wakes every sleep it reaches. No real time
/// passes and nothing polls: the test waits for a sleep to begin (`sleeper(until:)`), then moves the clock to it.
final class ProbeTestClock: Clock, @unchecked Sendable {
    typealias Duration = Swift.Duration

    struct Instant: InstantProtocol {
        typealias Duration = Swift.Duration
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: (deadline: Instant, wake: CheckedContinuation<Void, Error>)] = [:]
    private var watchers: [(deadline: Instant, resume: CheckedContinuation<Void, Never>)] = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Swift.Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, Error>) in
                let (settled, begun) = lock.withLock { () -> (Result<Void, Error>?, [CheckedContinuation<Void, Never>]) in
                    if Task.isCancelled { return (.failure(CancellationError()), []) }
                    if deadline <= current { return (.success(()), []) }
                    sleepers[id] = (deadline, wake)
                    let begun = watchers.filter { $0.deadline == deadline }.map { $0.resume }
                    watchers.removeAll { $0.deadline == deadline }
                    return (nil, begun)
                }
                if let settled { wake.resume(with: settled) }
                for watcher in begun { watcher.resume() }
            }
        } onCancel: {
            lock.withLock { sleepers.removeValue(forKey: id) }?.wake.resume(throwing: CancellationError())
        }
    }

    /// Returns once something sleeps until `deadline`.
    func sleeper(until deadline: Instant) async {
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            let begun = lock.withLock { () -> Bool in
                if sleepers.values.contains(where: { $0.deadline == deadline }) { return true }
                watchers.append((deadline, resume))
                return false
            }
            if begun { resume.resume() }
        }
    }

    /// The clock reads `instant`: every sleep until then wakes.
    func advance(to instant: Instant) {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            current = max(current, instant)
            let due = sleepers.filter { $0.value.deadline <= current }
            for id in due.keys { sleepers.removeValue(forKey: id) }
            return due.values.map { $0.wake }
        }
        for wake in woken { wake.resume() }
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
        firstToken()
        finish()
    }

    /// Each request's first token, its end left to `finish`.
    func firstToken() {
        for (_, events) in lock.withLock({ held }) { events.yield(.delta(text: "Hi", tokens: [1], logprobs: nil)) }
    }

    /// Each request's end, after its first token.
    func finish() {
        for (request, events) in lock.withLock({ held }) {
            events.yield(.finished(reason: .stop,
                                   usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: 1)))
            events.finish()
        }
    }

    /// Each request's events end with no first token and no terminal, as an engine teardown ends them.
    func tearDown() {
        for (_, events) in lock.withLock({ held }) { events.finish() }
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
