import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

// MARK: - Software signer (stands in for the Secure Enclave on CI / one machine)

/// An `AttestationSigner` backed by a plain in-memory P-256 key. Produces the
/// same DER ECDSA signatures and 64-byte raw public key the Secure Enclave does,
/// so handshake/roster logic can be exercised with no SE hardware.
private struct SoftwareSigner: AttestationSigner {
    let privateKey: P256.Signing.PrivateKey
    init() { privateKey = P256.Signing.PrivateKey() }
    func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data).derRepresentation
    }
    var publicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }
}

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    return f.date(from: s)!
}

// MARK: - Roster fixtures

private struct ClusterFixture {
    let coordinator: SoftwareSigner
    let coordinatorPubB64: String
    let signerA: SoftwareSigner
    let signerB: SoftwareSigner
    let roster: ClusterRosterBody
    let signedRoster: SignedClusterRoster
}

private func makeFixture(
    issuedAt: Date = iso("2026-06-15T00:00:00Z"),
    expiresAt: Date = iso("2026-06-15T01:00:00Z")
) throws -> ClusterFixture {
    let coordinator = SoftwareSigner()
    let signerA = SoftwareSigner()
    let signerB = SoftwareSigner()

    let members = [
        ClusterMember(
            nodeId: "node-a",
            sePublicKeyBase64: signerA.publicKeyBase64,
            x25519PublicKeyBase64: NodeKeyPair.generate().publicKeyBase64,
            trustLevel: "hardware"),
        ClusterMember(
            nodeId: "node-b",
            sePublicKeyBase64: signerB.publicKeyBase64,
            x25519PublicKeyBase64: NodeKeyPair.generate().publicKeyBase64,
            trustLevel: "self_signed"),
    ]
    let body = ClusterRosterBody(
        clusterId: "cluster-1", members: members, issuedAt: issuedAt, expiresAt: expiresAt)
    let sig = try coordinator.sign(ClusterRoster.canonicalBytes(body)).base64EncodedString()
    return ClusterFixture(
        coordinator: coordinator,
        coordinatorPubB64: coordinator.publicKeyBase64,
        signerA: signerA, signerB: signerB,
        roster: body,
        signedRoster: SignedClusterRoster(body: body, signature: sig))
}

// MARK: - Roster tests

@Suite("ClusterRoster")
struct ClusterRosterTests {
    @Test func verifiesValidRoster() throws {
        let f = try makeFixture()
        try ClusterRoster.verify(
            f.signedRoster,
            coordinatorPublicKeyBase64: f.coordinatorPubB64,
            now: iso("2026-06-15T00:30:00Z"))
    }

    @Test func rejectsTamperedRoster() throws {
        let f = try makeFixture()
        var tampered = f.signedRoster.body.members
        tampered[0] = ClusterMember(
            nodeId: "node-a", sePublicKeyBase64: tampered[0].sePublicKeyBase64,
            x25519PublicKeyBase64: tampered[0].x25519PublicKeyBase64, trustLevel: "hardware")
        // swap in a different cluster id to invalidate the signature
        let badBody = ClusterRosterBody(
            clusterId: "cluster-EVIL", members: tampered,
            issuedAt: f.roster.issuedAt, expiresAt: f.roster.expiresAt)
        let bad = SignedClusterRoster(body: badBody, signature: f.signedRoster.signature)
        #expect(throws: ClusterRosterError.signatureInvalid) {
            try ClusterRoster.verify(bad, coordinatorPublicKeyBase64: f.coordinatorPubB64,
                                     now: iso("2026-06-15T00:30:00Z"))
        }
    }

    @Test func rejectsExpiredRoster() throws {
        let f = try makeFixture()
        #expect(throws: ClusterRosterError.expired) {
            try ClusterRoster.verify(f.signedRoster, coordinatorPublicKeyBase64: f.coordinatorPubB64,
                                     now: iso("2026-06-15T02:00:00Z"))
        }
    }

    @Test func rejectsWrongCoordinatorKey() throws {
        let f = try makeFixture()
        let other = SoftwareSigner()
        #expect(throws: ClusterRosterError.signatureInvalid) {
            try ClusterRoster.verify(f.signedRoster, coordinatorPublicKeyBase64: other.publicKeyBase64,
                                     now: iso("2026-06-15T00:30:00Z"))
        }
    }

    @Test func minTrustIsWeakestMember() throws {
        let f = try makeFixture()
        let weakest = ClusterRoster.minTrustLevel(
            f.roster, strongestFirst: ["hardware", "self_signed", "none"])
        #expect(weakest == "self_signed")
    }
}

// MARK: - Handshake tests

