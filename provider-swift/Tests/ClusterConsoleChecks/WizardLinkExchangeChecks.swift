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

        // Commands (the onboarding's leader to a member's cluster service): an open wizard takes none.
        do {
            _ = try X.command(pairing: pairing(local: pinA, peer: pinB), selection: selection, peerAddress: asked.peerAddress,
                body: Data("{\"op\":\"status\"}".utf8), seconds: 10, port: port, policy: .loopbackForTests)
            expect(false, "a wizard must not take a command")
        } catch let failure as ClusterSetupFailure {
            expect(failure.text.contains("takes no commands"), "a wizard refuses commands: \(failure.text)")
        }
        // A cluster service answers each command over the same authenticated channel, and its refusal is named.
        let servicePort: UInt16 = 45_879
        let service = try X.Responder(pairing: pairing(local: pinB, peer: pinA), selection: selection, port: servicePort,
            policy: .loopbackForTests, answer: { .init(report: F.reportB(), facts: facts(pinB)) }, receive: { _ in String(repeating: "e", count: 64) },
            command: { data in
                guard String(decoding: data, as: UTF8.self).contains("serve") else { throw ClusterSetupFailure("this Mac does not follow the Mac that asked") }
                return Data("{\"serving\":true}".utf8)
            })
        try service.start()
        let served = try X.command(pairing: pairing(local: pinA, peer: pinB), selection: selection, peerAddress: nil,
            body: Data("{\"op\":\"serve\"}".utf8), seconds: 10, port: servicePort, policy: .loopbackForTests)
        expectEqual(String(decoding: served.reply, as: UTF8.self), "{\"serving\":true}", "a service's answer arrives whole, found by discovery")
        do {
            _ = try X.command(pairing: pairing(local: pinA, peer: pinB), selection: selection, peerAddress: nil,
                body: Data("{\"op\":\"stop\"}".utf8), seconds: 10, port: servicePort, policy: .loopbackForTests)
            expect(false, "a refused command must fail")
        } catch let failure as ClusterSetupFailure {
            expect(failure.text.contains("does not follow"), "the service's refusal is shown: \(failure.text)")
        }
        do {
            _ = try X.command(pairing: pairing(local: pinA, peer: pinB, secret: Data(repeating: 7, count: 32)), selection: selection, peerAddress: nil,
                body: Data("{\"op\":\"serve\"}".utf8), seconds: 3, port: servicePort, policy: .loopbackForTests)
            expect(false, "a command without the pairing's secret must not be taken")
        } catch {
            expect(true, "a command without the pairing's secret is refused")
        }
        service.stop()

        // A model copy (no manual download for clustering): the Mac that has the model sends it to a cluster service
        // over the same pairing-keyed, encrypted channel; every file is verified there and the folder appears whole.
        try modelCopyOverTheLink(pairing: { pairing(local: $0, peer: $1) }, wrongSecret: pairing(local: pinA, peer: pinB, secret: Data(repeating: 9, count: 32)),
            pinA: pinA, pinB: pinB, selection: selection)

        // Two processes on one Mac asking the same paired Mac at once (the onboarding and the leader's cluster service):
        // the other Mac keeps one live session per edge and a newer one supersedes the older, so each request must wait
        // for the other instead of taking its session away. Both answers arrive.
        let busyPort: UInt16 = 45_881
        let busy = try X.Responder(pairing: pairing(local: pinB, peer: pinA), selection: selection, port: busyPort,
            policy: .loopbackForTests, answer: { usleep(1_500_000); return .init(report: F.reportB(), facts: facts(pinB)) },
            receive: { _ in String(repeating: "e", count: 64) }, command: { data in data })
        try busy.start()
        final class Replies: @unchecked Sendable { let lock = NSLock(); var texts: [String] = []; var failures: [String] = [] }
        let replies = Replies()
        let group = DispatchGroup()
        let asking = pairing(local: pinA, peer: pinB)
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            do {
                let asked = try X.ask(pairing: asking, selection: selection, seconds: 8, port: busyPort, policy: .loopbackForTests)
                replies.lock.withLock { replies.texts.append("report from \(asked.answer.facts.memberID)") }
            } catch {
                replies.lock.withLock { replies.failures.append("the onboarding's ask: \(error)") }
            }
        }
        usleep(300_000)
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            do {
                let reply = try X.command(pairing: asking, selection: selection, peerAddress: nil, body: Data("status".utf8),
                    seconds: 8, port: busyPort, policy: .loopbackForTests)
                replies.lock.withLock { replies.texts.append(String(decoding: reply.reply, as: UTF8.self)) }
            } catch {
                replies.lock.withLock { replies.failures.append("the service's status: \(error)") }
            }
        }
        _ = group.wait(timeout: .now() + 60)
        busy.stop()
        expectEqual(replies.lock.withLock { replies.texts.sorted() }, ["report from \(ClusterSetupMemberFacts.memberID(pin: pinB))", "status"],
            "two requests at once from this Mac both get their answers: \(replies.lock.withLock { replies.failures })")

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

    static func modelCopyOverTheLink(pairing: (String, String) -> ClusterSetupLinkExchange.Pairing, wrongSecret: ClusterSetupLinkExchange.Pairing,
                                     pinA: String, pinB: String, selection: ClusterLinkInterfaceSelection) throws {
        typealias X = ClusterSetupLinkExchange
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".copy-check-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("leader/Tiny-Model-2026-10-13-r1"), store = base.appendingPathComponent("member-store")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        // Larger than the window (32 MiB) and not a multiple of the chunk (4 MiB), plus small files.
        let files: [(String, Data)] = [("config.json", Data("{\"num_hidden_layers\":2}".utf8)),
            ("model-00001-of-00002.safetensors", Data((0..<(37 << 20) + 12_345).map { _ in UInt8.random(in: 0...255, using: &generator) })),
            ("model-00002-of-00002.safetensors", Data((0..<4_000).map { _ in UInt8.random(in: 0...255, using: &generator) })),
            ("tokenizer.json", Data("{}".utf8))]
        var entries = [[String: Any]](), artifactFiles = [ClusterCatalogArtifact.File]()
        for (path, data) in files {
            try data.write(to: source.appendingPathComponent(path))
            let digest = CryptoKitSHA.hex(data)
            entries.append(["path": path, "size_bytes": data.count, "sha256": digest, "role": "weight"])
            artifactFiles.append(.init(path: path, sizeBytes: Int64(data.count), sha256: digest))
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "model_id": "Example/Tiny-Model", "version": "2026-10-13-r1",
            "r2_prefix": "v2/x/2026-10-13-r1", "aggregate_sha256": ClusterCatalogArtifact.aggregateDigest(artifactFiles),
            "total_size_bytes": files.reduce(0) { $0 + $1.1.count }, "file_count": files.count, "files": entries], options: [.sortedKeys])
        try manifest.write(to: source.appendingPathComponent("manifest.json"))
        let artifact = try ClusterCatalogArtifact.parse(manifest: manifest)
        final class Said: @unchecked Sendable { let lock = NSLock(); var lines = [String]() }
        let said = Said()
        let port: UInt16 = 45_883
        let provisioner = ClusterModelProvisionResponder(store: { store }, trust: { _ in nil }, say: { line in said.lock.withLock { said.lines.append(line) } })
        let member = try X.Responder(pairing: pairing(pinB, pinA), selection: selection, port: port, policy: .loopbackForTests,
            answer: { throw ClusterSetupFailure("not asked") }, receive: { _ in "" }, command: { $0 },
            provision: { tag, data in provisioner.handle(tag: tag, data) })
        try member.start()
        defer { member.stop() }
        final class Progress: @unchecked Sendable { let lock = NSLock(); var reports = [(Int64, Int64)]() }
        let progress = Progress()
        let outcome = try X.copyModel(pairing: pairing(pinA, pinB), selection: selection, peerAddress: nil, artifact: artifact, source: source,
            folder: "Tiny-Model-2026-10-13-r1", port: port, policy: .loopbackForTests) { sent, total in progress.lock.withLock { progress.reports.append((sent, total)) } }
        expect(!outcome.alreadyThere && outcome.sentBytes == artifact.totalBytes, "copy: every byte sent once (\(outcome.sentBytes) of \(artifact.totalBytes))")
        let placed = store.appendingPathComponent("Tiny-Model-2026-10-13-r1")
        for (path, data) in files { expect((try? Data(contentsOf: placed.appendingPathComponent(path))) == data, "copy: \(path) arrived byte for byte") }
        expect((try? Data(contentsOf: placed.appendingPathComponent("manifest.json"))) == manifest, "copy: the manifest is placed with the files")
        expect(progress.lock.withLock { progress.reports.last.map { $0.0 == $0.1 } } == true, "copy: progress ends at the total")
        expect(said.lock.withLock { said.lines.contains { $0.contains("in place, every file verified") } }, "copy: the member's service says it verified it")
        // Again: the member has it, nothing is sent.
        let again = try X.copyModel(pairing: pairing(pinA, pinB), selection: selection, peerAddress: nil, artifact: artifact, source: source,
            folder: "Tiny-Model-2026-10-13-r1", port: port, policy: .loopbackForTests) { _, _ in }
        expect(again.alreadyThere && again.sentBytes == 0, "copy: a second copy finds it there and sends nothing")
        // Bytes that do not match the manifest (changed after it was taken): refused on the member, nothing placed.
        let other = store.appendingPathComponent("Tiny-Model-copy")
        var changed = files[1].1; changed[5_000_000] ^= 0x5A
        try changed.write(to: source.appendingPathComponent(files[1].0))
        do {
            _ = try X.copyModel(pairing: pairing(pinA, pinB), selection: selection, peerAddress: nil, artifact: artifact, source: source,
                folder: "Tiny-Model-copy", port: port, policy: .loopbackForTests) { _, _ in }
            expect(false, "copy: changed bytes must be refused")
        } catch {
            expect("\(error)".contains("does not match its manifest digest"), "copy: the member names the digest mismatch: \(error)")
        }
        expect(!FileManager.default.fileExists(atPath: other.path), "copy: no folder appears for a refused copy")
        // Only the paired Mac can send: another secret is never answered.
        do {
            _ = try X.copyModel(pairing: wrongSecret, selection: selection, peerAddress: nil, artifact: artifact, source: source,
                folder: "Tiny-Model-other", port: port, policy: .loopbackForTests) { _, _ in }
            expect(false, "copy: a sender without the pairing's secret must be refused")
        } catch {
            expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent("Tiny-Model-other").path), "copy: nothing from an unpaired sender")
        }
    }
}

import CryptoKit
enum CryptoKitSHA {
    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
