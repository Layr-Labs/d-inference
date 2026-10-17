import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
@testable import InstalledContract

/// The setup wizard's fixtures. Hardware, Thunderbolt, layouts and capability
/// records are captured from the two Macs of the pair (Mac A the M3 Ultra,
/// Mac B the M5 Max) on 2026-10-10 and kept under `Fixtures/setup-wizard`,
/// with every identifier removed; link findings are the ones the link probe
/// reported on each Mac that morning.
enum WizardFixtures {
    nonisolated(unsafe) static var directory = URL(fileURLWithPath: "/")

    static func data(_ name: String) -> Data {
        (try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data()
    }

    static var profileA: ClusterDeviceProfile { try! ClusterDeviceProfile.decode(data("profile-mac-a.json")) }
    static var profileB: ClusterDeviceProfile { try! ClusterDeviceProfile.decode(data("profile-mac-b.json")) }
    static var thunderboltA: ClusterSetupThunderbolt { try! ClusterSetupThunderbolt.parse(systemProfilerJSON: data("thunderbolt-mac-a.json")) }
    static var thunderboltB: ClusterSetupThunderbolt { try! ClusterSetupThunderbolt.parse(systemProfilerJSON: data("thunderbolt-mac-b.json")) }

    /// The eight model folders both Macs hold, as their manifests name them.
    static let models: [ClusterSetupLocalModel] = [
        ("Qwen3.5-9B-2026-09-03-r1", "Qwen3.5-9B", "2026-09-03-r1", "127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b", 6113952230),
        ("Qwen3.8-27B-4bit-mtp-2026-09-03-r1", "EigenLabs/Qwen3.8-27B-4bit-mtp", "2026-09-03-r1", "bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463", 16320415757),
        ("gpt-oss-20b-2026-05-25-r1", "gpt-oss-20b", "2026-05-25-r1", "61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512", 12104215835),
        ("mimo-v2.6-flash-mopd-2026-09-28-r1", "mimo-v2.6-flash-mopd", "2026-09-28-r1", "2334547d8acc9898ad4a74570ce44d2b12390bbac8d4bc52c092eb5ad5cfe034", 172863462401),
        ("nvidia-nemotron-3.5-lightning-2026-09-30-r1", "nvidia-nemotron-3.5-lightning", "2026-09-30-r1", "366d9285ec367633c25b5c064ad94482e04be043c2a515a16e4fcf12c0a8f85b", 19059595830),
        ("qwen3.5-35b-a3b-2026-08-25-r1", "qwen3.5-35b-a3b", "2026-08-25-r1", "95811153b3bb2ed78bf44b3248b07b52fce637706107de8b0fddf21796ade01c", 20893747852),
        ("qwen3.6-35b-a3b-vl-mtp-mxfp8-2026-08-11-r1", "qwen3.6-35b-a3b-vl-mtp-mxfp8", "2026-08-11-r1", "d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed", 21308856601),
        ("ternary-bonsai-2-27b-2026-09-17-r1", "ternary-bonsai-2-27b", "2026-09-17-r1", "ea1e901e4946c0ba9ad70c78517548808b353db6b3a13e87a8fa20468d81244c", 8608670713),
    ].map { ClusterSetupLocalModel(folder: $0.0, modelID: $0.1, version: $0.2, artifactSHA256: $0.3, totalBytes: $0.4) }

    // MARK: - Links, as each Mac's probe read them

    /// Mac A: en7 ("Thunderbolt 6") ready, not isolated, nothing in the way of the fix.
    static let linkA = ClusterSetupLink(state: "ready", guidance: nil,
        port: .init(device: "rdma_en7", interface: "en7", verdict: "ready", bridge: nil, hasIPv4Address: true, gidPublished: true, isolated: false,
            findings: ["defaultRouteViaPort", "dnsViaPort", "dhcpLeaseOnPort", "clusterServiceMissing", "otherServiceOnPort"], blockers: [],
            isolationGuidance: "The cluster port en7 is not isolated; run `darkbloom cluster` to give it its own network service with a fixed address, no router and no DNS, outside every bridge, which asks for your approval once in a macOS prompt and lasts across restarts.",
            hardwarePort: "Thunderbolt 6"),
        portsDown: 5, thunderbolt: nil, thunderboltError: nil)

    /// Mac B: en6 ("Thunderbolt 2") ready, in bridge0, Internet Sharing shares to it directly.
    static let linkB = ClusterSetupLink(state: "ready", guidance: nil,
        port: .init(device: "rdma_en6", interface: "en6", verdict: "ready", bridge: "bridge0", hasIPv4Address: true, gidPublished: true,
            isolated: false, findings: ["portInBridge", "internetSharingOverPortBridge", "internetSharingToPort", "clusterServiceMissing"],
            blockers: ["internetSharingToPort"],
            isolationGuidance: "The cluster port en6 cannot be isolated yet (Internet Sharing shares to en6 directly): in System Settings, General, Sharing, click the info button next to Internet Sharing and turn off \u{201C}Thunderbolt 2\u{201D} (en6) under \u{201C}To devices using\u{201D}, then run `darkbloom cluster` again.",
            hardwarePort: "Thunderbolt 2"),
        portsDown: 2, thunderbolt: nil, thunderboltError: nil)

    static func mac(_ profile: ClusterDeviceProfile, disk: Int? = 1_200 * 1_073_741_824) -> ClusterSetupMac {
        .init(profile: profile, profileError: nil, chip: profile.chip, physicalMemoryBytes: profile.physicalMemoryBytes,
            osVersion: "\(profile.osVersion) (\(profile.osBuild))", osMajor: 27, osMinor: 2, diskFreeBytes: disk, diskTotalBytes: 1_800 * 1_073_741_824)
    }

    static let gib = 1_073_741_824

    static func guardClear(_ wired: Double, baseline: Double) -> ClusterSetupMemoryGuard {
        .init(decision: .clear, wiredBytes: Int(wired * Double(gib)), baselineBytes: Int(baseline * Double(gib)), detail: nil)
    }

    // MARK: - Setups

    static let planDigest = "51e20592ca8f" + String(repeating: "0", count: 52)

    static func setup(leader: Bool, digest: String = String(repeating: "a", count: 64), cut: Int = 4) -> ClusterSetupSetupSummary {
        .init(configurationSHA256: digest, clusterID: "wizard-pair", memberID: leader ? "mac-a" : "mac-b", role: leader ? "leader" : "follower",
            localRank: leader ? 0 : 1, peerID: leader ? "mac-b" : "mac-a", linkDevice: leader ? "rdma_en7" : "rdma_en6",
            publicModelID: "Qwen3.5-9B", runtimeModelID: "registered_qwen35_9b", artifactSHA256: models[0].artifactSHA256,
            planSHA256: planDigest, generationMode: "pipeline_v1", prefillSchedule: "serial_v1",
            stages: [.init(rank: 0, memberID: "mac-a", firstLayer: 0, endLayer: cut), .init(rank: 1, memberID: "mac-b", firstLayer: cut, endLayer: 32)],
            knownHostsPinMatches: true, identityFileUsable: true,
            workerVerified: true, progressGuard: true, workerDetail: nil, filesPresent: 12, filesExpected: 12,
            holdings: "mac-a holds layers 0 to 3: 1.06 GiB of weights of its 256.00 GiB")
    }

    // MARK: - Reports

    static func reportA(link: ClusterSetupLink = linkA, saved: ClusterSetupSaved = .notConfigured, inbox: ClusterSetupSetupSummary? = nil,
                        journal: ClusterDeviceJournalObservation = .absent, memoryGuard: ClusterSetupMemoryGuard = guardClear(9.7, baseline: 25.6),
                        code: String? = "482913", mac: ClusterSetupMac? = nil) -> ClusterSetupReport {
        var link = link
        link.thunderbolt = thunderboltA
        return .init(observedAt: "2026-10-10T15:30:00Z", version: "0.0.0-check", mac: mac ?? self.mac(profileA), link: link, saved: saved,
            inbox: inbox, journal: journal, memoryGuard: memoryGuard, models: models, modelsError: nil,
            pairingCode: code.map { .init(code: $0, basis: .pinnedHostKey, algorithm: "ssh-ed25519") },
            checks: [.init(name: "localLinkReadiness", outcome: "passed", detail: "rdma_en7 ready")])
    }

    static func reportB(link: ClusterSetupLink = linkB, saved: ClusterSetupSaved = .notConfigured, inbox: ClusterSetupSetupSummary? = nil,
                        journal: ClusterDeviceJournalObservation = .absent, memoryGuard: ClusterSetupMemoryGuard = guardClear(4.9, baseline: 16),
                        code: String? = "482913") -> ClusterSetupReport {
        var link = link
        link.thunderbolt = thunderboltB
        return .init(observedAt: "2026-10-10T15:30:01Z", version: "0.0.0-check", mac: mac(profileB), link: link, saved: saved,
            inbox: inbox, journal: journal, memoryGuard: memoryGuard, models: models, modelsError: nil,
            pairingCode: code.map { .init(code: $0, basis: .ownHostKey, algorithm: "ssh-ed25519") },
            checks: [.init(name: "localLinkReadiness", outcome: "passed", detail: "rdma_en6 ready")])
    }

    static let descriptionPair = ClusterSetupPair(source: .description, clusterID: "wizard-pair", localMemberID: "mac-a", peerMemberID: "mac-b",
        leads: nil, canReachPeer: true, modelFolder: models[0].folder, publicModelID: "Qwen3.5-9B")
    static let savedLeaderPair = ClusterSetupPair(source: .saved, clusterID: "wizard-pair", localMemberID: "mac-a", peerMemberID: "mac-b",
        leads: true, canReachPeer: true, modelFolder: models[0].folder, publicModelID: "Qwen3.5-9B")
    static let inboxFollowerPair = ClusterSetupPair(source: .inbox, clusterID: "wizard-pair", localMemberID: "mac-b", peerMemberID: "mac-a",
        leads: false, canReachPeer: false, modelFolder: models[0].folder, publicModelID: "Qwen3.5-9B")
    static let savedFollowerPair = ClusterSetupPair(source: .saved, clusterID: "wizard-pair", localMemberID: "mac-b", peerMemberID: "mac-a",
        leads: false, canReachPeer: false, modelFolder: models[0].folder, publicModelID: "Qwen3.5-9B")

    static func snapshot(_ local: ClusterSetupReport, pair: ClusterSetupPair? = descriptionPair, record: ClusterSetupRecord = .init(pair: recordPair),
                         pairError: String? = nil) -> ClusterSetupSnapshot {
        .init(local: local, pair: pair, pairError: pairError, record: record, recordError: nil)
    }

    static let recordPair = ClusterSetupRecord.Pair(description: "/Users/fixture/pair.json", capability: "/Users/fixture/capability.json",
        capabilitySHA256: String(repeating: "c", count: 64), memberID: "mac-a")

    static func confirmed(_ record: ClusterSetupRecord = .init(pair: recordPair), code: String = "482913") -> ClusterSetupRecord {
        var record = record
        record.add(.init(code: code, clusterID: "wizard-pair", at: "2026-10-10T15:31:00Z"))
        return record
    }

    // MARK: - Planning from the captured readings

    static var pairDescription: ClusterPairDescription {
        let trust = ClusterConfiguration.Trust(identityFile: "/Users/fixture/.ssh/id_fixture", knownHostsFile: "/Users/fixture/trust/known_hosts",
            knownHostsSHA256: String(repeating: "d", count: 64))
        let capability = try! ClusterCapabilityRecord.decode(data("capability-qwen35-9b.json"), writtenBy: "fixture")
        func member(_ id: String, _ host: String, _ device: String, _ address: String) -> ClusterPairDescription.Member {
            .init(id: id, host: host, port: 22, user: "fixture", ownerExecutable: "/Users/fixture/bin/darkbloom-owner",
                workerExecutable: "/Users/fixture/bin/worker/darkbloom-cluster-worker",
                modelDirectory: "/Users/fixture/models/\(models[0].folder)", runtimeBinarySHA256: capability.runtimeBinarySHA256,
                jacclDevice: device, linkAddress: address, trust: trust)
        }
        return .init(schema: ClusterPairDescription.schemaName, clusterID: "wizard-pair", publicModelID: "Qwen3.5-9B",
            capabilitySHA256: ClusterConfigurationCodec.sha256(data("capability-qwen35-9b.json")), chunkTokens: 512, requestTimeoutSeconds: 60,
            coordinatorPort: 52441, members: [member("mac-a", "mac-a.fixture", "rdma_en7", "192.0.2.1"), member("mac-b", "mac-b.fixture", "rdma_en6", "192.0.2.2")],
            tokenizerFiles: ClusterSetupPlanning.tokenizerFiles(manifest: data("manifest-qwen35-9b.json")))
    }

    /// Each model folder's fixture files: `layout-KEY.json` (the plan tool's
    /// `layout --json`), `capability-KEY.json` (the worker's
    /// `--describe-runtime`, both of one build) and `manifest-KEY.json`.
    static let fixtureKeys: [String: String] = [
        "Qwen3.5-9B": "qwen35-9b", "EigenLabs/Qwen3.8-27B-4bit-mtp": "qwen38-27b", "gpt-oss-20b": "gpt-oss-20b",
        "mimo-v2.6-flash-mopd": "mimo-v26", "nvidia-nemotron-3.5-lightning": "nemotron35", "qwen3.5-35b-a3b": "qwen35-a3b",
        "qwen3.6-35b-a3b-vl-mtp-mxfp8": "qwen36-a3b", "ternary-bonsai-2-27b": "bonsai2-27b",
    ]

    /// One reading per model folder, every family as the plan tool and the
    /// worker of one build answered for it on Mac A (2026-10-11): each
    /// layout from the artifact's own headers, each capability record as
    /// the worker described it.
    static var readings: [ClusterSetupPlanning.ModelReading] {
        func record(_ name: String) -> Result<(record: ClusterRuntimeCapability, data: Data, sha256: String), ClusterSetupFailure> {
            let bytes = data(name)
            return .success((try! ClusterCapabilityRecord.decode(bytes, writtenBy: "fixture"), bytes, ClusterConfigurationCodec.sha256(bytes)))
        }
        return models.map { model in
            let key = fixtureKeys[model.modelID] ?? model.folder
            return .init(model: model, layout: .success(try! ClusterModelLayout.decode(data("layout-\(key).json"))),
                capability: record("capability-\(key).json"),
                tokenizerFiles: ClusterSetupPlanning.tokenizerFiles(manifest: data("manifest-\(key).json")))
        }
    }

    /// Constructed, not captured: a folder of an architecture no family of
    /// this runtime reads, both Macs holding it, with the plan tool's refusal
    /// for an unregistered configuration. It keeps the blocked row honest
    /// now that every captured folder plans.
    static let unreadModel = ClusterSetupLocalModel(folder: "llama-3.1-8b-instruct-r1", modelID: "llama-3.1-8b-instruct", version: "r1",
        artifactSHA256: String(repeating: "e", count: 64), totalBytes: 16_060_000_000)
    static var unreadReading: ClusterSetupPlanning.ModelReading {
        .init(model: unreadModel, layout: .failure(.init("Configuration is not a registered resident model's")),
            capability: .failure(.init("not described")), tokenizerFiles: [])
    }

    /// The captured folders and then the constructed one, as step 4 decides them.
    static var decisions: [ClusterSetupPlanning.Decision] {
        ClusterSetupPlanning.decide(readings: readings + [unreadReading], description: pairDescription, localMemberID: "mac-a",
            localProfile: profileA, peerProfile: profileB, peerModels: models + [unreadModel], measurements: [])
    }

    static var options: [ClusterSetupModelOption] { decisions.map(\.option) }
}

/// The wizard's operations, scripted: every answer is a fixture, and the
/// check sees what was asked.
final class WizardScriptedOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [ClusterSetupSnapshot]
    private var counts = [String: Int]()
    private var _calls = [String]()
    var peer: ClusterSetupPeerResult = .reached(WizardFixtures.reportB(), seconds: 0.42)
    var plans: ClusterSetupPlansResult = .failed("not scripted")
    var linkPreview = ClusterSetupLinkFixResult(dryRun: true, succeeded: true, outcome: "dryRun", lines: ["Link fix: dryRun"],
        commands: ["/usr/sbin/networksetup -createnetworkservice 'Darkbloom Cluster Link (en7)' 'Thunderbolt 6'", "/usr/sbin/networksetup -setmanual ..."])
    var linkApplied = ClusterSetupLinkFixResult(dryRun: false, succeeded: true, outcome: "fixed", lines: ["Link fix: fixed"], commands: [])
    var action = ClusterConsoleActionResult(succeeded: true, lines: ["done"])
    var live = ClusterSetupLive(observed: true, ready: true, hostPhase: "serving", sessionPhase: "ready", port: 18452,
        members: [.init(rank: 0, memberID: "mac-a", ready: true, cleanupObserved: false, releaseAcknowledged: false, termination: nil),
                  .init(rank: 1, memberID: "mac-b", ready: true, cleanupObserved: false, releaseAcknowledged: false, termination: nil)],
        requestsServed: 3, keepWarmExchanges: 12, localWiredBytes: 12 * WizardFixtures.gib, localPhysicalBytes: 256 * WizardFixtures.gib,
        linkState: "ready")
    var promptEvents: [ClusterSetupPromptEvent] = [.text("RDMA lets one Mac"), .text(" write into another's memory."),
        .finished(.init(completionTokens: 8, firstTokenMilliseconds: 720, tokensPerSecond: 53.1, finishReason: "length"))]
    let launch = ScriptedSessionLaunch(processIdentifier: 4242)

