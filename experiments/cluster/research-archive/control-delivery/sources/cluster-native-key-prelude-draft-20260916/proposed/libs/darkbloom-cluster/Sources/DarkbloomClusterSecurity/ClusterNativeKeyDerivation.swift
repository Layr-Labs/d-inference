import CryptoKit
import Foundation

/// Internal-only key material. No Codable, wire encoding, public initializer,
/// debug description or arbitrary key export callback exists on the authority.
struct NativeDerivedTrafficKeys {
    let recordMaster: SymmetricKey
    let confirmation: SymmetricKey
}

enum NativeTrafficKeyDerivation {
    static let recordDomain = Data("darkbloom/native-rdma/record-master/v1".utf8)
    static let confirmationDomain = Data("darkbloom/native-rdma/key-confirmation/v1".utf8)
    static let proofDomain = Data("darkbloom/native-rdma/key-confirmation-proof/v1\0".utf8)

    static func derive(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data,
                       transcriptSHA256: Data) throws -> NativeDerivedTrafficKeys {
        guard nativeCanonicalX25519PublicKey(peerPublicKey), transcriptSHA256.count == 32 else {
            throw ClusterNativeKeyError.invalidKey
        }
        do {
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            // Fail closed even if an implementation returns an all-zero result
            // rather than rejecting a low-order point. Bytes never leave this scope.
            guard shared.withUnsafeBytes({ bytes in bytes.reduce(UInt8(0)) { $0 | $1 } }) != 0 else {
                throw ClusterNativeKeyError.invalidKey
            }
            let master = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcriptSHA256,
                sharedInfo: recordDomain, outputByteCount: 32)
            let confirmation = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcriptSHA256,
                sharedInfo: confirmationDomain, outputByteCount: 32)
            return .init(recordMaster: master, confirmation: confirmation)
        } catch { throw ClusterNativeKeyError.invalidKey }
    }
    static func confirmationMessage(rank: Int, transcriptSHA256: Data) throws -> Data {
        guard (0...1).contains(rank), transcriptSHA256.count == 32 else { throw ClusterNativeKeyError.wrongContext }
        var result = proofDomain; result.append(UInt8(rank)); result.append(transcriptSHA256); return result
    }
    static func confirmation(rank: Int, transcriptSHA256: Data, key: SymmetricKey) throws -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: try confirmationMessage(rank: rank, transcriptSHA256: transcriptSHA256), using: key))
    }
    static func verify(_ tag: Data, rank: Int, transcriptSHA256: Data, key: SymmetricKey) throws {
        guard tag.count == 32, HMAC<SHA256>.isValidAuthenticationCode(tag,
            authenticating: try confirmationMessage(rank: rank, transcriptSHA256: transcriptSHA256), using: key) else {
            throw ClusterNativeKeyError.authenticationFailed
        }
    }
}
