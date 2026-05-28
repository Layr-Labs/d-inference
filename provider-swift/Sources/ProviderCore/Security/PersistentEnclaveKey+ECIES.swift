/// PersistentEnclaveKey+ECIES — ECIES wrap/unwrap on top of the existing
/// Secure Enclave P-256 identity.
///
/// The persistent SE key in `PersistentEnclaveKey` is created with
/// `kSecAttrKeyTypeECSECPrimeRandom` + `.privateKeyUsage`, which permits
/// any private-key operation Apple has defined for that key class. That
/// includes both the existing ECDSA signing path AND ECIES decryption
/// via `SecKeyCreateDecryptedData`. Reusing the same SE key for both
/// avoids growing a second SE-bound entry in Keychain.
///
/// ECIES variant: `.eciesEncryptionStandardX963SHA256AESGCM`. This is
/// Apple's standard ECIES-with-X9.63-KDF over P-256 wrapped around
/// AES-256-GCM, with an ephemeral key pair generated per encrypt. The
/// ciphertext layout is `[ephemeral_pubkey (65B)][AES-GCM (12+N+16B)]`
/// — opaque to callers.
///
/// Encryption only needs the public key, so it works even on a binary
/// without the keychain-access-groups entitlement (we can encrypt
/// against any P-256 public key). Decryption needs the private key,
/// which the SE owns, so it goes through `SecKeyCreateDecryptedData`
/// and the SE handles the operation opaquely.
///
/// This is the KEK-wrap primitive used by `KVCacheKEK` to keep the
/// wrapped KEK at rest in the Keychain. Per-cache DEKs are then
/// wrapped by the KEK using plain AES-256-GCM (no ECIES), so they
/// stay cheap to (un)wrap on every cache open.

import Foundation
import Security

extension PersistentEnclaveKey {

    /// Encrypt `plaintext` to this SE identity's public key using
    /// `.eciesEncryptionStandardX963SHA256AESGCM`. Output is the
    /// Apple-defined opaque ECIES ciphertext (ephemeral pub || AES-GCM
    /// nonce || ciphertext || tag).
    ///
    /// Does not touch the Secure Enclave — public-key operations run
    /// in user space. Safe to call on binaries without keychain-
    /// access-groups entitlement.
    public func eciesEncrypt(_ plaintext: Data) throws -> Data {
        let algorithm: SecKeyAlgorithm = .eciesEncryptionStandardX963SHA256AESGCM

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw PersistentEnclaveKeyError.publicKeyExtractionFailed
        }

        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else {
            throw PersistentEnclaveKeyError.signingFailed(
                status: errSecParam,
                message: "ECIES encryption not supported on this SE key"
            )
        }

        var error: Unmanaged<CFError>?
        guard let ciphertext = SecKeyCreateEncryptedData(
            publicKey,
            algorithm,
            plaintext as CFData,
            &error
        ) as Data? else {
            let nsErr = error?.takeRetainedValue() as Error? as NSError?
            throw PersistentEnclaveKeyError.signingFailed(
                status: OSStatus(nsErr?.code ?? Int(errSecInternalError)),
                message: nsErr?.localizedDescription ?? "ECIES encrypt failed"
            )
        }
        return ciphertext
    }

    /// Decrypt `wrapped` using the SE-bound private key. The SE handles
    /// the X9.63 KDF + AES-GCM open opaquely; the private key never
    /// leaves the Enclave.
    public func eciesDecrypt(_ wrapped: Data) throws -> Data {
        let algorithm: SecKeyAlgorithm = .eciesEncryptionStandardX963SHA256AESGCM

        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, algorithm) else {
            throw PersistentEnclaveKeyError.signingFailed(
                status: errSecParam,
                message: "ECIES decryption not supported on this SE key"
            )
        }

        var error: Unmanaged<CFError>?
        guard let plaintext = SecKeyCreateDecryptedData(
            privateKey,
            algorithm,
            wrapped as CFData,
            &error
        ) as Data? else {
            let nsErr = error?.takeRetainedValue() as Error? as NSError?
            throw PersistentEnclaveKeyError.signingFailed(
                status: OSStatus(nsErr?.code ?? Int(errSecInternalError)),
                message: nsErr?.localizedDescription ?? "ECIES decrypt failed"
            )
        }
        return plaintext
    }
}
