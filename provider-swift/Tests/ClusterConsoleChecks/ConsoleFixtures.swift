import Foundation
import Darwin
import DarkbloomClusterProtocol
@testable import InstalledContract

/// Values the checks feed the console. Reports are built directly; every
/// identifier in them is made up.
enum ConsoleFixtures {
    typealias Link = ClusterLinkReadinessReport

    /// `assigned` and `kept` are what the probe adds for a port Darkbloom has on record.
    static func device(_ number: Int, _ verdict: ClusterLinkReadinessState, bridge: String? = nil,
                       assigned: Link.AssignedAddress? = nil, kept: Bool? = nil) -> Link.Device {
        let active = verdict != .noActivePort
        var device = Link.Device(device: "rdma_en\(number)", interface: "en\(number)", transport: .thunderbolt, portActive: active,
            interfaceActive: active, interfaceHasIPv4Address: verdict == .ready || verdict == .gidNotPublished,
            bridge: bridge, ipv4MappedGIDPresent: active ? verdict == .ready : nil, verdict: verdict)
        device.assignedAddress = assigned; device.addressKept = kept
        return device
    }

    /// A Mac whose active port has its own address.
    static let readyLink = Link(state: .ready, devices: [device(2, .noActivePort), device(7, .ready)])
    /// A Mac whose active port is only a bridge member: the fix applies.
    static let bridgedLink = Link(state: .portBridgedWithoutAddress,
        devices: [device(2, .noActivePort, bridge: "bridge0"), device(6, .portBridgedWithoutAddress, bridge: "bridge0")])
    /// Ready on the address Darkbloom assigned, with the system job that keeps it.
    static let keptLink = Link(state: .ready, devices: [device(2, .noActivePort), device(7, .ready, assigned: .present, kept: true)])
    /// Ready on an address Darkbloom added that nothing keeps: the fix only installs the job.
    static let temporaryLink = Link(state: .ready, devices: [device(2, .noActivePort), device(7, .ready, assigned: .present, kept: false)])
    /// macOS took the assigned address away and the job that puts it back is loaded.
    static let lostKeptLink = Link(state: .portBridgedWithoutAddress,
        devices: [device(2, .noActivePort, bridge: "bridge0"), device(6, .portBridgedWithoutAddress, bridge: "bridge0", assigned: .missing, kept: true)])
    /// The same loss with no job to put the address back.
    static let lostLink = Link(state: .portBridgedWithoutAddress,
        devices: [device(2, .noActivePort, bridge: "bridge0"), device(6, .portBridgedWithoutAddress, bridge: "bridge0", assigned: .missing, kept: false)])
    /// RDMA on, no cable.
    static let unpluggedLink = Link(state: .noActivePort, devices: [device(2, .noActivePort), device(6, .noActivePort)])
    static let disabledLink = Link(state: .rdmaDisabled)

    static func diagnostics(link: Link, live: ClusterLiveStatus? = nil, saved: ClusterStatusBinding? = nil,
                            journal: ClusterDeviceJournalObservation = .absent,
                            observation: String = "No discovery file.") -> ClusterDiagnosticsReport {
        .init(operation: "doctor", configurationState: saved == nil ? .notConfigured : .verified, saved: saved, live: live,
            deviceJournal: journal,
            checks: [.init(name: "savedConfiguration", outcome: saved == nil ? .notRun : .passed, detail: "fixture check detail"),
                     .init(name: "localServingObservation", outcome: live == nil ? .notObserved : .passed, detail: observation)],
            localLink: link, configuredLinkDevice: nil)
    }

    static func snapshot(link: Link = readyLink, saved: ClusterConsoleSavedSetup = .notConfigured,
                         candidate: ClusterConsoleCandidateSetup? = nil, live: ClusterLiveStatus? = nil,
                         journal: ClusterDeviceJournalObservation = .absent,
                         options: ClusterConsoleState.Options = .init()) -> ClusterConsoleSnapshot {
        let narration = ClusterConsoleLinkSetup.make(report: link, mayPrompt: false, temporary: options.temporary, dryRun: options.dryRun)
        let attended = ClusterConsoleLinkSetup.make(report: link, mayPrompt: true, temporary: options.temporary, dryRun: options.dryRun)
        return .init(observedAt: "2026-10-09T06:00:00Z", link: link,
            setup: .init(lines: narration.lines, next: attended.next, fixDevice: attended.fixDevice),
            diagnostics: diagnostics(link: link, live: live, journal: journal), saved: saved, candidate: candidate,
            admittedModels: ClusterRuntimeAdapter.admittedModels.map {
                .init(adapterID: $0.adapterID, adapterVersion: $0.adapterVersion, runtimeModelID: $0.runtimeModelID)
            })
    }

