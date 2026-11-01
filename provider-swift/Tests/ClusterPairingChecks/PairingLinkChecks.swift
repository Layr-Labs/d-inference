import Foundation
import DarkbloomClusterRemote
@testable import DarkbloomClusterSecurity

/// The ceremony over the real link control channel on loopback: two runs in
/// this process, each with its own store, as two Macs would run them.
extension PairingCheck {
    struct LinkSide {
        let identity = SoftwareIdentity()
        let store: ClusterPairingStore
        var accept = true
        var decide = true
        init(_ name: String) { store = ClusterPairingStore(directory: freshDirectory(name).appendingPathComponent("cluster-pairing")) }
    }

    static func port() -> UInt16 { UInt16.random(in: 40_000...46_000) }

    static func runLink(_ listener: LinkSide, _ connector: LinkSide, port: UInt16, lifetime: Double = 30,
                        clusterID: String? = "loop-pair")
        -> (listener: Result<ClusterLinkPairing.Result, ClusterPairingError>, connector: Result<ClusterLinkPairing.Result, ClusterPairingError>,
            codes: [String]) {
        let codes = NSLock()
        nonisolated(unsafe) var shown = [String]()
        @Sendable func callbacks(_ side: LinkSide) -> ClusterLinkPairing.Callbacks {
            ClusterLinkPairing.Callbacks(askConfirmation: { code, _, respond in
                codes.withLock { shown.append(code) }
                if side.decide { DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { respond(side.accept) } }
            })
        }
        @Sendable func options(_ role: ClusterPairingRole) -> ClusterLinkPairing.Options {
            var value = ClusterLinkPairing.Options(role: role, interface: "lo0", peerAddress: role == .connector ? .loopback : nil)
            value.port = port; value.policy = .loopbackForTests; value.lifetimeSeconds = lifetime
            return value
        }
        nonisolated(unsafe) var listenerResult: Result<ClusterLinkPairing.Result, ClusterPairingError> = .failure(.transport)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            listenerResult = ClusterLinkPairing.run(options: options(.listener),
                participant: TestPairing.storeBacked(listener.identity, name: "Loop listener", store: listener.store, clusterID: clusterID),
                hooks: TestPairing.hooks, store: listener.store, callbacks: callbacks(listener))
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.3)
        let connectorResult = ClusterLinkPairing.run(options: options(.connector),
            participant: TestPairing.storeBacked(connector.identity, name: "Loop connector", store: connector.store),
            hooks: TestPairing.hooks, store: connector.store, callbacks: callbacks(connector))
        if done.wait(timeout: .now() + lifetime + 15) == .timedOut { expect(false, "listener run did not end") }
        return (listenerResult, connectorResult, codes.withLock { shown })
    }

    static func linkPairing() {
        let listener = LinkSide("link-listener"), connector = LinkSide("link-connector")
        let result = runLink(listener, connector, port: port())
        guard case .success(let l) = result.listener, case .success(let c) = result.connector else {
            expect(false, "both runs paired: \(result.listener) / \(result.connector)"); return
        }
        expectEqual(result.codes.count, 2, "each Mac showed a code"); expectEqual(Set(result.codes).count, 1, "the same code")
        expectEqual(l.record.peerPin, ClusterPairingPin.of(identityKey: connector.identity.identityPublicKey), "listener pinned the connector")
        expectEqual(c.record.peerPin, ClusterPairingPin.of(identityKey: listener.identity.identityPublicKey), "connector pinned the listener")
        expectEqual(l.record.rosterSHA256, c.record.rosterSHA256, "both stored the same roster")
        expectEqual(l.record.clusterID, "loop-pair", "the listener's label")
        expectEqual(l.record.link.linkEpoch, c.record.link.linkEpoch, "same link epoch")
        expectEqual(l.record.link.edgeID, c.record.link.edgeID, "same edge")
        let ls = try? listener.store.edgeSecret(for: l.record), cs = try? connector.store.edgeSecret(for: c.record)
        expect(ls != nil && ls == cs, "both stored the same edge secret")
        expectEqual(mode(listener.store.recordsFile.path), 0o600, "listener pins 0600")
        expectEqual(mode(connector.store.secretFile(peerPin: c.record.peerPin).path), 0o600, "connector edge secret 0600")
        // The stored secret keys the ordinary link control channel.
        guard let ls, let cs, let epoch = UUID(uuidString: l.record.link.linkEpoch), let edgeID = UUID(uuidString: l.record.link.edgeID),
              let lk = try? ClusterLinkControlKey.qualification(secret: ls, epoch: epoch, edgeID: edgeID),
              let ck = try? ClusterLinkControlKey.qualification(secret: cs, epoch: epoch, edgeID: edgeID),
              let le = try? ClusterLinkControlEdge(edgeID: edgeID, epoch: epoch, key: lk, peerAddress: nil),
              let ce = try? ClusterLinkControlEdge(edgeID: edgeID, epoch: epoch, key: ck, peerAddress: .loopback) else {
            expect(false, "link control edge from the pairing"); return
        }
        let linkPort = port()
        guard let server = try? ClusterLinkControlListener(configuration: .init(interface: "lo0", port: linkPort,
                policy: .loopbackForTests, edges: [le]), handler: { _, _ in }),
              (try? server.start()) != nil,
              let client = try? ClusterLinkControlClient(configuration: .init(interface: "lo0", port: linkPort,
                policy: .loopbackForTests, edge: ce), handler: { _, _ in }) else { expect(false, "link control endpoints"); return }
        client.start()
        expect(client.peer.waitUntilConnected(timeout: .seconds(5)), "a link control session keyed by the paired secret comes up")
        expect((try? client.peer.ping()) != nil, "and carries a ping")
        client.stop(); server.stop()
        // Pairing again keeps the label and raises the generation on both.
        let again = runLink(listener, connector, port: port(), clusterID: nil)
        if case .success(let l2) = again.listener, case .success(let c2) = again.connector {
            expectEqual(l2.record.roster.generation, 2, "re-pairing: generation 2")
            expectEqual(c2.record.roster.generation, 2, "on both")
            expectEqual(l2.record.clusterID, "loop-pair", "the earlier label is kept")
            expect(l2.record.link.linkEpoch != l.record.link.linkEpoch, "a new link epoch")
            expectEqual((try? listener.store.load())?.pairings.count, 1, "still one pairing per peer")
        } else { expect(false, "re-pairing: \(again.listener) / \(again.connector)") }
    }

    static func linkRefusals() {
        // A decline on one Mac: nothing stored on either; both count it.
        var listener = LinkSide("refuse-listener"), connector = LinkSide("refuse-connector")
        connector.accept = false
        let declined = runLink(listener, connector, port: port())
        if case .failure(let error) = declined.connector { expectEqual(error, .declinedLocally, "the Mac that said no") } else { expect(false, "connector declined") }
        if case .failure(let error) = declined.listener { expectEqual(error, .declinedByPeer, "the other Mac") } else { expect(false, "listener declined") }
        expect((try? listener.store.load()) == nil && (try? connector.store.load()) == nil, "nothing stored after a decline")
        // Two more declines lock both out; the next offer is refused before any code.
        _ = runLink(listener, connector, port: port())
        _ = runLink(listener, connector, port: port())
        do { try listener.store.checkGate(); expect(false, "listener locked") } catch { expect(error is ClusterPairingError, "listener locked out after 3 failures") }
        connector.accept = true
        let fresh = LinkSide("refuse-fresh")
        let lockedPort = port()
        let locked = runLink(listener, fresh, port: lockedPort, lifetime: 3)
        if case .failure(.lockedOut(let until)) = locked.listener { expect(until > Date().timeIntervalSince1970, "the refusal says until when") }
        else { expect(false, "a locked-out Mac does not listen: \(locked.listener)") }
        if case .failure(.expired) = locked.connector {} else { expect(false, "the other Mac finds no listener: \(locked.connector)") }
        expect(locked.codes.isEmpty, "no code is shown while locked out")
        let own = ClusterLinkPairing.run(options: { var o = ClusterLinkPairing.Options(role: .connector, interface: "lo0", peerAddress: .loopback)
                o.port = port(); o.policy = .loopbackForTests; o.lifetimeSeconds = 2; return o }(),
            participant: TestPairing.participant(connector.identity), hooks: TestPairing.hooks, store: connector.store,
            callbacks: .init(askConfirmation: { _, _, respond in respond(true) }))
        if case .failure(.lockedOut) = own {} else { expect(false, "the locked-out connector does not even dial: \(own)") }
        // Nobody answers: the code expires on both and counts as a failure.
        listener = LinkSide("expire-listener"); connector = LinkSide("expire-connector")
        listener.decide = false; connector.decide = false
        let expired = runLink(listener, connector, port: port(), lifetime: 3)
        if case .failure(let error) = expired.listener { expectEqual(error, .expired, "listener: expired") } else { expect(false, "listener expired") }
        if case .failure(let error) = expired.connector { expect(error == .expired || error == .peerAborted, "connector: \(error)") } else { expect(false, "connector expired") }
        expectEqual(expired.codes.count, 2, "both had shown the code")
        expect((try? listener.store.load()) == nil, "nothing stored")
        // A connector with nothing listening gives up at its lifetime.
        let alone = ClusterLinkPairing.run(options: { var o = ClusterLinkPairing.Options(role: .connector, interface: "lo0", peerAddress: .loopback)
                o.port = port(); o.policy = .loopbackForTests; o.lifetimeSeconds = 2; return o }(),
            participant: TestPairing.participant(SoftwareIdentity()), hooks: TestPairing.hooks,
            store: LinkSide("alone").store, callbacks: .init(askConfirmation: { _, _, respond in respond(true) }))
        if case .failure(.expired) = alone {} else { expect(false, "a connector with no listener expires: \(alone)") }
    }
}