@Suite("ClusterHandshake")
struct ClusterHandshakeTests {
    /// Drive the full 3-message exchange and return both confirmed sessions.
    private func runHandshake(_ f: ClusterFixture) throws -> (ClusterSession, ClusterSession) {
        let initiator = ClusterHandshakeInitiator(
            clusterId: "cluster-1", localNodeId: "node-a",
            signer: f.signerA, roster: f.roster)
        let responder = ClusterHandshakeResponder(
            localNodeId: "node-b", signer: f.signerB, roster: f.roster)

        let m1 = initiator.start()
        let m2 = try responder.respond(m1)
        let (m3, sessionA) = try initiator.finish(m2)
        let sessionB = try responder.confirm(m3)
        return (sessionA, sessionB)
    }

    @Test func happyPathDerivesMatchingKeys() throws {
        let f = try makeFixture()
        let (a, b) = try runHandshake(f)
        // A's send key must equal B's recv key, and vice versa.
        #expect(a.sendKey() == b.recvKey())
        #expect(b.sendKey() == a.recvKey())
        // The two directions must differ.
        #expect(a.sendKey() != a.recvKey())
    }

    @Test func rejectsForgedResponderSignature() throws {
        let f = try makeFixture()
        let initiator = ClusterHandshakeInitiator(
            clusterId: "cluster-1", localNodeId: "node-a", signer: f.signerA, roster: f.roster)
        let responder = ClusterHandshakeResponder(
            localNodeId: "node-b", signer: f.signerB, roster: f.roster)
        let m1 = initiator.start()
        var m2 = try responder.respond(m1)
        // Replace responder signature with one over the wrong bytes.
        m2 = ClusterHandshakeMsg2(
            responderNodeId: m2.responderNodeId, ephemeralPublicKey: m2.ephemeralPublicKey,
            nonce: m2.nonce, signature: try f.signerB.sign(Data("not the transcript".utf8)))
        #expect(throws: ClusterHandshakeError.peerSignatureInvalid(nodeId: "node-b")) {
            _ = try initiator.finish(m2)
        }
    }

    @Test func rejectsPeerNotInRoster() throws {
        let f = try makeFixture()
        // Responder claims to be an id not on the roster.
        let responder = ClusterHandshakeResponder(
            localNodeId: "node-ghost", signer: f.signerB, roster: f.roster)
        let initiator = ClusterHandshakeInitiator(
            clusterId: "cluster-1", localNodeId: "node-a", signer: f.signerA, roster: f.roster)
        let m1 = initiator.start()
        #expect(throws: ClusterRosterError.memberNotFound(nodeId: "node-ghost")) {
            _ = try responder.respond(m1)
        }
    }

    @Test func rejectsImpersonatedInitiatorAtConfirm() throws {
        let f = try makeFixture()
        let initiator = ClusterHandshakeInitiator(
            clusterId: "cluster-1", localNodeId: "node-a", signer: f.signerA, roster: f.roster)
        let responder = ClusterHandshakeResponder(
            localNodeId: "node-b", signer: f.signerB, roster: f.roster)

        // Run a real Msg1/Msg2 so the responder stages node-a, then forge Msg3
        // with an attacker key that is NOT node-a's roster identity. confirm()
        // must reject it — proving Msg3 authenticates the initiator, not just
        // that *some* well-formed signature arrived.
        let m1 = initiator.start()
        let m2 = try responder.respond(m1)
        let attacker = SoftwareSigner()
        let forgedM3 = ClusterHandshakeMsg3(
            signature: try attacker.sign(Data("any bytes the attacker likes".utf8)))
        #expect(throws: ClusterHandshakeError.peerSignatureInvalid(nodeId: "node-a")) {
            _ = try responder.confirm(forgedM3)
        }
    }
}

// MARK: - Layer partition tests

@Suite("LayerPartition")
struct LayerPartitionTests {
    private let gb: UInt64 = 1_073_741_824

    @Test func memoryWeightedSplitAcrossTwoLaptops() throws {
        // 48 layers across 32GB + 24GB ≈ the demo cluster (post-OS-reserve).
        let p = try LayerPartition.partition(totalLayers: 48, nodes: [
            .init(nodeId: "mac-32", weightBytes: 28 * gb),
            .init(nodeId: "mac-24", weightBytes: 20 * gb),
        ])
        #expect(p.count == 2)
        #expect(p[0].start == 0)
        #expect(p[0].end == p[1].start)   // contiguous
        #expect(p[1].end == 48)
        #expect(p.reduce(0) { $0 + $1.count } == 48)
        #expect(p[0].count > p[1].count)  // bigger node, more layers
    }

    @Test func evenWeightsSplitEvenly() throws {
        let p = try LayerPartition.partition(totalLayers: 40, nodes: [
            .init(nodeId: "a", weightBytes: 16 * gb),
            .init(nodeId: "b", weightBytes: 16 * gb),
        ])
        #expect(p[0].count == 20 && p[1].count == 20)
    }

    @Test func tinyNodeStillGetsAtLeastOneLayer() throws {
        let p = try LayerPartition.partition(totalLayers: 10, nodes: [
            .init(nodeId: "huge", weightBytes: 200 * gb),
            .init(nodeId: "tiny", weightBytes: 1 * gb),
        ])
        #expect(p[1].count >= 1)
        #expect(p.reduce(0) { $0 + $1.count } == 10)
    }

