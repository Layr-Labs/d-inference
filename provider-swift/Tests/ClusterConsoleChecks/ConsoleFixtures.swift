import Foundation
import Darwin
import DarkbloomClusterProtocol
@testable import InstalledContract

/// Values the checks feed the console. Reports are built directly; every
/// identifier in them is made up.
enum ConsoleFixtures {
    typealias Link = ClusterLinkReadinessReport

    static func device(_ number: Int, _ verdict: ClusterLinkReadinessState, bridge: String? = nil) -> Link.Device {
        let active = verdict != .noActivePort
        return .init(device: "rdma_en\(number)", interface: "en\(number)", transport: .thunderbolt, portActive: active,
            interfaceActive: active, interfaceHasIPv4Address: verdict == .ready || verdict == .gidNotPublished,
            bridge: bridge, ipv4MappedGIDPresent: active ? verdict == .ready : nil, verdict: verdict)
    }

    /// A Mac whose active port has its own address.
    static let readyLink = Link(state: .ready, devices: [device(2, .noActivePort), device(7, .ready)])
    /// A Mac whose active port is only a bridge member: the fix applies.
    static let bridgedLink = Link(state: .portBridgedWithoutAddress,
        devices: [device(2, .noActivePort, bridge: "bridge0"), device(6, .portBridgedWithoutAddress, bridge: "bridge0")])
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
                         aliases: [ClusterConsoleLinkAlias] = []) -> ClusterConsoleSnapshot {
        let narration = ClusterConsoleLinkSetup.make(report: link, mayPrompt: false)
        let attended = ClusterConsoleLinkSetup.make(report: link, mayPrompt: true)
        return .init(observedAt: "2026-10-09T06:00:00Z", link: link,
            setup: .init(lines: narration.lines, next: attended.next, fixDevice: attended.fixDevice), aliases: aliases,
            diagnostics: diagnostics(link: link, live: live, journal: journal), saved: saved, candidate: candidate,
            admittedModels: ClusterRuntimeAdapter.admittedModels.map {
                .init(adapterID: $0.adapterID, adapterVersion: $0.adapterVersion, runtimeModelID: $0.runtimeModelID)
            })
    }

    static let trust = ClusterConsoleTrust(knownHostsPinSHA256: String(repeating: "a", count: 64), knownHostsPinMatches: true,
        hostKeys: [.init(algorithm: "ssh-ed25519", fingerprint: "SHA256:" + String(repeating: "Q", count: 43))],
        identityFileUsable: true, error: nil)

    static func pairing(role: ClusterConfiguration.Role = .leader) -> ClusterConsolePairing {
        let local = role == .leader ? 0 : 1
        return .init(clusterID: "fixture-cluster", memberID: "peer-\(local)", role: role, localRank: local,
            peerID: "peer-\(1 - local)", peerRank: 1 - local, linkDevice: "rdma_en7", trust: trust, pairApproval: nil)
    }

    static func model(role: ClusterConfiguration.Role = .leader) -> ClusterConsoleSavedModel {
        .init(publicModelID: "fixture/public-model", runtimeModelID: "registered_fixture", adapterID: "fixture-adapter",
            artifactSHA256: String(repeating: "b", count: 64), planSHA256: String(repeating: "c", count: 64),
            prefillSchedule: "serial",
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

    static func candidate(error: String? = nil, alreadySaved: Bool = false) -> ClusterConsoleCandidateSetup {
        .init(error: error, pairing: error == nil ? pairing() : nil, publicModelID: "fixture/public-model",
            runtimeModelID: "registered_fixture", configurationSHA256: String(repeating: "e", count: 64), alreadySaved: alreadySaved)
    }
}

/// Operations that run nothing: each call is counted and answers from a script.
final class ScriptedOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [ClusterConsoleSnapshot]
    private var counts = [String: Int]()
    private var _exported: ClusterDiagnosticExport.Input?
    private var gates = [String: DispatchSemaphore]()
    var link = ConsoleFixtures.readyLink
    var fixResult = ClusterConsoleActionResult(succeeded: true, lines: ["Link fix: fixed", "fixture fix sentence"])
    var previewResult = ClusterConsoleActionResult(succeeded: true, lines: ["Link fix (dry run): would ask for approval", "fixture preview sentence"])
    var recoverResult = ClusterConsoleActionResult(succeeded: true, lines: ["Device journal: nothingToRecover"])
    var approveResult = ClusterConsoleActionResult(succeeded: true, lines: ["Saved cluster setup fixture."])
    var launch: (@Sendable (@escaping @Sendable (ClusterConsoleSessionEvent) -> Void) throws -> any ClusterConsoleSessionHandle)?
    var status: (@Sendable () -> ClusterDiagnosticsReport)?

    init(_ snapshots: [ClusterConsoleSnapshot]) { self.snapshots = snapshots }

    func count(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
    var exported: ClusterDiagnosticExport.Input? { lock.withLock { _exported } }

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
            fixLink: { [self] _ in called("fixLink"); return fixResult },
            previewFixLink: { [self] _ in called("previewFixLink"); return previewResult },
            recoverJournal: { [self] in called("recoverJournal"); return recoverResult },
            approveSetup: { [self] _ in called("approveSetup"); return approveResult },
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
