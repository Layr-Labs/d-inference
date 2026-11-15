import DarkbloomClusterSecurity
import Foundation

/// The provider's Secure Enclave link signer (`Pairing/ClusterLinkSecureEnclaveSigner.swift`) for the plain-swiftc
/// check runners, which build the link sources without the Secure Enclave ones. These checks never reach this Mac's
/// key: a serving edge they start without an injected signer is refused.
struct ClusterLinkSecureEnclaveSigner: ClusterLinkIdentitySigner {
    var identityPublicKey: Data { Data() }
    func linkSignature(for message: Data) throws -> Data { throw ClusterLinkIdentityError.signerUnavailable }
    static func existing() throws -> Self { throw ClusterLinkIdentityError.signerUnavailable }
}
