import Foundation
import Darwin
@testable import InstalledContract
import DarkbloomClusterRemote

/// Step 4 over the paired link (no SSH, no typed address): the other Mac's
/// report and facts, and the setup handed to its inbox, through the real link
/// control channel and discovery datagrams on loopback.
extension ClusterConsoleCheck {
    static func wizardLinkExchange() throws {
        typealias F = WizardFixtures
        typealias X = ClusterSetupLinkExchange
        let port: UInt16 = 45_877
        let pinA = "1111222233334444aaaabbbbccccdddd", pinB = "5555666677778888eeeeffff00001111"
        let epoch = "3f1c2a64-8d0b-4c7e-9a51-2b6d7e8f9a01", edge = "8a7b6c5d-4e3f-4a1b-8c2d-0e1f2a3b4c5d"
        let secret = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })
        func pairing(local: String, peer: String, secret: Data = secret) -> X.Pairing {
            .init(localPin: local, peerPin: peer, clusterID: "pair-0123456789ab", linkEpoch: epoch, edgeID: edge,
                  secretFile: "/private/link/edge.secret", secret: secret)
        }
        @Sendable func facts(_ pin: String) -> ClusterSetupMemberFacts {
            .init(memberID: ClusterSetupMemberFacts.memberID(pin: pin), linkAddress: "127.0.0.1", user: "member",
                  ownerExecutable: "/opt/darkbloom/darkbloom", workerExecutable: "/opt/darkbloom/worker/darkbloom-cluster-worker",
                  modelDirectory: "/models/Qwen3.5-9B", runtimeBinarySHA256: String(repeating: "a", count: 64),
                  jacclDevice: "rdma_en5", linkSecretFile: "/private/link/edge.secret")
        }
        guard let selection = try? ClusterLinkInterfaceAdmission.select(interface: "lo0", localAddress: nil, peerAddress: nil,
            policy: .loopbackForTests, inspector: ClusterLinkSystemInterfaceInspector()) else {
            expect(false, "lo0 selection"); return
        }

        // Member IDs come from the pins alone: equal on both Macs, no host or user name.
        expectEqual(ClusterSetupMemberFacts.memberID(pin: pinA), "mac-111122223333", "member ID from the pin")
        let linkEpoch = UUID(uuidString: epoch)!
        expect(X.exchangeEpoch(linkEpoch) != linkEpoch && X.exchangeEpoch(linkEpoch) == X.exchangeEpoch(linkEpoch),
               "the exchange is keyed under its own epoch, the same on both Macs, never the serving epoch")

        final class Inbox: @unchecked Sendable {
            let lock = NSLock(); var received: [Data] = []
            var answer: (@Sendable () throws -> ClusterSetupLinkAnswer)?
        }
        let inbox = Inbox()
        inbox.answer = { .init(report: F.reportB(), facts: facts(pinB)) }
        let responder = try X.Responder(pairing: pairing(local: pinB, peer: pinA), selection: selection, port: port,
            policy: .loopbackForTests, answer: { try inbox.lock.withLock { inbox.answer! }() },
            receive: { data in
                inbox.lock.withLock { inbox.received.append(data) }
                return String(repeating: "d", count: 64)
            })
        try responder.start()
        defer { responder.stop() }

        // The paired Mac asks: found on the link by discovery, answered over the authenticated channel.
        let asked = try X.ask(pairing: pairing(local: pinA, peer: pinB), selection: selection, seconds: 10, port: port, policy: .loopbackForTests)
        expectEqual(asked.answer.facts, facts(pinB), "the other Mac's facts arrive whole")
        expectEqual(asked.answer.report, F.reportB(), "and its wizard report")
        expectEqual(asked.peerAddress, ClusterLinkIPv4Address.loopback, "from the address its discovery answer named")

        // The setup for its inbox: what was sent is what the inbox received, and the digest comes back.
        let delivery = Data("{\"schema\":\"darkbloom_cluster_setup_delivery_v1\"}".utf8)
        let digest = try X.deliver(pairing: pairing(local: pinA, peer: pinB), selection: selection, peerAddress: asked.peerAddress,
            delivery: delivery, seconds: 10, port: port, policy: .loopbackForTests)
        expectEqual(digest, String(repeating: "d", count: 64), "the inbox's digest is returned")
        expectEqual(inbox.lock.withLock { inbox.received }, [delivery], "the inbox received exactly the delivery")

        // A Mac without the pairing's secret is not answered.
        do {
            _ = try X.ask(pairing: pairing(local: pinA, peer: pinB, secret: Data(repeating: 9, count: 32)), selection: selection,
                seconds: 3, port: port, policy: .loopbackForTests)
            expect(false, "a wrong edge secret must not be answered")
        } catch let failure as ClusterSetupFailure {
            expect(failure.text.contains("did not take the paired connection"), "a wrong secret is refused: \(failure.text)")
        }

        // A Mac that answers for another pin is not the paired one.
        inbox.lock.withLock { inbox.answer = { .init(report: F.reportB(), facts: facts("99990000aaaabbbb99990000aaaabbbb")) } }
        do {
            _ = try X.ask(pairing: pairing(local: pinA, peer: pinB), selection: selection, seconds: 10, port: port, policy: .loopbackForTests)
            expect(false, "an answer for another member must be refused")
        } catch let failure as ClusterSetupFailure {
            expect(failure.text.contains("not the one this Mac paired with"), "another member is refused: \(failure.text)")
        }

        // Facts this build does not accept are refused before they reach a setup.
        inbox.lock.withLock { inbox.answer = { var bad = facts(pinB); bad.workerExecutable = "relative/worker"; return .init(report: F.reportB(), facts: bad) } }
        do {
            _ = try X.ask(pairing: pairing(local: pinA, peer: pinB), selection: selection, seconds: 10, port: port, policy: .loopbackForTests)
            expect(false, "a relative path must be refused")
        } catch let failure as ClusterSetupFailure {
            expect(failure.text.contains("does not accept"), "malformed facts are refused: \(failure.text)")
        }

        // The other Mac's own failure is named.
        inbox.lock.withLock { inbox.answer = { throw ClusterSetupFailure("this Mac does not know where its models are") } }
        do {
            _ = try X.ask(pairing: pairing(local: pinA, peer: pinB), selection: selection, seconds: 10, port: port, policy: .loopbackForTests)
            expect(false, "a failing answer must be reported")
        } catch let failure as ClusterSetupFailure {
            expect(failure.text.contains("could not report") && failure.text.contains("models"), "the other Mac's reason is shown: \(failure.text)")
        }

        // Nobody listening: the person is told to open the wizard on the other Mac.
        responder.stop()
        do {
            _ = try X.ask(pairing: pairing(local: pinA, peer: pinB), selection: selection, seconds: 2, port: port, policy: .loopbackForTests)
            expect(false, "nobody answering must fail")
        } catch let failure as ClusterSetupFailure {
            expect(failure.text.contains("open `darkbloom cluster` on the other Mac"), "says what to do: \(failure.text)")
        }

        // The pair description of the guided flow: each member's link secret, no SSH trust; mixed routes refused.
        func member(_ id: String, trust: ClusterConfiguration.Trust?, secret: String?) -> ClusterPairDescription.Member {
            .init(id: id, host: "10.219.1.2", port: 22, user: "member", ownerExecutable: "/opt/darkbloom/darkbloom",
                  workerExecutable: "/opt/darkbloom/worker/darkbloom-cluster-worker", modelDirectory: "/models/Qwen3.5-9B",
                  runtimeBinarySHA256: String(repeating: "a", count: 64), jacclDevice: "rdma_en5", linkAddress: "10.219.1.2",
                  trust: trust, linkSecretFile: secret)
        }
        let link = ClusterPairDescription.LinkControl(port: 47_420, linkEpoch: epoch, edgeID: edge)
        let linked = ClusterPairDescription(schema: ClusterPairDescription.schemaName, clusterID: "pair-0123456789ab", publicModelID: "-",
            capabilitySHA256: String(repeating: "0", count: 64), chunkTokens: 512, requestTimeoutSeconds: 120, coordinatorPort: 52_420,
            members: [member("mac-a", trust: nil, secret: "/a/edge.secret"), member("mac-b", trust: nil, secret: "/b/edge.secret")],
            tokenizerFiles: [], linkControl: link)
        let decoded = try ClusterPairDescription.decode(try JSONEncoder().encode(linked))
        expectEqual(decoded, linked, "a link pair description round-trips")
        let swapped = ClusterSetupPlanning.pairDescription(linked, folder: "Qwen3.8-27B", publicModelID: "m", capabilitySHA256: String(repeating: "1", count: 64),
            tokenizerFiles: [])
        expectEqual(swapped.linkControl, link, "another model folder keeps the link route")
        expectEqual(swapped.members.map(\.linkSecretFile), ["/a/edge.secret", "/b/edge.secret"], "and each member's secret file")
        expect(swapped.members.allSatisfy { $0.trust == nil }, "and no SSH trust")
        let mixed = ClusterPairDescription(schema: ClusterPairDescription.schemaName, clusterID: "pair-0123456789ab", publicModelID: "-",
            capabilitySHA256: String(repeating: "0", count: 64), chunkTokens: 512, requestTimeoutSeconds: 120, coordinatorPort: 52_420,
            members: [member("mac-a", trust: nil, secret: "/a/edge.secret"), member("mac-b", trust: nil, secret: nil)],
            tokenizerFiles: [], linkControl: link)
        do {
            _ = try ClusterPairDescription.decode(try JSONEncoder().encode(mixed))
            expect(false, "a member without its link secret must be refused")
        } catch {
            expect(String(describing: error).contains("link secret"), "names the missing secret: \(error)")
        }
    }
}
