import CryptoKit
import Foundation
@testable import DarkbloomClusterSecurity

/// The ceremony as a pure state machine: two sessions joined by an in-memory
/// queue, every message through its wire encoding.
extension PairingCheck {
    struct Run {
        var codes: [ClusterPairingRole: String] = [:]
        var outcomes: [ClusterPairingRole: ClusterPairingOutcome] = [:]
        var failures: [ClusterPairingRole: ClusterPairingError] = [:]
        var persisted: Set<ClusterPairingRole> = []
        var rolledBack: Set<ClusterPairingRole> = []
        var peerDecisions: [ClusterPairingRole: Bool] = [:]
        var sessions: [ClusterPairingRole: ClusterPairingSession] = [:]
    }

    struct Plan {
        var accept: [ClusterPairingRole: Bool] = [.listener: true, .connector: true]
        var persists: [ClusterPairingRole: Bool] = [.listener: true, .connector: true]
        /// Changes a message on its way; nil drops it.
        var tamper: ((ClusterPairingMessage, _ from: ClusterPairingRole) -> ClusterPairingMessage?)?
        var decide = true
    }

    static func runInMemory(_ listener: ClusterPairingParticipant, _ connector: ClusterPairingParticipant,
                            hooks: [ClusterPairingRole: ClusterPairingHooks] = [:], plan: Plan = Plan()) -> Run {
        var sessions: [ClusterPairingRole: ClusterPairingSession] = [
            .listener: try! ClusterPairingSession(role: .listener, participant: listener, hooks: hooks[.listener] ?? TestPairing.hooks),
            .connector: try! ClusterPairingSession(role: .connector, participant: connector, hooks: hooks[.connector] ?? TestPairing.hooks),
        ]
        var run = Run()
        var queue = [(to: ClusterPairingRole, bytes: Data)]()
        func perform(_ steps: [ClusterPairingStep], at role: ClusterPairingRole) {
            for step in steps {
                switch step {
                case .send(let message):
                    guard let sent = plan.tamper.map({ $0(message, role) }) ?? message else { continue }
                    queue.append((role.peer, try! sent.encoded()))
                case .showCode(let code, _):
                    run.codes[role] = code
                    if plan.decide {
                        let next = sessions[role]!.decide(accept: plan.accept[role] ?? true)
                        perform(next, at: role)
                    }
                case .peerDecided(let accepted): run.peerDecisions[role] = accepted
                case .persist:
                    let ok = plan.persists[role] ?? true
                    if ok { run.persisted.insert(role) }
                    perform(sessions[role]!.localPersisted(ok), at: role)
                case .rollback: run.rolledBack.insert(role)
                case .completed(let outcome): run.outcomes[role] = outcome
                case .failed(let error): run.failures[role] = error
                }
            }
        }
        perform(sessions[.connector]!.start(), at: .connector)
        var guardCount = 0
        while !queue.isEmpty, guardCount < 100 {
            guardCount += 1
            let (to, bytes) = queue.removeFirst()
            guard let message = try? ClusterPairingMessage.decode(bytes) else { run.failures[to] = .malformedMessage; continue }
            perform(sessions[to]!.receive(message), at: to)
        }
        run.sessions = sessions
        return run
    }

