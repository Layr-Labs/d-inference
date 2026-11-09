import Foundation
import Testing
@testable import ProviderCore

struct AbsentProviderRecoveryIntegrationTests {
    private final class Fixture {
        enum BootstrapMode { case success, acceptedThenTimeout, absentAfterTimeout }
        let root: URL
        let installRoot: URL
        let paths: AbsentProviderRecovery.Paths
        let updater: SelfUpdater
        var now = 1000.0
        var autoRestart = true
        var enabled = true
        var loaded = false
        var loadedOutput = "runs = 1"
        var disabledProbes = 0
        var onDisabledProbe: ((Int) throws -> Void)?
        var afterBootstrap: (() throws -> Void)?
        var mode = BootstrapMode.success
        var commands: [[String]] = []
        var lockObservedAtBootstrap = false

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("absent-integration-" + UUID().uuidString)
            installRoot = root.appendingPathComponent("install")
            paths = .init(plist: root.appendingPathComponent("provider.plist"),
                watchdogState: root.appendingPathComponent("watchdog.json"),
                daemonState: root.appendingPathComponent("daemon.json"),
                guardEnvironment: [KVBackendGuardStore.pathEnvKey: root.appendingPathComponent("guard.json").path])
            updater = SelfUpdater(coordinatorBaseURL: "http://127.0.0.1:1", installRoot: installRoot,
                verifyCodeSignatures: true, currentVersion: "1.0.0", now: { 1000 })
            try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
            // This is a real temporary plist; no executable or signed bundle is
            // substituted for the updater. Its command boundary is intercepted.
            let plist: [String: Any] = ["Label": LaunchAgent.label, "RunAtLoad": true,
                                       "ProgramArguments": ["/usr/bin/false"]]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: paths.plist)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
        var state: WatchdogState { WatchdogStateStore.read(from: paths.watchdogState) }
        var bootstrapCount: Int { commands.filter { $0.first == "bootstrap" }.count }
        var journal: URL { installRoot.appendingPathComponent("recovery/transaction.json") }

        func run(_ executable: String, _ arguments: [String]) throws -> SecurityCommandResult {
            #expect(executable == "/bin/launchctl")
            commands.append(arguments)
            switch arguments.first {
            case "print":
                #expect(arguments == ["print", LaunchctlControl.target(label: LaunchAgent.label)])
                return loaded ? .init(terminationStatus: 0, stdout: loadedOutput) :
                    .init(terminationStatus: 113, stderr: "Could not find service \"\(LaunchAgent.label)\" in domain for user gui")
            case "print-disabled":
                disabledProbes += 1
                try onDisabledProbe?(disabledProbes)
                #expect(arguments == ["print-disabled", LaunchctlControl.guiDomain()])
                return .init(terminationStatus: 0,
                    stdout: "disabled services = { \"\(LaunchAgent.label)\" => \(enabled ? "false" : "true") }")
            case "bootstrap":
                #expect(arguments == ["bootstrap", LaunchctlControl.guiDomain(), paths.plist.path])
                // Real kernel flock must still be owned at the effect boundary.
                do {
                    let unexpected = try updater.beginUpdateSession(operation: "integration-bootstrap-probe", timeout: 0)
                    unexpected.release()
                    Issue.record("bootstrap ran outside the real lifecycle lease")
                } catch UpdateError.lockBusy(_, _) {
                    lockObservedAtBootstrap = true
                }
                loaded = true
                try afterBootstrap?()
                switch mode {
                case .success: return .init(terminationStatus: 0)
                case .acceptedThenTimeout: throw SecurityCommandRunner.CommandError.timedOut
                case .absentAfterTimeout:
                    loaded = false
                    throw SecurityCommandRunner.CommandError.timedOut
                }
            default:
                Issue.record("unexpected command (enable/kickstart/restart forbidden): \(arguments)")
                return .init(terminationStatus: 1)
            }
        }

        func tick() throws -> AbsentProviderRecovery.Outcome {
            try AbsentProviderRecovery.handleTick(updater: updater, autoRestart: { self.autoRestart },
                runner: SecurityCommandRunner { try self.run($0, $1) }, paths: paths,
                clock: { self.now }, bootTime: 0)
        }
        func assertLeaseReleased() throws {
            let lease = try updater.beginUpdateSession(operation: "integration-release-probe", timeout: 0)
            lease.release()
        }

