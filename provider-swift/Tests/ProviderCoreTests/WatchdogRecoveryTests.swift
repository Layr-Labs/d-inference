import Foundation
import Testing

@testable import ProviderCore


@Suite("Watchdog re-arm action")
struct WatchdogRearmActionTests {
    @Test("auto_restart=true always arms")
    func armWhenEnabled() {
        #expect(WatchdogAgent.rearmAction(autoRestartEnabled: true, isLoaded: false) == .arm)
        #expect(WatchdogAgent.rearmAction(autoRestartEnabled: true, isLoaded: true) == .arm)
    }

    @Test("auto_restart=false disarms a loaded watchdog instead of leaving the stale job")
    func disarmWhenOptedOutAndLoaded() {
        // Pre-fix, an opted-out config left a previously armed watchdog
        // running on its OLD plist config, which could keep relaunching the
        // provider after crashes despite the opt-out.
        #expect(WatchdogAgent.rearmAction(autoRestartEnabled: false, isLoaded: true) == .disarm)
    }

    @Test("auto_restart=false with nothing loaded does nothing")
    func noopWhenOptedOutAndUnloaded() {
        #expect(WatchdogAgent.rearmAction(autoRestartEnabled: false, isLoaded: false) == nil)
    }
}

/// The watchdog launchd plist shape.
@Suite("Watchdog agent plist")
struct WatchdogAgentPlistTests {
    @Test("plist keeps one persistent watchdog alive and delegates cadence internally")
    func plistShape() {
        let plist = WatchdogAgent.makeWatchdogPlist(
            label: "io.darkbloom.watchdog",
            programArguments: ["/usr/local/bin/darkbloom", "watchdog"],
            logPath: "/tmp/watchdog.log"
        )
        #expect(plist["Label"] as? String == "io.darkbloom.watchdog")
        #expect(plist["ProgramArguments"] as? [String] == ["/usr/local/bin/darkbloom", "watchdog"])
        #expect(plist["StartInterval"] == nil)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["ThrottleInterval"] as? Int == 10)
        #expect(plist["ProcessType"] as? String == "Background")
        #expect(plist["StandardOutPath"] as? String == "/tmp/watchdog.log")
        #expect(plist["StandardErrorPath"] as? String == "/tmp/watchdog.log")
    }

    @Test("re-arm preserves the installed plist config when no override is given")
    func rearmPreservesInstalledConfig() {
        let installedArguments = [
            "/opt/darkbloom",
            "watchdog",
            "--config",
            "/tmp/custom-provider.toml",
        ]
        let installed = WatchdogAgent.configPathArgument(in: installedArguments)
        #expect(installed?.path == "/tmp/custom-provider.toml")

        // No explicit --config on `darkbloom restart`: the previously
        // installed custom config MUST survive the plist rewrite.
        let preserved = WatchdogAgent.rearmConfigPath(
            explicit: nil,
            installed: installed
        )
        #expect(preserved?.path == "/tmp/custom-provider.toml")

        // An explicit override wins over the installed value.
        let overridden = WatchdogAgent.rearmConfigPath(
            explicit: "/tmp/other.toml",
            installed: installed
        )
        #expect(overridden?.path == "/tmp/other.toml")

        // Short flag parses too; missing value or absent flag yields nil.
        #expect(
            WatchdogAgent.configPathArgument(
                in: ["/opt/darkbloom", "watchdog", "-c", "/tmp/short.toml"]
            )?.path == "/tmp/short.toml"
        )
        #expect(WatchdogAgent.configPathArgument(
            in: ["/opt/darkbloom", "watchdog", "--config"]
        ) == nil)
        #expect(WatchdogAgent.configPathArgument(
            in: ["/opt/darkbloom", "watchdog"]
        ) == nil)
    }

    @Test("plist propagates custom config and update opt-out environment")
    func configAndEnvironment() {
        let arguments = [
            "/opt/darkbloom",
            "watchdog",
            "--config",
            "/tmp/provider.toml",
        ]
        let plist = WatchdogAgent.makeWatchdogPlist(
            label: "io.darkbloom.watchdog",
            programArguments: arguments,
            logPath: "/tmp/watchdog.log",
            environment: [
                "DARKBLOOM_NO_UPDATE_CHECK": "1",
                "UNRELATED_SECRET": "no",
            ]
        )
        #expect(plist["ProgramArguments"] as? [String] == arguments)
        let environment = plist["EnvironmentVariables"] as? [String: String]
        #expect(environment == ["DARKBLOOM_NO_UPDATE_CHECK": "1"])
    }

    @Test("the watchdog label is distinct from the provider label")
    func distinctLabel() {
        #expect(WatchdogAgent.label != LaunchAgent.label)
        #expect(LaunchAgent.supportedLabels.contains(LaunchAgent.label))
    }
}

