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

    /// Tests only (fixed vectors): a key from known bytes. A provider never
    /// restores an endpoint key; every process makes a fresh one with
    /// `generate()` and keeps it in memory only, so no key of an earlier
    /// process or release can be the one a later process registers.
    ///
    /// Derives the public key from the secret key using CryptoKit's
    /// Curve25519 (same X25519 math as libsodium).
    init(rawSecret: Data) throws {
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
    /// - Returns: The decrypted plaintext, in storage that is zeroed after its
    ///   last reference is released (see ``ReleasedBufferWipe``).
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
        guard let plaintext = withZeroedCopy(of: secretKeyBytes, { secretKey in
            sodium.box.open(
                nonceAndAuthenticatedCipherText: Bytes(ciphertext),
                senderPublicKey: Bytes(senderPublicKey),
                recipientSecretKey: secretKey)
        }) else {
            throw CryptoError.decryptionFailed
        }
        return Data(zeroingOnRelease: plaintext)
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
        let sealed = withZeroedCopy(of: plaintext) { message in
            withZeroedCopy(of: secretKeyBytes) { secretKey -> Bytes? in
                sodium.box.seal(
                    message: message,
                    recipientPublicKey: Bytes(recipientPublicKey),
                    senderSecretKey: secretKey)
            }
        }
        guard let sealed else { throw CryptoError.encryptionFailed }
        return Data(sealed)
    }

    // MARK: - Precomputed shared key (Phase 3)

    /// Precompute the DH shared secret with a recipient's public key.
    ///
    /// Call once per request, then use ``encryptWithSharedKey(_:plaintext:)``
    /// for each chunk.  This avoids a ~150 us Curve25519 scalar multiply per
    /// chunk, dropping per-chunk encryption to ~1-2 us (XSalsa20-Poly1305
    /// symmetric only).
    public func precomputeSharedKey(recipientPublicKey: Data) throws -> Data {
        guard recipientPublicKey.count == 32 else {
            throw CryptoError.invalidPublicKeyLength(got: recipientPublicKey.count)
        }
        guard let key = withZeroedCopy(of: secretKeyBytes, { secretKey in
            sodium.box.beforenm(recipientPublicKey: Bytes(recipientPublicKey), senderSecretKey: secretKey)
        }) else {
            throw CryptoError.encryptionFailed
        }
        return Data(zeroingOnRelease: key)
    }

    /// Encrypt using a precomputed shared key from ``precomputeSharedKey(recipientPublicKey:)``.
    ///
    /// Output format is identical to ``encrypt(recipientPublicKey:plaintext:)``:
    /// `nonce (24 bytes) || authenticated_ciphertext`. The one copy of
    /// `plaintext` this makes is zeroed before it is freed.
    public func encryptWithSharedKey(_ sharedKey: Data, plaintext: some Collection<UInt8>) throws -> Data {
        let sealed = withZeroedCopy(of: plaintext) { message in
            withZeroedCopy(of: sharedKey) { key -> Bytes? in
                sodium.box.seal(message: message, beforenm: key)
            }
        }
        guard let sealed else { throw CryptoError.encryptionFailed }
        return Data(sealed)
    }

    /// Encrypt into an ``EncryptedPayload`` using a precomputed shared key.
    ///
    /// Drop-in replacement for ``encryptPayload(recipientPublicKey:plaintext:)``
    /// on the hot path where the same recipient key is used many times (e.g.
    /// per-chunk SSE encryption during a streaming response).
    public func encryptPayloadFast(sharedKey: Data, plaintext: some Collection<UInt8>) throws -> EncryptedPayload {
        let ciphertext = try encryptWithSharedKey(sharedKey, plaintext: plaintext)
        return EncryptedPayload(
            ephemeralPublicKey: publicKeyBase64,
            ciphertext: ciphertext.base64EncodedString()
        )
    }

    /// ``encryptPayloadFast(sharedKey:plaintext:)`` under a nonce the caller
    /// chooses, in the same `nonce (24) || tag (16) || encrypted_data` format,
    /// so any NaCl box open reads it. The caller must never use one nonce
    /// twice with one shared key.
    ///
    /// A box sealed with a precomputed key is the secretbox of that key
    /// (`crypto_box_easy_afternm` is `crypto_secretbox_easy`), which is the
    /// only libsodium seal swift-sodium exposes with an explicit nonce.
    func encryptPayloadFast(
        sharedKey: Data, plaintext: some Collection<UInt8>, nonce: [UInt8]
    ) throws -> EncryptedPayload {
        guard nonce.count == naclNonceSize else { throw CryptoError.encryptionFailed }
        let sealed = withZeroedCopy(of: plaintext) { message in
            withZeroedCopy(of: sharedKey) { key -> Bytes? in
                sodium.secretBox.seal(message: message, secretKey: key, nonce: nonce)
            }
        }
        guard let sealed else { throw CryptoError.encryptionFailed }
        return EncryptedPayload(
            ephemeralPublicKey: publicKeyBase64,
            ciphertext: Data(nonce + sealed).base64EncodedString()
        )
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
}

