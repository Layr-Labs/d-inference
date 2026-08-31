/// KeyWrappingService — abstraction over the wrap/unwrap step that
/// guards the KEK at rest in Keychain.
///
/// Production uses an SE-backed implementation that runs ECIES against
/// the persistent SE identity (see `SecureEnclaveKeyWrappingService`).
/// Tests use the in-memory implementation here, which performs the
/// same AES-256-GCM seal but with a known key so the test process can
/// generate fixtures and round-trip them without a Secure Enclave or
/// the keychain-access-groups entitlement.
///
/// The wrapping primitive is *not* expected to support AAD. AAD lives
/// on the layer below (the per-file DEK seal and per-chunk seal,
/// which use plain AES-256-GCM with the unwrapped KEK / DEK as key).

import CryptoKit
import Foundation

// MARK: - Protocol

public protocol KeyWrappingService: Sendable {
    /// Encrypt `plaintext` under a service-managed key. Implementations
    /// must produce a unique ciphertext per call (i.e. include a fresh
    /// nonce or ephemeral-key contribution); two `wrap(p)` calls on the
    /// same plaintext must produce different ciphertexts.
    func wrap(_ plaintext: Data) throws -> Data

    /// Inverse of `wrap`. Throws on tamper / wrong-key / corrupt input.
    func unwrap(_ wrapped: Data) throws -> Data

    /// Short identifier for logs / diagnostics. Must not contain key
    /// material.
    var identifier: String { get }
}

// MARK: - Errors

public enum KeyWrappingError: Error, CustomStringConvertible, Sendable {
    case invalidCiphertext(String)
    case authenticationFailed(String)
    case backendUnavailable(String)
    case backendError(String)

    public var description: String {
        switch self {
        case .invalidCiphertext(let m): return "invalid ciphertext: \(m)"
        case .authenticationFailed(let m): return "auth failed: \(m)"
        case .backendUnavailable(let m): return "backend unavailable: \(m)"
        case .backendError(let m): return "backend error: \(m)"
        }
    }
}

// MARK: - In-memory implementation (tests + dev only)

/// AES-256-GCM under a process-local key. Suitable only for tests; the
/// production code path is `SecureEnclaveKeyWrappingService`.
///
/// Marked `@unchecked Sendable` because `SymmetricKey` is value-type
/// internally but the public API isn't `Sendable`-conformant in
/// CryptoKit on macOS as of Swift 6.0.
public final class InMemoryKeyWrappingService: KeyWrappingService, @unchecked Sendable {

    private let key: SymmetricKey
    public let identifier: String

    /// Initialize with a caller-supplied key (e.g. a fixed-bytes key
    /// for reproducible fixtures).
    public init(key: SymmetricKey, identifier: String = "in-memory") {
        self.key = key
        self.identifier = identifier
    }

    /// Initialize with a freshly-random 256-bit key.
    public convenience init() {
        self.init(key: SymmetricKey(size: .bits256), identifier: "in-memory-random")
    }

    public func wrap(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        // `combined` is `nonce ‖ ciphertext ‖ tag` (12+N+16 bytes).
        // Force-unwrap is safe: `combined` is only nil when the
        // sealed box was created without a nonce, which `seal(_:using:)`
        // never does.
        guard let blob = sealed.combined else {
            throw KeyWrappingError.backendError("AES.GCM.seal produced no combined output")
        }
        return blob
    }

    public func unwrap(_ wrapped: Data) throws -> Data {
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: wrapped)
        } catch {
            throw KeyWrappingError.invalidCiphertext(String(describing: error))
        }
        do {
            return try AES.GCM.open(box, using: key)
        } catch {
            throw KeyWrappingError.authenticationFailed(String(describing: error))
        }
    }
}
