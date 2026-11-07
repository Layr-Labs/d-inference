import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import NIOCore
import Testing

@testable import ProviderCore

/// Me first, driven by the local endpoint itself: the unified endpoint's real
/// HTTP application (`makeLocalEndpointApplication`) over a loop slot whose
/// engine the test scripts. Nothing here loads weights or opens the GPU.
@Suite("Local requests are owner use (me first)", .serialized)
struct LocalUseOwnerPauseTests {
    static let model = "test/local-use-model"
    static let token = "synthetic-local-use-token"
    static let endpoint = LocalInferenceHTTPConfig(host: "127.0.0.1", port: 0, authToken: token)
    static let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer " + token]
    static let busyKeys = ["busy_reason", "busy_since_ms", "busy_addon"]
    static let twoMinutesMs: Int64 = 120_000

    struct Harness: Sendable {
        let loop: ProviderLoop
        let sandbox: ModelLoadingSandbox
        let clock: MeFirstTestClock
        let state: ProviderState
        let engine: LocalUseEngine
        /// A client on the loop's state that never connects (`heartbeatClient`).
        let client: CoordinatorClient

        func heartbeat() async throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(await client.buildHeartbeatJSON().utf8)) as? [String: Any])
        }

        func heartbeatBytes() async -> String { await LocalUseOwnerPauseTests.heartbeatBytes(of: client) }

        /// Local requests in flight as me first counts them, and as the
        /// model's reservations count them.
        func inFlight() async -> [Int] {
            [await loop.meFirstSnapshot?.localRequestsInFlight ?? -1, await loop.localUseReservations(LocalUseOwnerPauseTests.model)]
        }

        func app() async -> LocalInferenceApplication {
            await loop.makeLocalEndpointApplication(LocalUseOwnerPauseTests.endpoint)
        }

        func remove() { sandbox.remove() }
    }

    /// A unified-mode loop as `startLocalEndpoint` prepares it, without
    /// binding a port: me first per `[local]`, then the endpoint's slot.
    static func harness(local: LocalSettings? = nil) async throws -> Harness {
        let sandbox = try ModelLoadingSandbox()
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox, localEndpoint: endpoint, local: local)
        let clock = MeFirstTestClock()
        await loop.useMeFirstClockForTesting(clock)
        await loop.skipCapacityRebuildForTesting()
        await loop.enableMeFirstIfConfigured()
        let engine = LocalUseEngine()
        await installSlot(engine, on: loop)
        let state = await loop.state
        return Harness(loop: loop, sandbox: sandbox, clock: clock, state: state, engine: engine,
                       client: heartbeatClient(on: state))
    }

    /// A client on a loop's state that never connects: it builds the
    /// heartbeat the coordinator would get.
    static func heartbeatClient(on state: ProviderState) -> CoordinatorClient {
        CoordinatorClient(
            config: .init(url: "ws://127.0.0.1:0/ws/provider", hardware: ModelLoadingFixtures.defaultHardware,
                          models: [], backendName: "mlx-swift"),
            stats: AtomicProviderStats(), state: state, liveAPNsToken: { nil })
    }

    /// The heartbeat's exact bytes, with the live system metrics (CPU,
    /// memory pressure, thermal state) masked: they change on every build.
    static func heartbeatBytes(of client: CoordinatorClient) async -> String {
        await client.buildHeartbeatJSON()
            .replacing(#/"system_metrics":\{[^{}]*\}/#, with: #""system_metrics":{}"#)
    }

    static func installSlot(_ engine: LocalUseEngine, on loop: ProviderLoop) async {
        let tokenizer = TokenizerHandle(LocalUseTokenizer())
        let bridge = EngineV2Bridge(engine: engine, modelId: model, tokenizer: tokenizer, eosTokenIds: [])
        await loop.modelLoadingInstallSlot(model, bridge: bridge, modelType: nil, tokenizer: tokenizer)
    }

    static func chatJSON(model: String = model, stream: Bool, extra: String = "") -> String {
        #"{"model":"\#(model)","messages":[{"role":"user","content":"hi"}],"stream":\#(stream),"max_tokens":16\#(extra)}"#
    }

    static func chat(model: String = model, stream: Bool, extra: String = "") -> ByteBuffer {
        ByteBuffer(string: chatJSON(model: model, stream: stream, extra: extra))
    }

    /// `startLocalEndpoint` turns me first on as `[local]` says, before its
    /// server can take a request: the step the harness takes by hand. The
    /// address is TEST-NET-1 (RFC 5737), which no interface has, so the server
    /// never binds and writes no discovery file; the test cancels it anyway.
    @Test(arguments: [nil, LocalSettings(meFirst: false)] as [LocalSettings?])
    func startingTheEndpointTurnsMeFirstOnAsLocalSays(_ local: LocalSettings?) async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let unbindable = LocalInferenceHTTPConfig(host: "192.0.2.1", port: 0, authToken: Self.token)
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox, localEndpoint: unbindable, local: local)
        #expect(await loop.meFirstSnapshot == nil)

        await loop.startLocalEndpoint(unbindable)
        let expected = local == nil ? MeFirstSnapshot(idleMs: Self.twoMinutesMs, paused: false) : nil
        #expect(await loop.meFirstSnapshot == expected)

        let server = try #require(await loop.localServerTask)
        server.cancel()
        await server.value
    }

    /// The local request is admitted and holds its model: me first pauses
    /// Darkbloom. However long the stream runs, the pause holds, and the
    /// owner's idle time counts from the stream's end.
    @Test func aLocalStreamPausesDarkbloomUntilTwoIdleMinutesAfterItEnds() async throws {
        let h = try await Self.harness()
        defer { h.remove() }
        let open = try await h.heartbeat()
        #expect(open["status"] as? String == "idle")
        for key in Self.busyKeys { #expect(open[key] == nil) }
        #expect(await h.loop.meFirstSnapshot == MeFirstSnapshot(idleMs: Self.twoMinutesMs, paused: false))

        let start = h.clock.now
        h.engine.script(.hold)
        try await h.app().test(.router) { client in
            let stream = Task {
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                         body: Self.chat(stream: true)) { (response: TestResponse) in
                    (response.status, String(buffer: response.body))
                }
            }
            #expect(await modelLoadingWaitUntil { h.engine.heldCount == 1 })
            #expect(h.state.ownerPausesPublic)
            let paused = try await h.heartbeat()
            #expect(paused["status"] as? String == "draining")
            #expect(paused["busy_reason"] as? String == "owner")
            #expect((paused["busy_since_ms"] as? NSNumber)?.int64Value == start)
            #expect(await h.loop.meFirstSnapshot == MeFirstSnapshot(
                idleMs: Self.twoMinutesMs, paused: true, sinceMs: start, lastUseMs: start, localRequestsInFlight: 1))

            h.clock.advance(ms: 30 * 60_000)
            #expect(await !h.loop.resumeIfOwnerIdle())
            h.engine.finishHeld()
            let (status, body) = try await stream.value
            #expect(status == .ok)
            #expect(body.contains("[DONE]"))
        }
        let end = h.clock.now
        #expect(await modelLoadingWaitUntil { await h.loop.meFirstSnapshot?.localRequestsInFlight == 0 })
        #expect(await h.loop.meFirstSnapshot == MeFirstSnapshot(
            idleMs: Self.twoMinutesMs, paused: true, sinceMs: start, lastUseMs: end, resumesAtMs: end + Self.twoMinutesMs))

        #expect(await !h.loop.resumeIfOwnerIdleForTesting(advancing: h.clock, by: Self.twoMinutesMs - 1))
        #expect(try await h.heartbeat()["status"] as? String == "draining")
        #expect(await h.loop.resumeIfOwnerIdleForTesting(advancing: h.clock, by: 1))
        let resumed = try await h.heartbeat()
        #expect(resumed["status"] as? String == "idle")
        for key in Self.busyKeys { #expect(resumed[key] == nil) }
        #expect(!h.state.ownerPausesPublic && h.state.busy == nil)
    }

    /// The same, as the coordinator sees it: one draining heartbeat when the
    /// local request takes its model, one routable heartbeat at the resume.
    @Test func theCoordinatorHearsThePauseAndTheResume() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start().mockProviderWebSocketURL()
        let h = try await Self.harness()
        let client = CoordinatorClient(
            config: .init(url: url, hardware: ModelLoadingFixtures.defaultHardware, models: [],
                          backendName: "mlx-swift", heartbeatInterval: 3_600),
            stats: AtomicProviderStats(), state: h.state, liveAPNsToken: { nil })
        _ = await client.start()
        defer {
            h.remove()
            Task {
                await client.shutdown()
                await mock.shutdown()
            }
        }
        _ = try #require(try await mock.awaitFirstRegister(timeout: .seconds(10)))
        // Event heartbeats go out once the client counts its session registered.
        #expect(await modelLoadingWaitUntil { await client.sessionRegistered })
        await h.loop.setCoordinatorClientForTesting(client)

        let start = h.clock.now
        try await h.app().test(.router) { http in
            try await http.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                   body: Self.chat(stream: true)) { response in
                #expect(response.status == .ok)
            }
        }
        let paused = try #require(try await mock.waitForSnapshot { $0.heartbeats.count == 1 })
        #expect(paused.heartbeats[0].status == .draining)
        #expect(paused.heartbeats[0].busy == ProviderBusy(reason: .owner, sinceMs: start))
        #expect(await modelLoadingWaitUntil { await h.loop.meFirstSnapshot?.localRequestsInFlight == 0 })

        #expect(await h.loop.resumeIfOwnerIdleForTesting(advancing: h.clock, by: Self.twoMinutesMs))
        let resumed = try #require(try await mock.waitForSnapshot { $0.heartbeats.count == 2 })
        #expect(resumed.heartbeats[1].status == .idle && resumed.heartbeats[1].busy == nil)
    }

    /// A request the endpoint refuses before it holds a model (not served
    /// here, its load refused, cancelled while it waits, draining) is not use.
    @Test func aLocallyRefusedRequestNeverPausesDarkbloom() async throws {
        let h = try await Self.harness()
        defer { h.remove() }
        let open = MeFirstSnapshot(idleMs: Self.twoMinutesMs, paused: false)
        let loading = "test/local-use-loading"
        try await h.app().test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                     body: Self.chat(model: "test/local-use-not-here", stream: true)) { response in
                #expect(response.status == .notFound)
            }

            // Another request's load of the model fails: the waiting request is refused.
            await h.loop.modelLoadingMarkLoading(loading)
            let refused = Task {
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                         body: Self.chat(model: loading, stream: true)) { $0.status }
            }
            #expect(await modelLoadingWaitUntil { await h.loop.modelLoadingLoadingWaiterCount(loading) == 1 })
            #expect(!h.state.ownerPausesPublic)
            await h.loop.modelLoadingResumeLoadingWaiters(loading, failure: "Insufficient memory (0.0 GB free, need 1.0 GB)")
            let refusal = try await refused.value
            #expect(refusal == .tooManyRequests)

            // Cancelled while its model loads: it never holds the model.
            let cancelled = Task {
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                         body: Self.chat(model: loading, stream: true)) { $0.status }
            }
            #expect(await modelLoadingWaitUntil { await h.loop.modelLoadingLoadingWaiterCount(loading) == 1 })
            cancelled.cancel()
            await h.loop.modelLoadingClearLoading(loading)
            await h.loop.modelLoadingResumeLoadingWaiters(loading)
            _ = try? await cancelled.value

            #expect(await h.loop.meFirstSnapshot == open)
            #expect(try await h.heartbeat()["status"] as? String == "idle")

            // Draining for an update: refused at admission.
            await h.loop.beginServingDrain(owner: .update)
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                     body: Self.chat(stream: true)) { response in
                #expect(response.status == .serviceUnavailable)
            }
        }
        #expect(await h.loop.meFirstSnapshot == open)
        #expect(!h.state.ownerPausesPublic && h.state.busy == nil)
        #expect(h.engine.submitted == 0)
        #expect(await h.inFlight() == [0, 0])
        #expect(await !h.loop.meFirstResumeTimerArmedForTesting)
        #expect(DaemonStateFile.read(from: h.sandbox.daemonStateFile)?.meFirst == open)
    }

    /// Listing models, health and metrics, and the tokenizer utilities hold
    /// no model, so they are not use.
    @Test func modelListsHealthMetricsAndTokenizerCallsAreNotUse() async throws {
        let h = try await Self.harness()
        defer { h.remove() }
        let calls: [(String, HTTPRequest.Method, String?)] = [
            ("/v1/models", .get, nil), ("/models", .get, nil), ("/health", .get, nil), ("/v1/health", .get, nil),
            ("/props", .get, nil), ("/metrics", .get, nil),
            ("/tokenize", .post, #"{"model":"\#(Self.model)","prompt":"hi"}"#),
            ("/detokenize", .post, #"{"model":"\#(Self.model)","tokens":[1,2]}"#),
            ("/apply-template", .post, #"{"model":"\#(Self.model)","messages":[{"role":"user","content":"hi"}]}"#),
        ]
        try await h.app().test(.router) { client in
            for (uri, method, body) in calls {
                try await client.execute(uri: uri, method: method, headers: Self.headers,
                                         body: body.map { ByteBuffer(string: $0) }) { response in
                    #expect(response.status == .ok, "\(uri)")
                }
            }
        }
        #expect(await h.loop.meFirstSnapshot == MeFirstSnapshot(idleMs: Self.twoMinutesMs, paused: false))
        #expect(!h.state.ownerPausesPublic)
        #expect(h.engine.submitted == 0)
        #expect(await h.inFlight() == [0, 0])
    }

    /// `me_first = false` keeps today's unified mode: local requests run
    /// beside Darkbloom's and the heartbeat does not change, byte for byte.
    @Test func withMeFirstOffTheHeartbeatIsByteForByteUnchanged() async throws {
        let h = try await Self.harness(local: LocalSettings(meFirst: false))
        defer { h.remove() }
        #expect(await h.loop.meFirstSnapshot == nil)
        // A loop without the local endpoint, with the same slot.
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let plain = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        await Self.installSlot(LocalUseEngine(), on: plain)
        let reference = await Self.heartbeatBytes(of: Self.heartbeatClient(on: plain.state))
        #expect(await h.heartbeatBytes() == reference)

        h.engine.script(.hold)
        try await h.app().test(.router) { client in
            let stream = Task {
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                         body: Self.chat(stream: true)) { $0.status }
            }
            #expect(await modelLoadingWaitUntil { h.engine.heldCount == 1 })
            #expect(await h.loop.localUseReservations(Self.model) == 1)
            #expect(await h.heartbeatBytes() == reference)
            h.engine.finishHeld()
            let status = try await stream.value
            #expect(status == .ok)
        }
        #expect(await modelLoadingWaitUntil { await h.loop.localUseReservations(Self.model) == 0 })
        h.clock.advance(ms: 10 * 60_000)
        #expect(await !h.loop.resumeIfOwnerIdle())
        #expect(await h.heartbeatBytes() == reference)
        #expect(!h.state.ownerPausesPublic && h.state.busy == nil)
        #expect(await h.loop.meFirstSnapshot == nil)
        #expect(await h.loop.currentDaemonState().meFirst == nil)
        #expect(await !h.loop.meFirstResumeTimerArmedForTesting)
    }

    /// Every request that holds the model starts and ends its use exactly
    /// once, however it ends. A request held throughout is the witness: a
    /// second end for any request would end its use too.
    @Test func everyLocalRequestStartsAndEndsItsUseExactlyOnce() async throws {
        let h = try await Self.harness()
        defer { h.remove() }
        let witness = try await h.loop.acquireModelForLocal(Self.model)
        let start = h.clock.now
        @Sendable func settled() async -> Bool {
            guard await modelLoadingWaitUntil({ await h.inFlight() == [1, 1] }) else { return false }
            try? await Task.sleep(for: .milliseconds(150))
            return await h.inFlight() == [1, 1]
        }
        #expect(await h.inFlight() == [1, 1])

        try await h.app().test(.router) { client in
            for stream in [true, false] {
                h.engine.script(.complete(tokens: 3))
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                         body: Self.chat(stream: stream)) { response in
                    #expect(response.status == .ok, "completed, stream \(stream)")
                }
                #expect(await settled(), "completed, stream \(stream)")
            }

            h.engine.script(.fail)
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                     body: Self.chat(stream: true)) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("error"))
            }
            #expect(await settled(), "engine error mid-stream")

            // Refused after it took the model: tool_choice names a function it does not declare.
            let undeclared = #","tool_choice":{"type":"function","function":{"name":"undeclared"}}"#
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                     body: Self.chat(stream: true, extra: undeclared)) { response in
                #expect(response.status == .badRequest)
            }
            #expect(await settled(), "refused after acquisition")

            h.engine.script(.hold)
            let cancelled = Task {
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: Self.headers,
                                         body: Self.chat(stream: true)) { $0.status }
            }
            #expect(await modelLoadingWaitUntil { h.engine.heldCount == 1 })
            #expect(await h.inFlight() == [2, 2])
            cancelled.cancel()
            _ = try? await cancelled.value
            #expect(await settled(), "cancelled mid-stream")
            #expect(h.engine.heldCount == 0)
        }

        // The client disconnects mid-stream: a reset on a real loopback connection.
        h.engine.script(.hold)
        try await h.app().test(.live) { client in
            let socket = try LocalUseHTTPSocket(port: try #require(client.port), token: Self.token,
                                                body: Self.chatJSON(stream: true))
            defer { socket.close() }
            _ = try socket.read(until: #""content":"x"#)
            #expect(await h.inFlight() == [2, 2])
            socket.close()
            #expect(await settled(), "client disconnect")
            #expect(h.engine.heldCount == 0)
        }

        #expect(h.state.ownerPausesPublic)
        #expect(await h.loop.meFirstSnapshot?.sinceMs == start)
        await witness.releaseToken.fire()
        #expect(await modelLoadingWaitUntil { await h.inFlight() == [0, 0] })
        #expect(await h.loop.resumeIfOwnerIdleForTesting(advancing: h.clock, by: Self.twoMinutesMs))
    }

    /// A release that drops no reservation ends no use, so me first counts
    /// what the reservations count: a release of a model nothing holds,
    /// while the owner's request runs, leaves that request's use alone.
    @Test func aReleaseThatDropsNoReservationEndsNoUse() async throws {
        let h = try await Self.harness()
        defer { h.remove() }
        let running = try await h.loop.acquireModelForLocal(Self.model)
        #expect(await h.inFlight() == [1, 1])
        await h.loop.releaseLocalReservation("test/local-use-not-held")
        #expect(await h.inFlight() == [1, 1])
        #expect(h.state.ownerPausesPublic)
        await running.releaseToken.fire()
        #expect(await h.inFlight() == [0, 0])
        #expect(await h.loop.resumeIfOwnerIdleForTesting(advancing: h.clock, by: Self.twoMinutesMs))
    }

    /// The hook runs when a request takes its model and when it lets it go,
    /// never per token: 500 tokens stream while the clock moves, and the
    /// owner's last use stays at the stream's start until it ends.
    @Test func nothingRunsPerToken() async throws {
        let h = try await Self.harness()
        defer { h.remove() }
        let start = h.clock.now
        h.engine.script(.hold)
        try await h.app().test(.live) { client in
            let socket = try LocalUseHTTPSocket(port: try #require(client.port), token: Self.token,
                                                body: Self.chatJSON(stream: true))
            defer { socket.close() }
            _ = try socket.read(until: #""content":"x"#)
            for index in 1..<500 {
                h.clock.advance(ms: 1)
                h.engine.yieldHeld("t\(index) ")
            }
            _ = try socket.read(until: "t499 ")
            #expect(await h.loop.meFirstSnapshot?.lastUseMs == start)
            #expect(await h.inFlight() == [1, 1])
            h.clock.advance(ms: 1)
            h.engine.finishHeld()
            _ = try socket.read(until: "[DONE]")
        }
        #expect(await modelLoadingWaitUntil { await h.inFlight() == [0, 0] })
        #expect(await h.loop.meFirstSnapshot?.lastUseMs == start + 500)
    }

    /// The hook is O(1) with no I/O: start and end pairs while the owner
    /// works cost no more than a few microseconds each, on the wall clock
    /// production uses, and write nothing. Measured against me first off.
    @Test func theHookCostsNextToNothing() async throws {
        let pairs = 100_000
        func measure(meFirst: Bool) async throws -> (entryNs: UInt64, pairNs: Double, acquireP50Ns: UInt64,
                                                     acquireP99Ns: UInt64, stateUnchanged: Bool) {
            let sandbox = try ModelLoadingSandbox()
            defer { sandbox.remove() }
            let loop = try await ModelLoadingFixtures.makeLoop(
                sandbox: sandbox, localEndpoint: Self.endpoint, local: LocalSettings(meFirst: meFirst))
            await loop.skipCapacityRebuildForTesting()
            await loop.enableMeFirstIfConfigured()
            await Self.installSlot(LocalUseEngine(), on: loop)
            // The owner's first request (the pause's entry with me first on)
            // then holds the model throughout: the owner is at work.
            let entryBegin = DispatchTime.now().uptimeNanoseconds
            let held = try await loop.acquireModelForLocal(Self.model)
            let entryNs = DispatchTime.now().uptimeNanoseconds - entryBegin
            #expect(await loop.ownerPausesPublic == meFirst)
            await loop.writeDaemonState()
            let before = try? Data(contentsOf: sandbox.daemonStateFile)
            let pairNs = await loop.meanLocalUsePairNanos(pairs)
            let acquire = try await loop.localAcquireReleaseNanos(Self.model, count: 2_000)
            let after = try? Data(contentsOf: sandbox.daemonStateFile)
            await held.releaseToken.fire()
            return (entryNs, pairNs, acquire[acquire.count / 2], acquire[acquire.count * 99 / 100], before == after)
        }
        let off = try await measure(meFirst: false)
        let on = try await measure(meFirst: true)
        print("me first hook: \(Int(on.pairNs)) ns per start/end pair on, \(Int(off.pairNs)) ns off; local acquire+release p50 \(on.acquireP50Ns / 1_000) µs on, \(off.acquireP50Ns / 1_000) µs off; p99 \(on.acquireP99Ns / 1_000) µs on, \(off.acquireP99Ns / 1_000) µs off; first request \(on.entryNs / 1_000) µs on (pause entry), \(off.entryNs / 1_000) µs off")
        #expect(on.pairNs < 5_000)
        #expect(on.stateUnchanged && off.stateUnchanged)
        #expect(Double(on.acquireP50Ns) < Double(off.acquireP50Ns) + 50_000)
    }
}

