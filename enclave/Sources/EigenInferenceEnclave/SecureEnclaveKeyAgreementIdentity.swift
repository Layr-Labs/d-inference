import CryptoKit
import Foundation

/// Manages a hardware-bound P-256 key-agreement key in the Apple Secure Enclave.
///
/// We use this key to deterministically derive the provider's long-lived X25519
/// E2E transport secret inside the signed provider process without relying on
/// the macOS data-protection keychain. The key's `dataRepresentation` is an
/// opaque, device-bound blob that can be written to disk and only reloaded by
/// the same Secure Enclave.
public final class SecureEnclaveKeyAgreementIdentity {
    // Fixed peer public key used solely for deterministic E2E secret derivation.
    // The private half never ships. The resulting shared secret is stable for a
    // given Secure Enclave key but unique per machine.
    private static let derivationPeerPublicKey = try! P256.KeyAgreement.PublicKey(
        rawRepresentation: Data(
            base64Encoded: "etFcKoin6vgFKaVe8pPK/P/XvBbvA+BburS6LTigzotwv+wOhiobdUqqiuGAqBkmH+voNoW2Rw9IrLMjNGi+cQ=="
        )!
    )

    private static let derivationSalt = Data("darkbloom.e2e.x25519.salt.v1".utf8)
    private static let derivationInfo = Data("darkbloom.e2e.x25519.secret.v1".utf8)

    private let privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey
    public let publicKey: P256.KeyAgreement.PublicKey

    public init() throws {
        self.privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        self.publicKey = self.privateKey.publicKey
    }

    public init(dataRepresentation: Data) throws {
        self.privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
            dataRepresentation: dataRepresentation
        )
        self.publicKey = self.privateKey.publicKey
    }

    public var dataRepresentation: Data {
        privateKey.dataRepresentation
    }

    public var publicKeyRaw: Data {
        publicKey.rawRepresentation
    }

    public var publicKeyBase64: String {
        publicKey.rawRepresentation.base64EncodedString()
    }

    /// Deterministically derive the provider's X25519 secret bytes.
    ///
    /// This is not stored anywhere on disk; the caller can recreate it on demand
    /// by reloading the opaque Secure Enclave handle and re-running the ECDH+HKDF
    /// derivation.
    public func deriveX25519Secret() throws -> Data {
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(
            with: Self.derivationPeerPublicKey
        )
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Self.derivationSalt,
            sharedInfo: Self.derivationInfo,
            outputByteCount: 32
        )
        return symmetricKey.withUnsafeBytes { bytes in
            Data(bytes)
        }
    }
}
