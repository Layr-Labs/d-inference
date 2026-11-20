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
        // key_id e7d53f46617e9494, logged by the production coordinator at startup.
        case .prod: Pin(publicKeys: ["gvBKtKYQ8p/v1nY5kvhtUGMMvJUoznS9Rjj59QjPusM="], requireSignature: false)
        // key_id 7c638fff1a85dd4a, logged by the DevNet coordinators at startup.
        case .dev: Pin(publicKeys: ["wyhB/FIT7Nk4Mg2CVK2rBDpv730sGR6mG3AtgjaUg9s="], requireSignature: false)
        case .staging: Pin(publicKeys: [], requireSignature: false)
        }
    }
}
