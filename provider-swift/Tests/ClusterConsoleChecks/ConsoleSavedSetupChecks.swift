import Foundation
import Darwin
import CryptoKit
import DarkbloomClusterProtocol
@testable import InstalledContract

extension ClusterConsoleCheck {
    /// A saved setup on real files under the scratch directory, built by the
    /// installed-session fixture: fabricated metadata, no weights, no usable key.
    static func installedFixture(_ name: String, pairing: Bool = false) throws -> InstalledFixture {
        try InstalledFixture.make(root: scratch.appendingPathComponent(name), probe: probe, owner: owner, worker: worker, pairing: pairing)
    }

    private static var deadline: UInt64 { DispatchTime.now().uptimeNanoseconds + 5_000_000_000 }

    static func savedSetup() throws {
        expectEqual(ClusterConsoleSavedSetup.read(reference: nil, paths: try ClusterUserPaths(homeDirectory: scratch), deadline: deadline),
            .notConfigured, "no reference is no saved setup")

        let fixture = try installedFixture("saved")
        let saved = ClusterConsoleSavedSetup.read(reference: fixture.reference, paths: fixture.paths, deadline: deadline)
        expectEqual(saved.state, .loaded, "the fixture setup loads: \(saved.error ?? "")")
        expectEqual(saved.configurationSHA256, fixture.reference.sha256, "the setup is identified by its digest")
        let pairing = saved.pairing
        expect(pairing?.clusterID == "installed-fixture" && pairing?.memberID == "peer-0" && pairing?.role == .leader
            && pairing?.localRank == 0 && pairing?.peerID == "peer-1" && pairing?.peerRank == 1 && pairing?.linkDevice == "rdma_en0",
            "the pairing is read from the saved configuration: \(String(describing: pairing))")
        expect(pairing?.trust.knownHostsPinMatches == true && pairing?.trust.identityFileUsable == true && pairing?.trust.error == nil,
            "the trust files are as they were saved")
        expectEqual(pairing?.trust.knownHostsPinSHA256, fixture.configuration.trust.knownHostsSHA256, "the pin shown is the saved one")
        expect(pairing?.pairApproval == nil, "no coordinator approval is saved in this fixture")
        let model = saved.model
        expect(model?.publicModelID == "fixture/public-model" && model?.runtimeModelID == fixture.capability.runtimeModelID
            && model?.artifactSHA256 == fixture.capability.artifactSHA256 && model?.planSHA256 == fixture.configuration.selectedPlanSHA256,
            "the model is the saved capability's")
        expectEqual(model?.stages.map { "\($0.rank):\($0.peerID):\($0.local):\($0.sourceLayerStart)-\($0.sourceLayerEnd)" },
            ["0:peer-0:true:0-4", "1:peer-1:false:4-32"], "each rank's layers come from the selected Plan")
        let installed = saved.installed
        expect(installed?.workerBinary.verified == true && installed?.hasProgressGuard == true && installed?.acceptsStartupDeadline == true,
            "the worker's pin and what its bytes carry are read: \(String(describing: installed))")
        expect(installed?.manifest.verified == true, "the manifest is verified against its pin")
        // The fixture's weight file is listed in the manifest and absent on disk.
        expectEqual(installed?.artifactFiles, .init(expected: 5, present: 4, expectedBytes: Int64(manifestTotal(fixture)),
            missingOrDifferent: ["model.safetensors"]), "manifest files are counted by presence and size")

        // The follower's view of the same cluster.
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.configuration)) as! [String: Any]
        object["role"] = "follower"; object["memberID"] = "peer-1"
        let followerInput = fixture.root.appendingPathComponent("follower.json")
        try JSONSerialization.data(withJSONObject: object).write(to: followerInput)

        // A setup passed in for approval: read, described, and not saved.
        let capabilityInput = fixture.root.appendingPathComponent("capability.json")
        func tree() -> [String] { (try? FileManager.default.subpathsOfDirectory(atPath: fixture.paths.configurationsDirectory.path).sorted()) ?? [] }
        let before = tree()
        let same = ClusterConsoleCandidateSetup.read(.init(configurationInput: fixture.root.appendingPathComponent("input.json"),
            capabilityInput: capabilityInput, capabilitySHA256: fixture.configuration.capabilitySHA256), savedSHA256: fixture.reference.sha256)
        expect(same.error == nil && same.alreadySaved && !same.approvable && same.configurationSHA256 == fixture.reference.sha256,
            "the saved setup passed in again is recognized: \(String(describing: same))")
        let candidate = ClusterConsoleCandidate(configurationInput: followerInput, capabilityInput: capabilityInput,
            capabilitySHA256: fixture.configuration.capabilitySHA256)
        let other = ClusterConsoleCandidateSetup.read(candidate, savedSHA256: fixture.reference.sha256)
        expect(other.approvable && other.pairing?.role == .follower && other.pairing?.memberID == "peer-1" && other.pairing?.peerID == "peer-0",
            "a different setup is approvable and described: \(String(describing: other))")
        expectEqual(tree(), before, "reading a setup for approval saves nothing")
        let wrongPin = ClusterConsoleCandidateSetup.read(.init(configurationInput: followerInput, capabilityInput: capabilityInput,
            capabilitySHA256: String(repeating: "0", count: 64)), savedSHA256: nil)
        expect(wrongPin.error == "Capability input digest differs" && !wrongPin.approvable, "a wrong capability pin is the store's own refusal")
        let garbage = fixture.root.appendingPathComponent("garbage.json")
        try Data("{\"schema\":\"nonsense\"}".utf8).write(to: garbage)
        expect(ClusterConsoleCandidateSetup.read(.init(configurationInput: garbage, capabilityInput: capabilityInput,
            capabilitySHA256: fixture.configuration.capabilitySHA256), savedSHA256: nil).error != nil, "a malformed setup is refused")
        expect(ClusterConsoleCandidateSetup.read(.init(configurationInput: fixture.root.appendingPathComponent("absent.json"),
            capabilityInput: capabilityInput, capabilitySHA256: fixture.configuration.capabilitySHA256), savedSHA256: nil).error != nil,
            "a missing input is refused")

        // Approval is the store's save. The provider pointer update is the one
        // step the full suite covers; here it is observed through the seam.
        var approved: ClusterConfigurationReference?
        let result = ClusterConsoleObserver.result(try ClusterConfigurationStore(paths: fixture.paths).save(
            configurationInput: candidate.configurationInput, capabilityInput: candidate.capabilityInput,
            capabilitySHA256: candidate.capabilitySHA256) { approved = $0 })
        expect(result.succeeded && result.lines[0].contains(ClusterConsoleText.short(other.configurationSHA256 ?? "?"))
            && result.lines[1].contains("Distributed startup remains disabled"), "an approval reports what was saved: \(result.lines)")
        expectEqual(approved?.sha256, other.configurationSHA256, "the digest shown before approval is the one saved")
        expect(tree().count == before.count + 1, "exactly one configuration record was added")
        expect(ClusterConsoleCandidateSetup.read(candidate, savedSHA256: approved?.sha256).alreadySaved, "afterwards it is the saved setup")
        let follower = ClusterConsoleSavedSetup.read(reference: approved, paths: fixture.paths, deadline: deadline)
        expect(follower.pairing?.role == .follower && follower.model?.stages.map(\.local) == [false, true], "the follower owns the second stage")

        // A coordinator approval saved with the setup is shown as what it is.
        let paired = ClusterConsoleSavedSetup.read(reference: try installedFixture("paired", pairing: true).reference,
            paths: try ClusterUserPaths(homeDirectory: scratch.appendingPathComponent("paired")), deadline: deadline)
        expectEqual(paired.pairing?.pairApproval, .init(id: "installed-fixture-approval", model: "fixture/public-model", generation: 1,
            notAfter: "2033-05-18T03:33:20Z", allowedChips: ["Apple M4"]), "the saved pair approval is read field for field")

        // Trust inputs that changed after the save are seen, not assumed.
        let hosts = URL(fileURLWithPath: fixture.configuration.trust.knownHostsFile)
        try Data("bench ssh-ed25519 \(Data("fixture-host-key-blob".utf8).base64EncodedString()) note\n".utf8).write(to: hosts)
        let changed = ClusterConsoleSavedSetup.read(reference: fixture.reference, paths: fixture.paths, deadline: deadline)
        expect(changed.pairing?.trust.knownHostsPinMatches == false, "a known-hosts file that changed no longer matches its pin")
        expectEqual(changed.pairing?.trust.hostKeys.count, 1, "its key is still described")
        chmod(fixture.configuration.trust.identityFile, 0o644)
        let loose = ClusterConsoleSavedSetup.read(reference: fixture.reference, paths: fixture.paths, deadline: deadline)
        expect(loose.pairing?.trust.identityFileUsable == false && loose.pairing?.trust.error?.contains("identity file") == true,
            "an identity file others can read is not usable")
        try FileManager.default.removeItem(at: hosts)
        let gone = ClusterConsoleSavedSetup.read(reference: fixture.reference, paths: fixture.paths, deadline: deadline)
        expect(gone.pairing?.trust.knownHostsPinMatches == nil && gone.pairing?.trust.error?.contains("known-hosts file") == true,
            "a known-hosts file that is gone is unknown, not matching")

        // A reference whose record is gone is unreadable, with the reader's error.
        let dangling = try ClusterConfigurationReference(
            configuration: fixture.paths.configurationURL(sha256: String(repeating: "9", count: 64)).path, sha256: String(repeating: "9", count: 64))
        let unreadable = ClusterConsoleSavedSetup.read(reference: dangling, paths: fixture.paths, deadline: deadline)
        expect(unreadable.state == .unreadable && unreadable.error == "Configuration input does not exist" && unreadable.pairing == nil,
            "an unreadable setup shows nothing but its error: \(String(describing: unreadable.error))")

        // Host keys: the fingerprint OpenSSH prints, and never the host names.
        let blob = Data((0..<51).map { UInt8($0) })
        let expected = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let text = """
            # a comment
            bench-mac-b,192.0.2.10 ssh-ed25519 \(blob.base64EncodedString()) operator@elsewhere
            |1|hashedhostsalt=|hashedhostvalue= ecdsa-sha2-nistp256 \(Data("second".utf8).base64EncodedString())
            @cert-authority *.example ssh-rsa \(Data("authority".utf8).base64EncodedString())
            bench-mac-b ssh-ed25519 \(blob.base64EncodedString())
            malformed line
            host ssh-ed25519 not*base64

            """
        let keys = ClusterConsoleHostKeys.fingerprints(knownHosts: text)
        expectEqual(keys.map(\.algorithm), ["ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa"], "one entry per distinct key, in file order")
        expectEqual(keys.first?.fingerprint, expected, "the fingerprint is the SHA-256 of the key blob, unpadded base64")
        expect(expected.count == 50, "a SHA-256 fingerprint is 43 characters after its prefix")
        let described = String(describing: keys)
        expect(!described.contains("bench-mac-b") && !described.contains("192.0.2.10") && !described.contains("operator"),
            "host names, addresses and comments are not kept")
        expectEqual(ClusterConsoleHostKeys.fingerprints(knownHosts: (0..<20).map { "h ssh-ed25519 \(Data("k\($0)".utf8).base64EncodedString())" }.joined(separator: "\n")).count,
            ClusterConsoleHostKeys.maximumKeys, "a long file is summarized by its first keys")
        expectEqual(ClusterConsoleHostKeys.fingerprints(knownHosts: ""), [], "an empty file has no keys")
    }

    private static func manifestTotal(_ fixture: InstalledFixture) -> Int {
        ((try? JSONSerialization.jsonObject(with: fixture.manifestBytes)) as? [String: Any])?["total_size_bytes"] as? Int ?? -1
    }

    static func linkFixPreview() throws {
        // Tool text for a port that is only a bridge member, and for one with its own address.
        func tools(active: String, ownAddress: Bool, gid: Bool, second: String? = nil) -> ClusterLinkToolRunner {
            let devices = ["rdma_en5", "rdma_en6"].map { name in
                "hca_id:\t\(name)\n\ttransport:\t\t\tThunderbolt (100)\n\t\tport:\t1\n\t\t\tstate:\t\t\t\(name == active || name == second ? "PORT_ACTIVE (4)" : "PORT_DOWN (1)")\n\n"
            }.joined()
            func port(_ name: String) -> String {
                let on = "rdma_" + name == active || "rdma_" + name == second
                return "\(name): flags=8863<UP,BROADCAST,RUNNING> mtu 1500\n"
                    + (on && ownAddress ? "\tinet 192.0.2.10 netmask 0xffffff00 broadcast 192.0.2.255\n" : "")
                    + "\tstatus: \(on ? "active" : "inactive")\n"
            }
            let interfaces = "lo0: flags=8049<UP,LOOPBACK,RUNNING> mtu 16384\n\tinet 127.0.0.1 netmask 0xff000000\n" + port("en5") + port("en6")
                + "bridge0: flags=8863<UP,BROADCAST,RUNNING> mtu 1500\n\tinet 192.0.2.20 netmask 0xffffff00\n\tmember: en5 flags=3<LEARNING,DISCOVER>\n\tmember: en6 flags=3<LEARNING,DISCOVER>\n\tstatus: active\n"
            return { command in
                switch command {
                case .rdmaControlStatus: return .output("enabled\n")
                case .rdmaDeviceList: return .output(devices)
                case .interfaceList: return .output(interfaces)
                case .rdmaDeviceDetail(let device):
                    return .output("hca_id:\t\(device)\n\t\tport:\t1\n\t\t\tstate:\t\t\tPORT_ACTIVE (4)\n\t\t\tGID[  0]:\t\tfe80:0000:0000:0000:0200:5eff:fe00:5307\n"
                        + (gid ? "\t\t\tGID[  2]:\t\t::ffff:192.0.2.10\n" : ""))
                case .defaultRoute: return .output("   route to: default\n  interface: en0\n")
                }
            }
        }
        let bridged = tools(active: "rdma_en6", ownAddress: false, gid: false)
        expectEqual(ClusterLinkReadinessProbe.inspect(run: bridged).state, .portBridgedWithoutAddress, "the fixture is a bridged port without an address")

        var asked = [ClusterLinkToolCommand]()
        let preview = ClusterLinkRepair.previewFix(device: nil, run: { asked.append($0); return bridged($0) }, machineIdentifier: { "FIXTURE-MACHINE" })
        expect(preview.wouldPrompt && preview.device == "rdma_en6" && preview.interface == "en6", "the dry run plans the fix the real one would: \(preview)")
        expectEqual(preview.prompt, "Darkbloom wants to give Thunderbolt port en6 its own address so RDMA can use it.", "it quotes the prompt macOS would show")
        expect(preview.message.contains("Nothing was asked, recorded or changed"), "and says nothing happened")
        let derived = ClusterLinkLocalAddress.derived(machineIdentifier: "FIXTURE-MACHINE", interface: "en6").dottedDecimal
        let encoded = String(decoding: try JSONEncoder().encode(preview), as: UTF8.self)
        expect(!encoded.contains(derived) && !encoded.contains("169.254.") && !preview.summaryLines.joined().contains("169.254."),
            "the address it would use is not shown")
        expect(asked.allSatisfy { $0 != .rdmaDeviceDetail(device: "rdma_en5") } && asked.contains(.defaultRoute),
            "only the read-only tools ran, as far as the real fix reads before its prompt")
        expectEqual(ClusterConsoleObserver.result(preview).lines, preview.summaryLines, "the console shows the preview's own lines")
        expectEqual(preview.summaryLines[0], "Link fix (dry run): would ask for approval", "the first line says it is a dry run")

        // The same stops the real fix makes before any prompt.
        let ready = ClusterLinkRepair.previewFix(device: nil, run: tools(active: "rdma_en6", ownAddress: true, gid: true), machineIdentifier: { "M" })
        expect(!ready.wouldPrompt && ready.message == "The link is already ready; nothing was changed." && ready.prompt == nil, "a ready link needs no prompt")
        let noIdentity = ClusterLinkRepair.previewFix(device: nil, run: bridged, machineIdentifier: { nil })
        expect(!noIdentity.wouldPrompt && noIdentity.message.contains("hardware identifier"), "no machine identifier: stops as the fix does")
        let two = ClusterLinkRepair.previewFix(device: nil, run: tools(active: "rdma_en6", ownAddress: false, gid: false, second: "rdma_en5"), machineIdentifier: { "M" })
        expect(!two.wouldPrompt && two.message.contains("rdma_en5, rdma_en6") && two.message.contains("--device"), "two candidate ports: it names them")
        let named = ClusterLinkRepair.previewFix(device: "rdma_en5", run: tools(active: "rdma_en6", ownAddress: false, gid: false, second: "rdma_en5"), machineIdentifier: { "M" })
        expect(named.wouldPrompt && named.interface == "en5", "a named device is the one planned")
        let unlisted = ClusterLinkRepair.previewFix(device: "rdma_en9", run: bridged, machineIdentifier: { "M" })
        expect(!unlisted.wouldPrompt && unlisted.message.contains("lists no RDMA device with that name"), "an unlisted device is refused")
        let noRoute = ClusterLinkRepair.previewFix(device: nil, run: { $0 == .defaultRoute ? .timedOut : bridged($0) }, machineIdentifier: { "M" })
        expect(!noRoute.wouldPrompt && noRoute.message.contains("could not read"), "an unreadable route state stops before the prompt")

        // Nothing was recorded by any of it, and the alias record is only read.
        let paths = try ClusterUserPaths(homeDirectory: scratch.appendingPathComponent("alias-home"))
        expect(!FileManager.default.fileExists(atPath: paths.deviceDirectory.path), "a dry run creates no record directory")
        expectEqual(try ClusterConsoleLinkAlias.observe(paths: paths, run: bridged), [], "no record, no alias")
        expect(!FileManager.default.fileExists(atPath: paths.deviceDirectory.path), "observing the record creates nothing")
        guard let address = ClusterLinkLocalAddress(dottedDecimal: "169.254.7.9") else { throw ClusterConfigurationError.invalid("fixture address") }
        try ClusterLinkAliasStore(paths: paths).update { $0.set(.init(interface: "en6", address: address)) }
        let record = try Data(contentsOf: paths.deviceDirectory.appendingPathComponent("link-alias.json"))
        expectEqual(try ClusterConsoleLinkAlias.observe(paths: paths, run: bridged), [.init(interface: "en6", presence: .gone)],
            "a recorded address the port no longer carries is reported gone")
        let carrying: ClusterLinkToolRunner = { command in
            guard command == .interfaceList else { return bridged(command) }
            return .output("en6: flags=8863<UP,BROADCAST,RUNNING> mtu 1500\n\tinet 169.254.7.9 netmask 0xffff0000\n\tstatus: active\n")
        }
        expectEqual(try ClusterConsoleLinkAlias.observe(paths: paths, run: carrying), [.init(interface: "en6", presence: .present)], "and present when it does")
        expectEqual(try ClusterConsoleLinkAlias.observe(paths: paths, run: { _ in .timedOut }), [.init(interface: "en6", presence: .unknown)],
            "an unreadable listing is unknown, not gone")
        expectEqual(try Data(contentsOf: paths.deviceDirectory.appendingPathComponent("link-alias.json")), record, "observing never clears a spent entry")
        expect(!String(describing: try ClusterConsoleLinkAlias.observe(paths: paths, run: carrying)).contains("169.254"), "the recorded address is not shown")

        // The real fix's results are shown as its own lines, and the command with the address is not.
        let declined = ClusterConsoleObserver.result(ClusterLinkRepairResult(operation: .fix, outcome: .approvalDeclined, device: "rdma_en6", interface: "en6"))
        expect(!declined.succeeded && declined.lines == ["Link fix: approvalDeclined", "The macOS prompt was cancelled; nothing was changed."], "a declined prompt")
        let unavailable = ClusterConsoleObserver.result(ClusterLinkRepairResult(operation: .fix, outcome: .approvalUnavailable, device: "rdma_en6",
            interface: "en6", manualCommand: "sudo /sbin/ifconfig en6 inet 169.254.7.9 netmask 255.255.0.0 alias"))
        expect(!unavailable.succeeded && !unavailable.lines.joined().contains("169.254") && !unavailable.lines.joined().contains("sudo")
            && unavailable.lines.last?.contains("darkbloom cluster link --fix") == true, "the manual command is pointed to, not shown")
        expect(ClusterConsoleObserver.result(ClusterLinkRepairResult(operation: .fix, outcome: .fixed, device: "rdma_en6", interface: "en6")).succeeded,
            "a verified fix is a success")
    }

    static func recoveryResults() throws {
        let fixture = try installedFixture("recovery")
        let file = fixture.paths.deviceLeaseFile
        let nothing = ClusterConsoleObserver.result(try ClusterDeviceRecovery.recover(paths: fixture.paths))
        expect(nothing.succeeded && nothing.lines == ["Device journal: nothingToRecover", "The device journal is absent or empty. Nothing was changed."],
            "an empty journal: \(nothing.lines)")
        // A journal as an owner records it, left behind by an owner that is gone.
        let epoch = UUID().uuidString.lowercased()
        var record = try JSONSerialization.data(withJSONObject: ["schema": "darkbloom_native_lease_v1", "clusterID": "installed-fixture",
            "leaseID": UUID().uuidString.lowercased(), "ownerIncarnation": UUID().uuidString.lowercased(), "membershipEpoch": epoch,
            "nativeLaunchID": UUID().uuidString.lowercased(), "peerID": "peer-0", "rank": 0], options: [.sortedKeys])
        record.append(10)
        try record.write(to: file); chmod(file.path, 0o600)
        expectEqual(ClusterDeviceJournalObservation.read(paths: fixture.paths), .ownershipUnproven, "the stranded journal is observed")
        let held = open(file.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        expect(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0, "fixture scope lock")
        let refused = ClusterConsoleObserver.result(try ClusterDeviceRecovery.recover(paths: fixture.paths))
        expect(!refused.succeeded && refused.lines[0] == "Device journal: refusedLiveOwner" && refused.lines.last?.contains("Nothing was changed") == true,
            "a live owner: the refusal is shown and counted as a failure")
        _ = flock(held, LOCK_UN); Darwin.close(held)
        let cleared = ClusterConsoleObserver.result(try ClusterDeviceRecovery.recover(paths: fixture.paths))
        expect(cleared.succeeded && cleared.lines.count == 3 && cleared.lines[0] == "Device journal: cleared"
            && cleared.lines[1] == "Recorded session: cluster installed-fixture, member peer-0 rank 0, epoch \(epoch)", "a cleared journal names what it held: \(cleared.lines)")
        expectEqual(ClusterDeviceJournalObservation.read(paths: fixture.paths), .emptyJournal, "and the journal is empty afterwards")
    }
}
