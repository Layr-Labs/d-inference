import Foundation
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

/// Who this Mac is and who the other Mac must be on a serving edge, from local
/// configuration only: a coordinator-formed pair's roster, or the pairing
/// record whose link the setup names. The serving edges carry prompts, so both
/// ends prove the Secure Enclave key the other pinned.
enum DistributedInstalledLinkIdentity {
    static let noPairing = "This Mac has no pairing for this link (it was paired again or unpaired). "
        + "Run `darkbloom cluster` on both Macs; it pairs again by itself."

    /// The signer is asked only once both keys are known, so a setup without a
    /// pairing is refused without touching this Mac's key. Signer errors pass through.
    static func resolve(configuration: ClusterConfiguration, store: ClusterPairingStore = .default(),
                        signer: () throws -> any ClusterLinkIdentitySigner = { try ClusterLinkSecureEnclaveSigner.existing() })
        throws -> ClusterLinkIdentity {
        let pinned = try pinnedKeys(configuration: configuration, store: store)
        return try ClusterLinkIdentity(signer: signer(), localIdentityKey: pinned.local, peerIdentityKey: pinned.peer,
                                       clusterID: pinned.clusterID)
    }

    static func pinnedKeys(configuration: ClusterConfiguration, store: ClusterPairingStore) throws
        -> (local: Data, peer: Data, clusterID: String) {
        // Both members registered byte-equal rosters, verified against this cluster ID.
        if let member = configuration.nativeMember, let roster = member.roster, let pins = member.memberPins {
            let rank = configuration.localRank
            guard pins.count == 2, (0...1).contains(rank),
                  let local = roster.memberKey(pins[rank]).flatMap({ Data(base64Encoded: $0) }),
                  let peer = roster.memberKey(pins[1 - rank]).flatMap({ Data(base64Encoded: $0) }) else {
                throw ClusterLinkIdentityError.invalidIdentity
            }
            return (local, peer, configuration.clusterID)
        }
        guard let link = configuration.linkControl, let edgeID = UUID(uuidString: link.edgeID),
              let epoch = UUID(uuidString: link.linkEpoch), let records = try? store.load(),
              let record = records.pairings.first(where: {
                  UUID(uuidString: $0.link.edgeID) == edgeID && UUID(uuidString: $0.link.linkEpoch) == epoch
              }),
              let local = Data(base64Encoded: records.localIdentityKey),
              let peer = Data(base64Encoded: record.peerIdentityKey) else {
            throw ClusterConfigurationError.invalid(noPairing)
        }
        return (local, peer, record.clusterID)
    }

    /// What a serving edge's identity refusal tells the owner; nil for any other refusal.
    static func guidance(_ refusal: ClusterLinkControlRefusal) -> String? {
        switch refusal {
        case .localIdentityLocked:
            return "This Mac's key is locked until someone logs in once after a restart (at its screen or with Screen Sharing); "
                + "the pair resumes by itself."
        case .peerNotPinned, .identityMismatch, .peerSignatureRejected:
            return "The other Mac didn't prove it holds the key this Mac paired with. "
                + "If you paired it again, run `darkbloom cluster` on both Macs."
        default: return nil
        }
    }

    /// The refusal's name, then its guidance when it has one.
    static func describe(_ refusal: ClusterLinkControlRefusal) -> String {
        guidance(refusal).map { "\(refusal): \($0)" } ?? "\(refusal)"
    }
}
