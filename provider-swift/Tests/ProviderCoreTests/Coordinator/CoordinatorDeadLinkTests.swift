import Foundation
import Network
import Testing
@testable import ProviderCore

/// A coordinator node that is hard-reset leaves the provider's WebSocket open
/// with no TCP reset and no close frame. The provider must find the silent
/// link from its pings and reconnect at once, but never drop a link that still
/// delivers frames. These rows run the real `CoordinatorClient` over loopback
/// against `LoopbackWebSocketPeer`, with a 0.1 s ping interval, a 0.6 s bound
/// and 1.5 s before the first frame instead of 2 s, 6 s and 30 s.
@Suite("Coordinator dead link", .serialized)
struct CoordinatorDeadLinkTests {
    private static let liveness = CoordinatorLinkLiveness(
        pingInterval: .milliseconds(100), deadAfter: .milliseconds(600), suspensionGap: .seconds(30),
        firstFrameGrace: .milliseconds(1_500))

    @Test("a peer silent from the start is declared dead after the first-frame grace and the client reconnects at once",
          .timeLimit(.minutes(1)))
    func silentPeerIsDeclaredDeadAndReconnected() async throws {
        let peer = try LoopbackWebSocketPeer(behavior: .silent)
        let port = try await peer.start()
        defer { peer.stop() }
        // A session of 0.2 s counts as stable, so the first retry waits 0-0.25 s.
        let client = makeDeadLinkClient(
            port: port, reconnectPolicy: CoordinatorReconnectPolicy(stableSessionDuration: .milliseconds(200)))
        let (events, _) = await client.start()
        let drain = Task { for await _ in events {} }
        defer {
            drain.cancel()
            Task { await client.shutdown() }
        }

        let accepted = try await waitForAccepts(2, on: peer, within: .seconds(10))
        let reconnectAfter = accepted[1] - accepted[0]
        // The peer never sends a first frame: silence of more than 1.5 s, the
        // next 0.1 s tick, a 0-0.25 s wait and a loopback reconnect: about 2 s.
        // The upper limit leaves room for a loaded CI Mac.
        #expect(reconnectAfter > .milliseconds(1_500), "reconnected \(reconnectAfter) after connecting, before the grace")
        #expect(reconnectAfter < .seconds(6), "reconnected \(reconnectAfter) after connecting")
    }