    init(_ snapshots: [ClusterSetupSnapshot]) { self.snapshots = snapshots }

    func count(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
    var calls: [String] { lock.withLock { _calls } }
    /// From now on every refresh reads this.
    func set(_ snapshot: ClusterSetupSnapshot) { lock.withLock { snapshots = [snapshot] } }
    func set(peer: ClusterSetupPeerResult) { lock.withLock { self.peer = peer } }
    func set(plans: ClusterSetupPlansResult) { lock.withLock { self.plans = plans } }
    func set(live: ClusterSetupLive) { lock.withLock { self.live = live } }

    private func called(_ name: String) { lock.withLock { counts[name, default: 0] += 1; _calls.append(name) } }

    var operations: ClusterSetupOperations {
        ClusterSetupOperations(
            snapshot: { [self] in
                called("snapshot")
                return lock.withLock { snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0] }
            },
            reachPeer: { [self] in called("reachPeer"); return lock.withLock { peer } },
            planModels: { [self] _ in called("planModels"); return lock.withLock { plans } },
            fixLink: { [self] dryRun in called(dryRun ? "fixLink:dryRun" : "fixLink:apply"); return lock.withLock { dryRun ? linkPreview : linkApplied } },
            recordConfirmation: { [self] code, _ in called("recordConfirmation:\(code)"); return lock.withLock { action } },
            adoptPlan: { [self] folder, _, _ in called("adoptPlan:\(folder)"); return lock.withLock { action } },
            approveInbox: { [self] digest in called("approveInbox:\(digest.prefix(8))"); return lock.withLock { action } },
            recordCheck: { [self] _ in called("recordCheck"); return lock.withLock { action } },
            observeSession: { [self] in called("observeSession"); return lock.withLock { live } },
            launchSession: { [self] events in called("launchSession"); return launch.launch(events) },
            sendPrompt: { [self] _, _, events in
                called("sendPrompt")
                for event in lock.withLock({ promptEvents }) { events(event) }
            })
    }
}