    static func coordinatorVector() {
        guard let data = FileManager.default.contents(atPath: vector),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = object["member_keys"] as? [[String: String]], let registration = object["registration"] as? [String: Any],
              let roster = registration["roster"] as? [String: Any], let members = roster["members"] as? [[String: String]],
              let canonicalHex = object["roster_canonical"] as? String, let clusterID = object["cluster_id"] as? String,
              let generation = roster["generation"] as? Int else {
            expect(false, "the coordinator vector could not be read"); return
        }
        for key in keys {
            let point = Data(base64Encoded: key["se_public_key"]!)!
            expectEqual(ClusterPairingPin.of(identityKey: point), key["pin"]!, "pin of the vector's key")
            expect(ClusterPairingPin.isIdentityKey(point), "vector key is a P-256 point")
        }
        let ordered = members.map { (pin: $0["pin"]!, identityKey: Data(base64Encoded: $0["se_public_key"]!)!) }
        let canonical = ReferenceRoster.canonical(clusterID: clusterID, generation: UInt64(generation), members: ordered)
        expectEqual(canonical, ReferenceRoster.hexDecode(canonicalHex)!, "reference roster bytes equal the coordinator's")
        for member in members {
            let key = try! P256.Signing.PublicKey(x963Representation: Data(base64Encoded: member["se_public_key"]!)!)
            let signature = try! P256.Signing.ECDSASignature(derRepresentation: Data(base64Encoded: member["signature"]!)!)
            expect(key.isValidSignature(signature, for: canonical), "vector signature verifies the way the ceremony signs (SHA-256 of the bytes)")
            expect(ClusterPairingSession.verify(signature: Data(base64Encoded: member["signature"]!)!, message: canonical,
                                                key: Data(base64Encoded: member["se_public_key"]!)!), "ceremony verifier accepts it")
        }
        expect(ClusterPairingLabel.isValid(clusterID), "vector label is valid")
        for bad in ["", "-x", "a b", "a/b", String(repeating: "a", count: 129), "é"] { expect(!ClusterPairingLabel.isValid(bad), "label \(bad.debugDescription) refused") }
        let label = ClusterPairingLabel.derived(pins: [keys[0]["pin"]!, keys[1]["pin"]!])
        expectEqual(label, ClusterPairingLabel.derived(pins: [keys[1]["pin"]!, keys[0]["pin"]!]), "derived label is order-free")
        expect(label.hasPrefix("pair-") && label.count == 17 && ClusterPairingLabel.isValid(label), "derived label shape")
    }

    static func messageShapes() {
        let identity = SoftwareIdentity()
        var offer = ClusterPairingMessage(kind: .offer)
        offer.version = 1; offer.name = "Mac"; offer.interface = "en7"; offer.identityKey = identity.identityPublicKey
        offer.ephemeralKey = Data(repeating: 9, count: 32); offer.commitment = Data(repeating: 1, count: 32)
        expect((try? ClusterPairingMessage.decode(try! offer.encoded())) == offer, "a well-formed offer round-trips")
        var extra = offer; extra.nonce = Data(repeating: 2, count: 32)
        expect((try? ClusterPairingMessage.decode(try! extra.encoded())) == nil, "an offer with a nonce is refused")
        var missing = offer; missing.commitment = nil
        expect((try? ClusterPairingMessage.decode(try! missing.encoded())) == nil, "an offer without a commitment is refused")
        var shortKey = offer; shortKey.identityKey = Data(repeating: 4, count: 65)
        expect((try? ClusterPairingMessage.decode(try! shortKey.encoded())) == nil, "a key off the curve is refused")
        var control = offer; control.name = "Mac\u{1B}[2J"
        expect((try? ClusterPairingMessage.decode(try! control.encoded())) == nil, "a name with a control character is refused")
        var long = offer; long.name = String(repeating: "a", count: 97)
        expect((try? ClusterPairingMessage.decode(try! long.encoded())) == nil, "an overlong name is refused")
        expect((try? ClusterPairingMessage.decode(Data(repeating: 0x20, count: ClusterPairingPolicy.maximumMessageBytes + 1))) == nil,
               "an oversized message is refused")
        expect((try? ClusterPairingMessage.decode(Data("{\"kind\":\"nope\"}".utf8))) == nil, "an unknown kind is refused")
        var decision = ClusterPairingMessage(kind: .decision); decision.accept = true; decision.tag = Data(repeating: 3, count: 32)
        expect((try? ClusterPairingMessage.decode(try! decision.encoded())) != nil, "a decision decodes")
        decision.tag = Data(repeating: 3, count: 31)
        expect((try? ClusterPairingMessage.decode(try! decision.encoded())) == nil, "a short tag is refused")
        var refused = ClusterPairingMessage(kind: .refused); refused.reason = "locked_out"; refused.retryAfterEpochSeconds = 5
        expect((try? ClusterPairingMessage.decode(try! refused.encoded())) != nil, "a refusal with a retry time decodes")
    }