        func seedCandidate(failures: Int = 0, issued: Bool = false,
                           retry: Double? = nil, blocked: String? = nil,
                           intent: Bool = false) throws {
            let release = InstalledReleaseRecord(version: "2.0.0", releaseBundleHash: nil,
                installedBundleHash: "metadata-only", binaryHash: "metadata-only", enclaveHash: "metadata-only",
                metallibHash: "metadata-only", installGeneration: 2, installedAt: 1)
            let candidate = PendingReleaseCandidate(release: release, failureCount: failures,
                launchIntent: intent ? .init(id: "uncertain-old", preparedAt: 1, baseline: nil) : nil,
                pendingAttemptID: issued ? "issued-old" : nil, attemptStartedAt: issued ? 1 : nil,
                healthySince: nil, healthyProcessStartedAt: nil, retryNotBefore: retry,
                rollbackBlockedReason: blocked)
            let session = try updater.beginUpdateSession(operation: "candidate-setup", timeout: 0)
            defer { session.release() }
            try session.writeState(UpdateRecoveryState(installGeneration: 2, candidate: candidate))
        }
        func recoveryState() throws -> UpdateRecoveryState {
            let session = try updater.beginUpdateSession(operation: "candidate-inspect", timeout: 0)
            defer { session.release() }
            return try session.readState()
        }
        func expireGrace() throws {
            #expect(try tick() == .startGrace)
            now = 1301
        }