    static let trust = ClusterConsoleTrust(knownHostsPinSHA256: String(repeating: "a", count: 64), knownHostsPinMatches: true,
        hostKeys: [.init(kind: .host, algorithm: "ssh-ed25519", fingerprint: "SHA256:" + String(repeating: "Q", count: 43))],
        hostKeysNotShown: 0, identityFileUsable: true, error: nil)

    static func pairing(role: ClusterConfiguration.Role = .leader) -> ClusterConsolePairing {
        let local = role == .leader ? 0 : 1
        return .init(clusterID: "fixture-cluster", memberID: "peer-\(local)", role: role, localRank: local,
            peerID: "peer-\(1 - local)", peerRank: 1 - local, linkDevice: "rdma_en7", trust: trust, pairApproval: nil)
    }

    static func model(role: ClusterConfiguration.Role = .leader) -> ClusterConsoleSavedModel {
        .init(publicModelID: "fixture/public-model", runtimeModelID: "registered_fixture", adapterID: "fixture-adapter",
            artifactSHA256: String(repeating: "b", count: 64), planSHA256: String(repeating: "c", count: 64),
            prefillSchedule: ClusterPrefillSchedule.serial.rawValue,
            stages: [.init(rank: 0, peerID: "peer-0", local: role == .leader, sourceLayerStart: 0, sourceLayerEnd: 4),
                     .init(rank: 1, peerID: "peer-1", local: role == .follower, sourceLayerStart: 4, sourceLayerEnd: 32)],
            maximumLifetimeSeconds: 300, maximumRequests: 16, maximumPromptTokens: 8192, maximumOutputTokens: 128)
    }

    static let installed = ClusterConsoleInstalled(workerBinary: .verified, hasProgressGuard: true, acceptsStartupDeadline: true,
        manifest: .verified, artifactFiles: .init(expected: 12, present: 12, expectedBytes: 6_113_952_230, missingOrDifferent: []))

    static func savedSetup(role: ClusterConfiguration.Role = .leader) -> ClusterConsoleSavedSetup {
        .init(state: .loaded, error: nil, configurationSHA256: String(repeating: "d", count: 64),
            pairing: pairing(role: role), model: model(role: role), installed: installed)
    }

    /// The saved setup's public identity as the leader's status carries it.
    static func binding() throws -> ClusterStatusBinding {
        func pin(_ character: Character) -> String { String(repeating: String(character), count: 64) }
        return try JSONDecoder().decode(ClusterStatusBinding.self, from: JSONSerialization.data(withJSONObject: [
            "clusterID": "fixture-cluster", "memberID": "peer-0", "role": "leader", "configurationSHA256": pin("d"),
            "capabilitySHA256": pin("1"), "publicModelID": "fixture/public-model", "runtimeModelID": "registered_fixture",
            "artifactSHA256": pin("b"), "configurationModelSHA256": pin("2"), "planSHA256": pin("c"), "prefillSchedule": ClusterPrefillSchedule.serial.rawValue,
            "peers": [["id": "peer-0", "rank": 0, "runtimeBinarySHA256": pin("3")], ["id": "peer-1", "rank": 1, "runtimeBinarySHA256": pin("3")]],
            "maximumLifetimeSeconds": 300, "maximumRequests": 16,
        ] as [String: Any]))
    }

    /// A leader's status report: each rank is ready exactly when it has a capacity.
    static func live(host: String = "serving", phase: String = "ready", ready: Bool = true,
                     capacity: [Int?] = [4096, 8192]) throws -> ClusterLiveStatus {
        let binding = try binding()
        return .init(schema: ClusterLiveStatus.schemaName, nonce: "n", binding: binding, authenticationConfigured: true, hostPhase: host,
            session: .init(binding: binding, phase: phase, observedMembershipEpoch: ready ? "11111111-2222-3333-4444-555555555555" : nil,
                observedPrefillSchedule: ready ? .serial : nil, ready: ready,
                admission: ready ? .init(remainingLifetimeNanoseconds: 281_000_000_000, remainingRequests: 15, activeRequest: false, draining: false, valid: true) : nil,
                members: (0..<2).map { .init(peerID: "peer-\($0)", rank: $0, transport: $0 == 0 ? .localPipes : .authenticatedSSH,
                    nativeReady: capacity[$0] != nil, requestCapacityBytes: capacity[$0], nativeCleanupObserved: false,
                    ownerReleaseAcknowledged: false, ownerTermination: nil) },
                mtpEnabled: false, mtpOffReason: "runtimeCapabilityDisablesSpeculation", nativeBootstrap: .directNative,
                collectiveProgressLimitMilliseconds: 60_000),
            boundPort: 8000, acquisitions: 0, failed: false, ready: ready, admissionAvailable: ready, quarantined: false)
    }

