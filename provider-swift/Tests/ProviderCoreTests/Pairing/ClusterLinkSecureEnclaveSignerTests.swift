import CryptoKit
import Foundation
import Security
import Testing
import DarkbloomClusterSecurity
@testable import ProviderCore

/// This Mac's key as the link's identity signer, with software and failing signers in its place: the tests never
/// load this Mac's Secure Enclave key (`existing()`).
@Suite("Cluster link Secure Enclave signer")
struct ClusterLinkSecureEnclaveSignerTests {
    struct FailingSigner: AttestationSigner {
        let status: OSStatus
        let publicKeyBase64 = P256.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        func sign(_ data: Data) throws -> Data { throw PersistentEnclaveKeyError.signingFailed(status: status, message: "fixture") }
    }

    @Test func signsWithTheWrappedKeyAsAnUncompressedPoint() throws {
        let software = ClusterPairingProviderTests.SoftwareSigner()
        let signer = try ClusterLinkSecureEnclaveSigner(software)
        #expect(signer.identityPublicKey == software.x963 && signer.identityPublicKey.first == 4)
        let message = Data("link handshake".utf8)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signer.linkSignature(for: message))
        #expect(software.key.publicKey.isValidSignature(signature, for: message))
        let identity = try ClusterLinkIdentity(signer: signer, localIdentityKey: software.x963,
            peerIdentityKey: ClusterPairingProviderTests.SoftwareSigner().x963, clusterID: "provider-pair")
        #expect(identity.localPin == Data(SHA256.hash(data: Data("darkbloom/cluster-member-pin/v1\0".utf8) + software.x963)))
    }

    @Test func aLockedKeyIsLockedAndAnyOtherFailureUnavailable() throws {
        let locked = try ClusterLinkSecureEnclaveSigner(FailingSigner(status: errSecInteractionNotAllowed))
        #expect(throws: ClusterLinkIdentityError.signerLocked) { try locked.linkSignature(for: Data([1])) }
        let failing = try ClusterLinkSecureEnclaveSigner(FailingSigner(status: errSecInternalError))
        #expect(throws: ClusterLinkIdentityError.signerUnavailable) { try failing.linkSignature(for: Data([1])) }
        #expect(ClusterLinkSecureEnclaveSigner.identityError(
            PersistentEnclaveKeyError.keyLookupFailed(status: errSecInteractionNotAllowed)) == .signerLocked)
        #expect(ClusterLinkSecureEnclaveSigner.identityError(
            PersistentEnclaveKeyError.keyLookupFailed(status: errSecItemNotFound)) == .signerUnavailable)
        #expect(ClusterLinkSecureEnclaveSigner.identityError(PersistentEnclaveKeyError.missingEntitlement) == .signerUnavailable)
    }

    @Test func aKeyThatIsNotAPointIsUnavailable() {
        struct Malformed: AttestationSigner {
            let publicKeyBase64 = Data(repeating: 7, count: 32).base64EncodedString()
            func sign(_ data: Data) throws -> Data { Data() }
        }
        #expect(throws: ClusterLinkIdentityError.signerUnavailable) { try ClusterLinkSecureEnclaveSigner(Malformed()) }
    }
}
