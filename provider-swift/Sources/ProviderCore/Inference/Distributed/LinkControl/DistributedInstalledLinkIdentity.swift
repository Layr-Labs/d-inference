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
    /// Without an injected signer, this Mac's key is looked up at the first
    /// handshake, not here (`DistributedInstalledLinkDeferredSigner`).
    static func resolve(configuration: ClusterConfiguration, store: ClusterPairingStore = .default(),
                        signer: (() throws -> any ClusterLinkIdentitySigner)? = nil) throws -> ClusterLinkIdentity {
        let pinned = try pinnedKeys(configuration: configuration, store: store)
        let chosen = try signer?() ?? DistributedInstalledLinkDeferredSigner(pinnedKey: pinned.local)
        return try ClusterLinkIdentity(signer: chosen, localIdentityKey: pinned.local, peerIdentityKey: pinned.peer,
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

/// This Mac's pinned key, looked up at its first signature instead of when the
/// edge is built: a member that starts before anyone has logged in after a
/// restart keeps running, its handshakes are refused (`localIdentityLocked`,
/// retried with the link's backoff), and it links by itself after the login.
/// The key it finds must be the pinned one; once found it is kept.
final class DistributedInstalledLinkDeferredSigner: ClusterLinkIdentitySigner, @unchecked Sendable {
    let identityPublicKey: Data
    private let load: @Sendable () throws -> any ClusterLinkIdentitySigner
    private let lock = NSLock()
    private var loaded: (any ClusterLinkIdentitySigner)?

    init(pinnedKey: Data,
         load: @escaping @Sendable () throws -> any ClusterLinkIdentitySigner = { try ClusterLinkSecureEnclaveSigner.existing() }) {
        identityPublicKey = pinnedKey; self.load = load
    }

    func linkSignature(for message: Data) throws -> Data {
        let signer: any ClusterLinkIdentitySigner = try lock.withLock {
            if let loaded { return loaded }
            let found = try load()
            guard found.identityPublicKey == identityPublicKey else { throw ClusterLinkIdentityError.signerMismatch }
            loaded = found
            return found
        }
        return try signer.linkSignature(for: message)
    }
}
