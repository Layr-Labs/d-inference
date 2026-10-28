import Foundation
import DarkbloomClusterPlacement
@testable import InstalledContract

extension ClusterConsoleCheck {
    /// `handoff/TUI-wiring.md` against both screens: a row is wired when one
    /// of them runs or reads its operation, and every line either screen
    /// draws names a row that screen itself has wired.
    static func wizardWiring() throws {
        let table = try String(contentsOf: wiringTable, encoding: .utf8)
        var states = [String: String]()
        for line in table.split(whereSeparator: \.isNewline) where line.hasPrefix("| `") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 5 else { continue }
            states[cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`"))] = cells[cells.count - 2]
        }
        let wizard = Set(ClusterSetupWizardWiring.wired)
        for id in wizard { expect(states[id]?.hasPrefix("wired") == true, "the wizard shows \(id), which the table does not list as wired") }
        for (id, shownBy) in ClusterSetupWizardWiring.reconciledAtLaunch {
            expect(states[id]?.hasPrefix("wired") == true, "intent \(id) is not wired in the table")
            expect(wizard.contains(shownBy), "intent \(id) is shown by \(shownBy), which the wizard has not wired")
        }
        expectEqual(wizard.count, ClusterSetupWizardWiring.wired.count, "a wizard row is listed twice")
        for item in ClusterSetupWizardWiring.unavailable {
            expect(!wizard.contains(item.id), "\(item.id) is both wired and unavailable in the wizard")
            expect(states[item.id] != nil, "the wizard names \(item.id), which the table does not have")
            expect(!item.reason.isEmpty, "\(item.id) has no reason")
        }
        for key in ClusterSetupWizardWiring.keys { expect(wizard.contains(key.wiring), "key \(key.key) runs \(key.wiring), which is not wired") }

        // Every line of every wizard screen names a row the wizard has wired, or is furniture.
        var seen = Set<String>()
        for (name, base) in wizardStates() {
            for help in [false, true] {
                var state = base
                state.size = .init(columns: 120, rows: 400)
                state.showsHelp = help
                for line in ClusterSetupScreen.frame(state).lines {
                    guard case .wired(let id) = line.source else { continue }
                    seen.insert(id)
                    expect(wizard.contains(id), "\(name): a line names \(id), which the wizard has not wired: \(line.text)")
                }
            }
        }
        let missing = wizard.subtracting(seen).subtracting(Set(ClusterSetupWizardWiring.keys.map(\.wiring)))
        expectEqual(missing.sorted(), [], "wired wizard rows no line or key shows")
        // The key line offers nothing no operation backs.
        for (name, state) in wizardStates() {
            let keys = ClusterSetupScreen.keys(state, glyphs: .ascii).text.lowercased()
            for word in ["join", "leave", "drain", "discover", "revoke", "sudo"] {
                expect(!keys.contains(word), "\(name): the key line offers \(word)")
            }
        }
    }

    /// The report's pieces read from the captured outputs of both Macs, the
    /// pairing code, the record and inbox on real files, the stream reader
    /// and the status reading.
    static func wizardObservations() throws {
        typealias F = WizardFixtures
        // Thunderbolt, as each Mac's system_profiler printed it.
        let a = F.thunderboltA, b = F.thunderboltB
        expectEqual(a.receptacles.count, 6, "Mac A has six receptacles")
        let cableA = a.receptacles.first { $0.id == 6 }
        expect(cableA?.connected == true && cableA?.generation == .thunderbolt5 && cableA?.peerModel == "Mac17,7",
            "Mac A's receptacle 6 is a Thunderbolt 5 link to the M5 Max: \(String(describing: cableA))")
        let mini = a.receptacles.first { $0.id == 3 }
        expect(mini?.generation == .thunderbolt4 && mini?.peerName == "Mac mini", "a 40 Gb/s link is Thunderbolt 4 or USB4: \(String(describing: mini))")
        expect(a.receptacles.filter { !$0.connected }.allSatisfy(\.portIsThunderbolt5), "Mac A's idle ports offer 120 Gb/s")
        let cableB = b.receptacles.first { $0.id == 2 }
        expect(cableB?.generation == .thunderbolt5 && cableB?.peerModel == "Mac15,14", "Mac B's receptacle 2 is the link to the M3 Ultra")
        var linkA = F.linkA
        linkA.thunderbolt = a
        expectEqual(linkA.clusterConnection?.id, 6, "\"Thunderbolt 6\" is receptacle 6")
        expectEqual(ClusterSetupThunderbolt.receptacle(ofHardwarePort: "Thunderbolt 2"), 2, "hardware port names a receptacle")
        expect(ClusterSetupThunderbolt.receptacle(ofHardwarePort: "Wi-Fi") == nil, "Wi-Fi names none")
        expect((try? ClusterSetupThunderbolt.parse(systemProfilerJSON: Data("{}".utf8))) == nil, "an empty reading is an error")
        expect((try? ClusterSetupThunderbolt.parse(systemProfilerJSON: Data("not json".utf8))) == nil, "garbage is an error")
        let encoded = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        expect(!encoded.contains("uid") && !encoded.contains("route"), "only the named fields are kept")

        // Pairing codes: the same key gives the same six digits; another key another code.
        let key = Data((0..<51).map { UInt8($0) }).base64EncodedString()
        let other = Data((0..<51).map { UInt8(255 - $0) }).base64EncodedString()
        let pinned = ClusterSetupPairingCodes.pinned(knownHosts: "mac-b.fixture ssh-ed25519 \(key)\n")
        let own = ClusterSetupPairingCodes.own(keyscan: "# 127.0.0.1:22 SSH-2.0-OpenSSH\n127.0.0.1 ssh-ed25519 \(key)\n",
            pinnedKnownHosts: "mac-b.fixture ssh-ed25519 \(key)\n")
        expect(pinned?.code.count == 6 && pinned?.code.allSatisfy(\.isNumber) == true, "a code is six digits")
        expectEqual(pinned?.code, own?.code, "the leader's pinned key and the follower's own key give one code")
        expect(own?.differsFromPin == false, "the same key is not a difference")
        let swapped = ClusterSetupPairingCodes.own(keyscan: "127.0.0.1 ssh-ed25519 \(other)\n", pinnedKnownHosts: "mac-b.fixture ssh-ed25519 \(key)\n")
        expect(swapped?.code != pinned?.code && swapped?.differsFromPin == true, "another key gives another code and is flagged")
        let rsaFirst = ClusterSetupPairingCodes.own(keyscan: "127.0.0.1 ssh-rsa \(other)\n127.0.0.1 ssh-ed25519 \(key)\n", pinnedKnownHosts: nil)
        expectEqual(rsaFirst?.code, pinned?.code, "with no pin both ends use the Ed25519 key")
        expect(ClusterSetupPairingCodes.pinned(knownHosts: "@revoked h ssh-ed25519 \(key)\n") == nil, "a revoked key gives no code")
        expectEqual(ClusterSetupPairingCodes.keyscanType("ecdsa-sha2-nistp256"), "ecdsa", "keyscan names ecdsa")
        expectEqual(ClusterSetupPairingCodes.keyscanType("ssh-ed25519"), "ed25519", "keyscan names ed25519")
        expectEqual(ClusterSetupPairingCodes.code(fingerprint: "SHA256:fixture"), ClusterSetupPairingCodes.code(fingerprint: "SHA256:fixture"), "stable")
        expectEqual(ClusterSetupPairingCode(code: "482913", basis: .pinnedHostKey, algorithm: "ssh-ed25519").spaced, "482 913", "spaced")

        // Model folders from their manifests: a broken one is left out.
        let models = scratch.appendingPathComponent("wizard-models", isDirectory: true)
        try FileManager.default.createDirectory(at: models.appendingPathComponent("Qwen3.5-9B-r1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: models.appendingPathComponent("broken"), withIntermediateDirectories: true)
        try F.data("manifest-qwen35-9b.json").write(to: models.appendingPathComponent("Qwen3.5-9B-r1/manifest.json"))
        try Data("{".utf8).write(to: models.appendingPathComponent("broken/manifest.json"))
        let listed = try ClusterSetupModelFolders.list(parent: models)
        expectEqual(listed.map(\.folder), ["Qwen3.5-9B-r1"], "only readable manifests are listed")
        expectEqual(listed.first?.artifactSHA256, F.models[0].artifactSHA256, "the aggregate digest is the identity")
        expectEqual(ClusterSetupPlanning.tokenizerFiles(manifest: F.data("manifest-qwen35-9b.json")).count, 4, "the 9B pins its tokenizer and template files")

        // The record, on a real owner-only directory: round trip, bounded lists, a foreign schema refused.
        let home = scratch.appendingPathComponent("wizard-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = ClusterSetupStore(paths: .init(paths: try ClusterUserPaths(homeDirectory: home)))
        expectEqual(try store.readRecord(), ClusterSetupRecord(), "no record reads as empty")
        try store.updateRecord { $0.pair = F.recordPair }
        for index in 0..<12 {
            try store.updateRecord { $0.add(.init(code: String(format: "%06d", index), clusterID: "c", at: "t\(index)")) }
        }
        let record = try store.readRecord()
        expectEqual(record.pair, F.recordPair, "the pair is remembered")
        expectEqual(record.confirmed.count, ClusterSetupRecord.kept, "lists are bounded")
        expect(record.confirmed(code: "000011") != nil && record.confirmed(code: "000000") == nil, "the newest are kept")
        var mode = stat()
        expect(stat(store.paths.record.path, &mode) == 0 && mode.st_mode & 0o077 == 0, "the record is owner-only")
        expect(stat(store.paths.directory.path, &mode) == 0 && mode.st_mode & 0o077 == 0, "its directory is owner-only")
        try Data(#"{"schema":"other","confirmed":[],"sent":[],"checks":[]}"#.utf8).write(to: store.paths.record)
        expect((try? store.readRecord()) == nil, "a record of another schema is refused, not replaced")
        try FileManager.default.removeItem(at: store.paths.record)

        // The inbox: a delivery is checked with the strict codecs and kept; nothing else happens.
        let capability = F.data("capability-qwen35-9b.json")
        let digest = ClusterConfigurationCodec.sha256(capability)
        guard let setup = F.decisions.first(where: { $0.option.model.modelID == "Qwen3.5-9B" })?.setup,
              let followerSetup = setup.configurations["mac-b"] else {
            failures.append("the 9B decision wrote no follower setup")
            return
        }
        let delivery = try JSONEncoder().encode(ClusterSetupStore.Delivery(configuration: followerSetup, capability: capability, capabilitySHA256: digest))
        let saved = try store.receive(delivery)
        expect(ClusterConfigurationSyntax.hash(saved), "receiving returns the digest saving would produce")
        expect(store.inboxCandidate?.capabilitySHA256 == digest, "the inbox reads as a candidate for the existing approval")
        let summary = ClusterSetupLocalReader.inbox(store)
        expect(summary.summary?.role == "follower" && summary.summary?.configurationSHA256 == saved && summary.error == nil,
            "the inbox setup reads as the follower's: \(String(describing: summary.summary)) \(summary.error ?? "")")
        let wrongDigest = try JSONEncoder().encode(ClusterSetupStore.Delivery(configuration: followerSetup, capability: capability,
            capabilitySHA256: String(repeating: "0", count: 64)))
        expect((try? store.receive(wrongDigest)) == nil, "a capability that differs from its digest is refused")
        expect((try? store.receive(Data("{}".utf8))) == nil, "a malformed delivery is refused")
        expect((try? store.receive(Data(repeating: 32, count: ClusterSetupStore.Delivery.maximumBytes + 1))) == nil, "an oversized delivery is refused")
        store.clearInbox()
        expect(store.inboxCandidate == nil, "clearing empties the inbox")

        // The stream reader.
        expectEqual(ClusterSetupStream.parse(#"data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#)?.content, "Hi", "content")
        expectEqual(ClusterSetupStream.parse(#"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#)?.finishReason, "length", "finish")
        expectEqual(ClusterSetupStream.parse(#"data: {"choices":[{"delta":{"reasoning":"We need"},"finish_reason":null}]}"#)?.reasoning, true, "reasoning delta")
        expectEqual(ClusterSetupStream.parse(#"data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#)?.reasoning, false, "content delta is not reasoning")
        expectEqual(ClusterSetupStream.parse(#"data: {"choices":[],"usage":{"completion_tokens":8}}"#)?.completionTokens, 8, "usage")
        expectEqual(ClusterSetupStream.parse("data: [DONE]")?.done, true, "done")
        expect(ClusterSetupStream.parse(#"data: {"error":{"message":"Distributed generation did not complete"}}"#)?.error?.contains("did not complete") == true, "error")
        expect(ClusterSetupStream.parse(": keep-alive") == nil && ClusterSetupStream.parse("data: {") == nil, "other lines are ignored")

        // SSH failures in plain words, never OpenSSH's own text (it names the host).
        func ssh(_ text: String, _ status: Int32 = 255) -> String {
            ClusterSetupChild.sshFailure(.init(status: status, output: Data(), error: Data(text.utf8)))
        }
        expect(ssh("Host key verification failed.").contains("host key is not the one the setup pins"), "host key")
        expect(ssh("user@192.0.2.2: Permission denied (publickey).").contains("refused this Mac (developer route)"), "key refused (the developer route's words)")
        expect(ssh("ssh: connect to host 192.0.2.2 port 22: Operation timed out").contains("did not answer"), "timeout")
        expect(ssh("ssh: connect to host 192.0.2.2 port 22: Connection refused").contains("refused the connection") && !ssh("Connection refused").contains("Remote Login"), "refused")
        expect(ssh("zsh: no such file or directory: /x/darkbloom", 127).contains("not installed"), "missing darkbloom")
        expect(!ssh("ssh: connect to host 192.0.2.2 port 22: weird").contains("192.0.2.2"), "the address never shows")

        // A real child: input in, output out, a deadline that ends it.
        let echoed = try ClusterSetupChild.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: Data("setup".utf8),
            seconds: 5, maximumOutputBytes: 1024)
        expect(echoed.status == 0 && echoed.output == Data("setup".utf8), "input reaches the child and its output comes back")
        let started = Date()
        expect((try? ClusterSetupChild.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], seconds: 0.3, maximumOutputBytes: 16)) == nil,
            "a child past its deadline is ended")
        expect(Date().timeIntervalSince(started) < 5, "and the caller is not held")

        // The report decodes as it was encoded, and refuses another schema or an oversized one.
        let report = F.reportA()
        expectEqual(try ClusterSetupReport.decode(try report.encoded()), report, "the report round-trips")
        var foreign = report; foreign.schema = "other"
        expect((try? ClusterSetupReport.decode(try foreign.encoded())) == nil, "another schema is refused")
        expect((try? ClusterSetupReport.decode(Data(repeating: 32, count: ClusterSetupReport.maximumEncodedBytes + 1))) == nil, "oversized is refused")
        let json = String(decoding: try report.encoded(), as: UTF8.self)
        expect(!json.contains("/Users/") && json.range(of: #"\d+\.\d+\.\d+\.\d+"#, options: .regularExpression) == nil,
            "the report carries no path and no address")
    }
}
