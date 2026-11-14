import DarkbloomClusterSecurity
import Foundation
import Security

/// This Mac's Secure Enclave key as the link's identity signer: the key its
/// pairing and its roster pin. Signatures are DER; nothing here logs a key.
struct ClusterLinkSecureEnclaveSigner: ClusterLinkIdentitySigner {
    let signer: any AttestationSigner
    let identityPublicKey: Data

    init(_ signer: any AttestationSigner) throws {
        guard let raw = Data(base64Encoded: signer.publicKeyBase64), raw.count == 64 else {
            throw ClusterLinkIdentityError.signerUnavailable
        }
        self.signer = signer; identityPublicKey = Data([4]) + raw
    }

    func linkSignature(for message: Data) throws -> Data {
        do { return try signer.sign(message) } catch { throw Self.identityError(error) }
    }

    /// This Mac's existing persistent key, read without creating, deleting or
    /// repairing one (as `ClusterPairingProvider.existingPin()` reads it): a
    /// missing key must leave the pairing it pinned untouched.
    static func existing() throws -> Self {
        do {
            #if DEBUG
            if let path = ProcessInfo.processInfo.environment["DARKBLOOM_DEBUG_SE_KEY_FILE"], path.hasPrefix("/"),
               SecureEnclaveIdentity.isAvailable, let key = try? SecureEnclaveIdentity.debugLoadExisting(at: path) {
                return try Self(key)
            }
            #endif
            guard PersistentEnclaveKey.isAvailable else { throw ClusterLinkIdentityError.signerUnavailable }
            return try Self(PersistentEnclaveKey.loadExisting())
        } catch { throw identityError(error) }
    }

    /// errSecInteractionNotAllowed: the key's keychain stays locked until the
    /// Mac is unlocked once after it starts.
    static func identityError(_ error: any Error) -> ClusterLinkIdentityError {
        switch error {
        case let error as ClusterLinkIdentityError: return error
        case PersistentEnclaveKeyError.keyLookupFailed(errSecInteractionNotAllowed),
             PersistentEnclaveKeyError.signingFailed(errSecInteractionNotAllowed, _): return .signerLocked
        default: return .signerUnavailable
        }
    }
}
