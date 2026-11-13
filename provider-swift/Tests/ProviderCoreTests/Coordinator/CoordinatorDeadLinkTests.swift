import Foundation
import Network
import Testing
@testable import ProviderCore

/// A coordinator node that is hard-reset leaves the provider's WebSocket open
/// with no TCP reset and no close frame. The provider must find the silent
/// link from its pings and reconnect at once, but never drop a link that still
/// delivers frames. These rows run the real `CoordinatorClient` over loopback
/// against `LoopbackWebSocketPeer`, with a 0.1 s ping interval and a 0.6 s
/// bound instead of 2 s and 6 s.
@Suite("Coordinator dead link", .serialized)
struct CoordinatorDeadLinkTests {
    private static let liveness = CoordinatorLinkLiveness(
        pingInterval: .milliseconds(100), deadAfter: .milliseconds(600), suspensionGap: .seconds(30))

    @Test("a silent peer is declared dead within the bound and the client reconnects at once",
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
        // Silence of more than 0.6 s, the next 0.1 s tick, a 0-0.25 s wait and a
        // loopback reconnect. Before the change the bound alone was 30 s.
        #expect(reconnectAfter > .milliseconds(600), "reconnected \(reconnectAfter) after connecting, before the bound")
        #expect(reconnectAfter < .seconds(3), "reconnected \(reconnectAfter) after connecting")
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
