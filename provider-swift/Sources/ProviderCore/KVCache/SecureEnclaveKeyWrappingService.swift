/// SecureEnclaveKeyWrappingService — production-grade wrap/unwrap
/// backed by the persistent Secure Enclave P-256 identity already
/// owned by the provider (used for attestation signing).
///
/// Wrap path: ECIES encrypt against the SE public key — runs entirely
/// in user space, no SE round-trip needed. Two `wrap()` calls produce
/// different ciphertexts because ECIES generates a fresh ephemeral
/// keypair per call.
///
/// Unwrap path: ECIES decrypt via `SecKeyCreateDecryptedData`, which
/// dispatches to the SE. The private key never leaves the Enclave.
///
/// Reusing the same SE identity for both attestation signing and KV
/// cache KEK wrap is sound: `kSecAttrKeyTypeECSECPrimeRandom` with
/// `.privateKeyUsage` ACL permits any private-key operation, and the
/// two operations (ECDSA sign vs ECIES decrypt) use disjoint key-
/// derivation paths inside the SE. Compromise of either path doesn't
/// leak the other.

import Foundation
import Security

public final class SecureEnclaveKeyWrappingService: KeyWrappingService, @unchecked Sendable {

    private let enclaveKey: PersistentEnclaveKey
    public let identifier: String

    public init(enclaveKey: PersistentEnclaveKey, identifier: String = "secure-enclave") {
        self.enclaveKey = enclaveKey
        self.identifier = identifier
    }

    public func wrap(_ plaintext: Data) throws -> Data {
        do {
            return try enclaveKey.eciesEncrypt(plaintext)
        } catch let e as PersistentEnclaveKeyError {
            throw KeyWrappingError.backendError(String(describing: e))
        }
    }

    public func unwrap(_ wrapped: Data) throws -> Data {
        do {
            return try enclaveKey.eciesDecrypt(wrapped)
        } catch let e as PersistentEnclaveKeyError {
            // Classify by the structured OSStatus rather than the
            // localized error string (which is locale-dependent and
            // brittle). The SE surfaces tamper / wrong-key / corrupt-
            // ciphertext as these decode/auth statuses.
            if case .signingFailed(let status, _) = e, Self.isAuthFailure(status) {
                throw KeyWrappingError.authenticationFailed(String(describing: e))
            }
            throw KeyWrappingError.backendError(String(describing: e))
        }
    }

    /// OSStatus values the Security framework returns for an ECIES
    /// open that fails because the ciphertext was tampered, truncated,
    /// or sealed to a different key.
    private static func isAuthFailure(_ status: OSStatus) -> Bool {
        switch status {
        case errSecDecode,        // -26275: corrupt / wrong-key ciphertext
             errSecAuthFailed,    // -25293: authentication failed
             errSecParam:         // -50: malformed input to the decrypt
            return true
        default:
            return false
        }
    }
}
