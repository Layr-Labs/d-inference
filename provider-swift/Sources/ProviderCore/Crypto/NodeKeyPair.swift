import CryptoKit
import Foundation
import Sodium

// MARK: - Errors

public enum CryptoError: Error, CustomStringConvertible, Sendable {
    case ciphertextTooShort(got: Int, minimum: Int)
    case decryptionFailed
    case encryptionFailed
    case invalidPublicKeyLength(got: Int)
    case keyFileCorrupted(path: String, got: Int)

    public var description: String {
        switch self {
        case .ciphertextTooShort(let got, let minimum):
            "ciphertext too short: expected at least \(minimum) bytes for nonce, got \(got)"
        case .decryptionFailed:
            "decryption failed: authentication tag verification failed"
        case .encryptionFailed:
            "encryption failed"
        case .invalidPublicKeyLength(let got):
            "invalid public key length: expected 32, got \(got)"
        case .keyFileCorrupted(let path, let got):
            "key file corrupted at \(path): expected 32 bytes, got \(got)"
        }
    }
}

// MARK: - NodeKeyPair

/// Shared libsodium instance. Sodium is a value type whose methods are all
/// stateless wrappers around C libsodium functions (thread-safe by design).
private nonisolated(unsafe) let sodium = Sodium()

/// NaCl nonce size (24 bytes for XSalsa20-Poly1305).
private let naclNonceSize = 24

/// Ephemeral X25519 key pair for E2E encryption.
///
/// The secret exists only in this process's memory, protected by Hardened
/// Runtime + SIP. The attestation blob binds the public key to the Secure
/// Enclave signing identity.
///
/// Wire format (NaCl `crypto_box`):
///   ciphertext = nonce (24 bytes) || Poly1305 tag (16 bytes) || encrypted_data
///
/// The underlying primitive is XSalsa20-Poly1305 authenticated encryption
/// with an X25519 Diffie-Hellman shared secret, matching Go's
/// `golang.org/x/crypto/nacl/box` and the Rust `crypto_box` crate (v0.9).
/// Implemented via libsodium (swift-sodium).
public struct NodeKeyPair: Sendable {
    /// Raw 32-byte X25519 secret key.
    private let secretKeyBytes: Data
    /// Raw 32-byte X25519 public key.
    private let publicKeyData: Data

    // MARK: - Initialization

    /// Generate a fresh ephemeral key pair using libsodium's CSPRNG.
    public static func generate() -> NodeKeyPair {
        let kp = sodium.box.keyPair()!
        return NodeKeyPair(
            secretKeyBytes: Data(kp.secretKey),
            publicKeyData: Data(kp.publicKey)
        )
    }