    static func ceremonyBothConfirm() {
        let a = SoftwareIdentity(), b = SoftwareIdentity()
        let run = runInMemory(TestPairing.participant(a, name: "Listener Mac", interface: "bridge0", clusterID: "studio-pair"),
                              TestPairing.participant(b, name: "Connector Mac", interface: "en6"))
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        expect(run.codes[.listener] != nil && run.codes[.listener] == run.codes[.connector], "both screens show the same code")
        expect(run.codes[.listener].map { $0.count == 6 && $0.allSatisfy(\.isNumber) } ?? false, "six digits")
        guard let l = run.outcomes[.listener], let c = run.outcomes[.connector] else { expect(false, "both completed"); return }
        expectEqual(l.peer.pin, ClusterPairingPin.of(identityKey: b.identityPublicKey), "listener pins the connector's key")
        expectEqual(c.peer.pin, ClusterPairingPin.of(identityKey: a.identityPublicKey), "connector pins the listener's key")
        expectEqual(l.peer.interface, "en6", "listener knows the connector's interface")
        expectEqual(c.peer.name, "Listener Mac", "connector shows the listener's name")
        expectEqual(l.clusterID, "studio-pair", "the listener's label"); expectEqual(c.clusterID, "studio-pair", "both use it")
        expectEqual(l.generation, 1, "first pairing is generation 1"); expectEqual(c.generation, 1, "both agree")
        expectEqual(l.rosterMembers, c.rosterMembers, "both hold the same countersigned roster")
        expectEqual(l.rosterSHA256, c.rosterSHA256, "same roster hash")
        expect(l.rosterMembers.map(\.pin) == l.rosterMembers.map(\.pin).sorted(), "members in ascending pin order")
        let canonical = ReferenceRoster.canonical(clusterID: "studio-pair", generation: 1,
            members: l.rosterMembers.map { ($0.pin, Data(base64Encoded: $0.sePublicKey)!) })
        expectEqual(l.rosterCanonical, canonical, "the signed bytes are the coordinator's roster bytes")
        for member in l.rosterMembers {
            expect(ClusterPairingSession.verify(signature: Data(base64Encoded: member.signature)!, message: canonical,
                                                key: Data(base64Encoded: member.sePublicKey)!), "member \(member.pin.prefix(8)) signed the roster")
        }
        expectEqual(l.edgeSecret, c.edgeSecret, "both derived the same link edge secret")
        expectEqual(l.edgeSecret.count, 32, "32-byte edge secret")
        expect(!l.edgeSecret.allSatisfy { $0 == 0 }, "edge secret is not zero")
        expectEqual(l.linkEpoch, c.linkEpoch, "same link epoch"); expectEqual(l.transcriptSHA256, c.transcriptSHA256, "same transcript")
        expect(!String(describing: l).contains(l.edgeSecret.map { String(format: "%02x", $0) }.joined()), "description redacts the secret")
        expectEqual(run.peerDecisions[.listener], true, "listener learned the connector confirmed")
    }

    static func ceremonyGeneration() {
        let a = SoftwareIdentity(), b = SoftwareIdentity()
        let run = runInMemory(TestPairing.participant(a, generation: 0), TestPairing.participant(b, generation: 4))
        expectEqual(run.outcomes[.listener]?.generation, 5, "the higher stored generation wins and grows by one")
        expectEqual(run.outcomes[.connector]?.generation, 5, "both agree on it")
        let again = runInMemory(TestPairing.participant(a), TestPairing.participant(b))
        expect(again.codes[.listener] != run.codes[.listener] || again.outcomes[.listener]?.edgeSecret != run.outcomes[.listener]?.edgeSecret,
               "a new ceremony gives a new edge secret")
        expect(again.outcomes[.listener]?.linkEpoch != run.outcomes[.listener]?.linkEpoch, "and a new link epoch")
    }

