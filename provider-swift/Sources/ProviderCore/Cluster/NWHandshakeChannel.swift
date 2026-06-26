/// NWHandshakeChannel -- a `HandshakeChannel` over a TCP connection using
/// `Network.framework`, for carrying the handshake between two cluster Macs on
/// the same Thunderbolt-bridge / LAN.
///
/// Length-prefixed `HandshakeEnvelope` frames (4-byte big-endian length + JSON
/// body, via `HandshakeWire`). The lower-nodeId node dials the higher one
/// (`connect`); the higher one listens (`accept`). Both sides then run the
/// `ClusterHandshakeRunner` over the resulting channel.
///
/// This is a control-plane channel only (3 small messages per neighbor at
/// startup); the activation data plane is separate (MLX ring). The handshake
/// itself authenticates the peer against the coordinator roster, so this socket
/// does not need its own TLS — a MITM cannot forge the SE-signed transcript.

import Foundation
import Network

public actor NWHandshakeChannel: HandshakeChannel {
    private let connection: NWConnection
    private var started = false
    private var readBuffer = Data()

    public init(connection: NWConnection) {
        self.connection = connection
    }

    /// Dial a peer (initiator side).
    public static func connect(host: String, port: UInt16) -> NWHandshakeChannel {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!)
        let conn = NWConnection(to: endpoint, using: .tcp)
        return NWHandshakeChannel(connection: conn)
    }

    private func startIfNeeded() async throws {
        guard !started else { return }
        started = true
        let queue = DispatchQueue(label: "darkbloom.cluster.handshake")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume()
                case .failed(let e), .waiting(let e): cont.resume(throwing: e)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func send(_ envelope: HandshakeEnvelope) async throws {
        try await startIfNeeded()
        let framed = try HandshakeWire.encode(envelope)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    public func recv() async throws -> HandshakeEnvelope {
        try await startIfNeeded()
        // Read the 4-byte length prefix, then the body.
        let header = try await readExactly(4)
        let len = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        let body = try await readExactly(len)
        return try HandshakeWire.decode(body)
    }

    /// Pull exactly `count` bytes, buffering any overshoot for the next read.
    private func readExactly(_ count: Int) async throws -> Data {
        while readBuffer.count < count {
            let chunk = try await receiveChunk()
            if chunk.isEmpty { throw HandshakeWireError.channelClosed }
            readBuffer.append(chunk)
        }
        let out = readBuffer.prefix(count)
        readBuffer.removeFirst(count)
        return Data(out)
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if isComplete { cont.resume(returning: Data()); return }
                cont.resume(returning: Data())
            }
        }
    }

    public func close() {
        connection.cancel()
    }
}

/// Listener that accepts a single inbound handshake connection (responder side).
public actor NWHandshakeListener {
    private let listener: NWListener

    public init(port: UInt16) throws {
        self.listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
    }

    /// Wait for the next inbound peer and return a channel for it.
    public func accept() async throws -> NWHandshakeChannel {
        let queue = DispatchQueue(label: "darkbloom.cluster.handshake.listen")
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWHandshakeChannel, Error>) in
            listener.newConnectionHandler = { conn in
                cont.resume(returning: NWHandshakeChannel(connection: conn))
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let e) = state { cont.resume(throwing: e) }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }
}
