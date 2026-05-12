/// SecureEnclaveIdentity -- hardware-bound P-256 signing key management.
///
/// Manages a P-256 ECDSA signing key stored in the Apple Secure Enclave.
/// The private key never leaves the hardware -- only signing operations
/// can be performed through the CryptoKit API.
///
/// The Secure Enclave is available on all Apple Silicon Macs and provides:
///   - Hardware-isolated key storage (private key cannot be exported)
///   - Tamper-resistant signing operations
///   - Device-bound identity (key cannot be cloned to another device)
///
/// This identity serves two purposes in Darkbloom:
///   1. **Attestation signing**: The provider signs a hardware/software state
///      blob with this key, proving its identity and security posture.
///   2. **Challenge-response**: The coordinator periodically challenges the
///      provider to sign a nonce, verifying the same hardware is still connected.
///
/// The public key is a raw P-256 point (64 bytes: X || Y, without the 0x04
/// uncompressed prefix). Both base64 and hex representations are available
/// for interoperability with the Go coordinator (which expects either format).
///
/// The provider uses this identity ephemerally. Each process launch creates a
/// fresh Secure Enclave signing key and binds the current X25519 public key in
/// the registration attestation.
///
/// Ported from `enclave/Sources/DarkbloomEnclave/SecureEnclaveIdentity.swift`.
/// In pure Swift this is direct CryptoKit usage -- no FFI bridge needed.

import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "secure-enclave")

/// Manages a hardware-bound P-256 signing key in the Apple Secure Enclave.
///
/// The private key never leaves the Secure Enclave. Production provider startup
/// intentionally does not persist or reload the opaque Secure Enclave key
/// handle; attested identity is fresh per launch and bound to the X25519 key
/// used for E2E encryption.
///
/// Thread-safety: This type is `Sendable` because the Secure Enclave key
/// is immutable after creation and CryptoKit signing operations are safe
/// to call from any thread.
public final class SecureEnclaveIdentity: @unchecked Sendable {
    private let privateKey: SecureEnclave.P256.Signing.PrivateKey
    public let publicKey: P256.Signing.PublicKey

    // MARK: - Initializers

    /// Create a new identity (generates a new key in the Secure Enclave).
    ///
    /// Each call creates a distinct key -- there is no singleton and no
    /// production persistence path.
    public init() throws {
        self.privateKey = try SecureEnclave.P256.Signing.PrivateKey()
        self.publicKey = self.privateKey.publicKey
        logger.info("Created new Secure Enclave identity")
    }

    /// Public key as raw bytes (64 bytes: X || Y, without the 0x04 prefix).
    ///
    /// This format matches what the Go coordinator expects for P-256 public
    /// key verification (64-byte raw representation).
    public var publicKeyRaw: Data {
        publicKey.rawRepresentation
    }

    /// Public key as a base64-encoded string.
    ///
    /// Used in the attestation blob's `publicKey` field and sent to the
    /// coordinator during registration.
    public var publicKeyBase64: String {
        publicKey.rawRepresentation.base64EncodedString()
    }

    /// Public key as a lowercase hex string.
    public var publicKeyHex: String {
        publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Sign / Verify

    /// Sign arbitrary data using the Secure Enclave private key.
    ///
    /// The signing operation happens inside the Secure Enclave hardware.
    /// Returns the signature in DER-encoded format, which is the standard
    /// format for ECDSA signatures and compatible with Go's crypto/ecdsa
    /// and the ASN.1 DER parser.
    public func sign(_ data: Data) throws -> Data {
        let signature = try privateKey.signature(for: data)
        return signature.derRepresentation
    }

    /// Sign a UTF-8 string, returning the base64-encoded DER signature.
    ///
    /// Convenience method for signing string payloads (nonces, hashes).
    /// Returns nil if signing fails.
    public func signString(_ string: String) -> String? {
        guard let sigData = try? sign(Data(string.utf8)) else { return nil }
        return sigData.base64EncodedString()
    }

    /// Verify a DER-encoded signature against this identity's public key.
    ///
    /// This is a convenience method for verifying signatures produced by
    /// this same identity.
    public func verify(signature: Data, for data: Data) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }
        return publicKey.isValidSignature(sig, for: data)
    }

    /// Verify a DER-encoded signature against an arbitrary P-256 public key
    /// given as raw bytes (64 bytes: X || Y).
    ///
    /// This static method is used by attestation verification code to check
    /// signatures without needing the private key or Secure Enclave.
    public static func verify(signature: Data, for data: Data, publicKey: Data) -> Bool {
        guard let pk = try? P256.Signing.PublicKey(rawRepresentation: publicKey),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature)
        else {
            return false
        }
        return pk.isValidSignature(sig, for: data)
    }

    // MARK: - Availability

    /// Whether the Secure Enclave is available on this device.
    ///
    /// Returns `true` on all Apple Silicon Macs and iPhones with A7+.
    /// Returns `false` on Intel Macs and non-Apple hardware.
    public static var isAvailable: Bool {
        SecureEnclave.isAvailable
    }

    // MARK: - Ephemeral Startup

    /// Create a fresh provider signing identity for this process launch.
    public static func createEphemeral() throws -> SecureEnclaveIdentity? {
        guard SecureEnclave.isAvailable else {
            logger.warning("Secure Enclave not available on this device")
            return nil
        }
        return try SecureEnclaveIdentity()
    }
}