    /// A relay in the middle runs one session toward each Mac with its own
    /// keys. Both Macs complete their halves but see different codes, so a
    /// person comparing the screens says no.
    static func ceremonyRelay() {
        var differing = 0
        for _ in 0..<20 {
            let a = SoftwareIdentity(), b = SoftwareIdentity(), m = SoftwareIdentity()
            let towardListener = runInMemory(TestPairing.participant(a), TestPairing.participant(m))
            let towardConnector = runInMemory(TestPairing.participant(m), TestPairing.participant(b))
            if towardListener.codes[.listener] != towardConnector.codes[.connector] { differing += 1 }
            expectEqual(towardListener.outcomes[.listener]?.peer.pin, ClusterPairingPin.of(identityKey: m.identityPublicKey),
                        "without the comparison the listener would pin the relay")
        }
        expectEqual(differing, 20, "the two Macs' codes differ in every relayed run")
        // A relay that forwards the offer unchanged but substitutes its own
        // answer cannot open the connector's commitment for the listener.
        let a = SoftwareIdentity(), b = SoftwareIdentity()
        var nonce: Data?
        var plan = Plan()
        plan.tamper = { message, from in
            var changed = message
            if message.kind == .reveal, from == .connector { nonce = message.nonce; changed.nonce = Data(repeating: 7, count: 32) }
            return changed
        }
        let tampered = runInMemory(TestPairing.participant(a), TestPairing.participant(b), plan: plan)
        expect(nonce != nil, "the reveal was seen")
        expectEqual(tampered.failures[.listener], .commitmentMismatch, "a changed nonce breaks the commitment")
        expect(tampered.codes.isEmpty, "no code is shown")
        expectEqual(tampered.failures[.connector], .peerAborted, "the connector is told")
    }

    static func ceremonyTampering() {
        let a = SoftwareIdentity(), b = SoftwareIdentity(), other = SoftwareIdentity()
        // A proof signed by another key.
        var plan = Plan()
        plan.tamper = { message, from in
            var changed = message
            if message.kind == .proof, from == .connector { changed.signature = try! other.pairingSignature(for: Data("x".utf8)) }
            return changed
        }
        expectEqual(runInMemory(TestPairing.participant(a), TestPairing.participant(b), plan: plan).failures[.listener], .proofInvalid,
                    "a proof from another key is refused")
        // An attestation that does not verify.
        let refusing = ClusterPairingHooks(verifyAttestation: { _, _, _ in nil }, rosterCanonical: TestPairing.hooks.rosterCanonical)
        let noAttestation = runInMemory(TestPairing.participant(a), TestPairing.participant(b), hooks: [.connector: refusing])
        expectEqual(noAttestation.failures[.connector], .attestationInvalid, "an attestation that does not bind the keys is refused")
        expect(noAttestation.codes.isEmpty, "before any code")
        // An attestation made for another ephemeral key (replayed).
        let replay = ClusterPairingParticipant(identity: b, name: "Mac", interface: "lo0",
            attestation: { _ in try TestAttestation.make(b, ephemeral: Data(repeating: 5, count: 32)) })
        expectEqual(runInMemory(TestPairing.participant(a), replay).failures[.listener], .attestationInvalid,
                    "an attestation for another ceremony is refused")
        // A forged decision.
        var forge = Plan()
        forge.tamper = { message, _ in
            var changed = message
            if message.kind == .decision { changed.tag = Data(repeating: 1, count: 32) }
            return changed
        }
        let forged = runInMemory(TestPairing.participant(a), TestPairing.participant(b), plan: forge)
        expect(forged.failures.values.contains(.tagInvalid), "a decision without the agreed key is refused")
        expect(forged.outcomes.isEmpty, "nothing completes")
        // A forged countersignature (valid tag impossible without the key; a swapped signature).
        var swap = Plan()
        swap.tamper = { message, _ in
            var changed = message
            if message.kind == .countersign { changed.signature = try! other.pairingSignature(for: Data("y".utf8)) }
            return changed
        }
        let swapped = runInMemory(TestPairing.participant(a), TestPairing.participant(b), plan: swap)
        expect(swapped.failures.values.contains(.tagInvalid), "a changed countersignature is refused")
        expect(swapped.persisted.isEmpty, "nothing is stored")
        // The other end presents this Mac's own key.
        let mirror = runInMemory(TestPairing.participant(a), TestPairing.participant(a))
        expectEqual(mirror.failures[.listener], .selfPairing, "pairing with this Mac's own key is refused")
        // Out of order: a decision before any code.
        var listener = try! ClusterPairingSession(role: .listener, participant: TestPairing.participant(a), hooks: TestPairing.hooks)
        var decision = ClusterPairingMessage(kind: .decision); decision.accept = true; decision.tag = Data(repeating: 0, count: 32)
        let steps = listener.receive(decision)
        expect(steps.contains { if case .failed(.unexpectedMessage) = $0 { return true }; return false }, "a decision before an offer is refused")
        // A newer protocol version.
        var version = Plan()
        version.tamper = { message, _ in var changed = message; if message.kind == .offer { changed.version = 2 }; return changed }
        expectEqual(runInMemory(TestPairing.participant(a), TestPairing.participant(b), plan: version).failures[.listener], .unsupportedVersion,
                    "another protocol version is refused")
    }

