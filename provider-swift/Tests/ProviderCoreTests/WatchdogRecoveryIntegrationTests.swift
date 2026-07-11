import Foundation
import Testing
@testable import ProviderCore

@Suite("Watchdog update and rollback integration", .serialized)
struct WatchdogRecoveryIntegrationTests {
    @Test("down provider installs signed release before restart")
    func forwardUpdateWhileDown() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let mock = MockCoordinator(
            release: fixture.mockReleaseFixture(),
            releaseArtifact: fixture.artifact
        )
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let restarts = RecoveryRestartCounter()
        let service = makeService(
            updater: fixture.updater(baseURL: baseURL),
            restarts: restarts
        )
        let outcome = await service.recoverDownProvider(
            autoUpdateEnabled: true,
            now: 100
        )

        #expect(outcome == .restartIssued(updatedTo: "2.0.0", rolledBackTo: nil))
        #expect(restarts.value == 1)
        #expect(try fixture.liveBinaryContents() == "2.0.0-darkbloom")
        #expect(try fixture.persistentStateIsIntact())

        let state = try recoveryStore(fixture).loadState()
        #expect(state.candidate?.release.version == "2.0.0")
        #expect(state.candidate?.failureCount == 0)
        #expect(state.candidate?.pendingAttemptID != nil)
        #expect(state.predecessor?.release.version == "1.0.0")
        #expect(state.predecessor?.release.binaryHash.isEmpty == false)
        #expect(state.predecessor?.release.installedBundleHash.isEmpty == false)
        #expect(state.predecessor?.release.metallibHash.isEmpty == false)
    }

    @Test("third failed start restores predecessor and quarantines candidate")
    func threeFailureRollback() async throws {
        let context = try await installedCandidate()
        defer { context.fixture.cleanup() }
        defer { Task { await context.mock.shutdown() } }

        let first = await context.service.recoverDownProvider(
            autoUpdateEnabled: false,
            now: 200
        )
        let second = await context.service.recoverDownProvider(
            autoUpdateEnabled: false,
            now: 300
        )
        let third = await context.service.recoverDownProvider(
            autoUpdateEnabled: false,
            now: 400
        )

        #expect(first == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        #expect(second == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        #expect(third == .restartIssued(updatedTo: nil, rolledBackTo: "1.0.0"))
        #expect(try context.fixture.liveBinaryContents() == "1.0.0-darkbloom")
        #expect(try context.fixture.persistentStateIsIntact())

        let state = try recoveryStore(context.fixture).loadState()
        #expect(state.candidate == nil)
        #expect(state.current?.version == "1.0.0")
        #expect(state.quarantine?.version == "2.0.0")
        #expect(state.quarantine?.failureCount == 3)
        #expect(state.predecessor?.release.version == "1.0.0")
    }

    @Test("fresh matching heartbeat promotes after stabilization")
    func successfulStartReset() async throws {
        let context = try await installedCandidate(stabilizationSeconds: 60)
        defer { context.fixture.cleanup() }
        defer { Task { await context.mock.shutdown() } }

        let firstHeartbeat = DaemonState(
            pid: 4242,
            version: "2.0.0",
            writtenAt: 200,
            startedAt: 150
        )
        let first = context.service.observeHealthyProvider(
            providerRunning: true,
            daemonState: firstHeartbeat,
            now: 200
        )
        let secondHeartbeat = DaemonState(
            pid: 4242,
            version: "2.0.0",
            writtenAt: 261,
            startedAt: 150
        )
        let second = context.service.observeHealthyProvider(
            providerRunning: true,
            daemonState: secondHeartbeat,
            now: 261
        )

        #expect(first == .stabilizing(since: 200))
        #expect(second == .promoted(version: "2.0.0"))
        let state = try recoveryStore(context.fixture).loadState()
        #expect(state.candidate == nil)
        #expect(state.current?.version == "2.0.0")
        #expect(state.predecessor?.release.version == "1.0.0")
    }

    @Test("installed candidate retries restart without reinstalling")
    func installedCandidateRestartOnly() async throws {
        let context = try await installedCandidate()
        defer { context.fixture.cleanup() }
        defer { Task { await context.mock.shutdown() } }

        guard case .restartRequired(let current, let installed)
                = await context.updater.checkForUpdate()
        else {
            Issue.record("expected installed candidate restart requirement")
            return
        }
        #expect(current == "1.0.0")
        #expect(installed == "2.0.0")

        let predecessorBefore = try recoveryStore(context.fixture)
            .loadState().predecessor
        let outcome = await context.service.recoverDownProvider(
            autoUpdateEnabled: true,
            now: 200
        )
        #expect(outcome == .restartIssued(updatedTo: "2.0.0", rolledBackTo: nil))
        #expect(try fixturePredecessorCount(context.fixture) == 1)
        #expect(try recoveryStore(context.fixture).loadState().predecessor == predecessorBefore)
    }

    @Test("raised preload timeout raises the hung-candidate threshold — no false failure")
    func raisedPreloadTimeoutAvoidsFalseFailure() async throws {
        // Operator raised startup_preload_timeout_secs to 420s; the derived
        // hung-candidate threshold must exceed it (420 + 180 = 600).
        let derived = WatchdogRecoveryService.candidateStartupTimeout(
            preloadTimeoutSecs: 420
        )
        #expect(derived == 600)
        #expect(WatchdogRecoveryService.candidateStartupTimeout(
            preloadTimeoutSecs: 60
        ) == 300)

        let context = try await installedCandidate(
            candidateStartupTimeoutSeconds: derived
        )
        defer { context.fixture.cleanup() }
        defer { Task { await context.mock.shutdown() } }

        // 400s into a legitimate 420s preload: process alive, heartbeat not
        // yet written. The fixed 300s threshold would flag this healthy-but-
        // slow candidate as hung and charge a false start failure.
        let health = context.service.observeHealthyProvider(
            providerRunning: true,
            daemonState: nil,
            now: 100 + 400
        )
        #expect(health == .stabilizing(since: nil))

        let state = try recoveryStore(context.fixture).loadState()
        #expect(state.candidate?.failureCount == 0)
    }

    @Test("alive candidate within startup window defers the down-grace restart path — no false failure")
    func slowPreloadCandidateDefersRestartPath() async throws {
        // preload=420s → candidate startup window = max(300, 420+180) = 600s.
        // installedCandidate arms attemptStartedAt=100 via the install at now=100.
        let window = WatchdogRecoveryService.candidateStartupTimeout(
            preloadTimeoutSecs: 420
        )
        let context = try await installedCandidate(
            candidateStartupTimeoutSeconds: window
        )
        defer { context.fixture.cleanup() }
        defer { Task { await context.mock.shutdown() } }

        let restartsBefore = context.restarts.value  // 1 from the install

        // now=550: well past the 300s generic down-grace, but within the 600s
        // candidate window; the process is still ALIVE (legitimately preloading).
        // The pre-fix down-grace path charged a failed start here and restarted.
        let outcome = await context.service.recoverDownProvider(
            autoUpdateEnabled: false,
            providerProcessAlive: true,
            now: 550
        )
        guard case .retryBackoff(let until, let reason) = outcome else {
            Issue.record("expected startup-window backoff, got \(outcome)")
            return
        }
        #expect(until == 700)  // attemptStartedAt(100) + window(600)
        #expect(reason.contains("startup window"))
        #expect(context.restarts.value == restartsBefore)  // no restart issued

        let state = try recoveryStore(context.fixture).loadState()
        #expect(state.candidate?.failureCount == 0)         // no failed start charged
        #expect(state.candidate?.pendingAttemptID != nil)   // attempt still pending
        #expect(state.quarantine == nil)                    // no quarantine
        #expect(try context.fixture.liveBinaryContents() == "2.0.0-darkbloom")  // no rollback

        // Contrast: a DEAD candidate at the same instant IS charged a failed
        // start — proving the defer is gated on the process being alive.
        let dead = await context.service.recoverDownProvider(
            autoUpdateEnabled: false,
            providerProcessAlive: false,
            now: 560
        )
        #expect(dead == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        #expect(try recoveryStore(context.fixture)
            .loadState().candidate?.failureCount == 1)
    }

    @Test("flat rollback after an app candidate runs the flat predecessor, not the quarantined app")
    func flatToAppRollbackRunsFlatPredecessor() async throws {
        // Legacy .flat install updates to an .app candidate (leaves Darkbloom.app
        // in installRoot); the candidate fails 3x and rolls back to the flat
        // predecessor. The live bin/darkbloom must resolve to the flat
        // predecessor binary — NOT a symlink back into the quarantined app.
        let fixture = try UpdateRecoveryFixture(layout: .flat, candidateLayout: .app)
        defer { fixture.cleanup() }
        let mock = MockCoordinator(
            release: fixture.mockReleaseFixture(),
            releaseArtifact: fixture.artifact
        )
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let restarts = RecoveryRestartCounter()
        let service = makeService(
            updater: fixture.updater(baseURL: baseURL),
            restarts: restarts
        )

        let install = await service.recoverDownProvider(
            autoUpdateEnabled: true,
            now: 100
        )
        #expect(install == .restartIssued(updatedTo: "2.0.0", rolledBackTo: nil))
        #expect(fixture.appBundleExists())  // candidate app is now on disk
        #expect(try fixture.liveFlatBinaryResolvedContents() == "2.0.0-darkbloom")

        _ = await service.recoverDownProvider(autoUpdateEnabled: false, now: 200)
        _ = await service.recoverDownProvider(autoUpdateEnabled: false, now: 300)
        let third = await service.recoverDownProvider(autoUpdateEnabled: false, now: 400)
        #expect(third == .restartIssued(updatedTo: nil, rolledBackTo: "1.0.0"))

        // The fix: stale Darkbloom.app is retired and bin/darkbloom is the real
        // flat predecessor. Without it, ensureCanonicalLinks would re-point
        // bin/darkbloom into the leftover candidate app (→ "2.0.0-darkbloom").
        #expect(try fixture.liveFlatBinaryResolvedContents() == "1.0.0-darkbloom")
        #expect(!fixture.appBundleExists())
        #expect(try fixture.persistentStateIsIntact())

        let state = try recoveryStore(fixture).loadState()
        #expect(state.candidate == nil)
        #expect(state.current?.version == "1.0.0")
        #expect(state.quarantine?.version == "2.0.0")
    }

    @Test("exhausted tick budget skips the update at a safe point but still restarts")
    func tickDeadlineSkipsUpdateSafely() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let mock = MockCoordinator(
            release: fixture.mockReleaseFixture(),
            releaseArtifact: fixture.artifact
        )
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let restarts = RecoveryRestartCounter()
        let service = makeService(
            updater: fixture.updater(baseURL: baseURL),
            restarts: restarts,
            isPastTickDeadline: { true }
        )
        let outcome = await service.recoverDownProvider(
            autoUpdateEnabled: true,
            now: 100
        )

        // The newer release was available but the exhausted budget defers it;
        // the restart action still fires and the live install is untouched.
        #expect(outcome == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        #expect(restarts.value == 1)
        #expect(try fixture.liveBinaryContents() == "1.0.0-darkbloom")
        let state = try recoveryStore(fixture).loadState()
        #expect(state.candidate == nil)
    }

    @Test("watchdog network session is bounded")
    func watchdogSessionIsBounded() {
        let session = SelfUpdater.watchdogURLSession()
        #expect(
            session.configuration.timeoutIntervalForRequest
                == SelfUpdater.watchdogRequestTimeoutSeconds
        )
        #expect(
            session.configuration.timeoutIntervalForResource
                == SelfUpdater.watchdogResourceTimeoutSeconds
        )
        #expect(!session.configuration.waitsForConnectivity)
    }

    @Test("new version without heartbeat is a failed start, even if process lives")
    func hungCandidateCountsAsFailedStart() async throws {
        let context = try await installedCandidate()
        defer { context.fixture.cleanup() }
        defer { Task { await context.mock.shutdown() } }

        let health = context.service.observeHealthyProvider(
            providerRunning: true,
            daemonState: nil,
            now: 401
        )
        #expect(health == .inactiveCandidate(attemptStartedAt: 100))

        let recovery = await context.service.recoverDownProvider(
            autoUpdateEnabled: false,
            now: 401
        )
        #expect(recovery == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        #expect(try recoveryStore(context.fixture)
            .loadState().candidate?.failureCount == 1)
    }

    @Test("process death after atomic app exchange is recovered")
    func crashBetweenRenameAndMetadata() throws {
        enum InjectedCrash: Error { case afterExchange }

        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let updater = SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:1",
            installRoot: fixture.installRoot,
            verifyCodeSignatures: false,
            currentVersion: fixture.oldVersion
        )
        guard case .success(let staged) = updater.stageBundleForTesting(
            from: fixture.tarball,
            release: fixture.release,
            installDir: fixture.installRoot
        ) else {
            Issue.record("failed to stage fixture")
            return
        }

        let crashingStore = UpdateRecoveryStore(
            installRoot: fixture.installRoot,
            verifyCodeSignatures: false,
            faultInjector: { point in
                if point == .liveLayoutReplaced { throw InjectedCrash.afterExchange }
            }
        )
        let firstLock = try UpdateProcessLock.acquire(
            at: crashingStore.lockPath,
            operation: "crashing-commit"
        )
        #expect(throws: InjectedCrash.self) {
            try crashingStore.commit(
                staged: staged,
                currentVersion: fixture.oldVersion,
                now: 100
            )
        }
        firstLock.release()
        #expect(try fixture.liveBinaryContents() == "2.0.0-darkbloom")

        let recoveredStore = recoveryStore(fixture)
        let recoveryLock = try UpdateProcessLock.acquire(
            at: recoveredStore.lockPath,
            operation: "post-crash-recovery"
        )
        defer { recoveryLock.release() }
        try recoveredStore.recoverInterruptedTransaction(now: 101)

        let state = try recoveredStore.loadState()
        #expect(state.candidate?.release.version == "2.0.0")
        #expect(state.predecessor?.release.version == "1.0.0")
        #expect(!FileManager.default.fileExists(
            atPath: recoveredStore.recoveryRoot
                .appendingPathComponent("transaction.json").path
        ))
    }

    @Test("every app and flat transaction boundary is restart-safe")
    func allPowerLossBoundaries() throws {
        enum PowerLoss: Error { case injected }

        for layout in [
            VerifiedPredecessor.Layout.app,
            VerifiedPredecessor.Layout.flat,
        ] {
            for point in UpdateRecoveryStore.FaultPoint.allCases {
                let fixture = try UpdateRecoveryFixture(layout: layout)
                defer { fixture.cleanup() }
                let updater = SelfUpdater(
                    coordinatorBaseURL: "http://127.0.0.1:1",
                    installRoot: fixture.installRoot,
                    verifyCodeSignatures: false,
                    currentVersion: fixture.oldVersion
                )
                guard case .success(let staged) = updater.stageBundleForTesting(
                    from: fixture.tarball,
                    release: fixture.release,
                    installDir: fixture.installRoot
                ) else {
                    Issue.record("failed to stage \(layout) at \(point)")
                    continue
                }
                let store = UpdateRecoveryStore(
                    installRoot: fixture.installRoot,
                    verifyCodeSignatures: false,
                    faultInjector: { hit in
                        if hit == point { throw PowerLoss.injected }
                    }
                )
                let lock = try UpdateProcessLock.acquire(
                    at: store.lockPath,
                    operation: "power-loss-\(point)"
                )
                do {
                    try store.commit(
                        staged: staged,
                        currentVersion: fixture.oldVersion,
                        now: 100
                    )
                    Issue.record("fault \(point) did not interrupt commit")
                } catch PowerLoss.injected {
                    // Expected process-death boundary.
                }
                lock.release()

                let recovered = UpdateRecoveryStore(
                    installRoot: fixture.installRoot,
                    verifyCodeSignatures: false
                )
                let recoveryLock = try UpdateProcessLock.acquire(
                    at: recovered.lockPath,
                    operation: "power-loss-recovery"
                )
                try recovered.recoverInterruptedTransaction(now: 101)
                recoveryLock.release()

                let expected = point == .predecessorPromoted
                    ? "1.0.0-darkbloom"
                    : "2.0.0-darkbloom"
                #expect(try fixture.liveBinaryContents() == expected)
                #expect(try fixture.persistentStateIsIntact())
            }
        }
    }

    @Test("corrupt predecessor is refused without touching current install")
    func corruptPredecessorRefused() async throws {
        let context = try await installedCandidate()
        defer { context.fixture.cleanup() }
        defer { Task { await context.mock.shutdown() } }

        let predecessorBinary = context.fixture.installRoot
            .appendingPathComponent(
                "recovery/predecessor/Darkbloom.app/Contents/MacOS/darkbloom")
        try Data("tampered predecessor".utf8).write(to: predecessorBinary)

        _ = await context.service.recoverDownProvider(
            autoUpdateEnabled: false,
            now: 200
        )
        _ = await context.service.recoverDownProvider(
            autoUpdateEnabled: false,
            now: 300
        )
        let third = await context.service.recoverDownProvider(
            autoUpdateEnabled: false,
            now: 400
        )

        guard case .retryBackoff(_, let reason) = third else {
            Issue.record("expected rollback safety backoff, got \(third)")
            return
        }
        #expect(reason.contains("hash mismatch"))
        #expect(try context.fixture.liveBinaryContents() == "2.0.0-darkbloom")
        let state = try recoveryStore(context.fixture).loadState()
        #expect(state.candidate?.failureCount == 3)
        #expect(state.candidate?.retryNotBefore == 700)
        #expect(state.quarantine == nil)
    }

    @Test("flat predecessor enclave and full tree are verified")
    func flatPredecessorEnclaveVerification() async throws {
        let context = try await installedCandidate(layout: .flat)
        defer { context.fixture.cleanup() }
        defer { Task { await context.mock.shutdown() } }
        let store = recoveryStore(context.fixture)
        let state = try store.loadState()
        guard let predecessor = state.predecessor else {
            Issue.record("missing flat predecessor")
            return
        }
        try Data("tampered enclave".utf8).write(
            to: context.fixture.installRoot.appendingPathComponent(
                "recovery/predecessor/bin/darkbloom-enclave"
            )
        )
        #expect(throws: (any Error).self) {
            try store.verifyPredecessor(predecessor)
        }
    }

    @Test("missing predecessor enters retry backoff without touching live install")
    func missingPredecessorBackoff() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let app = fixture.installRoot.appendingPathComponent("Darkbloom.app")
        let appBin = app.appendingPathComponent("Contents/MacOS")
        let record = InstalledReleaseRecord(
            version: "1.0.0",
            releaseBundleHash: nil,
            installedBundleHash: try UpdateAtomicFilesystem.treeHash(root: app),
            binaryHash: try UpdateAtomicFilesystem.sha256(
                file: appBin.appendingPathComponent("darkbloom")),
            enclaveHash: try UpdateAtomicFilesystem.sha256(
                file: appBin.appendingPathComponent("darkbloom-enclave")),
            metallibHash: try UpdateAtomicFilesystem.sha256(
                file: appBin.appendingPathComponent("mlx.metallib")),
            installGeneration: 1,
            installedAt: 1
        )
        var state = UpdateRecoveryState(
            installGeneration: 1,
            candidate: PendingReleaseCandidate(
                release: record,
                failureCount: 2,
                launchIntent: nil,
                pendingAttemptID: "third-attempt",
                attemptStartedAt: 50,
                healthySince: nil,
                healthyProcessStartedAt: nil,
                retryNotBefore: nil,
                rollbackBlockedReason: nil
            )
        )
        let store = recoveryStore(fixture)
        try store.writeState(state)

        let restarts = RecoveryRestartCounter()
        let updater = SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:1",
            installRoot: fixture.installRoot,
            verifyCodeSignatures: false,
            currentVersion: fixture.oldVersion
        )
        let service = makeService(updater: updater, restarts: restarts)
        let outcome = await service.recoverDownProvider(
            autoUpdateEnabled: false,
            now: 100
        )

        guard case .retryBackoff(let until, let reason) = outcome else {
            Issue.record("expected missing-predecessor backoff, got \(outcome)")
            return
        }
        #expect(until == 400)
        #expect(reason.contains("no recorded predecessor"))
        #expect(restarts.value == 0)
        #expect(try fixture.liveBinaryContents() == "1.0.0-darkbloom")
        state = try store.loadState()
        #expect(state.candidate?.failureCount == 3)
        #expect(state.candidate?.retryNotBefore == 400)

        let stillWaiting = await service.recoverDownProvider(
            autoUpdateEnabled: false,
            now: 399
        )
        guard case .retryBackoff(let waitingUntil, _) = stillWaiting else {
            Issue.record("expected active backoff, got \(stillWaiting)")
            return
        }
        #expect(waitingUntil == 400)
        #expect(restarts.value == 0)

        let retried = await service.recoverDownProvider(
            autoUpdateEnabled: false,
            now: 400
        )
        #expect(retried == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        #expect(restarts.value == 1)

        let fourthFailure = await service.recoverDownProvider(
            autoUpdateEnabled: false,
            now: 500
        )
        guard case .retryBackoff(let nextUntil, _) = fourthFailure else {
            Issue.record("expected longer second backoff, got \(fourthFailure)")
            return
        }
        #expect(nextUntil == 1_100)
        #expect(try store.loadState().candidate?.failureCount == 4)
    }

    @Test("quarantine blocks bad version and strictly newer release escapes")
    func quarantineAndNewerEscape() async throws {
        let context = try await installedCandidate()
        defer { context.fixture.cleanup() }
        defer { Task { await context.mock.shutdown() } }
        _ = await context.service.recoverDownProvider(autoUpdateEnabled: false, now: 200)
        _ = await context.service.recoverDownProvider(autoUpdateEnabled: false, now: 300)
        _ = await context.service.recoverDownProvider(autoUpdateEnabled: false, now: 400)

        let blocked = await context.updater.checkForUpdate()
        guard case .quarantined(let version, _) = blocked else {
            Issue.record("expected v2 quarantine, got \(blocked)")
            return
        }
        #expect(version == "2.0.0")

        let newer = try UpdateRecoveryFixture(oldVersion: "1.0.0", newVersion: "3.0.0")
        defer { newer.cleanup() }
        let newerMock = MockCoordinator(
            release: newer.mockReleaseFixture(),
            releaseArtifact: newer.artifact
        )
        let newerBase = try await newerMock.start()
        defer { Task { await newerMock.shutdown() } }
        let updater = SelfUpdater(
            coordinatorBaseURL: newerBase.absoluteString,
            installRoot: context.fixture.installRoot,
            verifyCodeSignatures: false,
            currentVersion: "1.0.0"
        )
        let service = makeService(updater: updater, restarts: context.restarts)
        let outcome = await service.recoverDownProvider(
            autoUpdateEnabled: true,
            now: 500
        )
        #expect(outcome == .restartIssued(updatedTo: "3.0.0", rolledBackTo: nil))
        #expect(try context.fixture.liveBinaryContents() == "3.0.0-darkbloom")
    }

    @Test("auto-update disabled restarts without querying or replacing")
    func autoUpdateDisabled() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let updater = SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:1",
            installRoot: fixture.installRoot,
            verifyCodeSignatures: false,
            currentVersion: fixture.oldVersion
        )
        let restarts = RecoveryRestartCounter()
        let service = makeService(updater: updater, restarts: restarts)

        let outcome = await service.recoverDownProvider(
            autoUpdateEnabled: false,
            now: 100
        )
        #expect(outcome == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        #expect(restarts.value == 1)
        #expect(try fixture.liveBinaryContents() == "1.0.0-darkbloom")
        #expect(try recoveryStore(fixture).loadState().candidate == nil)
    }

    @Test("watchdog defers while another process owns update lock")
    func watchdogLockContention() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let store = recoveryStore(fixture)
        let held = try UpdateProcessLock.acquire(
            at: store.lockPath,
            operation: "manual-update"
        )
        defer { held.release() }

        let restarts = RecoveryRestartCounter()
        let updater = SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:1",
            installRoot: fixture.installRoot,
            verifyCodeSignatures: false,
            currentVersion: fixture.oldVersion
        )
        let service = makeService(updater: updater, restarts: restarts)
        let outcome = await service.recoverDownProvider(
            autoUpdateEnabled: true,
            now: 100
        )
        guard case .lockBusy(let reason) = outcome else {
            Issue.record("expected lock contention, got \(outcome)")
            return
        }
        #expect(reason.contains("manual-update"))
        #expect(restarts.value == 0)
    }

    @Test("intentional stop racing download cancels install")
    func intentionalStopDuringDownload() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let mock = MockCoordinator(
            release: fixture.mockReleaseFixture(),
            releaseArtifact: fixture.artifact
        )
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let updater = fixture.updater(baseURL: baseURL)
        let session = try updater.beginUpdateSession(
            operation: "watchdog-stop-race"
        )
        defer { session.release() }
        try session.recover(now: 100)

        let result = await updater.update(
            session: session,
            beforeInstall: { false }
        )
        guard case .cancelled(let reason) = result else {
            Issue.record("expected stop-race cancellation, got \(result)")
            return
        }
        #expect(reason.contains("intentionally stopped"))
        #expect(try fixture.liveBinaryContents() == "1.0.0-darkbloom")
        #expect(try recoveryStore(fixture).loadState().candidate == nil)
    }

    @Test("explicit manual override reinstalls quarantined version")
    func manualOverride() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let store = recoveryStore(fixture)
        var state = UpdateRecoveryState()
        state.quarantine = FailedReleaseQuarantine(
            version: "2.0.0",
            failureCount: 3,
            quarantinedAt: 10,
            reason: "three failed starts"
        )
        try store.writeState(state)

        let mock = MockCoordinator(
            release: fixture.mockReleaseFixture(),
            releaseArtifact: fixture.artifact
        )
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let updater = fixture.updater(baseURL: baseURL)

        guard case .quarantined = await updater.checkForUpdate() else {
            Issue.record("non-override check did not honor quarantine")
            return
        }
        let result = await updater.update(manualOverride: true)
        #expect(result.isUpdated(to: "2.0.0"))
        #expect(try fixture.liveBinaryContents() == "2.0.0-darkbloom")
        let installed = try store.loadState()
        #expect(installed.quarantine == nil)
        #expect(installed.candidate?.pendingAttemptID == nil)
        #expect(installed.candidate?.attemptStartedAt == nil)
    }

    @Test("intentional stop remains unmanaged")
    func intentionalStop() {
        let decision = WatchdogPolicy.decide(
            autoRestartEnabled: true,
            providerLoaded: false,
            providerRunning: false,
            downSince: 1,
            now: 1_000
        )
        #expect(decision == .notManaged)
    }

    private struct InstalledContext {
        let fixture: UpdateRecoveryFixture
        let mock: MockCoordinator
        let updater: SelfUpdater
        let service: WatchdogRecoveryService
        let restarts: RecoveryRestartCounter
    }

    private func installedCandidate(
        stabilizationSeconds: Double = 180,
        candidateStartupTimeoutSeconds: Double = 300,
        layout: VerifiedPredecessor.Layout = .app
    ) async throws -> InstalledContext {
        let fixture = try UpdateRecoveryFixture(layout: layout)
        let mock = MockCoordinator(
            release: fixture.mockReleaseFixture(),
            releaseArtifact: fixture.artifact
        )
        let baseURL = try await mock.start()
        let updater = fixture.updater(baseURL: baseURL)
        let restarts = RecoveryRestartCounter()
        let service = makeService(
            updater: updater,
            restarts: restarts,
            stabilizationSeconds: stabilizationSeconds,
            candidateStartupTimeoutSeconds: candidateStartupTimeoutSeconds
        )
        let outcome = await service.recoverDownProvider(
            autoUpdateEnabled: true,
            now: 100
        )
        guard outcome == .restartIssued(updatedTo: "2.0.0", rolledBackTo: nil) else {
            await mock.shutdown()
            fixture.cleanup()
            throw TestSetupError.initialUpdateFailed("\(outcome)")
        }
        return InstalledContext(
            fixture: fixture,
            mock: mock,
            updater: updater,
            service: service,
            restarts: restarts
        )
    }

    private func makeService(
        updater: SelfUpdater,
        restarts: RecoveryRestartCounter,
        stabilizationSeconds: Double = 180,
        candidateStartupTimeoutSeconds: Double = 300,
        isPastTickDeadline: @escaping @Sendable () -> Bool = { false }
    ) -> WatchdogRecoveryService {
        WatchdogRecoveryService(
            updater: updater,
            dependencies: .init(
                kickstartIfLoaded: {
                    restarts.increment()
                    return true
                },
                // Injected: tests must never shell out to the real
                // `launchctl print` for the host's provider job.
                launchSnapshot: { nil },
                processAlive: { _ in true },
                isPastTickDeadline: isPastTickDeadline,
                log: { _ in }
            ),
            stabilizationSeconds: stabilizationSeconds,
            candidateStartupTimeoutSeconds: candidateStartupTimeoutSeconds
        )
    }

    private func recoveryStore(
        _ fixture: UpdateRecoveryFixture
    ) -> UpdateRecoveryStore {
        UpdateRecoveryStore(
            installRoot: fixture.installRoot,
            verifyCodeSignatures: false
        )
    }

    private func fixturePredecessorCount(
        _ fixture: UpdateRecoveryFixture
    ) throws -> Int {
        let recovery = fixture.installRoot.appendingPathComponent("recovery")
        return try FileManager.default.contentsOfDirectory(atPath: recovery.path)
            .filter { $0 == "predecessor" }
            .count
    }

    private enum TestSetupError: Error {
        case initialUpdateFailed(String)
    }
}

private extension UpdateResult {
    func isUpdated(to version: String) -> Bool {
        if case .updated(_, let installed) = self {
            return installed == version
        }
        return false
    }
}
