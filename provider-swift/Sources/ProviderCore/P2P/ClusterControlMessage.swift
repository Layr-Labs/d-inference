import Foundation

// MARK: - Message type discriminator

public enum ClusterMsgType: UInt8, Sendable {
    case handshakeHello    = 0x01
    case handshakeAck      = 0x02
    case ping              = 0x03
    case pong              = 0x04
    case inferenceStep     = 0x05  // rank 0 → rank 1: encrypted (seqLen || activation)
    case inferenceToken    = 0x06  // rank 1 → rank 0: encrypted token ID
    case jacclBootstrap    = 0x07  // rank 0 → rank 1: jaccl coordinator port + session ID
    case sessionEnd        = 0xFF
}

// MARK: - Handshake

public struct HandshakeHello: Codable, Sendable {
    /// Raw 64-byte P-256 SE public key (X || Y uncompressed, no prefix byte).
    public let sePubKeyRaw: Data
    /// Raw 32-byte ephemeral X25519 public key.
    public let ephemeralX25519PubKey: Data
    /// 32-byte random nonce.
    public let nonce: Data
    /// DER ECDSA signature over SHA256(ephemeralX25519PubKey || nonce).
    public let seSignature: Data
}

public struct HandshakeAck: Codable, Sendable {
    /// Raw 64-byte P-256 SE public key.
    public let sePubKeyRaw: Data
    /// Raw 32-byte ephemeral X25519 public key.
    public let ephemeralX25519PubKey: Data
    /// 32-byte random nonce (rank 1's contribution).
    public let nonce: Data
    /// DER ECDSA signature over SHA256(hello.nonce || ack.nonce || ack.ephemeralX25519PubKey).
    public let seSignature: Data
}

// MARK: - Health

public enum MemoryPressureLevel: String, Codable, Sendable {
    case normal, warning, critical
}

public struct PongPayload: Codable, Sendable {
    public let modelLoaded: Bool
    public let inferenceInFlight: Bool
    public let memoryPressure: MemoryPressureLevel

    public init(modelLoaded: Bool, inferenceInFlight: Bool, memoryPressure: MemoryPressureLevel) {
        self.modelLoaded = modelLoaded
        self.inferenceInFlight = inferenceInFlight
        self.memoryPressure = memoryPressure
    }
}

// MARK: - jaccl bootstrap

/// Sent by rank 0 → rank 1 immediately after the SE handshake completes.
/// Carries the TCP port rank 0 will bind for jaccl's coordinator side channel
/// and a session identifier used to name the shared topology JSON file.
public struct JacclBootstrapPayload: Codable, Sendable {
    /// TCP port rank 0 binds for jaccl's coordinator side channel.
    /// Rank 1 connects to rank 0's Thunderbolt IP on this port.
    public let port: UInt16
    /// Unique session identifier (UUID string). Both ranks use this to
    /// derive the topology file path `/tmp/darkbloom-jaccl-topology-<sessionID>.json`.
    public let sessionID: String

    public init(port: UInt16, sessionID: String) {
        self.port = port
        self.sessionID = sessionID
    }
}

// MARK: - Frame encoding
//
// Every ThunderboltLink frame:
//   [1 byte: ClusterMsgType.rawValue] [N bytes: payload]
//
// Payload encoding by type:
//   handshakeHello / handshakeAck / pong / jacclBootstrap → JSON-encoded Codable struct
//   ping / sessionEnd                                      → empty (0 bytes)
//   inferenceStep / inferenceToken                         → raw AES-GCM ciphertext (opaque bytes)

public enum ClusterFrame {

    // MARK: Encode

    public static func encode(type: ClusterMsgType, payload: Data = Data()) -> Data {
        var frame = Data(capacity: 1 + payload.count)
        frame.append(type.rawValue)
        frame.append(payload)
        return frame
    }

    public static func encodeJSON<T: Encodable>(type: ClusterMsgType, value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        return encode(type: type, payload: payload)
    }

    // MARK: Decode

    public static func decodeType(from frame: Data) throws -> ClusterMsgType {
        guard let first = frame.first, let t = ClusterMsgType(rawValue: first) else {
            throw ClusterError.unknownMessageType(frame.first ?? 0)
        }
        return t
    }

    public static func decodePayload(from frame: Data) -> Data {
        frame.count > 1 ? frame.dropFirst() : Data()
    }

    public static func decodeJSON<T: Decodable>(_ type: T.Type, from frame: Data) throws -> T {
        let payload = decodePayload(from: frame)
        return try JSONDecoder().decode(type, from: payload)
    }
}

// MARK: - Errors

public enum ClusterError: Error, Sendable {
    case unknownMessageType(UInt8)
    case unexpectedMessage(expected: ClusterMsgType, got: ClusterMsgType)
    case handshakeFailed(String)
    case peerSEKeyMismatch
    case linkLost
    case inferenceTimeout
    case notReady(ClusterHealth)
    /// All retry attempts exhausted — caller should return HTTP 429.
    case serviceUnavailable
    /// No pinned SE key in Keychain for this peer IP. Run `cluster setup` first.
    case peerSEKeyNotPinned
}

// MARK: - Health state

public enum ClusterHealth: Sendable, CustomStringConvertible {
    case ready
    case degraded(missedPings: Int)
    case unavailable

    public var description: String {
        switch self {
        case .ready: return "ready"
        case .degraded(let n): return "degraded(missedPings: \(n))"
        case .unavailable: return "unavailable"
        }
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