@Suite("Watchdog persistent cadence", .serialized)
struct WatchdogSchedulerTests {
    @Test("injected cadence repeats and cancellation exits at the sleep boundary")
    func cadenceAndCancellation() async {
        let sleepRequested = AsyncTestLatch()
        let advance = AsyncTestLatch()
        let (ticks, continuation) = AsyncStream<Void>.makeStream()
        var iterator = ticks.makeAsyncIterator()
        let scheduler = WatchdogScheduler(interval: .seconds(60)) { _ in
            sleepRequested.signal()
            await advance.wait()
            try Task.checkCancellation()
        }
        let task = Task {
            await scheduler.run { continuation.yield() }
            continuation.finish()
        }

        let firstTick = await iterator.next()
        #expect(firstTick != nil)
        await sleepRequested.wait()
        advance.signal()
        let secondTick = await iterator.next()
        #expect(secondTick != nil)
        await sleepRequested.wait()
        advance.signal()
        let thirdTick = await iterator.next()
        #expect(thirdTick != nil)
        await sleepRequested.wait()

        task.cancel()
        advance.signal()
        await task.value
        let afterCancellation = await iterator.next()
        #expect(afterCancellation == nil)
    }
}


@Suite("Crash-loop guard recovery wiring", .serialized)
struct CrashLoopGuardRecoveryWiringTests {

