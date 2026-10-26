import Foundation
import Network
import Testing
@testable import ProviderCore

/// A coordinator restart makes every provider reconnect at once. A peer that
/// accepts TCP but never completes the TLS handshake or WebSocket upgrade left
/// the connection in `.preparing` with nothing to time it out, so the provider
/// never registered again until its process restarted.
@Suite("Coordinator handshake deadline", .serialized)
struct CoordinatorHandshakeDeadlineTests {
    @Test(.timeLimit(.minutes(1)))
    func stalledHandshakeTimesOutAndCancelsTheConnection() async throws {
        let peer = try SilentPeer()
        let port = try await peer.start()
        defer { peer.stop() }
        let connection = NWConnection(
            to: .url(try #require(URL(string: "ws://127.0.0.1:\(port)/ws/provider"))),
            using: webSocketParameters())
        defer { connection.cancel() }

        let error = await #expect(throws: CoordinatorError.self) {
            try await CoordinatorConnectionHandshake.start(
                connection, on: DispatchQueue(label: "handshake-deadline-test"), timeout: 0.3
            ) {
                Issue.record("a peer that never upgrades cannot become ready")
            }
        }
        guard case .handshakeTimeout? = error else {
            Issue.record("expected a handshake timeout, got \(String(describing: error))")
            return
        }
        #expect(peer.acceptedCount == 1)
        // The deadline releases the stalled transport, not only the waiter.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while connection.state != .cancelled && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(connection.state == .cancelled)
    }

    @Test(.timeLimit(.minutes(1)))
    func clientRetriesAfterAStalledHandshake() async throws {
        let peer = try SilentPeer()
        let port = try await peer.start()
        defer { peer.stop() }
        let client = CoordinatorClient(
            config: CoordinatorClientConfig(
                url: "ws://127.0.0.1:\(port)/ws/provider",
                hardware: handshakeTestHardware(),
                models: [],
                backendName: "mlx-swift",
                heartbeatInterval: 60,
                handshakeTimeout: 0.3),
            stats: AtomicProviderStats(),
            state: ProviderState(),
            liveAPNsToken: { nil })
        let (events, _) = await client.start()
        defer { Task { await client.shutdown() } }

        // Each stalled attempt must end as an ordinary failed connection and
        // reach the reconnect loop's backoff, never wait forever.
        var disconnects = 0
        for await event in events {
            switch event {
            case .connected:
                Issue.record("a peer that never upgrades cannot register a session")
            case .disconnected:
                disconnects += 1
            default:
                break
            }
            if disconnects == 2 { break }
        }
        #expect(disconnects == 2)
        #expect(peer.acceptedCount >= 2)
        #expect(await !client.hasRegisteredConnection())
    }
}

/// Accepts TCP connections on loopback and reads the upgrade request without
/// ever answering it.
private final class SilentPeer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "silent-coordinator-peer")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var acceptedCount: Int { lock.withLock { connections.count } }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in }
        }
        let listener = self.listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: NWError.posix(.EADDRNOTAVAIL))
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ connections }) { connection.cancel() }
    }
}

/// The client's transport stack: plain TCP for a `ws://` URL plus WebSocket.
private func webSocketParameters() -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
    return parameters
}

private func handshakeTestHardware() -> HardwareInfo {
    HardwareInfo(
        machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
        memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546)
}