extension ProviderLoop {
    func localUseReservations(_ model: String) -> Int { localReservations.count(model) }

    /// `count` start and end pairs of local use on this actor, as the
    /// endpoint's hooks make them; the mean nanoseconds per pair.
    func meanLocalUsePairNanos(_ count: Int) -> Double {
        let begin = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<count {
            noteLocalUse(.start)
            noteLocalUse(.end)
        }
        return Double(DispatchTime.now().uptimeNanoseconds - begin) / Double(count)
    }

    /// Local acquisitions and releases of `model` through the endpoint's own
    /// calls, each pair timed; sorted nanoseconds.
    func localAcquireReleaseNanos(_ model: String, count: Int) async throws -> [UInt64] {
        var samples: [UInt64] = []
        samples.reserveCapacity(count)
        for _ in 0..<count {
            let begin = DispatchTime.now().uptimeNanoseconds
            let acquired = try await acquireModelForLocal(model)
            await acquired.releaseToken.fire()
            samples.append(DispatchTime.now().uptimeNanoseconds - begin)
        }
        return samples.sorted()
    }
}

/// A local engine the test scripts per request: each streams an `x` first,
/// then completes, fails, or holds until the test ends it (or it is cancelled).
final class LocalUseEngine: CBv2Engine, @unchecked Sendable {
    enum Script: Sendable {
        case complete(tokens: Int)
        case hold
        case fail
    }