    @Test func rejectsMoreNodesThanLayers() throws {
        #expect(throws: LayerPartitionError.tooManyNodesForLayers(nodes: 2, layers: 1)) {
            _ = try LayerPartition.partition(totalLayers: 1, nodes: [
                .init(nodeId: "a", weightBytes: gb), .init(nodeId: "b", weightBytes: gb)])
        }
    }

    @Test func rejectsEmptyNodeList() throws {
        #expect(throws: LayerPartitionError.noNodes) {
            _ = try LayerPartition.partition(totalLayers: 10, nodes: [])
        }
    }
}

// MARK: - Link cipher tests

@Suite("ClusterLinkCrypto")
struct ClusterLinkCryptoTests {
    private func sessionPair() throws -> (ClusterSession, ClusterSession) {
        let f = try makeFixture()
        let initiator = ClusterHandshakeInitiator(
            clusterId: "cluster-1", localNodeId: "node-a", signer: f.signerA, roster: f.roster)
        let responder = ClusterHandshakeResponder(
            localNodeId: "node-b", signer: f.signerB, roster: f.roster)
        let m1 = initiator.start()
        let m2 = try responder.respond(m1)
        let (m3, sa) = try initiator.finish(m2)
        let sb = try responder.confirm(m3)
        return (sa, sb)
    }

    @Test func sealOpenRoundTrip() throws {
        let (a, b) = try sessionPair()
        let send = ClusterSealingChannel(key: a.sendKey())
        let recv = ClusterOpeningChannel(key: b.recvKey())

        let activation = Data((0..<8192).map { UInt8($0 & 0xff) })
        let ctx0 = ClusterFrameContext(clusterId: "cluster-1", requestId: "req-1", layerRange: "0..24", seq: 0)
        let frame = try send.seal(activation, context: ctx0)
        let opened = try recv.open(frame, context: ctx0)
        #expect(opened == activation)
    }

    @Test func nonceIsMonotonicAcrossFrames() throws {
        let (a, b) = try sessionPair()
        let send = ClusterSealingChannel(key: a.sendKey())
        let recv = ClusterOpeningChannel(key: b.recvKey())
        for seq in UInt64(0)..<5 {
            let pt = Data("token-\(seq)".utf8)
            let ctx = ClusterFrameContext(clusterId: "cluster-1", requestId: "req-1", layerRange: "0..24", seq: seq)
            let frame = try send.seal(pt, context: ctx)
            #expect(try recv.open(frame, context: ctx) == pt)
        }
    }

    @Test func tamperedAADIsRejected() throws {
        let (a, b) = try sessionPair()
        let send = ClusterSealingChannel(key: a.sendKey())
        let recv = ClusterOpeningChannel(key: b.recvKey())
        let pt = Data("secret activations".utf8)
        let sealCtx = ClusterFrameContext(clusterId: "cluster-1", requestId: "req-1", layerRange: "0..24", seq: 0)
        let frame = try send.seal(pt, context: sealCtx)
        // Attacker replays into a different request id.
        let evilCtx = ClusterFrameContext(clusterId: "cluster-1", requestId: "req-EVIL", layerRange: "0..24", seq: 0)
        #expect(throws: ClusterLinkError.openFailed) {
            _ = try recv.open(frame, context: evilCtx)
        }
    }

    @Test func outOfOrderFrameIsRejected() throws {
        let (a, b) = try sessionPair()
        let send = ClusterSealingChannel(key: a.sendKey())
        let recv = ClusterOpeningChannel(key: b.recvKey())
        let c0 = ClusterFrameContext(clusterId: "cluster-1", requestId: "r", layerRange: "0..24", seq: 0)
        let c1 = ClusterFrameContext(clusterId: "cluster-1", requestId: "r", layerRange: "0..24", seq: 1)
        _ = try send.seal(Data("a".utf8), context: c0)        // advance sender to 1
        let f1 = try send.seal(Data("b".utf8), context: c1)
        // Receiver still expects seq 0 → seq-1 frame must be rejected.
        #expect(throws: ClusterLinkError.openFailed) {
            _ = try recv.open(f1, context: c1)
        }
    }

    @Test func wrongDirectionKeyFailsToOpen() throws {
        let (a, b) = try sessionPair()
        // Seal with A→B key, attempt to open with A's recv (B→A) key: must fail.
        let send = ClusterSealingChannel(key: a.sendKey())
        let wrong = ClusterOpeningChannel(key: a.recvKey())
        let ctx = ClusterFrameContext(clusterId: "cluster-1", requestId: "r", layerRange: "0..24", seq: 0)
        let frame = try send.seal(Data("x".utf8), context: ctx)
        #expect(throws: ClusterLinkError.openFailed) {
            _ = try wrong.open(frame, context: ctx)
        }
    }
}