    /// Restore from a raw 32-byte secret key (e.g. loaded from disk).
    ///
    /// Derives the public key from the secret key using CryptoKit's
    /// Curve25519 (same X25519 math as libsodium).
    public init(rawSecret: Data) throws {
        guard rawSecret.count == 32 else {
            throw CryptoError.keyFileCorrupted(path: "<raw>", got: rawSecret.count)
        }
        let privKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawSecret)
        self.secretKeyBytes = rawSecret
        self.publicKeyData = Data(privKey.publicKey.rawRepresentation)
    }

    private init(secretKeyBytes: Data, publicKeyData: Data) {
        self.secretKeyBytes = secretKeyBytes
        self.publicKeyData = publicKeyData
    }

    // MARK: - Public key accessors

    /// Base64-encoded public key (standard encoding, no padding stripping).
    public var publicKeyBase64: String {
        publicKeyData.base64EncodedString()
    }

    /// Raw 32-byte public key.
    public var publicKeyBytes: Data {
        publicKeyData
    }

    // MARK: - Decrypt

    /// Decrypt a NaCl box message.
    ///
    /// - Parameters:
    ///   - senderPublicKey: The sender's 32-byte X25519 public key.
    ///   - ciphertext: `nonce (24 bytes) || authenticated_ciphertext`. The authenticated
    ///     ciphertext includes the 16-byte Poly1305 authentication tag prepended by XSalsa20-Poly1305.
    /// - Returns: The decrypted plaintext.
    public func decrypt(senderPublicKey: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count >= naclNonceSize else {
            throw CryptoError.ciphertextTooShort(got: ciphertext.count, minimum: naclNonceSize)
        }
        guard senderPublicKey.count == 32 else {
            throw CryptoError.invalidPublicKeyLength(got: senderPublicKey.count)
        }

        // swift-sodium's open(nonceAndAuthenticatedCipherText:...) expects
        // the combined format: nonce (24) || tag (16) || encrypted_data,
        // which is exactly the wire format we receive.
        guard let plaintext = sodium.box.open(
            nonceAndAuthenticatedCipherText: Bytes(ciphertext),
            senderPublicKey: Bytes(senderPublicKey),
            recipientSecretKey: Bytes(secretKeyBytes)
        ) else {
            throw CryptoError.decryptionFailed
        }

        return Data(plaintext)
    }

    // MARK: - Encrypt

    /// Encrypt a plaintext using NaCl box.
    ///
    /// - Parameters:
    ///   - recipientPublicKey: The recipient's 32-byte X25519 public key.
    ///   - plaintext: The data to encrypt.
    /// - Returns: `nonce (24 bytes) || authenticated_ciphertext` where the
    ///   authenticated ciphertext includes the 16-byte Poly1305 tag.
    public func encrypt(recipientPublicKey: Data, plaintext: Data) throws -> Data {
        guard recipientPublicKey.count == 32 else {
            throw CryptoError.invalidPublicKeyLength(got: recipientPublicKey.count)
        }

        // swift-sodium's seal() generates a random nonce and prepends it
        // to the authenticated ciphertext, producing the combined format:
        // nonce (24) || tag (16) || encrypted_data.
        // Use the Bytes? overload (combined format), not the tuple overload.
        guard let sealed: Bytes = sodium.box.seal(
            message: Bytes(plaintext),
            recipientPublicKey: Bytes(recipientPublicKey),
            senderSecretKey: Bytes(secretKeyBytes)
        ) else {
            throw CryptoError.encryptionFailed
        }

        return Data(sealed)
    }

    // MARK: - EncryptedPayload helpers

    /// Decrypt an `EncryptedPayload` (the wire type used in WebSocket messages).
    public func decryptPayload(_ payload: EncryptedPayload) throws -> Data {
        guard let ephemeralKeyData = Data(base64Encoded: payload.ephemeralPublicKey),
              ephemeralKeyData.count == 32 else {
            throw CryptoError.invalidPublicKeyLength(
                got: Data(base64Encoded: payload.ephemeralPublicKey)?.count ?? 0
            )
        }
        guard let ciphertextData = Data(base64Encoded: payload.ciphertext) else {
            throw CryptoError.ciphertextTooShort(got: 0, minimum: naclNonceSize)
        }
        return try decrypt(senderPublicKey: ephemeralKeyData, ciphertext: ciphertextData)
    }

    /// Encrypt data into an `EncryptedPayload` for sending over the wire.
    /// Uses this key pair's public key as the ephemeral key in the payload.
    public func encryptPayload(recipientPublicKey: Data, plaintext: Data) throws -> EncryptedPayload {
        let ciphertext = try encrypt(recipientPublicKey: recipientPublicKey, plaintext: plaintext)
        return EncryptedPayload(
            ephemeralPublicKey: publicKeyBase64,
            ciphertext: ciphertext.base64EncodedString()
        )
    }

    // MARK: - Legacy Cleanup

    private static let legacyDirNames = [".darkbloom", ".dginf", ".eigeninference"]

    /// Paths where legacy `node_key` files may exist.
    public static var legacyNodeKeyPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return legacyDirNames.map { home.appendingPathComponent($0).appendingPathComponent("node_key") }
    }

    /// Paths where legacy `enclave_e2e_ka.data` files may exist.
    public static var legacyEnclaveKeyPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return legacyDirNames.map {
            home.appendingPathComponent($0).appendingPathComponent("enclave_e2e_ka.data")
        }
    }

    /// Remove legacy E2E secret files from all known directories.
    public static func purgeLegacyFiles() {
        let paths = legacyNodeKeyPaths + legacyEnclaveKeyPaths
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.removeItem(at: path)
        }
    }
}

// MARK: - CustomDebugStringConvertible

extension NodeKeyPair: CustomDebugStringConvertible {
    public var debugDescription: String {
        "NodeKeyPair(public: \(publicKeyBase64), secret: [REDACTED])"
    }
}
