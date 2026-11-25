import Foundation

/// What a provider that serves blind requests registers: the protocol version
/// and the coordinator request-signing keys it pins. The keys come from the
/// build (`pinned(for:)`), never from the connection.
public struct BlindRequestRegistration: Sendable {
    public let protocolVersion: Int
    public let pins: [CoordinatorRequestSigningPin]

    public init(protocolVersion: Int = BlindSignedTerms.currentVersion, pins: [CoordinatorRequestSigningPin]) {
        self.protocolVersion = protocolVersion
        self.pins = pins
    }

    /// The coordinator request-signing keys each build pins for blind
    /// requests: base64 of a raw 32-byte Ed25519 public key and the pin's
    /// expiry, Unix milliseconds. A build that pins none serves no blind
    /// request.
    static func pinnedKeys(for environment: BuildEnvironment) -> [CoordinatorRequestSigningPin] {
        let keys: [(publicKey: String, expiresAtMs: Int64)]
        switch environment {
        case .prod, .dev, .staging: keys = []
        }
        return keys.compactMap { CoordinatorRequestSigningPin(base64PublicKey: $0.publicKey, expiresAtMs: $0.expiresAtMs) }
    }
}
