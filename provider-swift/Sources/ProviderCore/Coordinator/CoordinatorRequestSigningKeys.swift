/// The coordinator request-signing public keys each build serves, and whether
/// it refuses a request that carries no signature (`CoordinatorRequestVerifier`).
///
/// A key is the base64 of a raw 32-byte Ed25519 public key; its `key_id` is
/// `CoordinatorRequestSignature.keyID`. A new key is listed next to the old
/// one before signing moves to it; `requireSignature` stays off until every
/// coordinator of that environment signs.
enum CoordinatorRequestSigningKeys {
    struct Pin: Sendable, Equatable {
        var publicKeys: [String]
        var requireSignature: Bool
    }

    static func pin(for environment: BuildEnvironment) -> Pin {
        switch environment {
        case .prod: Pin(publicKeys: [], requireSignature: false)
        case .dev: Pin(publicKeys: [], requireSignature: false)
        case .staging: Pin(publicKeys: [], requireSignature: false)
        }
    }
}