    private let lock = NSLock()
    private var scripts: [Script] = []
    private var held: [CBv2RequestID: AsyncStream<CBv2Event>.Continuation] = [:]
    private var submissions = 0

    var submitted: Int { lock.withLock { submissions } }
    var heldCount: Int { lock.withLock { held.count } }

    func script(_ next: Script) { lock.withLock { scripts.append(next) } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let script = lock.withLock { () -> Script in
            submissions += 1
            return scripts.isEmpty ? .complete(tokens: 1) : scripts.removeFirst()
        }
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        continuation.yield(.delta(text: "x", tokens: [5], logprobs: nil))
        switch script {
        case .complete(let tokens):
            for _ in 1..<max(tokens, 1) { continuation.yield(.delta(text: "x", tokens: [5], logprobs: nil)) }
            continuation.yield(.finished(reason: .stop, usage: .init(promptTokens: 3, completionTokens: max(tokens, 1))))
            continuation.finish()
        case .fail:
            continuation.yield(.finished(reason: .error("synthetic engine failure"),
                                         usage: .init(promptTokens: 3, completionTokens: 1)))
            continuation.finish()
        case .hold:
            lock.withLock { held[request.id] = continuation }
        }
        return stream
    }

    /// One more token on every held stream.
    func yieldHeld(_ text: String) {
        for stream in lock.withLock({ Array(held.values) }) {
            stream.yield(.delta(text: text, tokens: [6], logprobs: nil))
        }
    }

