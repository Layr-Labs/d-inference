import Foundation
import Network
#if canImport(os)
import os
#endif

// MARK: - Setup note
//
// Thunderbolt networking creates a bridge/Ethernet interface on macOS.
// Before running, raise the kernel socket buffer ceiling on both Macs:
//
//   sudo sysctl -w kern.ipc.maxsockbuf=268435456
//   sudo sysctl -w net.inet.tcp.sendspace=33554432
//   sudo sysctl -w net.inet.tcp.recvspace=33554432
//
// Assign static IPs to the Thunderbolt interface on each machine:
//   sudo ifconfig bridge100 192.168.100.1 255.255.255.0   # Mac A
//   sudo ifconfig bridge100 192.168.100.2 255.255.255.0   # Mac B
//
// The interface name (bridge100, en7, en8…) varies. Find it with:
//   networksetup -listallhardwareports | grep -A2 -i thunderbolt

// MARK: - Wire format
//
// Every message is framed as:
//   [8 bytes: UInt64 little-endian payload length] [payload bytes]
//
// The receiver accumulates until it has the exact byte count,
// so partial TCP segments are handled correctly.

public enum ThunderboltError: Error, LocalizedError {
    case invalidFrameLength(UInt64)
    case connectionClosed
    case incompleteRead(expected: Int, got: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidFrameLength(let n): return "Invalid frame length \(n) — corrupt header or wrong endpoint"
        case .connectionClosed:          return "Connection closed before frame completed"
        case .incompleteRead(let e, let g): return "Incomplete read: expected \(e) bytes, got \(g)"
        }
    }
}

// MARK: - ThunderboltLink

/// Factory for listener and outbound connections over Thunderbolt networking.
public enum ThunderboltLink {
    public static let defaultPort: UInt16 = 7777
    /// 256 MB sanity cap on a single frame — raise if transferring full weight shards.
    public static let maxFrameBytes: UInt64 = 256 * 1024 * 1024

    // MARK: Parameters

    static func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true           // disable Nagle
        tcp.connectionTimeout = 10
        // keepalive so a stalled peer is detected within ~30 s
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3

        let params = NWParameters(tls: nil, tcp: tcp)
        // Thunderbolt networking surfaces as wiredEthernet on macOS.
        // If both machines have Wi-Fi up too, this prevents accidental
        // fallback to the slower interface.
        params.requiredInterfaceType = .wiredEthernet
        params.prohibitedInterfaceTypes = [.wifi, .cellular, .loopback]
        return params
    }

    // MARK: Listener

    /// Start a listener. Calls `onConnection` for every accepted peer.
    /// The returned `NWListener` must be kept alive; cancel it to stop accepting.
    public static func listen(
        on port: UInt16 = defaultPort,
        queue: DispatchQueue = .global(qos: .userInitiated),
        onConnection: @escaping @Sendable (ThunderboltConnection) -> Void
    ) throws -> NWListener {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw CocoaError(.fileReadUnknown)
        }
        let listener = try NWListener(using: makeParameters(), on: nwPort)
        listener.newConnectionHandler = { nwConn in
            let conn = ThunderboltConnection(nwConn)
            conn.start(queue: queue)
            onConnection(conn)
        }
        listener.start(queue: queue)
        return listener
    }

    // MARK: Connector

    /// Connect to a peer. Resolves when the TCP handshake completes.
    public static func connect(
        to host: String,
        port: UInt16 = defaultPort,
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) async throws -> ThunderboltConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ThunderboltError.invalidFrameLength(0)
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let nwConn = NWConnection(to: endpoint, using: makeParameters())
        let conn = ThunderboltConnection(nwConn)
        try await conn.startAndAwaitReady(queue: queue)
        return conn
    }
}

// MARK: - ThunderboltConnection

/// A single bidirectional TCP connection over the Thunderbolt interface.
/// Thread-safe: all NWConnection calls are dispatched onto its private queue.
public final class ThunderboltConnection: Sendable {
    private let nwConn: NWConnection
    private let logger = Logger(subsystem: "io.darkbloom.provider", category: "ThunderboltLink")

    init(_ nwConn: NWConnection) {
        self.nwConn = nwConn
    }

    // MARK: Internal start

    func start(queue: DispatchQueue) {
        nwConn.start(queue: queue)
    }

    func startAndAwaitReady(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nwConn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.nwConn.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let err):
                    self?.nwConn.stateUpdateHandler = nil
                    cont.resume(throwing: err)
                case .cancelled:
                    self?.nwConn.stateUpdateHandler = nil
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            nwConn.start(queue: queue)
        }
    }

    // MARK: Send

    /// Send `data` as a single framed message.
    public func send(_ data: Data) async throws {
        var frame = Data(capacity: 8 + data.count)
        var length = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(data)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nwConn.send(content: frame, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) }
                else        { cont.resume() }
            })
        }
    }

    // MARK: Receive

    /// Receive one complete framed message. Blocks until all payload bytes arrive.
    public func receive() async throws -> Data {
        let header = try await accumulate(exactly: 8)
        let payloadLength = header.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }

        guard payloadLength > 0, payloadLength <= ThunderboltLink.maxFrameBytes else {
            throw ThunderboltError.invalidFrameLength(payloadLength)
        }
        return try await accumulate(exactly: Int(payloadLength))
    }

    /// Accumulate exactly `n` bytes, handling TCP segmentation correctly.
    private func accumulate(exactly n: Int) async throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(n)

        while buffer.count < n {
            let remaining = n - buffer.count
            let chunk = try await rawReceive(upTo: remaining)
            buffer.append(chunk)
        }
        return buffer
    }

    /// Single NWConnection receive call — returns between 1 and `maxLength` bytes.
    private func rawReceive(upTo maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            nwConn.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, err in
                if let err {
                    cont.resume(throwing: err)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(throwing: ThunderboltError.connectionClosed)
                } else {
                    cont.resume(throwing: ThunderboltError.incompleteRead(expected: maxLength, got: 0))
                }
            }
        }
    }

    // MARK: Stream

    /// Continuous receive as an AsyncThrowingStream. Ends when the connection closes.
    public func receiveStream() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    while true {
                        let data = try await receive()
                        continuation.yield(data)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: Close

    public func cancel() {
        nwConn.cancel()
    }

    public var debugDescription: String {
        nwConn.debugDescription
    }
}