    static let candidateSHA256 = String(repeating: "e", count: 64)

    static func candidate(error: String? = nil, alreadySaved: Bool = false, sha256: String = candidateSHA256) -> ClusterConsoleCandidateSetup {
        .init(error: error, pairing: error == nil ? pairing() : nil, publicModelID: "fixture/public-model",
            runtimeModelID: "registered_fixture", configurationSHA256: error == nil ? sha256 : nil, alreadySaved: alreadySaved)
    }

    /// The inputs a console is started with when a setup is passed in. The
    /// scripted operations never read them.
    static let candidateInputs = ClusterConsoleCandidate(configurationInput: URL(fileURLWithPath: "/fixture/setup.json"),
        capabilityInput: URL(fileURLWithPath: "/fixture/capability.json"), capabilitySHA256: String(repeating: "f", count: 64))
}

/// Operations that run nothing: each call is counted and answers from a script.
final class ScriptedOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [ClusterConsoleSnapshot]
    private var counts = [String: Int]()
    private var _exported: ClusterDiagnosticExport.Input?
    private var _approved = [String]()
    private var _fixes = [ClusterConsoleLinkFix]()
    private var gates = [String: DispatchSemaphore]()
    var link = ConsoleFixtures.readyLink
    var fixResult = ClusterConsoleActionResult(succeeded: true, lines: ["Link fix: fixed", "fixture fix sentence"])
    var dryRunResult = ClusterConsoleActionResult(succeeded: true, lines: ["Link fix: dryRun", "fixture dry run sentence"])
    var recoverResult = ClusterConsoleActionResult(succeeded: true, lines: ["Device journal: nothingToRecover"])
    var approveResult = ClusterConsoleActionResult(succeeded: true, lines: ["Saved cluster setup fixture."])
    var launch: (@Sendable (@escaping @Sendable (ClusterConsoleSessionEvent) -> Void) throws -> any ClusterConsoleSessionHandle)?
    var status: (@Sendable () -> ClusterDiagnosticsReport)?

    init(_ snapshots: [ClusterConsoleSnapshot]) { self.snapshots = snapshots }

    func count(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
    var exported: ClusterDiagnosticExport.Input? { lock.withLock { _exported } }
    /// The digests each approval was asked to save, in order.
    var approved: [String] { lock.withLock { _approved } }
    /// Each link fix that was asked for, in order.
    var fixes: [ClusterConsoleLinkFix] { lock.withLock { _fixes } }

    /// From now on the named operation waits on `gate` before it answers; nil lets it through again.
    func hold(_ name: String, at gate: DispatchSemaphore?) { lock.withLock { gates[name] = gate } }

    private func called(_ name: String) {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            counts[name, default: 0] += 1
            return gates[name]
        }
        gate?.wait()
    }

    var operations: ClusterConsoleOperations {
        ClusterConsoleOperations(
            snapshot: { [self] in
                called("snapshot")
                // Each refresh takes the next scripted reading; the last one repeats.
                return lock.withLock { snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0] }
            },
            inspectLink: { [self] in called("inspectLink"); return link },
            observeSession: { [self] in
                called("observeSession")
                return .init(status: status?() ?? ConsoleFixtures.diagnostics(link: link))
            },
            fixLink: { [self] fix in
                lock.withLock { _fixes.append(fix) }
                called("fixLink")
                return fix.dryRun ? dryRunResult : fixResult
            },
            recoverJournal: { [self] in called("recoverJournal"); return recoverResult },
            approveSetup: { [self] _, expected in
                called("approveSetup")
                lock.withLock { _approved.append(expected) }
                return approveResult
            },
            exportDiagnostics: { [self] input in
                called("exportDiagnostics")
                lock.withLock { _exported = input }
                return .init(succeeded: true, lines: ["Wrote fixture export."])
            },
            launchSession: { [self] events in
                called("launchSession")
                guard let launch else { throw ClusterConfigurationError.invalid("fixture has no session to launch") }
                return try launch(events)
            })
    }
}

/// A stand-in session handle: records interrupts and ends when told to.
final class ScriptedSession: ClusterConsoleSessionHandle, @unchecked Sendable {
    let processIdentifier: Int32
    private let lock = NSLock()
    private var _interrupts = 0
    init(processIdentifier: Int32) { self.processIdentifier = processIdentifier }
    var interrupts: Int { lock.withLock { _interrupts } }
    func interrupt() { lock.withLock { _interrupts += 1 } }
}
