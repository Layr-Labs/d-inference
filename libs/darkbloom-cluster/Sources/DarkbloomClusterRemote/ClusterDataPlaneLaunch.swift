import CryptoKit
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation

/// The two workers' data-plane credentials for one session the leader
/// launches over its own authenticated owner routes (S16): two member
/// identities made for the session, each rank pinning the other's. The
/// identity private keys never leave this call; each worker receives only its
/// own per-epoch worker key and its member's certificate over it, on its owner
/// route, as its first input line. A coordinator-formed pair (S10/S17) issues
/// the same lines from the members' pinned Secure Enclave identities instead.
public enum ClusterDataPlaneLaunch {
    public static func sessionCredentialLines(epoch: UUID) throws -> [Data] {
        let identities = [P256.Signing.PrivateKey(), P256.Signing.PrivateKey()]
        return try (0...1).map { rank in
            let credential = try ClusterDataPlaneCredential.issue(identity: identities[rank], epoch: epoch, rank: rank,
                peerPin: ClusterDataPlanePin(identities[1 - rank].publicKey))
            let fields = credential.wireFields
            return try ClusterWorkerCodec.encode(ClusterWorkerDataPlaneTrust(membershipEpoch: epoch, rank: rank,
                workerSigningKey: fields.workerSigningKey, workerCertificate: fields.workerCertificate,
                memberIdentity: fields.memberIdentity, peerPin: fields.peerPin))
        }
    }

    /// A marker every worker built with the keyed data plane carries.
    public static let workerMarker = "darkbloom/data-plane/hello/v1"
}
