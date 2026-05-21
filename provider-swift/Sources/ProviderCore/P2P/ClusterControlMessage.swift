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
    case promptTokens      = 0x08  // rank 0 → rank 1: { uid, tokens, maxTokens } — begin TP request
    case stepToken         = 0x09  // rank 0 → rank 1: { uid, token } — advance decode by one token
    case sessionStop       = 0x0A  // rank 0 → rank 1: { uid } — abort / end of request
    case ppActivation      = 0x0B  // rank 0 → rank 1: { uid, seqLen, sealedActivation } — PP activation
    case ppToken           = 0x0C  // rank 1 → rank 0: { uid, sealedToken } — PP sampled token
    case ppSessionEnd      = 0x0D  // rank 0 → rank 1: { uid } — PP request complete
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

// MARK: - TP inference payloads (PR 4b)

/// Sent by rank 0 → rank 1 at the start of a tensor-parallel inference request.
/// Carries the prompt token IDs and generation budget. Rank 1 uses these to reset
/// its KV cache and run the prefill forward pass in lockstep with rank 0.
public struct PromptTokensPayload: Codable, Sendable {
    /// Unique request identifier (UUID string). Used to correlate frames
    /// for this request; becomes load-bearing in PR 4d's concurrent-request path.
    public let uid: String
    /// Prompt token IDs in order.
    public let tokens: [Int]
    /// Maximum number of new tokens to generate (not including the prompt).
    public let maxTokens: Int

    public init(uid: String, tokens: [Int], maxTokens: Int) {
        self.uid = uid
        self.tokens = tokens
        self.maxTokens = maxTokens
    }
}

/// Sent by rank 0 → rank 1 after each greedy-sampled token.
/// Rank 1 feeds this token as input for the next decode step, running
/// `model.callAsFunction` in lockstep with rank 0's matching call.
public struct StepTokenPayload: Codable, Sendable {
    /// Request identifier — must match the `uid` in the leading `promptTokens` frame.
    public let uid: String
    /// The token ID sampled by rank 0 on the previous decode step.
    public let token: Int

    public init(uid: String, token: Int) {
        self.uid = uid
        self.token = token
    }
}

/// Sent by rank 0 → rank 1 when generation ends (EOS reached, maxTokens exhausted,
/// or a fatal error occurred on rank 0). Rank 1 exits its decode loop cleanly.
public struct SessionStopPayload: Codable, Sendable {
    /// Request identifier that is being stopped.
    public let uid: String

    public init(uid: String) {
        self.uid = uid
    }
}

// MARK: - PP inference payloads (PR 4c)

/// Sent by rank 0 → rank 1 for each pipeline-parallel decode step.
///
/// `sealedActivation` is the AES-GCM ciphertext produced by
/// `TensorCrypto.sealActivation(seqLen:activation:key:)`. It carries the
/// activation tensor for layers 0..splitLayer.
///
/// Note on double-encryption: `sealedActivation` is itself AES-GCM sealed by
/// TensorCrypto before being embedded in this JSON payload. The outer
/// ThunderboltLink `ClusterFrame.encode/decode` wraps the whole frame in a
/// second layer of AES-256-GCM. Double encryption is intentional — it matches
/// the design established by `inferenceStep`/`inferenceToken` (raw ciphertext
/// sent as frame payload, then ClusterFrame wraps again) and gives defence-in-
/// depth against link-layer stripping. TensorCrypto's docstring does not flag
/// the outer encryption as redundant; both layers are kept.
public struct PPActivationPayload: Codable, Sendable {
    /// Unique request identifier (UUID string).
    public let uid: String
    /// Sequence length of the activation tensor. Rank 1 uses this to reshape
    /// the decrypted bytes into `[1, seqLen, hiddenDim]`.
    public let seqLen: Int
    /// AES-GCM sealed activation tensor bytes (from TensorCrypto.sealActivation).
    public let sealedActivation: Data

    public init(uid: String, seqLen: Int, sealedActivation: Data) {
        self.uid = uid
        self.seqLen = seqLen
        self.sealedActivation = sealedActivation
    }
}

/// Sent by rank 1 → rank 0 after sampling the next token.
///
/// `sealedToken` is the AES-GCM ciphertext of a single `Int32` token ID,
/// produced by `TensorCrypto.sealToken(_:key:)`.
public struct PPTokenPayload: Codable, Sendable {
    /// Request identifier — must match the `uid` in the leading `ppActivation` frame.
    public let uid: String
    /// AES-GCM sealed token ID bytes (from TensorCrypto.sealToken).
    public let sealedToken: Data

    public init(uid: String, sealedToken: Data) {
        self.uid = uid
        self.sealedToken = sealedToken
    }
}

/// Sent by rank 0 → rank 1 when generation ends (EOS reached, maxTokens
/// exhausted, or a fatal error occurred on rank 0). Rank 1 exits its decode
/// loop cleanly and resets its KV cache.
public struct PPSessionEndPayload: Codable, Sendable {
    /// Request identifier that is ending.
    public let uid: String

    public init(uid: String) {
        self.uid = uid
    }
}

// MARK: - Frame encoding
//
// Every ThunderboltLink frame:
//   [1 byte: ClusterMsgType.rawValue] [N bytes: payload]
//
// Payload encoding by type:
//   handshakeHello / handshakeAck / pong / jacclBootstrap          → JSON-encoded Codable struct
//   promptTokens / stepToken / sessionStop                          → JSON-encoded Codable struct
//   ppActivation / ppToken / ppSessionEnd                           → JSON-encoded Codable struct
//   ping / sessionEnd                                               → empty (0 bytes)
//   inferenceStep / inferenceToken                                  → raw AES-GCM ciphertext (opaque bytes)
//
// All frames travel over the encrypted ThunderboltLink; the link-layer
// AES-256-GCM wrapping in ClusterFrame.encode/decode covers every type.

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
