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
        port: UInt16, reconnectPolicy: CoordinatorReconnectPolicy = CoordinatorReconnectPolicy()
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
                heartbeatInterval: 60),
            stats: AtomicProviderStats(),
            state: ProviderState(),
            liveAPNsToken: { nil },
            reconnectPolicy: reconnectPolicy,
            linkLiveness: Self.liveness)
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