    @Test("a busy stream whose pongs never come keeps the link", .timeLimit(.minutes(1)))
    func busyStreamWithoutPongsKeepsTheLink() async throws {
        // A frame that the client reads and ignores: no drain barrier waits on "x".
        let frame = Data(#"{"type":"drain_ack","id":"x"}"#.utf8)
        let peer = try LoopbackWebSocketPeer(behavior: .streams(frame: frame, interval: .milliseconds(50)))
        try await expectLinkKept(by: peer)
    }

    @Test("a peer that answers pings and sends nothing keeps the link", .timeLimit(.minutes(1)))
    func answeredPingsKeepTheLink() async throws {
        try await expectLinkKept(by: LoopbackWebSocketPeer(behavior: .answersPings))
    }

    /// A provider whose handling of one message, a large vision request among
    /// others, took longer than the bound read nothing meanwhile, so its own
    /// link watch saw silence and dropped a live link 6-8 s after the request
    /// came in. Here the client's actor is held for three times the bound while
    /// the peer keeps streaming frames.
    @Test("a link stays up while one message's handling holds the client longer than the bound",
          .timeLimit(.minutes(1)))
    func longHandlingKeepsTheLink() async throws {
        let frame = Data(#"{"type":"drain_ack","id":"x"}"#.utf8)
        let peer = try LoopbackWebSocketPeer(behavior: .streams(frame: frame, interval: .milliseconds(50)))
        let port = try await peer.start()
        defer { peer.stop() }
        // A dropped link would be retried within 0.25 s, so a drop shows below.
        let client = makeDeadLinkClient(
            port: port, reconnectPolicy: CoordinatorReconnectPolicy(stableSessionDuration: .milliseconds(200)))
        let (events, _) = await client.start()
        let drain = Task { for await _ in events {} }
        defer {
            drain.cancel()
            Task { await client.shutdown() }
        }

        _ = try await waitForAccepts(1, on: peer, within: .seconds(10))
        // Frames are flowing; then one handling holds the actor.
        try await Task.sleep(for: .milliseconds(300))
        await holdActor(client, for: Self.liveness.deadAfter * 3)
        try await Task.sleep(for: Self.liveness.deadAfter * 4)
        #expect(peer.accepted.count == 1, "the client reconnected \(peer.accepted.count - 1) times")
    }

    @Test("a link declared dead is closed with the provider's private code 4001 before it is dropped",
          .timeLimit(.minutes(1)))
    func deadLinkIsClosedWithThePrivateCode() async throws {
        let peer = try LoopbackWebSocketPeer(behavior: .recordsCloses)
        let port = try await peer.start()
        defer { peer.stop() }
        let client = makeDeadLinkClient(port: port)
        let (events, _) = await client.start()
        let drain = Task { for await _ in events {} }
        defer {
            drain.cancel()
            Task { await client.shutdown() }
        }

        // The peer never answers: the 1.5 s first-frame grace ends the link.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, !peer.closeCodes.contains(4001) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(peer.closeCodes.contains(4001), "close codes read: \(peer.closeCodes)")
    }

    /// A handler can end the connection, here a member's refusal of a
    /// native-pair frame that breaks the contract. A frame read before that
    /// must not be handled, as the old loop's next read on the cancelled
    /// connection failed. The client's actor is held while both frames arrive,
    /// so the second one is already read when the first ends the connection.
    @Test("a frame read before a handler ended the connection is not handled", .timeLimit(.minutes(1)))
    func frameReadBeforeAHandlerEndedTheConnectionIsNotHandled() async throws {
        let peer = try LoopbackWebSocketPeer(behavior: .answersPings)
        let port = try await peer.start()
        defer { peer.stop() }
        let client = makeDeadLinkClient(
            port: port, reconnectPolicy: CoordinatorReconnectPolicy(stableSessionDuration: .milliseconds(200)),
            executionRole: .clusterMember)
        let (events, _) = await client.start()
        let cancels = Task { () -> [String] in
            var requestIDs: [String] = []
            for await event in events {
                if case .cancel(let requestID, _) = event { requestIDs.append(requestID) }
            }
            return requestIDs
        }
        defer {
            cancels.cancel()
            Task { await client.shutdown() }
        }

        _ = try await waitForAccepts(1, on: peer, within: .seconds(10))
        // The registration is sent; then both frames arrive while the actor is held.
        try await Task.sleep(for: .milliseconds(300))
        let queue = await client.connectionQueue
        let hold = Task { await holdActor(client, for: .milliseconds(600)) }
        try await Task.sleep(for: .milliseconds(100))
        // A member without an accepted session takes any native-pair frame as a contract break.
        peer.send([Data(#"{"type":"native_pair_probe"}"#.utf8),
                   Data(#"{"type":"cancel","request_id":"read-before-the-end"}"#.utf8)])
        // Both frames are read by now. The connection's queue is then held past
        // the actor's release, so the cancel that the first frame's handling
        // issues cannot reach `connection.state` before the loop takes the
        // second frame: an order a loaded Mac can produce, made certain here.
        try await Task.sleep(for: .milliseconds(300))
        queue.async { Thread.sleep(forTimeInterval: 0.5) }
        await hold.value

        // The first frame ended the connection: the client connects again.
        _ = try await waitForAccepts(2, on: peer, within: .seconds(10))
        cancels.cancel()
        let handled = await cancels.value
        #expect(handled.isEmpty, "cancels handled after the connection ended: \(handled)")
    }

    /// Reading no longer waits on handling, so a handler that stops would let
    /// frames pile up while each of them still counts as liveness. Past a limit
    /// of the inbound backlog the provider closes the link with its private
    /// code 4003 and reconnects. Each row lowers one limit and holds the
    /// client's actor while the peer streams.
    @Test("frames read and not handled past the byte limit close the link with 4003", .timeLimit(.minutes(1)))
    func backlogPastTheByteLimitClosesTheLink() async throws {
        try await expectBacklogClose(CoordinatorInboundBacklog(maxBytes: 1 << 20),
                                     streaming: Self.ignoredFrame(paddedTo: 64 << 10), every: .milliseconds(5))
    }

    @Test("frames read and not handled past the frame limit close the link with 4003", .timeLimit(.minutes(1)))
    func backlogPastTheFrameLimitClosesTheLink() async throws {
        try await expectBacklogClose(CoordinatorInboundBacklog(maxFrames: 64),
                                     streaming: Self.ignoredFrame(paddedTo: 0), every: .milliseconds(2))
    }

    @Test("a frame waiting for its handling past the age limit closes the link with 4003", .timeLimit(.minutes(1)))
    func backlogPastTheAgeLimitClosesTheLink() async throws {
        try await expectBacklogClose(CoordinatorInboundBacklog(maxAge: .milliseconds(500)),
                                     streaming: Self.ignoredFrame(paddedTo: 0), every: .milliseconds(50))
    }

    /// Under the limits nothing is dropped: every frame read while a handling
    /// holds the client is handled afterwards, in order, on the same link.
    @Test("frames read while a handling holds the client are all handled, in order, on the same link",
          .timeLimit(.minutes(1)))
    func framesReadDuringAHoldAreAllHandledInOrder() async throws {
        let peer = try LoopbackWebSocketPeer(behavior: .answersPings)
        let port = try await peer.start()
        defer { peer.stop() }
        let client = makeDeadLinkClient(port: port)
        let (events, _) = await client.start()
        let sent = (0..<200).map { "held-\($0)" }
        let cancels = Task { () -> [String] in
            var requestIDs: [String] = []
            for await event in events {
                if case .cancel(let requestID, _) = event { requestIDs.append(requestID) }
                if requestIDs.count == sent.count { break }
            }
            return requestIDs
        }
        let giveUp = Task {
            try await Task.sleep(for: .seconds(10))
            cancels.cancel()
        }
        defer {
            giveUp.cancel()
            cancels.cancel()
            Task { await client.shutdown() }
        }

        _ = try await waitForAccepts(1, on: peer, within: .seconds(10))
        try await Task.sleep(for: .milliseconds(300))
        // Half the dead bound, so no link watch reacts to the hold.
        let hold = Task { await holdActor(client, for: .milliseconds(300)) }
        try await Task.sleep(for: .milliseconds(50))
        peer.send(sent.map { Data(#"{"type":"cancel","request_id":"\#($0)"}"#.utf8) })
        await hold.value

        let handled = await cancels.value
        #expect(handled == sent, "handled \(handled.count) of \(sent.count), first \(handled.prefix(3))")
        #expect(peer.accepted.count == 1, "the client reconnected \(peer.accepted.count - 1) times")
    }

    /// Streams `frame` every `interval`, holds the client's actor for 2 s, and
    /// expects the peer to read close code 4003 and the client to reconnect.
    private func expectBacklogClose(_ backlog: CoordinatorInboundBacklog, streaming frame: Data,
                                    every interval: DispatchTimeInterval) async throws {
        let peer = try LoopbackWebSocketPeer(behavior: .streamsAndRecordsCloses(frame: frame, interval: interval))
        let port = try await peer.start()
        defer { peer.stop() }
        let client = makeDeadLinkClient(
            port: port, reconnectPolicy: CoordinatorReconnectPolicy(stableSessionDuration: .milliseconds(200)),
            inboundBacklog: backlog)
        let (events, _) = await client.start()
        let drain = Task { for await _ in events {} }
        defer {
            drain.cancel()
            Task { await client.shutdown() }
        }

        _ = try await waitForAccepts(1, on: peer, within: .seconds(10))
        try await Task.sleep(for: .milliseconds(300))
        // One handling holds the client while frames keep coming: the backlog grows.
        await holdActor(client, for: .seconds(2))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, !peer.closeCodes.contains(4003) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(peer.closeCodes.contains(4003), "close codes read: \(peer.closeCodes)")
        _ = try await waitForAccepts(2, on: peer, within: .seconds(10))
    }

    /// A message the client reads and ignores (no drain barrier waits on its
    /// id), its id padded with `padding` bytes.
    private static func ignoredFrame(paddedTo padding: Int) -> Data {
        Data(#"{"type":"drain_ack","id":"x\#(String(repeating: "x", count: padding))"}"#.utf8)
    }

    /// Connects a client to `peer` and checks that it keeps its first
    /// connection for four times the bound.
    private func expectLinkKept(by peer: LoopbackWebSocketPeer) async throws {
        let port = try await peer.start()
        defer { peer.stop() }
        let client = makeDeadLinkClient(port: port)
        let (events, _) = await client.start()
        let drain = Task { for await _ in events {} }
        defer {
            drain.cancel()
            Task { await client.shutdown() }
        }

        _ = try await waitForAccepts(1, on: peer, within: .seconds(10))
        try await Task.sleep(for: Self.liveness.deadAfter * 4)
        #expect(peer.accepted.count == 1, "the client reconnected \(peer.accepted.count - 1) times")
    }

    private func makeDeadLinkClient(
        port: UInt16, reconnectPolicy: CoordinatorReconnectPolicy = CoordinatorReconnectPolicy(),
        executionRole: ProviderExecutionRole = .solo,
        inboundBacklog: CoordinatorInboundBacklog = CoordinatorInboundBacklog()
    ) -> CoordinatorClient {
        CoordinatorClient(
            config: CoordinatorClientConfig(
                url: "ws://127.0.0.1:\(port)/ws/provider",
                hardware: HardwareInfo(
                    machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                    memoryGb: 128, memoryAvailableGb: 124,
                    cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                    gpuCores: 40, memoryBandwidthGbs: 546),
                models: [],
                backendName: "mlx-swift",
                heartbeatInterval: 60,
                executionRole: executionRole,
                // A member's window outlasts every row, so no refusal ends a link here.
                memberNegotiationWindow: .seconds(60)),
            stats: AtomicProviderStats(),
            state: ProviderState(),
            liveAPNsToken: { nil },
            reconnectPolicy: reconnectPolicy,
            linkLiveness: Self.liveness,
            inboundBacklog: inboundBacklog)
    }

    /// Returns the accept times once `peer` accepted `count` connections.
    private func waitForAccepts(
        _ count: Int, on peer: LoopbackWebSocketPeer, within limit: Duration
    ) async throws -> [ContinuousClock.Instant] {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            let accepted = peer.accepted
            if accepted.count >= count { return accepted }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the peer accepted \(peer.accepted.count) connections in \(limit), expected \(count)")
        throw CancellationError()
    }
}

/// Holds `client`'s actor for `duration`, as a long handling of one message does.
private func holdActor(_ client: isolated CoordinatorClient, for duration: Duration) {
    Thread.sleep(forTimeInterval: Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
}
