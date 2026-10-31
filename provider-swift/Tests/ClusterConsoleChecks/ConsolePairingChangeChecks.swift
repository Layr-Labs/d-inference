import CryptoKit
import Darwin
import Foundation
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
@testable import InstalledContract

extension ClusterConsoleCheck {
    /// A software P-256 key in place of a Mac's Secure Enclave key.
    struct PairingKey: ClusterPairingIdentity {
        let key = P256.Signing.PrivateKey()
        var identityPublicKey: Data { key.publicKey.x963Representation }
        func pairingSignature(for message: Data) throws -> Data { try key.signature(for: message).derRepresentation }
    }

    /// One pairing ceremony in memory, each end stored in its own store with the edge both ends derive from their pins
    /// and interfaces, as the pairing command stores it.
    static func pairInMemory(_ listener: PairingKey, _ connector: PairingKey, stores: (ClusterPairingStore, ClusterPairingStore)) throws {
        let posture = ClusterPairingPeerPosture(chipName: "Test chip", hardwareModel: "Test1,1", osVersion: "26.0.0",
            sipEnabled: true, secureBootEnabled: true, authenticatedRootEnabled: true)
        // The attestation is the identity key's signature over the ceremony's ephemeral key.
        let hooks = ClusterPairingHooks(verifyAttestation: { attestation, identityKey, ephemeral in
            guard let key = try? P256.Signing.PublicKey(x963Representation: identityKey),
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: attestation),
                  key.isValidSignature(signature, for: ephemeral) else { return nil }
            return posture
        }, rosterCanonical: { clusterID, generation, members in
            Data(([clusterID, String(generation)] + members.map { $0.pin + $0.identityKey.base64EncodedString() }).joined(separator: "\n").utf8)
        })
        func participant(_ key: PairingKey, _ store: ClusterPairingStore) -> ClusterPairingParticipant {
            .storeBacked(identity: key, name: "Test Mac", interface: "lo0", attestation: { try key.pairingSignature(for: $0) }, store: store)
        }
        var sessions: [ClusterPairingRole: ClusterPairingSession] = [
            .listener: try ClusterPairingSession(role: .listener, participant: participant(listener, stores.0), hooks: hooks),
            .connector: try ClusterPairingSession(role: .connector, participant: participant(connector, stores.1), hooks: hooks),
        ]
        var queue = [(ClusterPairingRole, ClusterPairingMessage)]()
        var completed = 0
        func perform(_ steps: [ClusterPairingStep], _ role: ClusterPairingRole) {
            for step in steps {
                switch step {
                case .send(let message): queue.append((role == .listener ? .connector : .listener, message))
                case .showCode: perform(sessions[role]!.decide(accept: true), role)
                case .persist(let outcome):
                    let edge = ClusterLinkControlEdge.derivedEdgeID(firstMember: outcome.localPin, firstInterface: outcome.localInterface,
                        secondMember: outcome.peer.pin, secondInterface: outcome.peer.interface)
                    let stored = (try? (role == .listener ? stores.0 : stores.1).commit(outcome, edgeID: edge)) != nil
                    perform(sessions[role]!.localPersisted(stored), role)
                case .completed: completed += 1
                case .peerDecided, .rollback, .failed: break
                }
            }
        }
        perform(sessions[.connector]!.start(), .connector)
        while !queue.isEmpty {
            let (to, message) = queue.removeFirst()
            perform(sessions[to]!.receive(message), to)
        }
        guard completed == 2 else { throw ClusterSetupFailure("the pairing in memory did not complete") }
    }

    /// A cluster service's listener answers with the key of the pairing it started with, and a pairing made since is
    /// another pairing (2026-10-31: after the Macs paired again, the member's service refused every lease and the
    /// wizard's reading with `handshakeRejected` until it restarted). The service starts a listener again when the
    /// pairing read here is another one than the listener names, and stops it when there is none; an unreadable store
    /// changes nothing. Real ceremonies in private stores, real listeners on loopback, the other Mac dialing with the
    /// pairing it stored.
    static func listenersFollowThePairing() throws {
        typealias X = ClusterSetupLinkExchange
        guard let selection = try? ClusterLinkInterfaceAdmission.select(interface: "lo0", localAddress: nil, peerAddress: nil,
            policy: .loopbackForTests, inspector: ClusterLinkSystemInterfaceInspector()) else {
            expect(false, "lo0 selection"); return
        }
        let port: UInt16 = 45_891
        let root = scratch.appendingPathComponent("pairing-again", isDirectory: true)
        let here = ClusterPairingStore(directory: root.appendingPathComponent("this-mac/cluster-pairing", isDirectory: true))
        let there = ClusterPairingStore(directory: root.appendingPathComponent("other-mac/cluster-pairing", isDirectory: true))
        func listen(_ pairing: X.Pairing) throws -> X.Responder {
            let listener = try X.Responder(pairing: pairing, selection: selection, port: port, policy: .loopbackForTests,
                answer: { throw ClusterSetupFailure("not asked") }, receive: { _ in "" }, command: { _ in Data("answered".utf8) })
            try listener.start()
            return listener
        }
        // What the other Mac's service and wizard get for a pairing ("answered", or why not), without the per-user request
        // lock that `ClusterSetupLinkExchange.command` takes: a cluster service running on this Mac shares it.
        func dial(_ pairing: X.Pairing) -> String {
            do {
                let session = try X.Session(pairing: pairing, selection: selection, peerAddress: .loopback, port: port, policy: .loopbackForTests)
                defer { session.close() }
                let reply = try session.request(tag: X.commandTag, Data("status".utf8), reply: X.commandReplyTag, seconds: 2)
                return String(decoding: reply, as: UTF8.self) == "ok:answered" ? "answered" : "unexpected reply"
            } catch let failure as ClusterSetupFailure { return failure.text } catch { return "\(error)" }
        }

        let thisMac = PairingKey(), otherMac = PairingKey()
        try pairInMemory(thisMac, otherMac, stores: (here, there))
        guard let first = try X.pairing(store: here), let firstThere = try X.pairing(store: there) else {
            expect(false, "both Macs read the pairing back"); return
        }
        expectEqual(try X.pairing(store: here)?.identity, first.identity, "the same store reads as the same pairing: nothing restarts")
        let listener = try listen(first)
        defer { listener.stop() }
        expectEqual(listener.pairing, first.identity, "a listener names the pairing whose key it answers with")
        expectEqual(dial(firstThere), "answered", "the other Mac is answered with the pairing both Macs stored")

        // The same two keys pair again: the same pins and edge, a new link epoch and edge secret.
        try pairInMemory(thisMac, otherMac, stores: (here, there))
        guard let second = try X.pairing(store: here), let secondThere = try X.pairing(store: there) else {
            expect(false, "both Macs read the new pairing back"); return
        }
        expect(second.identity != first.identity && second.linkEpoch != first.linkEpoch, "pairing again is another pairing (a new link epoch)")
        expect(second.localPin == first.localPin && second.peerPin == first.peerPin && second.edgeID == first.edgeID,
               "with the same pins and edge")
        let stale = dial(secondThere)
        expect(stale.contains("refused (handshakeRejected)"), "a listener keyed with the earlier pairing refuses the new one: \(stale)")
        listener.stop()
        let restarted = try listen(second)
        defer { restarted.stop() }
        expectEqual(dial(secondThere), "answered", "started again with the pairing now, the listener answers the new pairing")
        let earlier = dial(firstThere)
        expect(earlier.contains("refused (handshakeRejected)"), "and refuses the earlier one: \(earlier)")
        restarted.stop()

        // A new key on this Mac replaces its pairings: another local pin, edge and link epoch.
        try pairInMemory(PairingKey(), otherMac, stores: (here, there))
        guard let rekeyed = try X.pairing(store: here) else { expect(false, "the pairing under the new key reads back"); return }
        expect(rekeyed.localPin != second.localPin && rekeyed.peerPin == second.peerPin && rekeyed.edgeID != second.edgeID
               && rekeyed.identity != second.identity, "a new Secure Enclave key is another pairing")

        // A store others may open is refused, never read as no pairing; after unpairing it reads as none, without a failure.
        chmod(here.directory.path, 0o755)
        var refused = false
        do { _ = try X.pairing(store: here) } catch { refused = true }
        chmod(here.directory.path, 0o700)
        expect(refused, "an unsafe pairing store is a failure to read, not an unpairing")
        _ = try here.forget(peerPin: rekeyed.peerPin)
        do { expect(try X.pairing(store: here) == nil, "an unpaired Mac has no pairing to answer for") } catch {
            expect(false, "an unpaired store reads without a failure: \(error)")
        }
    }
}
