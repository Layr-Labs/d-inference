/// AttestationSigner -- protocol abstracting over ephemeral and persistent
/// Secure Enclave signing keys for attestation.
///
/// Both `SecureEnclaveIdentity` (CryptoKit, ephemeral) and
/// `PersistentEnclaveKey` (Security framework, keychain-backed) conform.
/// `AttestationBuilder` and `ProviderLoop` use this protocol to accept
/// either implementation.

import Foundation

public protocol AttestationSigner: Sendable {
    /// Sign arbitrary data, returning a DER-encoded ECDSA signature.
    func sign(_ data: Data) throws -> Data

    /// Base64-encoded P-256 public key (raw 64 bytes: X || Y).
    var publicKeyBase64: String { get }
}

// MARK: - Conformances

extension SecureEnclaveIdentity: AttestationSigner {}

extension PersistentEnclaveKey: AttestationSigner {}
