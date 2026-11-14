import CryptoKit
import Darwin
import Foundation
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
@testable import InstalledContract

/// Counts key lookups of a deferred signer.
final class LinkIdentityAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// A software P-256 key standing in for a Mac's Secure Enclave key.
struct SoftwareLinkSigner: ClusterLinkIdentitySigner {
    let key = P256.Signing.PrivateKey()
    var identityPublicKey: Data { key.publicKey.x963Representation }
    func linkSignature(for message: Data) throws -> Data { try key.signature(for: message).derRepresentation }
}

extension InstalledSessionCheck {
    /// Who a serving edge pins (`DistributedInstalledLinkIdentity`): the roster of a coordinator-formed pair, or the
    /// pairing record the setup's link names. Temporary stores and software keys only; this Mac's pairing and key are
    /// never read.
    static func linkIdentity(_ f: InstalledFixture) throws {
        let local = SoftwareLinkSigner(), peer = SoftwareLinkSigner(), other = SoftwareLinkSigner()
        let pinLocal = ClusterPairingPin.of(identityKey: local.identityPublicKey)
        let pinPeer = ClusterPairingPin.of(identityKey: peer.identityPublicKey)
        let scratch = f.root.deletingLastPathComponent().appendingPathComponent("link-identity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let empty = ClusterPairingStore(directory: scratch.appendingPathComponent("never-paired"))

        // Coordinator pair: the roster's keys in the setup's rank order, the setup's cluster ID.
        let roster = ClusterRoster(generation: 1, members: [(pinLocal, local), (pinPeer, peer)].sorted { $0.0 < $1.0 }.map {
            ClusterRoster.Member(pin: $0.0, sePublicKey: $0.1.identityPublicKey.base64EncodedString(), signature: "")
        })
        let approval = ClusterRuntimeApproval(id: "fixture", model: f.configuration.publicModelID, generation: 1,
            placementPolicySHA256: nil, artifactSHA256: String(repeating: "b", count: 64), nativeRuntimeSHA256: nil,
            metallibSHA256: nil, resourceLibrarySHA256: nil, capabilitySHA256: nil, resourcePolicySHA256: nil, profileSHA256: nil,
            schedule: 1, maximumTransportFrame: 131_112, maximumPlaintext: 131_072, maximumRecords: 1024,
            maximumCumulativePlaintext: 16_777_216, allowedNumericsClasses: [], minimumMembers: 2, maximumMembers: 2,
            minimumMemberUsableBytes: 1, notAfter: "2033-05-18T03:33:20Z")
        func member(_ pins: [String]) -> ClusterConfiguration {
            f.configuration.replacingNativeMember(ClusterNativeMemberAttachment(ownerSHA256: String(repeating: "1", count: 64),
                metallibPath: "/fixture/mlx.metallib", resourceLibraryPath: "/fixture/resource.metallib",
                clusterApproval: approval, roster: roster, memberPins: pins, edges: nil))
        }
        try require(f.configuration.localRank == 0, "the fixture is rank 0")
        let formed = try DistributedInstalledLinkIdentity.resolve(configuration: member([pinLocal, pinPeer]), store: empty,
                                                                  signer: { local })
        try require(formed.localIdentityKey == local.identityPublicKey && formed.peerIdentityKey == peer.identityPublicKey
            && formed.clusterID == f.configuration.clusterID, "a coordinator pair pins its roster's keys and cluster ID")
        // The roster names the other key at this rank: this Mac's signer isn't the one it is pinned as.
        try refusedWith(.signerMismatch) {
            _ = try DistributedInstalledLinkIdentity.resolve(configuration: member([pinPeer, pinLocal]), store: empty, signer: { local })
        }
        try refusedWith(.signerLocked) {
            _ = try DistributedInstalledLinkIdentity.resolve(configuration: member([pinLocal, pinPeer]), store: empty,
                                                             signer: { throw ClusterLinkIdentityError.signerLocked })
        }

        // Local pairing: the record whose link is the setup's, matched whatever the UUID text's case.
        let epoch = UUID(), edge = UUID()
        let linked = try changedConfiguration(f) { object in
            object["trust"] = nil
            object["linkControl"] = ["schema": "darkbloom_cluster_link_control_v1", "port": 47999,
                                     "linkEpoch": epoch.uuidString.lowercased(), "edgeID": edge.uuidString.lowercased(),
                                     "secretFile": scratch.appendingPathComponent("link-secret").path]
        }
        let store = try pairingStore(scratch.appendingPathComponent("paired"), local: local, peer: peer, epoch: epoch, edge: edge)
        let paired = try DistributedInstalledLinkIdentity.resolve(configuration: linked, store: store, signer: { local })
        try require(paired.localIdentityKey == local.identityPublicKey && paired.peerIdentityKey == peer.identityPublicKey
            && paired.clusterID == "loop-pair", "a local pairing pins its record's keys and cluster ID")
        try refusedWith(.signerMismatch) {
            _ = try DistributedInstalledLinkIdentity.resolve(configuration: linked, store: store, signer: { other })
        }
        try refusedWith(.signerLocked) {
            _ = try DistributedInstalledLinkIdentity.resolve(configuration: linked, store: store,
                                                             signer: { throw ClusterLinkIdentityError.signerLocked })
        }

        // No pairing for this link (paired again, unpaired, never paired, or an unreadable store): refused in words,
        // before this Mac's key is asked for.
        let repaired = try pairingStore(scratch.appendingPathComponent("repaired"), local: local, peer: peer, epoch: UUID(), edge: edge)
        let widened = try pairingStore(scratch.appendingPathComponent("widened"), local: local, peer: peer, epoch: epoch, edge: edge)
        chmod(widened.recordsFile.path, 0o644)
        for candidate in [repaired, empty, widened] {
            var asked = false
            do {
                _ = try DistributedInstalledLinkIdentity.resolve(configuration: linked, store: candidate, signer: { asked = true; return local })
                throw CheckFailure(message: "a setup whose link has no pairing resolved an identity")
            } catch ClusterConfigurationError.invalid(let message) {
                try require(message == DistributedInstalledLinkIdentity.noPairing && !asked,
                    "the missing pairing is refused in words, without this Mac's key: \(message)")
            }
        }

        // Without an injected signer, building the edge never touches this Mac's key: the lookup waits for the first
        // handshake, so a key that is locked (or missing) at start is a retried refusal, not a failed start.
        let deferred = try DistributedInstalledLinkIdentity.resolve(configuration: linked, store: store)
        try require(deferred.localIdentityKey == local.identityPublicKey, "the deferred identity pins the record's key")
        try refusedWith(.signerUnavailable) {
            _ = try deferred.signature(role: .listener, epoch: epoch, edgeID: edge, transcript: Data([1]))
        }
        let attempts = LinkIdentityAttempts()
        let resumes = DistributedInstalledLinkDeferredSigner(pinnedKey: local.identityPublicKey, load: {
            if attempts.next() == 1 { throw ClusterLinkIdentityError.signerLocked }
            return local
        })
        let afterLogin = try ClusterLinkIdentity(signer: resumes, localIdentityKey: local.identityPublicKey,
                                                 peerIdentityKey: peer.identityPublicKey, clusterID: "loop-pair")
        try refusedWith(.signerLocked) {
            _ = try afterLogin.signature(role: .connector, epoch: epoch, edgeID: edge, transcript: Data([2]))
        }
        _ = try afterLogin.signature(role: .connector, epoch: epoch, edgeID: edge, transcript: Data([2]))
        _ = try afterLogin.signature(role: .connector, epoch: epoch, edgeID: edge, transcript: Data([3]))
        try require(attempts.count == 2, "a locked key is looked up again; once found it is kept")
        // Another key found is refused by the deferred signer itself, and looked up again (never kept).
        let wrongLoads = LinkIdentityAttempts()
        let wrongKey = DistributedInstalledLinkDeferredSigner(pinnedKey: local.identityPublicKey, load: {
            _ = wrongLoads.next(); return other
        })
        for _ in 0..<2 { try refusedWith(.signerMismatch) { _ = try wrongKey.linkSignature(for: Data([4])) } }
        try require(wrongLoads.count == 2, "a key that isn't the pinned one is not kept")

        // What the follower's events and the leader's log say for an identity refusal.
        try require(DistributedInstalledLinkIdentity.describe(.localIdentityUnavailable).contains("run `darkbloom cluster` on both Macs"),
            "a missing or replaced key says how to pair again")
        try require(DistributedInstalledLinkIdentity.describe(.localIdentityLocked).contains("logs in once after a restart"),
            "a locked key says how the pair resumes")
        for refusal in [ClusterLinkControlRefusal.peerNotPinned, .identityMismatch, .peerSignatureRejected] {
            try require(DistributedInstalledLinkIdentity.describe(refusal).contains("didn't prove it holds the key"),
                "\(refusal) says the other Mac didn't prove its key")
        }
        try require(DistributedInstalledLinkIdentity.describe(.unknownEdge) == "unknownEdge", "other refusals keep their name")
    }

    private static func refusedWith(_ expected: ClusterLinkIdentityError, line: Int = #line, _ body: () throws -> Void) throws {
        do { try body() } catch let error as ClusterLinkIdentityError {
            try require(error == expected, "line \(line): expected \(expected), got \(error)"); return
        }
        throw CheckFailure(message: "line \(line): expected \(expected)")
    }

    /// An owner-only pairing store holding one pairing of `local` with `peer` on the link `epoch`/`edge`, in upper case.
    private static func pairingStore(_ directory: URL, local: SoftwareLinkSigner, peer: SoftwareLinkSigner, epoch: UUID,
                                     edge: UUID) throws -> ClusterPairingStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let localKey = local.identityPublicKey.base64EncodedString(), peerKey = peer.identityPublicKey.base64EncodedString()
        let localPin = ClusterPairingPin.of(identityKey: local.identityPublicKey)
        let peerPin = ClusterPairingPin.of(identityKey: peer.identityPublicKey)
        let digest = String(repeating: "a", count: 64)
        let record: [String: Any] = ["peerPin": peerPin, "peerIdentityKey": peerKey, "peerName": "Loop peer",
            "peerPosture": ["chipName": "Apple M4", "hardwareModel": "Mac", "osVersion": "15", "sipEnabled": true,
                            "secureBootEnabled": true, "authenticatedRootEnabled": true],
            "role": "listener", "pairedAt": "2026-11-14T00:00:00Z", "clusterID": "loop-pair",
            "roster": ["generation": 1, "members": [["pin": localPin, "se_public_key": localKey, "signature": ""],
                                                    ["pin": peerPin, "se_public_key": peerKey, "signature": ""]]],
            "rosterSHA256": digest,
            "link": ["linkEpoch": epoch.uuidString, "edgeID": edge.uuidString,
                     "secretFile": directory.appendingPathComponent("edge-\(peerPin.prefix(16)).secret").path,
                     "localInterface": "lo0", "peerInterface": "lo0"],
            "transcriptSHA256": digest]
        let records: [String: Any] = ["schema": ClusterPairingRecords.schemaName, "localPin": localPin,
                                      "localIdentityKey": localKey, "pairings": [record]]
        let store = ClusterPairingStore(directory: directory)
        try JSONSerialization.data(withJSONObject: records).write(to: store.recordsFile)
        chmod(store.recordsFile.path, 0o600)
        try require(try store.load()?.pairings.count == 1, "the fixture pairing store reads back")
        return store
    }
}