        func createInvalidJournal() throws -> Data {
            let bytes = Data("deliberately invalid journal: must not be read for stopped service".utf8)
            try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: journal)
            return bytes
        }
    }

    @Test func enabledAbsentJobPersistsGraceAndBootstrapsUnderRealLease() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(fixture.updater.verifiesCodeSignatures)
        let first = try fixture.tick()
        try #require(first == .startGrace)
        #expect(fixture.state.downSince == 1000)
        let firstBytes = try Data(contentsOf: fixture.paths.watchdogState)
        try fixture.assertLeaseReleased()
        fixture.now = 1001
        let second = try fixture.tick()
        #expect(second == .waiting)
        #expect(try Data(contentsOf: fixture.paths.watchdogState) == firstBytes)
        #expect(fixture.bootstrapCount == 0)
        fixture.now = 1301
        let third = try fixture.tick()
        #expect(third == .issued)
        #expect(fixture.bootstrapCount == 1)
        #expect(fixture.lockObservedAtBootstrap)
        #expect(fixture.state.downSince == nil)
        #expect(fixture.state.lastRestartAt == 1301)
        #expect(fixture.state.lastRestartVersion == "1.0.0")
        #expect(fixture.state.consecutiveCrashLoopRestarts == 1)
        #expect(!fixture.commands.contains { ["enable", "kickstart", "bootout"].contains($0.first ?? "") })
        try fixture.assertLeaseReleased()
    }

    @Test func stoppedAndOptedOutServicesDoNotReadRealInvalidJournal() throws {
        for optedOut in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            fixture.enabled = optedOut
            fixture.autoRestart = !optedOut
            let journalBefore = try fixture.createInvalidJournal()
            let outcome = try fixture.tick()
            #expect(outcome == .ineligible)
            #expect(try Data(contentsOf: fixture.journal) == journalBefore)
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.watchdogState.path))
            #expect(fixture.bootstrapCount == 0)
            try fixture.assertLeaseReleased()
        }
    }

    @Test func realBusyUpdateSessionPreventsMutationThenRecoversAfterRelease() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let holder = try fixture.updater.beginUpdateSession(operation: "integration-stop-holder", timeout: 0)
        defer { holder.release() }
        do {
            _ = try fixture.tick()
            Issue.record("busy real lifecycle lease unexpectedly succeeded")
        } catch UpdateError.lockBusy(_, _) {}
        #expect(fixture.bootstrapCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.watchdogState.path))
        holder.release()
        let afterRelease = try fixture.tick()
        #expect(afterRelease == .startGrace)
        try fixture.assertLeaseReleased()
    }

    @Test func realPendingCandidateWaitsForGraceWithoutChargingAttempt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let release = InstalledReleaseRecord(version: "2.0.0", releaseBundleHash: nil,
            installedBundleHash: "metadata-only", binaryHash: "metadata-only", enclaveHash: "metadata-only",
            metallibHash: "metadata-only", installGeneration: 2, installedAt: 1)
        let pending = PendingReleaseCandidate(release: release, failureCount: 1, launchIntent: nil,
            pendingAttemptID: "existing-attempt", attemptStartedAt: 1, healthySince: nil,
            healthyProcessStartedAt: nil, retryNotBefore: nil, rollbackBlockedReason: nil)
        let recovery = UpdateRecoveryState(installGeneration: 2, candidate: pending)
        let setup = try fixture.updater.beginUpdateSession(operation: "integration-state-setup", timeout: 0)
        defer { setup.release() }
        try setup.writeState(recovery)
        setup.release()
        let stateURL = fixture.installRoot.appendingPathComponent("recovery/state.json")
        let before = try Data(contentsOf: stateURL)
        let outcome = try fixture.tick()
        #expect(outcome == .startGrace)
        #expect(try Data(contentsOf: stateURL) == before)
        #expect(fixture.bootstrapCount == 0)
        #expect(fixture.state.downSince == 1000)
        let inspect = try fixture.updater.beginUpdateSession(operation: "integration-state-inspect", timeout: 0)
        defer { inspect.release() }
        #expect(try inspect.readState() == recovery)
    }

    @Test func actualAdapterTimeoutKeepsRealOutageStateAndNextLoadedTickDoesNotRetry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.tick()
        try #require(first == .startGrace)
        let before = try Data(contentsOf: fixture.paths.watchdogState)
        fixture.now = 1301
        fixture.mode = .acceptedThenTimeout
        let uncertain = try fixture.tick()
        #expect(uncertain == .unknown)
        #expect(fixture.lockObservedAtBootstrap)
        #expect(fixture.bootstrapCount == 1)
        #expect(try Data(contentsOf: fixture.paths.watchdogState) == before)
        #expect(fixture.state.lastRestartAt == nil)
        let observedLoaded = try fixture.tick()
        #expect(observedLoaded == .loaded)
        #expect(fixture.bootstrapCount == 1)
        #expect(try Data(contentsOf: fixture.paths.watchdogState) == before)
        try fixture.assertLeaseReleased()
    }

    @Test func eligibleServiceRejectsRealCorruptJournalBeforeBootstrap() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let journalBefore = try fixture.createInvalidJournal()
        do {
            _ = try fixture.tick()
            Issue.record("eligible service skipped real journal validation")
        } catch UpdateRecoveryStore.StoreError.corruptTransaction(_) {}
        #expect(try Data(contentsOf: fixture.journal) == journalBefore)
        #expect(fixture.bootstrapCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.watchdogState.path))
        try fixture.assertLeaseReleased()
    }


    @Test func candidateExpiredBackoffBootstrapsAndPersistsOneIssuedAttempt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedCandidate(failures: 3, retry: 1400, blocked: "verified predecessor unavailable")
        try fixture.expireGrace()
        let before = try fixture.recoveryState()
        #expect(try fixture.tick() == .deferred)
        #expect(try fixture.recoveryState() == before)
        #expect(fixture.bootstrapCount == 0)
        fixture.now = 1400
        #expect(try fixture.tick() == .issued)
        let after = try fixture.recoveryState()
        #expect(after.candidate?.failureCount == 3)
        #expect(after.candidate?.pendingAttemptID != nil)
        #expect(after.candidate?.attemptStartedAt == 1400)
        #expect(after.candidate?.launchIntent == nil)
        #expect(after.candidate?.retryNotBefore == nil)
        #expect(after.candidate?.rollbackBlockedReason == nil)
        #expect(fixture.state.lastRestartVersion == "2.0.0")
        #expect(fixture.state.lastRestartAt == 1400)
        #expect(fixture.bootstrapCount == 1)
        #expect(fixture.lockObservedAtBootstrap)
        #expect(try fixture.tick() == .loaded)
        #expect(try fixture.recoveryState() == after)
        try fixture.assertLeaseReleased()
    }

    @Test func absentIssuedCandidateChargesOnceAndRetriesBelowRollbackThreshold() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedCandidate(failures: 1, issued: true)
        try fixture.expireGrace()
        #expect(try fixture.tick() == .issued)
        let state = try fixture.recoveryState()
        #expect(state.candidate?.failureCount == 2)
        #expect(state.candidate?.pendingAttemptID != nil)
        #expect(state.candidate?.pendingAttemptID != "issued-old")
        #expect(state.candidate?.attemptStartedAt == 1301)
        #expect(fixture.bootstrapCount == 1)
        #expect(fixture.state.lastRestartVersion == "2.0.0")
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.guardEnvironment[KVBackendGuardStore.pathEnvKey]!))
        #expect(try fixture.tick() == .loaded)
        #expect(try fixture.recoveryState() == state)
    }

    @Test func missingPredecessorRefusalChargesOnceBacksOffThenRetriesIntactCandidate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedCandidate(failures: 2, issued: true)
        try fixture.expireGrace()
        #expect(try fixture.tick() == .deferred)
        let refused = try fixture.recoveryState()
        #expect(fixture.updater.verifiesCodeSignatures)
        #expect(refused.candidate?.failureCount == 3)
        #expect(refused.candidate?.pendingAttemptID == nil)
        #expect(refused.candidate?.retryNotBefore == 1601)
        #expect(refused.candidate?.rollbackBlockedReason?.contains("no recorded predecessor") == true)
        #expect(fixture.bootstrapCount == 0)
        #expect(fixture.state.lastRestartAt == nil)
        fixture.now = 1600
        #expect(try fixture.tick() == .deferred)
        #expect(try fixture.recoveryState() == refused)
        fixture.now = 1601
        #expect(try fixture.tick() == .issued)
        let retried = try fixture.recoveryState()
        #expect(retried.candidate?.failureCount == 3)
        #expect(retried.candidate?.pendingAttemptID != nil)
        #expect(retried.candidate?.retryNotBefore == nil)
        #expect(fixture.bootstrapCount == 1)
        #expect(fixture.lockObservedAtBootstrap)
    }

    @Test func ambiguousCandidateBootstrapKeepsDurableIntentWithoutChargingFailure() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedCandidate(failures: 1, intent: true)
        try fixture.expireGrace()
        fixture.mode = .absentAfterTimeout
        #expect(try fixture.tick() == .unknown)
        let unknown = try fixture.recoveryState()
        #expect(unknown.candidate?.failureCount == 1)
        #expect(unknown.candidate?.launchIntent != nil)
        #expect(unknown.candidate?.launchIntent?.id != "uncertain-old")
        #expect(unknown.candidate?.pendingAttemptID == nil)
        #expect(unknown.candidate?.attemptStartedAt == nil)
        #expect(fixture.state.lastRestartAt == nil)
        fixture.now = 1302
        fixture.mode = .success
        #expect(try fixture.tick() == .issued)
        let recovered = try fixture.recoveryState()
        #expect(recovered.candidate?.failureCount == 1)
        #expect(recovered.candidate?.launchIntent == nil)
        #expect(recovered.candidate?.pendingAttemptID != nil)
        #expect(recovered.candidate?.attemptStartedAt == 1302)
        #expect(fixture.bootstrapCount == 2)
    }

    @Test func stoppedCandidatePreservesPendingFailureAndBackoffBytes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedCandidate(failures: 2, issued: true, retry: 1400, blocked: "keep")
        let before = try fixture.recoveryState()
        fixture.enabled = false
        fixture.now = 2000
        #expect(try fixture.tick() == .ineligible)
        #expect(try fixture.recoveryState() == before)
        #expect(fixture.bootstrapCount == 0)
    }

    @Test func unknownBootstrapWithLaunchProofGetsDurableAttemptBeforeLoadedHandoff() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedCandidate()
        try fixture.expireGrace()
        fixture.mode = .acceptedThenTimeout
        #expect(try fixture.tick() == .unknown)
        let before = try fixture.recoveryState()
        #expect(before.candidate?.launchIntent != nil)
        #expect(before.candidate?.pendingAttemptID == nil)
        fixture.now = 1302
        #expect(try fixture.tick() == .loaded)
        let reconciled = try fixture.recoveryState()
        #expect(reconciled.candidate?.pendingAttemptID == before.candidate?.launchIntent?.id)
        #expect(reconciled.candidate?.attemptStartedAt == 1302)
        #expect(reconciled.candidate?.healthySince == nil)
        #expect(reconciled.candidate?.failureCount == 0)
        #expect(fixture.state.lastRestartAt == nil)
        #expect(fixture.bootstrapCount == 1)
        fixture.now = 1303
        #expect(try fixture.tick() == .loaded)
        #expect(try fixture.recoveryState() == reconciled)
    }

    @Test func loadedWithoutLaunchProofPreservesUncertainIntent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedCandidate(intent: true)
        fixture.loaded = true
        fixture.loadedOutput = "state = waiting"
        let before = try fixture.recoveryState()
        #expect(try fixture.tick() == .loaded)
        #expect(try fixture.recoveryState() == before)
        #expect(fixture.bootstrapCount == 0)
    }

    @Test func preCommandStateReadFailureIsKnownNonissuanceAndUndoesGuard() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedCandidate(failures: 3, retry: 1, blocked: "missing")
        #expect(WatchdogStateStore.write(.init(downSince: 1000, lastRestartAt: 990,
            lastRestartVersion: "2.0.0", consecutiveCrashLoopRestarts: 2), to: fixture.paths.watchdogState))
        fixture.now = 1301
        fixture.onDisabledProbe = { count in
            if count == 3 {
                let state = fixture.installRoot.appendingPathComponent("recovery/state.json")
                try FileManager.default.removeItem(at: state)
                try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
            }
        }
        #expect(try fixture.tick() == .deferred)
        #expect(fixture.bootstrapCount == 0)
        #expect(fixture.state.lastRestartAt == 990)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.guardEnvironment[KVBackendGuardStore.pathEnvKey]!))
        try fixture.assertLeaseReleased()
    }

    @Test func postCommandPersistenceFailureRetainsProtectionWithoutInventedCount() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedCandidate(failures: 3, retry: 1, blocked: "missing")
        #expect(WatchdogStateStore.write(.init(downSince: 1000, lastRestartAt: 990,
            lastRestartVersion: "2.0.0", consecutiveCrashLoopRestarts: 2), to: fixture.paths.watchdogState))
        fixture.now = 1301
        fixture.afterBootstrap = {
            let state = fixture.installRoot.appendingPathComponent("recovery/state.json")
            try FileManager.default.removeItem(at: state)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        }
        #expect(try fixture.tick() == .unknown)
        #expect(fixture.bootstrapCount == 1)
        #expect(fixture.state.lastRestartAt == 990)
        #expect(fixture.state.consecutiveCrashLoopRestarts == 2)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.guardEnvironment[KVBackendGuardStore.pathEnvKey]!))
        try fixture.assertLeaseReleased()
    }

    @Test func rollbackCleanupErrorReloadsCommittedStateWithoutResurrectingCandidate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let session = try fixture.updater.beginUpdateSession(operation: "committed-rollback-boundary", timeout: 0)
        defer { session.release() }
        // Exercise the error handler with the real persisted state left after
        // commit/journal removal. This is not a signed bundle rollback fixture.
        let committed = UpdateRecoveryState(installGeneration: 3)
        try session.writeState(committed)
        let file = fixture.installRoot.appendingPathComponent("recovery/state.json")
        let bytes = try Data(contentsOf: file)
        let recovered = try AbsentProviderRecovery.recoverRollbackOutcome(session: session,
            now: 1301, reason: "cleanup failed after committed rollback")
        #expect(recovered == committed)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(fixture.bootstrapCount == 0)
    }

    @Test func rollbackErrorWithCorruptJournalNeverOverwritesDurableCandidate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedCandidate(failures: 3)
        let file = fixture.installRoot.appendingPathComponent("recovery/state.json")
        let bytes = try Data(contentsOf: file)
        _ = try fixture.createInvalidJournal()
        let session = try fixture.updater.beginUpdateSession(operation: "unreplayable-rollback", timeout: 0)
        defer { session.release() }
        do {
            _ = try AbsentProviderRecovery.recoverRollbackOutcome(session: session,
                now: 1301, reason: "rollback interrupted")
            Issue.record("corrupt transaction unexpectedly recovered")
        } catch UpdateRecoveryStore.StoreError.corruptTransaction(_) {}
        #expect(try Data(contentsOf: file) == bytes)
        #expect(fixture.bootstrapCount == 0)
    }

    @Test func loadedZeroRunsDoesNotAttributeUnconfirmedLaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedCandidate(intent: true)
        fixture.loaded = true
        fixture.loadedOutput = "runs = 0"
        let before = try fixture.recoveryState()
        #expect(try fixture.tick() == .loaded)
        #expect(try fixture.recoveryState() == before)
    }

    @Test func loadedCorruptStatePreservesExistingRecoveryHandoff() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedCandidate(intent: true)
        let file = fixture.installRoot.appendingPathComponent("recovery/state.json")
        let bad = Data("corrupt".utf8)
        try bad.write(to: file)
        fixture.loaded = true
        #expect(try fixture.tick() == .loaded)
        #expect(try Data(contentsOf: file) == bad)
        #expect(fixture.bootstrapCount == 0)
    }

    @Test func loadedIntentBusyDisabledAndProbeFailureRemainUnmodified() throws {
        for mode in 0..<3 {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try fixture.seedCandidate(intent: true)
            fixture.loaded = true
            let before = try fixture.recoveryState()
            var holder: SelfUpdater.UpdateSession?
            if mode == 0 {
                holder = try fixture.updater.beginUpdateSession(operation: "loaded-busy", timeout: 0)
            } else if mode == 1 {
                fixture.enabled = false
            } else {
                fixture.onDisabledProbe = { _ in throw SecurityCommandRunner.CommandError.timedOut }
            }
            defer { holder?.release() }
            #expect(try fixture.tick() == .loaded)
            holder?.release()
            #expect(try fixture.recoveryState() == before)
            #expect(fixture.bootstrapCount == 0)
        }
    }

    @Test func tamperedPredecessorIsRefusedWithoutBootstrapOrSignatureBypass() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedCandidate(failures: 2, issued: true)
        let recoveryRoot = fixture.installRoot.appendingPathComponent("recovery")
        let relativeBundle = "predecessor/Darkbloom.app"
        let bundle = recoveryRoot.appendingPathComponent(relativeBundle)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for name in ["darkbloom", "enclave", "mlx.metallib"] {
            try Data("tampered tiny fixture".utf8).write(to: bundle.appendingPathComponent(name))
        }
        let old = InstalledReleaseRecord(version: "1.0.0", releaseBundleHash: nil,
            installedBundleHash: "deliberately-not-the-tree-hash", binaryHash: "invalid",
            enclaveHash: "invalid", metallibHash: "invalid", installGeneration: 1, installedAt: 1)
        let predecessor = VerifiedPredecessor(release: old, layout: .app,
            bundlePath: relativeBundle, binaryPath: relativeBundle + "/darkbloom",
            enclavePath: relativeBundle + "/enclave", metallibPath: relativeBundle + "/mlx.metallib", verifiedAt: 1)
        try JSONEncoder().encode(predecessor).write(to: recoveryRoot.appendingPathComponent("predecessor/manifest.json"))
        try fixture.expireGrace()
        #expect(try fixture.tick() == .deferred)
        let refused = try fixture.recoveryState()
        #expect(refused.candidate?.failureCount == 3)
        #expect(refused.candidate?.rollbackBlockedReason?.contains("bundle hash mismatch") == true)
        #expect(refused.candidate?.retryNotBefore == 1601)
        #expect(fixture.updater.verifiesCodeSignatures)
        #expect(fixture.bootstrapCount == 0)
        #expect(try Data(contentsOf: bundle.appendingPathComponent("darkbloom")) == Data("tampered tiny fixture".utf8))
    }
}