    /// Ends every held stream normally.
    func finishHeld() {
        let streams = lock.withLock { () -> [AsyncStream<CBv2Event>.Continuation] in
            defer { held.removeAll() }
            return Array(held.values)
        }
        for stream in streams {
            stream.yield(.finished(reason: .stop, usage: .init(promptTokens: 3, completionTokens: 1)))
            stream.finish()
        }
    }

    func cancel(_ id: CBv2RequestID) {
        let stream = lock.withLock { held.removeValue(forKey: id) }
        stream?.yield(.finished(reason: .cancelled, usage: .init(promptTokens: 3, completionTokens: 1)))
        stream?.finish()
    }

    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: heldCount, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }

    func shutdown() async {
        for id in lock.withLock({ Array(held.keys) }) { cancel(id) }
    }
}

/// Renders every prompt as three tokens; never an official tokenizer.
private struct LocalUseTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [1, 2, 3] }
}

/// One raw loopback HTTP/1.1 chat request whose streamed response the test
/// reads as it arrives; `close()` resets the connection (SO_LINGER 0).
final class LocalUseHTTPSocket {
    private var descriptor: Int32 = -1
    private var received = Data()

    init(port: Int, token: String, body: String) throws {
        // The live test server listens on `localhost`, which may be IPv6.
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICSERV
        var addresses: UnsafeMutablePointer<addrinfo>?
        try #require(getaddrinfo("localhost", String(port), &hints, &addresses) == 0)
        defer { freeaddrinfo(addresses) }
        var candidate = addresses
        while let address = candidate?.pointee, descriptor < 0 {
            candidate = address.ai_next
            let socket = Darwin.socket(address.ai_family, address.ai_socktype, address.ai_protocol)
            if socket < 0 { continue }
            if Darwin.connect(socket, address.ai_addr, address.ai_addrlen) == 0 { descriptor = socket } else { Darwin.close(socket) }
        }
        try #require(descriptor >= 0, "nothing listens on localhost:\(port)")
        do {
            var noSignal: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var reset = linger(l_onoff: 1, l_linger: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
            let request = "POST /v1/chat/completions HTTP/1.1\r\nHost: localhost:\(port)\r\n"
                + "Authorization: Bearer \(token)\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            let bytes = Array(request.utf8)
            var offset = 0
            while offset < bytes.count {
                let sent = bytes[offset...].withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
                if sent < 0 && errno == EINTR { continue }
                try #require(sent > 0)
                offset += sent
            }
        } catch {
            close()
            throw error
        }
    }

    /// Reads until the response so far contains `marker`, and returns it.
    func read(until marker: String) throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while ContinuousClock.now < deadline {
            let text = String(decoding: received, as: UTF8.self)
            if text.contains(marker) { return text }
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            try #require(count > 0, "the response ended before \(marker)")
            received.append(contentsOf: buffer.prefix(count))
        }
        throw POSIXError(.ETIMEDOUT)
    }

    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit { close() }
}
