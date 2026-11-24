import Foundation
import Darwin
import CryptoKit
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
@testable import InstalledContract

struct Failure: Error { let message: String }
func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
private func reject(_ body: () throws -> Void) throws {
    do { try body() } catch is Failure { throw Failure(message: "Assertion in refusal") } catch { return }
    throw Failure(message: "Expected refusal")
}

@main enum ClusterDiagnosticsCheck {
    static func main() throws {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(30); defer { alarm(0) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("diagnostics-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try InstalledFixture.make(root: root, probe: URL(fileURLWithPath: CommandLine.arguments[1]),
            owner: URL(fileURLWithPath: CommandLine.arguments[2]), worker: URL(fileURLWithPath: CommandLine.arguments[3]))
        try validation(f)
        try status(f)
        try discovery(f)
        try journal(f)
        try recovery(f)
        try modeAndServingPolicy(f)
        try earlierReleaseWorker(f)
        try linkFindings()
        print("Cluster diagnostics: read-only leader/follower metadata, closed fresh status, local discovery, journal uncertainty, explicit recovery, generation mode, pair-serving policy and local link findings passed")
    }

    static func tree(_ root: URL) throws -> [String: String] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        var result = [String: String]()
        for url in files {
            var info = stat(); try require(lstat(url.path, &info) == 0, "stat")
            let digest = info.st_mode & S_IFMT == S_IFREG ? ClusterConfigurationCodec.sha256(try Data(contentsOf: url)) : "directory"
            result[String(url.path.dropFirst(root.path.count))] = "\(info.st_mode):\(digest)"
        }
        return result
    }

    static func validation(_ f: InstalledFixture) throws {
        let before = try tree(f.root)
        let value = try DistributedInstalledValidation.validate(reference: f.reference, paths: f.paths,
            deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        try require(value.plan.configuration.role == .leader && value.model.publicModelID == f.configuration.publicModelID, "leader metadata")
        try require(try tree(f.root) == before, "metadata validation wrote files")
        try require(!FileManager.default.fileExists(atPath: f.paths.deviceDirectory.appendingPathComponent("configuration").path), "matrix published")

        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.configuration)) as! [String: Any]
        object["role"] = "follower"; object["memberID"] = "peer-1"
        let input = f.root.appendingPathComponent("follower.json")
        try JSONSerialization.data(withJSONObject: object).write(to: input)
        var reference: ClusterConfigurationReference?
        _ = try ClusterConfigurationStore(paths: f.paths).save(configurationInput: input,
            capabilityInput: f.root.appendingPathComponent("capability.json"), capabilitySHA256: f.configuration.capabilitySHA256) { reference = $0 }
        let followerBefore = try tree(f.root)
        let follower = try DistributedInstalledValidation.validate(reference: reference!, paths: f.paths,
            deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        try require(follower.plan.configuration.role == .follower && follower.plan.localPeer.rank == 1, "follower local selection")
        try require(try tree(f.root) == followerBefore, "follower validation wrote files")
        try reject { _ = try DistributedInstalledValidation.validate(reference: reference!, paths: f.paths, deadline: 1) }
        let fallback = value.model.directory.appendingPathComponent("chat_template.json")
        try Data("{}".utf8).write(to: fallback)
        let refusalBefore = try tree(f.root)
        try reject { _ = try DistributedInstalledValidation.validate(reference: f.reference, paths: f.paths,
            deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000) }
        try require(try tree(f.root) == refusalBefore, "refused metadata wrote files")
        try FileManager.default.removeItem(at: fallback)
    }

