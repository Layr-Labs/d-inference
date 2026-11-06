import Foundation
import Network
import Testing
@testable import ProviderCore

/// The coordinator measures each provider connection's round trip with a
/// WebSocket ping every 30 s, and its WebSocket library puts a counter in the
/// ping's payload ("1", "2", …). Network.framework answers the ping and also
/// hands it up with that payload. The receive loop skipped only empty control
/// frames, so every probe reached the message codec and logged "Failed to parse
/// coordinator message" at error level: on production pair leaders, one
/// `<private>` error every 30.0 s for the whole session.
@Suite("Coordinator inbound control frames", .serialized)
struct CoordinatorInboundControlFrameTests {
    @Test(.timeLimit(.minutes(1)))
    func aPingWithAPayloadIsAControlFrameNotAMessage() async throws {
        let peer = try PingingPeer(payload: Data("1".utf8))
        let port = try await peer.start()
        defer { peer.stop() }
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws/provider"))
        let connection = NWConnection(to: .url(url), using: CoordinatorClient.connectionParameters(for: url))
        defer { connection.cancel() }
        try await CoordinatorConnectionHandshake.start(
            connection, on: DispatchQueue(label: "inbound-control-frame-test"), timeout: 10) {}

        let (data, opcode) = try await receiveOneMessage(connection)
        // What Network.framework delivers: the ping, with the coordinator's payload.
        #expect(opcode == .ping)
        #expect(data == Data("1".utf8))
        #expect(CoordinatorClient.inboundFrame(data: data, opcode: opcode) == .control)
    }

    @Test func onlyAConfirmedControlOpcodeIsSkipped() {
        #expect(CoordinatorClient.inboundFrame(data: nil, opcode: .pong) == .control)
        #expect(CoordinatorClient.inboundFrame(data: Data("2".utf8), opcode: .pong) == .control)
        #expect(CoordinatorClient.inboundFrame(data: Data(), opcode: .ping) == .control)
        // No data and no control opcode: the peer dropped the transport.
        #expect(CoordinatorClient.inboundFrame(data: nil, opcode: nil) == .transportClosed)
        #expect(CoordinatorClient.inboundFrame(data: Data(), opcode: .text) == .transportClosed)
        let drainAck = Data(#"{"type":"drain_ack","id":"x"}"#.utf8)
        #expect(CoordinatorClient.inboundFrame(data: drainAck, opcode: .text) == .message(drainAck))
        #expect(CoordinatorClient.inboundFrame(data: drainAck, opcode: nil) == .message(drainAck))
    }
}

private func receiveOneMessage(_ connection: NWConnection) async throws -> (Data?, NWProtocolWebSocket.Opcode?) {
    try await withCheckedThrowingContinuation { continuation in
        connection.receiveMessage { data, context, _, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            continuation.resume(returning: (data, metadata?.opcode))
        }
    }
}

/// A loopback WebSocket server that sends one ping carrying `payload` to each
/// connection once its upgrade completes, as the coordinator's transport probe does.
private final class PingingPeer: @unchecked Sendable {
    private let listener: NWListener
    private let payload: Data
    private let queue = DispatchQueue(label: "pinging-coordinator-peer")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    init(payload: Data) throws {
        self.payload = payload
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.lock.withLock { self.connections.append(connection) }
            connection.stateUpdateHandler = { [payload = self.payload] state in
                guard case .ready = state else { return }
                let ping = NWProtocolWebSocket.Metadata(opcode: .ping)
                let context = NWConnection.ContentContext(identifier: "transport-probe", metadata: [ping])
                connection.send(content: payload, contentContext: context, isComplete: true,
                                completion: .contentProcessed { _ in })
            }
            connection.start(queue: self.queue)
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