    /// Ordered action log: the load-bearing property is that a trip lands
    /// BEFORE the kickstart, so the daemon this very tick relaunches reads
    /// the guard on its first model load.
    private final class ActionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _actions: [String] = []
        var actions: [String] { lock.withLock { _actions } }
        func append(_ action: String) { lock.withLock { _actions.append(action) } }
    }

    private func makeService(
        updater: SelfUpdater,
        log: ActionLog,
        kickstartStarts: Bool = true
    ) -> WatchdogRecoveryService {
        WatchdogRecoveryService(
            updater: updater,
            dependencies: .init(
                kickstartIfLoaded: {
                    log.append(kickstartStarts ? "kickstart" : "kickstart-refused")
                    return kickstartStarts
                },
                // Injected: tests must never shell out to the real
                // `launchctl print` for the host's provider job.
                launchSnapshot: { nil },
                processAlive: { _ in true },
                tripKVBackendGuard: { crashCount, _, guardedVersion in
                    log.append("trip(\(crashCount),v\(guardedVersion))")
                    return KVBackendCrashLoopGuard.StagedTrip(
                        persisted: true,
                        undo: { log.append("untrip") },
                        emit: { log.append("emit") })
                },
                noteCrashLoopChain: { count, version in
                    log.append("chain(\(count),v\(version))")
                },
                log: { _ in }))
    }

    private func plainUpdater(_ fixture: UpdateRecoveryFixture) -> SelfUpdater {
        SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:1",
            installRoot: fixture.installRoot,
            verifyCodeSignatures: false,
            currentVersion: fixture.oldVersion)
    }

    @Test("at the threshold the guard trips BEFORE the kickstart")
    func tripsBeforeKickstart() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let log = ActionLog()
        let outcome = await makeService(updater: plainUpdater(fixture), log: log)
            .recoverDownProvider(
                autoUpdateEnabled: false,
                crashLoopRestartCount: WatchdogPolicy.crashLoopTripThreshold,
                lastRestartVersion: fixture.oldVersion,
                now: 1_000)
        #expect(outcome == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        // No self-update has ever run in this fixture, so the installed
        // version IS the process version (the fixture's oldVersion), the
        // recorded chain version matches it (continuity), and the guard is
        // written before the kickstart — never rolled back on this path.
        // The trip EVENT fires only after the kickstart: the trip becomes
        // real (alertable) exactly when the counted restart is issued.
        #expect(log.actions == [
            "chain(3,v\(fixture.oldVersion))",
            "trip(3,v\(fixture.oldVersion))",
            "kickstart",
            "emit",
        ])
    }

    @Test("below the threshold, and for callers that do not track the chain, no trip")
    func belowThresholdNoTrip() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let log = ActionLog()
        let service = makeService(updater: plainUpdater(fixture), log: log)
        _ = await service.recoverDownProvider(
            autoUpdateEnabled: false,
            crashLoopRestartCount: WatchdogPolicy.crashLoopTripThreshold - 1,
            lastRestartVersion: fixture.oldVersion,
            now: 1_000)
        // Default 0: the healthy-path candidate re-entries, which handle a
        // RUNNING-but-inert process, not the launchd death loop. (Version
        // scoping keeps 0 at 0 even though no recorded version is passed.)
        _ = await service.recoverDownProvider(autoUpdateEnabled: false, now: 2_000)
        #expect(log.actions == [
            "chain(2,v\(fixture.oldVersion))",
            "kickstart",
            "chain(0,v\(fixture.oldVersion))",
            "kickstart",
        ])
    }

    @Test("a binary promotion resets the chain: the new install's first crash is 1, not N+1")
    func promotionResetsChain() async throws {
        // v0.8.0 tripped at 3, then a candidate stabilized and PROMOTED
        // (~10 min — under the 15-min healthy reset). The new binary's
        // first short-lived crash must compute 1, not 4: without the
        // version scope it would instantly guard the release that was
        // shipped to fix the loop. Model the post-promotion state: the
        // durable installed record says newVersion, the chain was recorded
        // against oldVersion.
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let updater = plainUpdater(fixture)

        let session = try updater.beginUpdateSession(operation: "test-promo", timeout: 0)
        var state = try session.readState()
        state.current = InstalledReleaseRecord(
            version: fixture.newVersion,
            releaseBundleHash: nil,
            installedBundleHash: "bundle-hash",
            binaryHash: "binary-hash",
            enclaveHash: "enclave-hash",
            metallibHash: "metallib-hash",
            installGeneration: 1,
            installedAt: 50)
        try session.writeState(state)
        session.release()

        let log = ActionLog()
        let outcome = await makeService(updater: updater, log: log)
            .recoverDownProvider(
                autoUpdateEnabled: false,
                crashLoopRestartCount: 4,  // raw: old chain at 3, +1
                lastRestartVersion: fixture.oldVersion,
                now: 1_000)
        #expect(outcome == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        // Scoped to 1 for the new install — reported for persistence, and
        // decisively NOT tripped.
        #expect(log.actions == ["chain(1,v\(fixture.newVersion))", "kickstart"])
    }

    @Test("a nil recorded version (legacy state file) cannot prove continuity: reset")
    func legacyNilVersionResets() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let log = ActionLog()
        _ = await makeService(updater: plainUpdater(fixture), log: log)
            .recoverDownProvider(
                autoUpdateEnabled: false,
                crashLoopRestartCount: WatchdogPolicy.crashLoopTripThreshold,
                lastRestartVersion: nil,
                now: 1_000)
        #expect(log.actions == ["chain(1,v\(fixture.oldVersion))", "kickstart"],
            "a legacy chain with no recorded version must reset, not trip")
    }

    @Test("a refused kickstart rolls the fresh trip back — no stranded guard")
    func refusedKickstartRollsBackTrip() async throws {
        // The operator stopped/unloaded the provider between the guard
        // write and the kickstart (`.noLongerLoaded`): no restart was
        // issued, the persisted counter correctly does not advance — so
        // the guard written for that never-issued third restart must not
        // strand and force contiguous on the next manual start.
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let log = ActionLog()
        let outcome = await makeService(
            updater: plainUpdater(fixture), log: log, kickstartStarts: false)
            .recoverDownProvider(
                autoUpdateEnabled: false,
                crashLoopRestartCount: WatchdogPolicy.crashLoopTripThreshold,
                lastRestartVersion: fixture.oldVersion,
                now: 1_000)
        #expect(outcome == .noLongerLoaded)
        // No "emit" entry: an undone trip leaves no telemetry trace — the
        // exact-equality assertion pins zero emissions on this path.
        #expect(log.actions == [
            "chain(3,v\(fixture.oldVersion))",
            "trip(3,v\(fixture.oldVersion))",
            "kickstart-refused",
            "untrip",
        ])
    }

    @Test("a pending update candidate with a viable rollback path suppresses the trip")
    func candidateRollbackWins() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let mock = MockCoordinator(
            release: fixture.mockReleaseFixture(),
            releaseArtifact: fixture.artifact)
        try await mock.withRunning { baseURL in
        let log = ActionLog()
        let service = makeService(updater: fixture.updater(baseURL: baseURL), log: log)

        // Install the v2 candidate (kickstart #1 — no chain yet).
        let install = await service.recoverDownProvider(autoUpdateEnabled: true, now: 100)
        #expect(install == .restartIssued(updatedTo: "2.0.0", rolledBackTo: nil))

        // Now the box crash-loops with the candidate pending. Even at the
        // guard threshold the trip is SUPPRESSED: the candidate's own
        // failure counter (same threshold, charged on these same restarts)
        // is walking toward a binary rollback, which fixes paged too —
        // the pre-0.8.0 predecessor resolves `.auto` to contiguous.
        //
        // The chain stamps the CANDIDATE's version while it is pending (the
        // candidate binary is the one launchd boots and crashes): the first
        // candidate crash rescopes the pre-install chain to 1, and the
        // recorded version follows what the previous call reported.
        let first = await service.recoverDownProvider(
            autoUpdateEnabled: false, crashLoopRestartCount: 3,
            lastRestartVersion: fixture.oldVersion, now: 200)
        let second = await service.recoverDownProvider(
            autoUpdateEnabled: false, crashLoopRestartCount: 2,
            lastRestartVersion: fixture.newVersion, now: 300)
        #expect(first == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        #expect(second == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        #expect(log.actions.contains("chain(1,v\(fixture.newVersion))"),
            "the first candidate crash rescopes the chain to the candidate version")
        #expect(log.actions.contains("chain(2,v\(fixture.newVersion))"))

        // Third failure: the ROLLBACK fires. Still no trip — the rollback
        // just won, and a guard for a version that is leaving the box would
        // be a stranded record. The chain rescopes AGAIN, to the restored
        // predecessor (a rollback is a version change too).
        let third = await service.recoverDownProvider(
            autoUpdateEnabled: false, crashLoopRestartCount: 3,
            lastRestartVersion: fixture.newVersion, now: 400)
        #expect(third == .restartIssued(updatedTo: nil, rolledBackTo: "1.0.0"))
        #expect(log.actions.contains("chain(1,v\(fixture.oldVersion))"))

        #expect(!log.actions.contains { $0.hasPrefix("trip") },
            "candidate rollback owns recovery end to end — the guard must never fire")
        #expect(log.actions.filter { $0 == "kickstart" }.count == 4)

        // AFTER the rollback the candidate is gone and the restored
        // predecessor's chain walks its OWN fresh window: if the rolled-back
        // binary keeps crash-looping, the guard trips for it at the
        // threshold — stamped with the predecessor's version (the durable
        // installed record is oldVersion again).
        let postRollback = await service.recoverDownProvider(
            autoUpdateEnabled: false, crashLoopRestartCount: 2,
            lastRestartVersion: fixture.oldVersion, now: 500)
        #expect(postRollback == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        #expect(!log.actions.contains { $0.hasPrefix("trip") },
            "two post-rollback crashes stay under the threshold")
        let thirdPostRollback = await service.recoverDownProvider(
            autoUpdateEnabled: false, crashLoopRestartCount: 3,
            lastRestartVersion: fixture.oldVersion, now: 600)
        #expect(thirdPostRollback == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        #expect(log.actions.contains("trip(3,v\(fixture.oldVersion))"))
        }
    }

    @Test("post-self-update version skew: the guard stamps the INSTALLED daemon version")
    func skewStampsInstalledDaemonVersion() async throws {
        // The persistent watchdog keeps running its OLD executable image
        // (fixture.oldVersion) after it installs and promotes a newer
        // release. Simulate the post-promotion state: the update-recovery
        // durable installed record says newVersion while the process image —
        // the SelfUpdater's currentVersion — is still oldVersion. This is
        // exactly the window where crash loops are most likely, and a guard
        // stamped with the watchdog image's version would never activate.
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let updater = plainUpdater(fixture)  // process image at oldVersion

        let session = try updater.beginUpdateSession(operation: "test-skew", timeout: 0)
        var state = try session.readState()
        state.current = InstalledReleaseRecord(
            version: fixture.newVersion,
            releaseBundleHash: nil,
            installedBundleHash: "bundle-hash",
            binaryHash: "binary-hash",
            enclaveHash: "enclave-hash",
            metallibHash: "metallib-hash",
            installGeneration: 1,
            installedAt: 50)
        try session.writeState(state)
        session.release()

        // Trip through the REAL guard action into a hermetic record path.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-backend-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let env = [KVBackendGuardStore.pathEnvKey: url.path]
        let events = ActionLog()
        let service = WatchdogRecoveryService(
            updater: updater,
            dependencies: .init(
                kickstartIfLoaded: { true },
                launchSnapshot: { nil },
                processAlive: { _ in true },
                tripKVBackendGuard: { crashCount, tripNow, guardedVersion in
                    KVBackendCrashLoopGuard.stageTrip(
                        crashCount: crashCount, now: tripNow,
                        guardedVersion: guardedVersion, lastKnownModel: nil,
                        environment: env, emitTelemetry: { _ in events.append("event") })
                },
                log: { _ in }))

        let outcome = await service.recoverDownProvider(
            autoUpdateEnabled: false,
            crashLoopRestartCount: WatchdogPolicy.crashLoopTripThreshold,
            // The chain accumulated on the NEW daemon: each of its restarts
            // stamped the resolved installed version, so continuity holds.
            lastRestartVersion: fixture.newVersion,
            now: 1_000)
        #expect(outcome == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        #expect(events.actions == ["event"],
            "an issued kickstart emits the trip event exactly once")

        let record = KVBackendGuardStore.read(environment: env)
        #expect(record?.providerVersion == fixture.newVersion,
            "the guard must bind the installed daemon (\(fixture.newVersion)), not the watchdog image (\(fixture.oldVersion))")
        // The NEW daemon — the one launchd actually boots and the one that
        // was crash-looping — honors the guard...
        #expect(EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
            record: record, runningVersion: fixture.newVersion))
        // ...and its startup stale-clear keeps it (same version, not stale).
        #expect(KVBackendGuardStore.clearIfStale(
            runningVersion: fixture.newVersion, environment: env) == nil)
        #expect(KVBackendGuardStore.read(environment: env) == record)
        // The existing clears still work: the NEXT release after the guarded
        // one reads it as stale and deletes it at startup.
        #expect(KVBackendGuardStore.clearIfStale(
            runningVersion: "3.0.0", environment: env) == record)
        #expect(KVBackendGuardStore.read(environment: env) == nil)
    }

    /// Persist the exact state the P1 review names: a pending candidate that
    /// IS the installed live layout (v-new), whose rollback was REFUSED and
    /// whose retry backoff has already expired, while `state.current` still
    /// names the predecessor (v-old) — `installCandidate` leaves `current`
    /// unchanged until promotion.
    private func writeRefusedRollbackCandidateState(
        fixture: UpdateRecoveryFixture,
        updater: SelfUpdater,
        retryNotBefore: Double
    ) throws {
        let session = try updater.beginUpdateSession(
            operation: "test-refused-rollback", timeout: 0)
        var state = try session.readState()
        state.current = InstalledReleaseRecord(
            version: fixture.oldVersion,
            releaseBundleHash: nil,
            installedBundleHash: "old-bundle-hash",
            binaryHash: "old-binary-hash",
            enclaveHash: "old-enclave-hash",
            metallibHash: "old-metallib-hash",
            installGeneration: 1,
            installedAt: 10)
        state.candidate = PendingReleaseCandidate(
            release: InstalledReleaseRecord(
                version: fixture.newVersion,
                releaseBundleHash: nil,
                installedBundleHash: "new-bundle-hash",
                binaryHash: "new-binary-hash",
                enclaveHash: "new-enclave-hash",
                metallibHash: "new-metallib-hash",
                installGeneration: 2,
                installedAt: 50),
            failureCount: UpdateRecoveryState.rollbackThreshold,
            launchIntent: nil,
            pendingAttemptID: nil,
            attemptStartedAt: nil,
            healthySince: nil,
            healthyProcessStartedAt: nil,
            retryNotBefore: retryNotBefore,
            rollbackBlockedReason: "predecessor bundle unreadable")
        try session.writeState(state)
        session.release()
    }

    @Test("a refused rollback binds the guard to the CANDIDATE version launchd will start")
    func refusedRollbackStampsCandidateVersion() async throws {
        // While a pending candidate exists, the LIVE layout is the
        // candidate's — `state.current` still names the predecessor, and the
        // watchdog's own process version is commonly that same predecessor.
        // Once the candidate's rollback is refused, the guard is the one
        // automated mitigation left, and launchd will kickstart the
        // CANDIDATE binary: a guard stamped from `current` (or the process
        // image) would read as stale to the relaunched candidate daemon and
        // never bind — it would even be deleted at its startup.
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let updater = plainUpdater(fixture)  // process image at oldVersion
        try writeRefusedRollbackCandidateState(
            fixture: fixture, updater: updater, retryNotBefore: 900)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-backend-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let env = [KVBackendGuardStore.pathEnvKey: url.path]
        let service = WatchdogRecoveryService(
            updater: updater,
            dependencies: .init(
                kickstartIfLoaded: { true },
                launchSnapshot: { nil },
                processAlive: { _ in true },
                tripKVBackendGuard: { crashCount, tripNow, guardedVersion in
                    KVBackendCrashLoopGuard.stageTrip(
                        crashCount: crashCount, now: tripNow,
                        guardedVersion: guardedVersion, lastKnownModel: nil,
                        environment: env, emitTelemetry: { _ in })
                },
                log: { _ in }))

        // The retry backoff (retryNotBefore: 900) has expired at now: the
        // recovery path re-enters, skips the refused rollback, and trips.
        let outcome = await service.recoverDownProvider(
            autoUpdateEnabled: false,
            crashLoopRestartCount: WatchdogPolicy.crashLoopTripThreshold,
            // The chain accumulated on the CANDIDATE's crashes, each stamped
            // with the candidate version — continuity holds.
            lastRestartVersion: fixture.newVersion,
            now: 1_000)
        #expect(outcome == .restartIssued(updatedTo: nil, rolledBackTo: nil))

        let record = KVBackendGuardStore.read(environment: env)
        #expect(record?.providerVersion == fixture.newVersion,
            "the guard must bind the candidate launchd will start (\(fixture.newVersion)), not the predecessor `state.current` names (\(fixture.oldVersion))")
        // The relaunched CANDIDATE daemon honors it...
        #expect(EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
            record: record, runningVersion: fixture.newVersion))
        // ...its startup stale-clear keeps it (same version, not stale)...
        #expect(KVBackendGuardStore.clearIfStale(
            runningVersion: fixture.newVersion, environment: env) == nil)
        #expect(KVBackendGuardStore.read(environment: env) == record)
        // ...and it never binds the predecessor.
        #expect(!EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
            record: record, runningVersion: fixture.oldVersion))
    }

    @Test("a bookkeeping failure AFTER the kickstart must not undo the guard")
    func postKickstartWriteFailureKeepsGuard() async throws {
        // `kickstartIfLoaded()` succeeded — launchd has already issued the
        // counted restart — and THEN the candidate-state write fails (disk
        // full, unwritable recovery dir). The attempt returns `.failed`, but
        // the relaunched daemon is booting NOW: undoing the trip would bring
        // it up paged and guardless while the chain counter (persisted only
        // for `.restartIssued`) did not advance either. The undo must be
        // scoped strictly to exits where the kickstart was NOT issued.
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let updater = plainUpdater(fixture)
        // A candidate is required so the post-kickstart `markLaunchIssued`
        // actually mutates state and attempts the failing write; the
        // refused-rollback shape also makes the trip eligible.
        try writeRefusedRollbackCandidateState(
            fixture: fixture, updater: updater, retryNotBefore: 900)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-backend-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let env = [KVBackendGuardStore.pathEnvKey: url.path]
        let statePath = fixture.installRoot
            .appendingPathComponent("recovery/state.json")
        let events = ActionLog()
        let service = WatchdogRecoveryService(
            updater: updater,
            dependencies: .init(
                kickstartIfLoaded: {
                    // The recovery dir dies BETWEEN the kickstart and the
                    // launch bookkeeping: a directory at the state path makes
                    // the atomic replace (rename) fail.
                    try? FileManager.default.removeItem(at: statePath)
                    try? FileManager.default.createDirectory(
                        at: statePath, withIntermediateDirectories: false)
                    return true
                },
                launchSnapshot: { nil },
                processAlive: { _ in true },
                tripKVBackendGuard: { crashCount, tripNow, guardedVersion in
                    KVBackendCrashLoopGuard.stageTrip(
                        crashCount: crashCount, now: tripNow,
                        guardedVersion: guardedVersion, lastKnownModel: nil,
                        environment: env, emitTelemetry: { _ in events.append("event") })
                },
                log: { _ in }))

        let outcome = await service.recoverDownProvider(
            autoUpdateEnabled: false,
            crashLoopRestartCount: WatchdogPolicy.crashLoopTripThreshold,
            lastRestartVersion: fixture.newVersion,
            now: 1_000)
        guard case .failed = outcome else {
            Issue.record("expected .failed from the post-kickstart write failure, got \(outcome)")
            return
        }
        // The kickstart WAS issued, so the guard survives the bookkeeping
        // failure and the relaunched daemon boots contiguous — and the trip
        // event was emitted exactly once (the counted restart did happen).
        let record = KVBackendGuardStore.read(environment: env)
        #expect(record?.providerVersion == fixture.newVersion,
            "the guard must survive a bookkeeping failure after an issued kickstart")
        #expect(EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
            record: record, runningVersion: fixture.newVersion))
        #expect(events.actions == ["event"])
    }

    @Test("a rolled-back re-trip restores the PRE-EXISTING guard, never deletes it")
    func rollbackRestoresPreexistingGuard() async throws {
        // A guard from an earlier completed trip is on disk. A later
        // recovery attempt RE-trips (refreshing crashCount) but then ends
        // without a kickstart: the undo must restore the earlier record —
        // original trippedAt and crashCount — not delete the guard.
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-backend-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let env = [KVBackendGuardStore.pathEnvKey: url.path]

        let earlier = KVBackendGuard(
            trippedAt: 100, providerVersion: fixture.oldVersion, crashCount: 3)
        KVBackendGuardStore.write(earlier, environment: env)

        let events = ActionLog()
        let service = WatchdogRecoveryService(
            updater: plainUpdater(fixture),
            dependencies: .init(
                kickstartIfLoaded: { false },  // operator stopped it mid-recovery
                launchSnapshot: { nil },
                processAlive: { _ in true },
                tripKVBackendGuard: { crashCount, tripNow, guardedVersion in
                    KVBackendCrashLoopGuard.stageTrip(
                        crashCount: crashCount, now: tripNow,
                        guardedVersion: guardedVersion, lastKnownModel: nil,
                        environment: env, emitTelemetry: { _ in events.append("event") })
                },
                log: { _ in }))
        let outcome = await service.recoverDownProvider(
            autoUpdateEnabled: false,
            crashLoopRestartCount: 4,
            lastRestartVersion: fixture.oldVersion,
            now: 1_000)
        #expect(outcome == .noLongerLoaded)
        #expect(KVBackendGuardStore.read(environment: env) == earlier,
            "the earlier trip's record must survive the rolled-back re-trip untouched")
        #expect(events.actions.isEmpty,
            "an undone trip must leave no telemetry trace — no restart was issued")
    }
}