    static func status(_ f: InstalledFixture) throws {
        let binding = try ClusterStatusBinding(configuration: f.configuration, capability: f.capability)
        let nonce = UUID().uuidString.lowercased(), epoch = UUID().uuidString.lowercased()
        let sample = ClusterLiveStatus(schema: ClusterLiveStatus.schemaName, nonce: nonce, binding: binding,
            authenticationConfigured: true, hostPhase: "serving", session: .init(binding: binding, phase: "ready",
                observedMembershipEpoch: epoch, observedPrefillSchedule: .serial, observedGenerationMode: .pipeline, ready: true,
                admission: .init(requestsServed: 0, keepWarmExchanges: 0, activeRequest: false, draining: false, valid: true),
                members: (0..<2).map { .init(peerID: "peer-\($0)", rank: $0, transport: $0 == 0 ? .localPipes : .authenticatedSSH,
                    nativeReady: true, requestCapacityBytes: 1024, nativeCleanupObserved: false, ownerReleaseAcknowledged: false, ownerTermination: nil) },
                mtpEnabled: false, mtpOffReason: "runtimeCapabilityDisablesSpeculation",
                nativeBootstrap: .directNative, collectiveProgressLimitMilliseconds: 60_000),
            boundPort: 8000, acquisitions: 0, failed: false, ready: true, admissionAvailable: true, quarantined: false)
        func decode(_ bytes: Data, auth: Bool = true) throws -> ClusterLiveStatus {
            try ClusterStatusCodec.decode(bytes, nonce: nonce, binding: binding, authenticationConfigured: auth, port: 8000)
        }
        let encoded = try ClusterStatusCodec.encode(sample)
        try require(try decode(encoded) == sample, "round trip")
        func changed(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]; change(&object)
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]); data.append(10); return data
        }
        let noAuth = try changed { $0["authenticationConfigured"] = false }
        try require(try !decode(noAuth, auth: false).authenticationConfigured, "explicit no-auth rejected")
        try reject { _ = try decode(noAuth) }
        for field in ["nonce", "schema", "hostPhase"] {
            try reject { _ = try decode(changed { $0[field] = "wrong" }) }
        }
        try reject { _ = try decode(changed { $0["unknown"] = true }) }
        try reject { _ = try decode(changed { $0["acquisitions"] = true }) }
        try reject { _ = try decode(changed { $0["boundPort"] = 8001 }) }
        try reject { _ = try decode(changed { $0["ready"] = false }) }
        try reject { _ = try decode(changed { var b = $0["binding"] as! [String: Any]; b["planSHA256"] = String(repeating: "0", count: 64); $0["binding"] = b }) }
        // Counters only: no lifetime or request count exists to report; a
        // negative counter or a retired field is refused.
        for (key, value) in [("requestsServed", -1), ("keepWarmExchanges", -1), ("remainingRequests", 16), ("remainingLifetimeNanoseconds", 1)] {
            try reject { _ = try decode(changed { var s = $0["session"] as! [String: Any]; var a = s["admission"] as! [String: Any]; a[key] = value; s["admission"] = a; $0["session"] = s }) }
        }
        try reject { _ = try decode(changed { var s = $0["session"] as! [String: Any]; s["observedPrefillSchedule"] = "one_chunk_lookahead_v1"; $0["session"] = s }) }
        try reject { _ = try decode(changed { var s = $0["session"] as! [String: Any]; s["mtpEnabled"] = true; $0["session"] = s }) }
        // The running mode is the saved one, and is reported only with an epoch.
        try require(sample.binding.generationMode == .pipeline && sample.session.observedGenerationMode == .pipeline, "generation mode missing from status")
        try reject { _ = try decode(changed { var s = $0["session"] as! [String: Any]; s["observedGenerationMode"] = "phase_split_v1"; $0["session"] = s }) }
        try reject { _ = try decode(changed { var s = $0["session"] as! [String: Any]; s.removeValue(forKey: "observedGenerationMode"); $0["session"] = s }) }
        try reject { _ = try decode(changed { var b = $0["binding"] as! [String: Any]; b["generationMode"] = "phase_split_v1"; $0["binding"] = b }) }
        // A resident tensor assistant runs under the tensor-parallel mode, which names no head: the saved
        // setup's binding carries its speculation, so the session reports MTP on and the leader reads it.
        try require(!binding.speculationEnabled && binding.speculationOffReason
            == DistributedInstalledSpeculation(configuration: f.configuration, capability: f.capability).offReason,
            "the binding's speculation is not the session's")
        func assisted(_ object: [String: Any]) -> [String: Any] {
            var object = object; object["speculationEnabled"] = true; object["speculationOffReason"] = "none"
            object["generationMode"] = ClusterGenerationMode.tensorParallel.rawValue; return object
        }
        let assistedBinding = try JSONDecoder().decode(ClusterStatusBinding.self, from: JSONSerialization.data(withJSONObject:
            assisted(try JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as! [String: Any])))
        func assistedStatus(mtp: Bool) throws -> Data {
            try changed { object in
                object["binding"] = assisted(object["binding"] as! [String: Any])
                var s = object["session"] as! [String: Any]
                s["binding"] = assisted(s["binding"] as! [String: Any]); s["observedGenerationMode"] = ClusterGenerationMode.tensorParallel.rawValue
                s["mtpEnabled"] = mtp; s["mtpOffReason"] = mtp ? "none" : "generationModeRunsNoHead"; object["session"] = s
            }
        }
        try require(try ClusterStatusCodec.decode(assistedStatus(mtp: true), nonce: nonce, binding: assistedBinding,
            authenticationConfigured: true, port: 8000).session.mtpEnabled, "a running tensor assistant is refused as stale")
        try reject { _ = try ClusterStatusCodec.decode(assistedStatus(mtp: false), nonce: nonce, binding: assistedBinding,
            authenticationConfigured: true, port: 8000) }
        try reject { _ = try decode(assistedStatus(mtp: true)) }
        // The direct native bootstrap cannot be reported as owner-authenticated.
        try require(!sample.session.nativeBootstrapOwnerAuthenticated && String(decoding: encoded, as: UTF8.self).contains("\"nativeBootstrap\":\"directNative\""), "bootstrap honesty missing from status")
        try reject { _ = try decode(changed { var s = $0["session"] as! [String: Any]; s["nativeBootstrapOwnerAuthenticated"] = true; $0["session"] = s }) }
        try reject { _ = try decode(changed { var s = $0["session"] as! [String: Any]; s.removeValue(forKey: "nativeBootstrap"); $0["session"] = s }) }
        try reject { _ = try decode(changed { var s = $0["session"] as! [String: Any]; s["collectiveProgressLimitMilliseconds"] = 0; $0["session"] = s }) }
        try reject { _ = try decode(changed { var s = $0["session"] as! [String: Any]; var m = s["members"] as! [[String: Any]]; m[1]["ownerReleaseAcknowledged"] = true; s["members"] = m; $0["session"] = s }) }
        let text = String(decoding: encoded, as: UTF8.self)
        try reject { _ = try decode(Data(text.replacingOccurrences(of: "\"acquisitions\":0", with: "\"acquisitions\":0,\"acquisitions\":0").utf8)) }
        try reject { _ = try decode(Data(text.replacingOccurrences(of: "\"acquisitions\":0", with: "\"acquisitions\":0.0").utf8)) }
        try reject { _ = try decode(Data(repeating: 32, count: ClusterStatusCodec.maximumBytes + 1)) }
    }

    static func discovery(_ f: InstalledFixture) throws {
        func record(host: String, base: String? = nil, key: String = "fixture-bearer") throws -> ClusterStatusDiscovery {
            let advertised = host == "0.0.0.0" || host.isEmpty ? "127.0.0.1" : host
            return try JSONDecoder().decode(ClusterStatusDiscovery.self, from: JSONSerialization.data(withJSONObject:
                ["host": host, "port": 8000, "base_url": base ?? "http://\(advertised):8000/v1", "api_key": key]))
        }
        let assigned: Set<String> = ["127.0.0.1", "::1", "192.0.2.24"]
        for host in ["127.0.0.1", "0.0.0.0", "::", "::1", "localhost", "192.0.2.24"] {
            let url = try record(host: host).endpoint(localAddresses: assigned)
            try require(url.path == "/v1/cluster/status" && url.port == 8000, "local address refused")
        }
        try reject { _ = try record(host: "192.0.2.25").endpoint(localAddresses: assigned) }
        try reject { _ = try record(host: "other.example").endpoint(localAddresses: assigned) }
        try reject { _ = try record(host: "127.0.0.1", base: "http://remote.example:8000/v1").endpoint(localAddresses: assigned) }
        try reject { _ = try record(host: "127.0.0.1", base: "http://127.0.0.1:8000/v1?redirect=1").endpoint(localAddresses: assigned) }
        try reject { _ = try record(host: "127.0.0.1", key: "bad\nkey").endpoint(localAddresses: assigned) }
        try require(try record(host: "127.0.0.1", key: "").endpoint(localAddresses: assigned).port == 8000, "no-auth discovery")
        let link = f.root.appendingPathComponent("discovery-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: f.root.appendingPathComponent("input.json").path)
        try reject { _ = try ClusterStatusDiscovery.read(link) }
    }

    /// `cluster recover` against this fixture's device directory. Runs after
    /// `journal`, which leaves bytes no build wrote in the journal.
    static func recovery(_ f: InstalledFixture) throws {
        let file = f.paths.deviceLeaseFile
        func size() -> Int { ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.intValue ?? -1 }
        let unreadable = try ClusterDeviceRecovery.recover(paths: f.paths)
        try require(unreadable.outcome == .refusedUnreadable && !unreadable.journalEmpty && !unreadable.recoveryPerformed && size() > 0,
            "recovery cleared bytes it could not interpret")
        // A journal as an owner records it, left behind by an owner that is gone.
        let epoch = UUID().uuidString.lowercased()
        func strand() throws {
            var record = try JSONSerialization.data(withJSONObject: ["schema": "darkbloom_native_lease_v1", "clusterID": "installed-fixture",
                "leaseID": UUID().uuidString.lowercased(), "ownerIncarnation": UUID().uuidString.lowercased(), "membershipEpoch": epoch,
                "nativeLaunchID": UUID().uuidString.lowercased(), "peerID": "peer-0", "rank": 0], options: [.sortedKeys])
            record.append(10)
            try record.write(to: file) // Same inode: the fixture's own stand-in for a dead owner.
            chmod(file.path, 0o600)
        }
        try FileManager.default.removeItem(at: file); try Data().write(to: file); chmod(file.path, 0o600)
        try require(try ClusterDeviceRecovery.recover(paths: f.paths).outcome == .nothingToRecover, "empty journal needed recovery")
        try strand()
        try require(ClusterDeviceJournalObservation.read(paths: f.paths) == .ownershipUnproven, "stranded journal not observed")
        // While a process holds the device scope, recovery refuses and changes nothing.
        let held = open(file.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try require(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0, "fixture scope lock")
        let live = try ClusterDeviceRecovery.recover(paths: f.paths)
        try require(live.outcome == .refusedLiveOwner && !live.journalEmpty && !live.recoveryPerformed && size() > 0, "recovery ignored a live device scope")
        _ = flock(held, LOCK_UN); Darwin.close(held)
        let cleared = try ClusterDeviceRecovery.recover(paths: f.paths)
        try require(cleared.outcome == .cleared && cleared.journalEmpty && cleared.recoveryPerformed && size() == 0, "stranded journal was not cleared")
        try require(cleared.record == .init(clusterID: "installed-fixture", peerID: "peer-0", rank: 0, membershipEpoch: epoch), "recovery did not name what it cleared")
        try require(ClusterDeviceJournalObservation.read(paths: f.paths) == .emptyJournal, "journal not empty after recovery")
        let again = try ClusterDeviceRecovery.recover(paths: f.paths)
        try require(again.outcome == .nothingToRecover && again.journalEmpty && !again.recoveryPerformed, "recovery is not idempotent")
        let encoded = String(decoding: try JSONEncoder().encode(cleared), as: UTF8.self)
        try require(encoded.contains("\"schema\":\"darkbloom_cluster_recovery_v1\"") && encoded.contains("\"outcome\":\"cleared\""), "recovery report shape")
        let refused = ClusterDeviceRecovery.report(.refusedLiveWorker(processIdentifier: 77, record: .init(clusterID: "c", peerID: "p", rank: 1,
            membershipEpoch: epoch, leaseID: epoch, ownerIncarnation: epoch, nativeLaunchID: epoch)))
        try require(refused.outcome == .refusedLiveWorker && refused.liveProcessIdentifier == 77 && !refused.journalEmpty && !refused.recoveryPerformed,
            "a running recorded worker must be reported, not cleared")
    }

    /// What the status binding shows of the mode, and what `cluster doctor`
    /// says about a model or a chip a pair does not serve. Each fixture is a
    /// leader, rank 0 of two: the pipeline-only rank under every grant.
    static func modeAndServingPolicy(_ f: InstalledFixture) throws {
        func validation(_ fixture: InstalledFixture, chip: String = "Apple M3 Ultra") -> [ClusterDiagnosticsReport.Check] {
            ClusterInstalledMetadataChecks.localInstalledMetadata(reference: fixture.reference, paths: fixture.paths,
                deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000, localChipClass: ClusterChipClass(chipName: chip))
        }
        let ordinary = validation(f)
        try require(ordinary.map(\.name) == ["localInstalledMetadata"] && ordinary[0].outcome == .passed, "ordinary setup: \(ordinary.map(\.detail))")
        let all: [ClusterGenerationMode] = [.pipeline, .pipelineCompactDecode, .phaseSplit]
        let split = try InstalledFixture.make(root: f.root.appendingPathComponent("doctor-split"), probe: f.probe, owner: f.owner, worker: f.worker,
            generationMode: "phase_split_v1", advertisedModes: all)
        let shown = try ClusterStatusBinding(configuration: split.configuration, capability: split.capability)
        try require(shown.generationMode == .phaseSplit && shown.peers.map(\.supportedGenerationModes) == [all, all], "the binding does not show the mode and each worker's support")
        try require(validation(split).first?.outcome == .passed, "an advertised mode failed the doctor")
        // MTP on by default: the session reports it from the saved mode and what both workers advertise.
        try require(DistributedInstalledSpeculation(mode: .phaseSplitMTP, everyMemberAdvertisesHead: true)
            == .init(enabled: true, offReason: "none")
            && DistributedInstalledSpeculation(mode: .phaseSplit, everyMemberAdvertisesHead: true).offReason == "setupSelectsPhaseSplitWithoutHead"
            && DistributedInstalledSpeculation(mode: .pipeline, everyMemberAdvertisesHead: true).offReason == "generationModeRunsNoHead"
            && DistributedInstalledSpeculation(mode: .phaseSplit, everyMemberAdvertisesHead: false).offReason == "runtimeCapabilityDisablesSpeculation",
            "MTP posture differs from the saved mode")
        let head: [ClusterGenerationMode] = [.pipeline, .pipelineCompactDecode, .phaseSplit, .phaseSplitMTP]
        let speculative = try InstalledFixture.make(root: f.root.appendingPathComponent("doctor-mtp"), probe: f.probe, owner: f.owner, worker: f.worker,
            generationMode: "phase_split_mtp_v1", advertisedModes: head)
        try require(speculative.capability.speculation == ClusterRuntimeCapability.decodingRankSpeculation
            && DistributedInstalledSpeculation(configuration: speculative.configuration, capability: speculative.capability).enabled,
            "a setup naming the speculative phase split does not report MTP on")
        try require(validation(speculative).first?.outcome == .passed, "the speculative phase split failed the doctor")
        // The 27B is saved only in tensor parallel, the one mode that keeps its images, video and committed-token logprobs.
        let big = try InstalledFixture.make(root: f.root.appendingPathComponent("doctor-27b"), probe: f.probe, owner: f.owner, worker: f.worker,
            generationMode: ClusterGenerationMode.tensorParallel.rawValue, advertisedModes: all + [.tensorParallel],
            registered: ("registered_qwen38_27b", "registered_qwen38_27b_greedy_generation_v1", "EigenLabs/Qwen3.8-27B-4bit-mtp"))
        // The owner's serving (2026-10-14 08:45): any Apple silicon runs any rank of the 27B, and the doctor passes it.
        for chip in ["Apple M3 Ultra", "Apple M5 Max", "Apple M4 Max"] {
            let granted = validation(big, chip: chip)
            try require(granted.map(\.name) == ["localInstalledMetadata"] && granted[0].outcome == .passed,
                "the 27B failed the doctor on \(chip): \(granted.map { "\($0.name) \($0.outcome) \($0.detail)" })")
        }
        // A chip with no class is a policy refusal; the metadata still passed.
        let refused = validation(big, chip: "Apple M1 (Virtual)")
        try require(refused.map(\.name) == ["pairServingPolicy", "localInstalledMetadata"] && refused[0].outcome == .failed
            && refused[1].outcome == .passed, "a classless chip was not reported as policy: \(refused.map(\.name))")
        try require(refused[0].detail.contains("EigenLabs/Qwen3.8-27B-4bit-mtp") && refused[0].detail.contains("policy decision"),
            "policy refusal text: \(refused[0].detail)")
        // The 9B led by the M5 Max: no role is tied to a chip.
        try require(validation(f, chip: "Apple M5 Max").map(\.name) == ["localInstalledMetadata"], "9B led by the M5 Max was refused")
        // GPT-OSS at cut 4 (the fixture's): the M3 Ultra ran rank 0 at cut 4 in a check that diverged, so its rank is a
        // policy refusal there and nowhere else.
        let gpt = try InstalledFixture.make(root: f.root.appendingPathComponent("doctor-gptoss"), probe: f.probe, owner: f.owner, worker: f.worker,
            registered: ("registered_gpt_oss_20b", "registered_gpt_oss_20b_greedy_generation_v1", "fixture/gpt-oss"), adapter: .gptossLayerStage)
        let steered = validation(gpt, chip: "Apple M3 Ultra")
        try require(steered.first?.name == "pairServingPolicy" && steered[0].detail.contains("diverged from its single-Mac reference"),
            "GPT-OSS's diverged rank-shape on the M3 Ultra: \(steered.map(\.detail))")
        try require(validation(gpt, chip: "Apple M4 Max").map(\.name) == ["localInstalledMetadata"], "GPT-OSS on an M4 Max was refused")
    }

    /// A pair set up before this Mac updated, and stopped since: its saved setup still pins the worker of the release
    /// the update replaced, which the kept rollback copy holds. The doctor says WARN for that alone; a pin that is no
    /// earlier release's worker, or any other pinned file that differs, stays a failure.
    static func earlierReleaseWorker(_ f: InstalledFixture) throws {
        let root = f.root.appendingPathComponent("doctor-updated", isDirectory: true)
        let app = root.appendingPathComponent("app", isDirectory: true), kept = root.appendingPathComponent("kept", isDirectory: true)
        // The app and its kept copy have the umask's folder modes, as the installer and `snapshotLiveAsPredecessor` leave them.
        for (directory, mode) in [(root, 0o700), (app, 0o755), (kept, 0o755)] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: mode])
        }
        // The setup pins the worker this Mac ran when the pair was set up (the probe stands for it).
        let installed = app.appendingPathComponent("darkbloom-cluster-worker")
        let earlier = kept.appendingPathComponent("darkbloom-cluster-worker")
        try FileManager.default.copyItem(at: f.probe, to: installed)
        try FileManager.default.copyItem(at: f.probe, to: earlier)
        let pair = try InstalledFixture.make(root: root.appendingPathComponent("setup"), probe: installed, owner: f.owner, worker: f.worker)
        // `signed` stands in for this provider's signature check of the installed worker (nil: this check binary's own,
        // which has no Developer ID and so never vouches for a worker).
        // `own`: this build's own worker, the one in the running app (the installed one here, as on a Mac whose setup
        // the app planned).
        var asked: [URL] = []
        func doctor(_ earlier: ClusterInstalledMetadataChecks.EarlierRelease?, signed: Bool? = nil,
                    own: URL? = installed) -> [ClusterDiagnosticsReport.Check] {
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000, chip = ClusterChipClass(chipName: "Apple M3 Ultra")
            guard let signed else {
                return ClusterInstalledMetadataChecks.localInstalledMetadata(reference: pair.reference, paths: pair.paths,
                    deadline: deadline, localChipClass: chip, earlier: earlier, thisBuildsWorker: own)
            }
            return ClusterInstalledMetadataChecks.localInstalledMetadata(reference: pair.reference, paths: pair.paths,
                deadline: deadline, localChipClass: chip, earlier: earlier, thisBuildsWorker: own,
                signedWorker: { asked.append($0); return signed })
        }
        let release = ClusterInstalledMetadataChecks.EarlierRelease(version: "0.10.17", worker: earlier)
        try require(doctor(release).map(\.outcome) == [.passed], "a setup on the installed worker: \(doctor(release).map(\.detail))")

        // The update replaces the installed worker (another build's bytes); the pair was stopped, so nothing re-planned it.
        try FileManager.default.removeItem(at: installed)
        try FileManager.default.copyItem(at: f.owner, to: installed)
        let warned = doctor(release)
        try require(warned.map(\.name) == ["localInstalledMetadata"] && warned[0].outcome == .warning
            && warned[0].detail == ClusterInstalledMetadataChecks.earlierWorkerDetail("0.10.17") && warned[0].detail.contains("Darkbloom 0.10.17"),
            "a setup pinning the earlier release's worker: \(warned.map { "\($0.outcome) \($0.detail)" })")
        let encoded = String(decoding: try JSONEncoder().encode(warned[0]), as: UTF8.self)
        try require(encoded.contains("\"outcome\":\"warning\""), "warning shape: \(encoded)")

        // No kept copy, or one whose worker is not the pinned one: the pin is no earlier release's worker.
        try require(doctor(nil).map(\.outcome) == [.failed] && doctor(nil)[0].detail.contains("Installed input identity or SHA-256 differs"),
            "no earlier release: \(doctor(nil).map(\.detail))")
        let other = ClusterInstalledMetadataChecks.EarlierRelease(version: "0.10.17", worker: f.worker)
        try require(doctor(other).map(\.outcome) == [.failed], "a kept worker that is not the pinned one: \(doctor(other).map(\.detail))")
        let missing = ClusterInstalledMetadataChecks.EarlierRelease(version: "0.10.17", worker: kept.appendingPathComponent("absent"))
        try require(doctor(missing).map(\.outcome) == [.failed], "a kept copy without a worker")

        // More than one update while the pair was stopped: the kept copy is a later release than the pinned one. With
        // the installed worker signed like this provider, a warning that names no release; unsigned (foreign or
        // changed), or in a build that can't tell, a failure.
        let several = doctor(other, signed: true)
        try require(several.map(\.outcome) == [.warning] && several[0].detail == ClusterInstalledMetadataChecks.anotherBuildsWorkerDetail,
            "a pin older than the kept copy, the installed worker signed: \(several.map { "\($0.outcome) \($0.detail)" })")
        try require(asked.map(\.standardizedFileURL) == [installed.standardizedFileURL], "the installed worker was not the one checked: \(asked)")
        try require(doctor(nil, signed: true).map(\.outcome) == [.warning], "no kept copy, the installed worker signed")
        try require(doctor(other, signed: false).map(\.outcome) == [.failed] && doctor(nil, signed: false).map(\.outcome) == [.failed],
            "an installed worker not signed like this provider")
        try require(!DistributedInstalledHelperSignature.current.signsWorker(installed) && doctor(other).map(\.outcome) == [.failed],
            "a build without this project's Developer ID vouched for a worker")
        // A signed provider refuses a worker its certificate didn't sign (here an unsigned one: the launch's strict check).
        let someoneElse = DistributedInstalledHelperSignature.signed(.init(leafSHA1: Data(repeating: 1, count: 20),
            identifier: "io.darkbloom.provider", cdhash: Data(repeating: 2, count: 20), team: DistributedInstalledHelperSignature.releaseTeam))
        try require(!someoneElse.signsWorker(installed), "a worker another certificate signed was vouched for")
        // The setup names a worker other than this build's own (a second app, a worker outside the app): the next start
        // would pin that one, so no warning, signed or not.
        try require(doctor(other, signed: true, own: kept.appendingPathComponent("darkbloom-cluster-worker")).map(\.outcome) == [.failed]
            && doctor(other, signed: true, own: nil).map(\.outcome) == [.failed], "a worker that isn't this build's own was vouched for")
        // The kept copy's rule comes first: it names the release.
        try require(doctor(release, signed: true).map(\.detail) == [ClusterInstalledMetadataChecks.earlierWorkerDetail("0.10.17")],
            "the kept copy's release was not named")

        // Another pinned file differs as well: the setup is not only an earlier release's.
        let tokenizer = URL(fileURLWithPath: pair.configuration.peers[0].modelDirectory).appendingPathComponent("tokenizer.json")
        let original = try Data(contentsOf: tokenizer)
        try Data("{\"changed\":true}".utf8).write(to: tokenizer)
        try require(doctor(release).map(\.outcome) == [.failed], "a changed tokenizer beside the earlier worker: \(doctor(release).map(\.detail))")
        try require(doctor(other, signed: true).map(\.outcome) == [.failed], "a changed tokenizer beside a signed worker")
        try original.write(to: tokenizer)
        try require(doctor(release).map(\.outcome) == [.warning], "the warning after the tokenizer was put back")

        // The installed worker is the pinned one again, and something else fails: that failure is reported.
        try FileManager.default.removeItem(at: installed)
        try FileManager.default.copyItem(at: f.probe, to: installed)
        try Data("{\"changed\":true}".utf8).write(to: tokenizer)
        try require(doctor(release).map(\.outcome) == [.failed], "a changed tokenizer on the pinned worker")
        try require(doctor(other, signed: true).map(\.outcome) == [.failed], "a changed tokenizer on the pinned, signed worker")
        try original.write(to: tokenizer)
    }

    static func journal(_ f: InstalledFixture) throws {
        let file = f.paths.deviceLeaseFile
        let fd = open(file.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try require(fd >= 0, "fixture gate missing"); defer { Darwin.close(fd) }
        try require(flock(fd, LOCK_EX | LOCK_NB) == 0, "fixture gate busy"); defer { _ = flock(fd, LOCK_UN) }
        let before = try tree(f.root)
        try require(ClusterDeviceJournalObservation.read(paths: f.paths) == .emptyJournal, "empty locked journal not distinguished")
        try require(try tree(f.root) == before, "journal read wrote files")
        let payload = Data("unresolved ownership".utf8)
        let written = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        try require(written == payload.count, "journal fixture write")
        let unresolved = try tree(f.root)
        try require(ClusterDeviceJournalObservation.read(paths: f.paths) == .ownershipUnproven, "nonempty journal inferred orphan/ready")
        try require(try tree(f.root) == unresolved, "journal observation changed ownership")
    }
}