// MARK: - Zeroed buffers

/// Calls `body` with a `[UInt8]` copy of `bytes` (swift-sodium takes and
/// returns arrays) and zeroes that copy before it is freed. `bytes` is a
/// collection so the copy is allocated once at its final size, not grown
/// through buffers that would be freed unzeroed. `body` must not keep the
/// array: the copy is zeroed in place only while it is the array's sole owner.
private func withZeroedCopy<R>(of bytes: some Collection<UInt8>, _ body: (Bytes) throws -> R) rethrows -> R {
    var copy = Bytes(bytes)
    defer { copy.withUnsafeMutableBytes { secureZero($0) } }
    return try body(copy)
}

private extension Data {
    /// A copy of `bytes` whose storage, and `bytes` itself, are zeroed and
    /// freed by ``ReleasedBufferWipe`` after the last reference to the copy is
    /// released, on whichever path that happens. Nothing is zeroed before
    /// then, so making the copy adds no zeroing to the caller's path. `bytes`
    /// must not be kept elsewhere: it is zeroed in place only while this is its
    /// sole owner. Copies made from the result (a mutation of a shared value,
    /// a `String`, a re-encoding) are separate allocations and are not
    /// covered, nor is a value of at most 14 bytes, which Foundation keeps
    /// inline in the `Data` itself.
    init(zeroingOnRelease bytes: consuming Bytes) {
        guard !bytes.isEmpty else {
            self.init()
            return
        }
        let buffer = ReleasedBuffer(copying: bytes)
        self.init(bytesNoCopy: buffer.storage, count: buffer.count, deallocator: .custom { _, _ in
            ReleasedBufferWipe.enqueue(buffer)
        })
    }
}

/// The storage behind a `Data(zeroingOnRelease:)` and the array it was
/// copied from, zeroed and freed together.
private final class ReleasedBuffer: @unchecked Sendable {
    let storage: UnsafeMutableRawPointer
    let count: Int
    private var source: Bytes

    init(copying source: consuming Bytes) {
        let count = source.count
        let storage = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        source.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { storage.copyMemory(from: base, byteCount: count) }
        }
        self.storage = storage
        self.count = count
        self.source = source
    }

    /// Runs once, on `ReleasedBufferWipe`'s queue.
    func zeroAndFree() {
        secureZero(UnsafeMutableRawBufferPointer(start: storage, count: count))
        storage.deallocate()
        source.withUnsafeMutableBytes { secureZero($0) }
        source = []
    }
}

/// Zeroes and frees the buffers behind `Data(zeroingOnRelease:)` on one
/// background queue. The thread that releases the last reference to such a
/// buffer, for a request body after the request's last message is sent,
/// only enqueues the work, so zeroing a request body never runs on the
/// request's path.
enum ReleasedBufferWipe {
    private static let queue = DispatchQueue(label: "ProviderCore.ReleasedBufferWipe", qos: .utility)
    /// Read and written only on `queue`.
    private nonisolated(unsafe) static var observer: (@Sendable (Int) -> Void)?

    fileprivate static func enqueue(_ buffer: ReleasedBuffer) {
        queue.async {
            buffer.zeroAndFree()
            observer?(buffer.count)
        }
    }

    /// Tests only: returns after every buffer released before the call has
    /// been zeroed and freed.
    static func waitForPendingForTesting() {
        queue.sync {}
    }

    /// Tests only: while suspended, released buffers wait, still unzeroed.
    /// Each call must be followed by exactly one `resumeForTesting()`.
    static func suspendForTesting() {
        queue.suspend()
    }

    static func resumeForTesting() {
        queue.resume()
    }

    /// Tests only: `observer` receives each buffer's byte count once it is
    /// zeroed. Call while the queue is not suspended.
    static func observeForTesting(_ observer: (@Sendable (Int) -> Void)?) {
        queue.sync { self.observer = observer }
    }
}

// MARK: - CustomDebugStringConvertible

extension NodeKeyPair: CustomDebugStringConvertible {
    public var debugDescription: String {
        "NodeKeyPair(public: \(publicKeyBase64), secret: [REDACTED])"
    }
}

/// Reflection (`Mirror`, `dump`) shows only the public key: the default
/// mirror would list the secret's bytes.
extension NodeKeyPair: CustomReflectable {
    public var customMirror: Mirror {
        Mirror(self, children: ["publicKey": publicKeyBase64], displayStyle: .struct)
    }
}