    static func ceremonyDeclines() {
        let a = SoftwareIdentity(), b = SoftwareIdentity()
        var plan = Plan(); plan.accept[.connector] = false
        let declined = runInMemory(TestPairing.participant(a), TestPairing.participant(b), plan: plan)
        expectEqual(declined.failures[.connector], .declinedLocally, "the Mac that said no")
        expectEqual(declined.failures[.listener], .declinedByPeer, "the other Mac learns it")
        expect(declined.persisted.isEmpty, "nothing is stored on either Mac")
        expect(ClusterPairingError.declinedLocally.countsAsFailedAttempt && ClusterPairingError.declinedByPeer.countsAsFailedAttempt,
               "a decline counts toward the lockout on both")
        expect(!ClusterPairingError.transport.countsAsFailedAttempt && !ClusterPairingError.rateLimited.countsAsFailedAttempt,
               "a lost link and a rate limit do not")
        var failing = Plan(); failing.persists[.connector] = false
        let partial = runInMemory(TestPairing.participant(a), TestPairing.participant(b), plan: failing)
        expectEqual(partial.failures[.connector], .persistenceFailed, "the Mac that could not store fails")
        expectEqual(partial.failures[.listener], .peerAborted, "the other Mac is told")
        expect(partial.rolledBack.contains(.listener) || !partial.persisted.contains(.listener),
               "the other Mac rolls back what it stored")
        expect(partial.outcomes.isEmpty, "nothing completes")
        var silent = Plan(); silent.decide = false
        let waiting = runInMemory(TestPairing.participant(a), TestPairing.participant(b), plan: silent)
        expect(waiting.codes.count == 2 && waiting.failures.isEmpty, "both wait for a person")
        // With the code on screen, an abort anyone on the link could send is ignored; the other Mac's own counts.
        var listener = waiting.sessions[.listener]!, connector = waiting.sessions[.connector]!
        var forged = ClusterPairingMessage(kind: .abort); forged.reason = "declined"
        expect(listener.receive(try! ClusterPairingMessage.decode(try! forged.encoded())).isEmpty, "an untagged abort is ignored once the code shows")
        forged.tag = Data(repeating: 9, count: 32)
        expect(listener.receive(try! ClusterPairingMessage.decode(try! forged.encoded())).isEmpty, "a wrongly tagged abort too")
        expect(!listener.isFinished, "the listener still waits for its person")
        let ending = connector.fail(.expired)
        guard case .send(let abort)? = ending.first else { expect(false, "the connector sends an abort"); return }
        expect(abort.tag != nil, "the connector's abort is tagged")
        let steps = listener.receive(try! ClusterPairingMessage.decode(try! abort.encoded()))
        expect(steps.contains { if case .failed(.expired) = $0 { return true }; return false }, "the other Mac's tagged abort ends it: \(steps)")
    }
}
