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
        expect(same.error == nil && same.alreadySaved && same.configurationSHA256 == fixture.reference.sha256,
            "the saved setup passed in again is recognized: \(String(describing: same))")
        let candidate = ClusterConsoleCandidate(configurationInput: followerInput, capabilityInput: capabilityInput,
            capabilitySHA256: fixture.configuration.capabilitySHA256)
        let other = ClusterConsoleCandidateSetup.read(candidate, savedSHA256: fixture.reference.sha256)
        expect(other.error == nil && !other.alreadySaved && other.pairing?.role == .follower && other.pairing?.memberID == "peer-1"
            && other.pairing?.peerID == "peer-0", "a different setup is described, with its own digest: \(String(describing: other))")
        guard let shown = other.configurationSHA256 else { throw ClusterConfigurationError.invalid("the fixture setup has no digest") }
        expect(shown != fixture.reference.sha256, "and that digest is not the saved setup's")
        expectEqual(tree(), before, "reading a setup for approval saves nothing")
        let wrongPin = ClusterConsoleCandidateSetup.read(.init(configurationInput: followerInput, capabilityInput: capabilityInput,
            capabilitySHA256: String(repeating: "0", count: 64)), savedSHA256: nil)
        expect(wrongPin.error == "Capability input digest differs" && wrongPin.configurationSHA256 == nil && wrongPin.pairing == nil,
            "a wrong capability pin is the store's own refusal, and nothing is offered")
        let garbage = fixture.root.appendingPathComponent("garbage.json")
        try Data("{\"schema\":\"nonsense\"}".utf8).write(to: garbage)
        expect(ClusterConsoleCandidateSetup.read(.init(configurationInput: garbage, capabilityInput: capabilityInput,
            capabilitySHA256: fixture.configuration.capabilitySHA256), savedSHA256: nil).error != nil, "a malformed setup is refused")
        expect(ClusterConsoleCandidateSetup.read(.init(configurationInput: fixture.root.appendingPathComponent("absent.json"),
            capabilityInput: capabilityInput, capabilitySHA256: fixture.configuration.capabilitySHA256), savedSHA256: nil).error != nil,
            "a missing input is refused")

        // Approval is the store's save, on a held copy of what was shown. The
        // provider pointer update is the one step the full suite covers; here
        // it is observed through the seam.
        let holding = fixture.root.appendingPathComponent("holding")
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func held() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: holding.path)) ?? [] }
        let store = ClusterConfigurationStore(paths: fixture.paths)
        let reviewedBytes = try Data(contentsOf: followerInput)

        // The input is rewritten between the review and the keypress: refused, nothing saved.
        var saves = 0
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]).write(to: followerInput)
        expectEqual(ClusterConsoleCandidateSetup.read(candidate, savedSHA256: nil).configurationSHA256, shown,
            "the same setup spelled differently is the same setup")
        var rewritten = object; rewritten["memberID"] = "peer-0"; rewritten["role"] = "leader"
        try JSONSerialization.data(withJSONObject: rewritten).write(to: followerInput)
        let stale = ClusterConsoleObserver.approve(candidate, expectedSHA256: shown, holdingIn: holding) { _ in
            saves += 1
            throw ClusterConfigurationError.invalid("the save must not be reached")
        }
        expect(!stale.succeeded && stale.lines == ["The setup changed after it was shown, so nothing was saved. Press r and review it again."],
            "a setup that changed after it was shown is refused: \(stale.lines)")
        expect(saves == 0 && tree() == before && held().isEmpty, "the refusal saved nothing and held nothing")
        try reviewedBytes.write(to: followerInput)

        // The originals are replaced while the save runs: the reviewed bytes are what is saved.
        var approved: ClusterConfigurationReference?
        var heldDuringSave = [String](), heldMode: mode_t = 0
        let result = ClusterConsoleObserver.approve(candidate, expectedSHA256: shown, holdingIn: holding) { reviewed in
            saves += 1
            heldDuringSave = held()
            var status = stat()
            if stat(reviewed.configurationInput.path, &status) == 0 { heldMode = status.st_mode & 0o777 }
            expect(reviewed.configurationInput != candidate.configurationInput && reviewed.capabilityInput != candidate.capabilityInput
                && (try? Data(contentsOf: reviewed.configurationInput)) == reviewedBytes, "the save is handed the held copies")
            try JSONSerialization.data(withJSONObject: rewritten).write(to: followerInput)
            return try store.save(configurationInput: reviewed.configurationInput, capabilityInput: reviewed.capabilityInput,
                capabilitySHA256: candidate.capabilitySHA256) { approved = $0 }
        }
        expect(result.succeeded && result.lines.count == 2 && result.lines[0].contains(ClusterConsoleText.short(shown))
            && result.lines[1].hasPrefix("Nothing was started or enabled by saving it"), "an approval reports what was saved: \(result.lines)")
        expectEqual(approved?.sha256, shown, "the digest shown before approval is the one saved, whatever became of the input")
        expect(saves == 1 && heldDuringSave.count == 1 && heldDuringSave[0].hasPrefix("darkbloom-cluster-approval-") && heldMode == 0o600,
            "the copies are private and exist only for the save: \(heldDuringSave), mode \(String(heldMode, radix: 8))")
        expect(held().isEmpty, "and are removed when it returns")
        expect(tree().count == before.count + 1, "exactly one configuration record was added")
        try reviewedBytes.write(to: followerInput)
        expect(ClusterConsoleCandidateSetup.read(candidate, savedSHA256: approved?.sha256).alreadySaved, "afterwards it is the saved setup")
        let follower = ClusterConsoleSavedSetup.read(reference: approved, paths: fixture.paths, deadline: deadline)
        expect(follower.pairing?.role == .follower && follower.model?.stages.map(\.local) == [false, true], "the follower owns the second stage")

        // A save that throws is the action's error, and its copies are removed too.
        let failed = ClusterConsoleObserver.approve(candidate, expectedSHA256: shown, holdingIn: holding) { _ in
            throw ClusterConfigurationError.invalid("fixture save refusal")
        }
        expect(!failed.succeeded && failed.lines == ["fixture save refusal"] && held().isEmpty, "a refused save is shown as the store worded it: \(failed.lines)")
        // A directory that is not there to hold the copies stops the approval before any save.
        let nowhere = ClusterConsoleObserver.approve(candidate, expectedSHA256: shown, holdingIn: fixture.root.appendingPathComponent("absent-holding")) { _ in
            saves += 1
            throw ClusterConfigurationError.invalid("the save must not be reached")
        }
        expect(!nowhere.succeeded && saves == 1 && nowhere.lines.first?.hasPrefix("Cannot hold the reviewed setup for saving") == true,
            "nowhere to hold the copies: \(nowhere.lines)")
        // A save that answers with another setup is a failure, never a quiet success.
        if let saved = try? store.save(configurationInput: fixture.root.appendingPathComponent("input.json"), capabilityInput: capabilityInput,
            capabilitySHA256: fixture.configuration.capabilitySHA256, updateProvider: { _ in }) {
            let mismatch = ClusterConsoleObserver.result(saved, expectedSHA256: shown)
            expect(!mismatch.succeeded && mismatch.lines.count == 1 && mismatch.lines[0].contains("not the one that was shown")
                && mismatch.lines[0].contains(ClusterConsoleText.short(saved.configurationSHA256)), "a different digest saved is said so: \(mismatch.lines)")
            expect(ClusterConsoleObserver.result(saved, expectedSHA256: saved.configurationSHA256).succeeded, "the expected digest is a success")
        } else {
            expect(false, "the fixture setup saves again")
        }

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
        expect(changed.pairing?.trust.hostKeys.map(\.kind) == [.host] && changed.pairing?.trust.hostKeysNotShown == 0, "its key is still described")
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
            @revoked * ssh-ed25519 \(blob.base64EncodedString())
            @unknown-marker bench-mac-b ssh-ed25519 \(Data("unread".utf8).base64EncodedString())
            malformed line
            host ssh-ed25519 not*base64

            """
        let listed = ClusterConsoleHostKeys.fingerprints(knownHosts: text)
        expectEqual(listed.keys.map(\.algorithm), ["ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa", "ssh-ed25519"], "one entry per distinct key and kind, in file order")
        expectEqual(listed.keys.map(\.kind), [.host, .host, .certificateAuthority, .revoked],
            "a certificate authority and a revoked key are not listed as host keys")
        expectEqual(listed.notShown, 0, "nothing is left out of a short file")
        expectEqual(listed.keys.first?.fingerprint, expected, "the fingerprint is the SHA-256 of the key blob, unpadded base64")
        expect(expected.count == 50, "a SHA-256 fingerprint is 43 characters after its prefix")
        let described = String(describing: listed.keys)
        expect(!described.contains("bench-mac-b") && !described.contains("192.0.2.10") && !described.contains("operator"),
            "host names, addresses and comments are not kept")
        let long = ClusterConsoleHostKeys.fingerprints(knownHosts: (0..<20).map { "h ssh-ed25519 \(Data("k\($0)".utf8).base64EncodedString())" }.joined(separator: "\n"))
        expect(long.keys.count == ClusterConsoleHostKeys.maximumKeys && long.notShown == 20 - ClusterConsoleHostKeys.maximumKeys,
            "a long file is shown by its first keys and a count of the rest: \(long.keys.count) and \(long.notShown)")
        let empty = ClusterConsoleHostKeys.fingerprints(knownHosts: "")
        expect(empty.keys.isEmpty && empty.notShown == 0, "an empty file has no keys")
    }

    private static func manifestTotal(_ fixture: InstalledFixture) -> Int {
        ((try? JSONSerialization.jsonObject(with: fixture.manifestBytes)) as? [String: Any])?["total_size_bytes"] as? Int ?? -1
    }

    /// The link fix as the console runs and words it: the repair's own code
    /// over a scripted Mac, with no tool started, no prompt and no file.
    static func linkFixResults() throws {
        final class Mac {
            var record = ClusterLinkAliasRecord()
            var approvals = [ClusterLinkPrivilegedRequest]()
            var recordWrites = 0
            var answer = ClusterLinkApprovalResult.declined
        }
        // Tool text for a Mac whose active port is only a bridge member, or has its own address.
        func tools(ownAddress: Bool, gid: Bool) -> ClusterLinkToolRunner {
            let devices = ["rdma_en5", "rdma_en6"].map { name in
                "hca_id:\t\(name)\n\ttransport:\t\t\tThunderbolt (100)\n\t\tport:\t1\n\t\t\tstate:\t\t\t\(name == "rdma_en6" ? "PORT_ACTIVE (4)" : "PORT_DOWN (1)")\n\n"
            }.joined()
            let interfaces = "lo0: flags=8049<UP,LOOPBACK,RUNNING> mtu 16384\n\tinet 127.0.0.1 netmask 0xff000000\n"
                + "en5: flags=8863<UP,BROADCAST,RUNNING> mtu 1500\n\tstatus: inactive\n"
                + "en6: flags=8863<UP,BROADCAST,RUNNING> mtu 1500\n" + (ownAddress ? "\tinet 192.0.2.10 netmask 0xffffff00 broadcast 192.0.2.255\n" : "") + "\tstatus: active\n"
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
                // No system job is loaded or installed on this scripted Mac.
                case .keeperJob, .keeperJobFile: return .unavailable
                case .keeperJobFileList: return .output("")
                // Link setup v2 reads none of this on a first-version scripted Mac.
                case .hardwarePorts, .networkServiceOrder, .networkServiceInfo, .bridgePreferences, .internetSharingEnabled,
                     .internetSharingDevices, .routeTable, .dnsConfiguration, .dhcpPacket:
                    return .unavailable
                }
            }
        }
        func environment(_ mac: Mac, _ run: @escaping ClusterLinkToolRunner) -> ClusterLinkRepair.Environment {
            .init(toolRunner: { run }, requestApproval: { mac.approvals.append($0); return mac.answer },
                machineIdentifier: { "FIXTURE-MACHINE" }, loadRecord: { mac.record },
                updateRecord: { change in mac.recordWrites += 1; change(&mac.record) }, pause: {})
        }
        let bridged = tools(ownAddress: false, gid: false)
        expectEqual(ClusterLinkReadinessProbe.inspect(run: bridged).state, .portBridgedWithoutAddress, "the scripted Mac has a bridged port without an address")
        let derived = ClusterLinkLocalAddress.derived(machineIdentifier: "FIXTURE-MACHINE", interface: "en6").dottedDecimal

        // A dry run: the commands an approval would run, and nothing asked, recorded or changed.
        let mac = Mac()
        let dry = ClusterLinkRepair.fix(device: nil, mode: .durable, dryRun: true, in: environment(mac, bridged))
        expect(dry.outcome == .dryRun && dry.device == "rdma_en6" && dry.interface == "en6" && dry.durable == true, "the dry run plans the fix the real one would: \(dry.outcome.code)")
        expect(mac.approvals.isEmpty && mac.recordWrites == 0 && mac.record.aliases.isEmpty, "it asked for no approval and recorded nothing")
        let shown = ClusterConsoleObserver.result(dry)
        expect(shown.succeeded && shown.lines == dry.summaryLines && shown.lines[0] == "Link fix: dryRun", "the console shows the dry run's own lines: \(shown.lines.prefix(2))")
        expect(shown.lines.contains("  /bin/launchctl bootstrap system /Library/LaunchDaemons/io.darkbloom.cluster-link.en6.plist")
            && shown.lines.contains { $0.contains("/sbin/ifconfig en6 inet \(derived) netmask 255.255.0.0 alias") },
            "with the exact commands, as `darkbloom cluster link --fix --dry-run` prints them")
        let blind = ClusterDiagnosticRedaction(identifiers: .init())
        expect(shown.lines.allSatisfy { !blind.redact($0).contains(derived) && !blind.redact($0).contains("169.254.") },
            "and an export of those lines carries no address")
        let brief = ClusterLinkRepair.fix(device: nil, mode: .temporary, dryRun: true, in: environment(mac, bridged))
        expect(brief.durable == false && brief.plannedCommands == ["/sbin/ifconfig en6 inet \(derived) netmask 255.255.0.0 alias"],
            "a temporary fix would run the one command that adds the address")
        expect(mac.approvals.isEmpty && mac.recordWrites == 0, "and its dry run asked and recorded nothing either")

        // The real fix's endings, each shown as the repair worded it.
        let ready = ClusterConsoleObserver.result(ClusterLinkRepair.fix(device: nil, mode: .durable, dryRun: false,
            in: environment(mac, tools(ownAddress: true, gid: true))))
        expect(ready.succeeded && ready.lines == ["Link fix: alreadyReady", "The link is already ready; nothing was changed."] && mac.approvals.isEmpty,
            "a ready link needs no prompt: \(ready.lines)")
        let declined = ClusterConsoleObserver.result(ClusterLinkRepair.fix(device: nil, mode: .durable, dryRun: false, in: environment(mac, bridged)))
        expect(!declined.succeeded && declined.lines == ["Link fix: approvalDeclined", "The macOS prompt was cancelled; nothing was changed."], "a declined prompt: \(declined.lines)")
        expectEqual(mac.approvals.map(\.prompt), ["Darkbloom wants to give Thunderbolt port en6 its own address and keep it there so RDMA can use it."],
            "one approval was asked for, with the sentence macOS shows")
        expect(mac.record.aliases.isEmpty, "a declined fix leaves no record behind")
        mac.answer = .unavailable
        let unavailable = ClusterLinkRepair.fix(device: nil, mode: .durable, dryRun: false, in: environment(mac, bridged))
        let pointed = ClusterConsoleObserver.result(unavailable)
        expect(!unavailable.manualCommands.isEmpty && unavailable.manualCommands.allSatisfy { $0.hasPrefix("sudo ") }, "the repair has commands for an administrator")
        expect(!pointed.succeeded && pointed.lines.count == 3 && pointed.lines[0] == "Link fix: approvalUnavailable"
            && !pointed.lines.joined().contains(derived) && !pointed.lines.joined().contains("sudo ")
            && pointed.lines[2].contains("`darkbloom cluster link --fix --dry-run`"), "the screen points to them and shows neither sudo nor the address: \(pointed.lines)")
        mac.answer = .applied
        let unverified = ClusterConsoleObserver.result(ClusterLinkRepair.fix(device: nil, mode: .durable, dryRun: false, in: environment(mac, bridged)))
        expect(!unverified.succeeded && unverified.lines[0] == "Link fix: appliedButNotReady" && unverified.lines[1].contains("is still not ready")
            && unverified.lines[1].contains("is not installed and loaded as written"), "an approved change that did not take is a failure, in the repair's words: \(unverified.lines)")
        let unlisted = ClusterConsoleObserver.result(ClusterLinkRepair.fix(device: "rdma_en9", mode: .durable, dryRun: true, in: environment(mac, bridged)))
        expect(!unlisted.succeeded && unlisted.lines[0] == "Link fix: deviceNotListed", "an unlisted device is refused before anything is planned")

        // The record the fix left is what the probe reports about the port, and what the screen says.
        expect(mac.record.alias(on: "en6") != nil, "the approved fix is on record")
        let recorded = ClusterLinkReadinessProbe.inspect(run: bridged, recorded: mac.record)
        expect(recorded.devices.contains { $0.device == "rdma_en6" && $0.assignedAddress == .missing && $0.addressKept == false },
            "the probe reports the recorded address missing and nothing keeping it")
        let plain = ConsoleFixtures.snapshot(link: recorded).plainLines.joined(separator: "\n")
        expect(plain.contains("en6 does not carry the address Darkbloom has on record for it, and no system job would put it back.")
            && plain.contains("its recorded address is missing") && !plain.contains(derived), "the screen says so, by port name only")

        // The guided setup's reading of a link, which decides what the screen does by itself.
        typealias Setup = ClusterConsoleLinkSetup
        expectEqual(Setup.make(report: ConsoleFixtures.unpluggedLink, mayPrompt: true).next, .awaitConnection, "no cable: wait for one")
        expectEqual(Setup.make(report: ConsoleFixtures.unpluggedLink, mayPrompt: true, dryRun: true).next, .stopped, "a dry run does not wait")
        let attended = Setup.make(report: ConsoleFixtures.bridgedLink, mayPrompt: true)
        expect(attended.next == .fix && attended.fixDevice == "rdma_en6" && attended.lines.last?.contains("install a small system job that keeps it there") == true,
            "a port without an address: the flow plans the fix and says what it installs")
        let unattended = Setup.make(report: ConsoleFixtures.bridgedLink, mayPrompt: false)
        expect(unattended.next == .stopped && unattended.fixDevice == nil && unattended.lines.last?.hasPrefix("Next: run `darkbloom cluster`") == true,
            "unattended, the flow only says what to run")
        let brieflyAttended = Setup.make(report: ConsoleFixtures.bridgedLink, mayPrompt: true, temporary: true)
        expect(brieflyAttended.next == .fix && brieflyAttended.lines.last?.contains("lasts until macOS next removes it") == true, "a temporary fix is worded as one")
        let waiting = Setup.make(report: ConsoleFixtures.lostKeptLink, mayPrompt: true)
        expect(waiting.next == .awaitKeeper && waiting.fixDevice == "rdma_en6" && waiting.lines.last?.hasSuffix("Waiting for it\u{2026}") == true,
            "a lost address whose job is loaded: wait for the job, and know which device the fix would be for")
        expectEqual(Setup.make(report: ConsoleFixtures.lostKeptLink, mayPrompt: false).fixDevice, nil, "unattended, nothing follows the wait")
        expectEqual(Setup.make(report: ConsoleFixtures.lostKeptLink, mayPrompt: true, dryRun: true).next, .fix, "a dry run plans at once")
        expectEqual(Setup.make(report: ConsoleFixtures.lostLink, mayPrompt: true).next, .fix, "a lost address nothing keeps is fixed like a missing one")
        let unkept = Setup.make(report: ConsoleFixtures.temporaryLink, mayPrompt: true)
        expect(unkept.next == .fix && unkept.fixDevice == "rdma_en7", "a ready port whose address nothing keeps: the fix installs the job")
        expectEqual(Setup.make(report: ConsoleFixtures.temporaryLink, mayPrompt: true, temporary: true).next, .ready, "unless a temporary address is what was asked for")
        expectEqual(Setup.make(report: ConsoleFixtures.keptLink, mayPrompt: true).next, .ready, "a kept address is ready")
        expectEqual(Setup.make(report: ConsoleFixtures.readyLink, mayPrompt: true).next, .ready, "an address of the port's own is ready")
        expectEqual(Setup.make(report: ConsoleFixtures.disabledLink, mayPrompt: true).next, .stopped, "RDMA off stops with the probe's guidance")
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
