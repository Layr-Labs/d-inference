import Foundation
import Testing

@testable import ProviderCore

// The crash-loop KV-backend guard, end to end minus the engine factory
// (whose resolution behavior is pinned in EngineV2KVBackendGateTests where
// real engines are constructed):
//
//   * the pure counter progression (`WatchdogPolicy.crashLoopCount`) and its
//     persistence (`nextState`) — the decision table,
//   * the on-disk record (`KVBackendGuardStore`) — round-trip, fail-open on
//     garbage, manual clear, version-scoped auto-clear,
//   * the activation predicate
//     (`EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous`),
//   * the trip action (`KVBackendCrashLoopGuard.trip`) — record contents,
//     trippedAt preservation across re-trips, and the ERROR engine_health
//     event,
//   * the recovery-flow wiring (`WatchdogRecoveryService`) — trips before
//     the kickstart, not below the threshold, and never while an update
//     candidate still owns recovery.

// MARK: - Counter decision table

@Suite("Crash-loop counter (pure decision table)")
struct WatchdogCrashLoopCountTests {
    let bound = WatchdogPolicy.crashLoopUptimeBoundSeconds

    @Test("first-ever restart starts the chain at 1")
    func firstRestartStartsChain() {
        let count = WatchdogPolicy.crashLoopCount(
            current: WatchdogState(),
            effectiveDownSince: 1_000)
        #expect(count == 1)
    }

    @Test("short uptime after the previous restart continues the chain")
    func shortUptimeIncrements() {
        // Restarted at t=1000; crashed (downSince) 60s later — well inside
        // the bound, so the second restart is consecutive with the first.
        let count = WatchdogPolicy.crashLoopCount(
            current: WatchdogState(lastRestartAt: 1_000, consecutiveCrashLoopRestarts: 1),
            effectiveDownSince: 1_060)
        #expect(count == 2)
    }

    @Test("two crashes do NOT reach the trip threshold; the third does")
    func twoCrashesNoTripThreeTrips() {
        // The exact fleet scenario: healthy box, then a paged defect kills
        // the daemon on every boot. Walk the persisted state the way the
        // watchdog command does and check the count against the threshold.
        var state = WatchdogState()
        var now = 10_000.0

        // Crash 1: no previous restart — chain starts at 1.
        var count = WatchdogPolicy.crashLoopCount(
            current: state, effectiveDownSince: now)
        #expect(count == 1)
        #expect(count < WatchdogPolicy.crashLoopTripThreshold)
        state = WatchdogPolicy.nextState(
            for: .restart, current: state, now: now + 300, crashLoopCount: count)!

        // Crash 2: provider lived ~90s after restart 1.
        now = state.lastRestartAt! + 90
        count = WatchdogPolicy.crashLoopCount(current: state, effectiveDownSince: now)
        #expect(count == 2)
        #expect(count < WatchdogPolicy.crashLoopTripThreshold, "2 crashes must not trip")
        state = WatchdogPolicy.nextState(
            for: .restart, current: state, now: now + 300, crashLoopCount: count)!

        // Crash 3: provider lived ~90s after restart 2 — the trip.
        now = state.lastRestartAt! + 90
        count = WatchdogPolicy.crashLoopCount(current: state, effectiveDownSince: now)
        #expect(count == 3)
        #expect(count >= WatchdogPolicy.crashLoopTripThreshold, "3 crashes must trip")
    }

    @Test("long uptime resets the chain to 1, not 0 — a restart did happen")
    func longUptimeResets() {
        let count = WatchdogPolicy.crashLoopCount(
            current: WatchdogState(lastRestartAt: 1_000, consecutiveCrashLoopRestarts: 2),
            effectiveDownSince: 1_000 + bound + 1)
        #expect(count == 1)
    }

    @Test("the bound is exclusive: uptime of exactly the bound is NOT crash-loop-shaped")
    func boundIsExclusive() {
        let atBound = WatchdogPolicy.crashLoopCount(
            current: WatchdogState(lastRestartAt: 1_000, consecutiveCrashLoopRestarts: 2),
            effectiveDownSince: 1_000 + bound)
        #expect(atBound == 1)

        let justInside = WatchdogPolicy.crashLoopCount(
            current: WatchdogState(lastRestartAt: 1_000, consecutiveCrashLoopRestarts: 2),
            effectiveDownSince: 1_000 + bound - 1)
        #expect(justInside == 3)
    }

    @Test("a missing outage timestamp cannot continue a chain")
    func missingDownSinceStartsChain() {
        let count = WatchdogPolicy.crashLoopCount(
            current: WatchdogState(lastRestartAt: 1_000, consecutiveCrashLoopRestarts: 2),
            effectiveDownSince: nil)
        #expect(count == 1)
    }

    @Test("a negative gap (clock rollback) counts as short — fail toward the guard")
    func negativeGapCountsAsShort() {
        let count = WatchdogPolicy.crashLoopCount(
            current: WatchdogState(lastRestartAt: 1_000, consecutiveCrashLoopRestarts: 1),
            effectiveDownSince: 900)
        #expect(count == 2)
    }

    @Test("a delayed kickstart must be stamped at the KICKSTART, not tick entry")
    func delayedKickstartStampTiming() {
        // The recovery path may legally spend up to 600s in an update
        // download BEFORE the kickstart (the watchdog URLSession's resource
        // timeout). Model the worst case: tick enters at T, the daemon
        // actually launches at T+600, crashes ~60s later, and the next tick
        // sees the outage at T+700.
        let tickEntry = 10_000.0
        let kickstart = tickEntry + 600
        let nextDownSince = tickEntry + 700

        // Stamped at the kickstart (what runTick persists via its re-read of
        // the clock): apparent uptime is 100s — unmistakably loop-shaped.
        let stampedAtKickstart = WatchdogPolicy.nextState(
            for: .restart,
            current: WatchdogState(downSince: tickEntry - 400, consecutiveCrashLoopRestarts: 1),
            now: kickstart,
            crashLoopCount: 2)!
        #expect(WatchdogPolicy.crashLoopCount(
            current: stampedAtKickstart, effectiveDownSince: nextDownSince) == 3)

        // Stamped at tick entry (the defect): the download window is
        // credited to the daemon as uptime, 700s of the 900s bound —
        // two more such crashes and the chain STILL reads 700 < 900, but a
        // marginally slower box (crash at +210s) reads 910 ≥ 900 and wrongly
        // resets the chain to 1 mid-loop.
        let stampedAtTickEntry = WatchdogPolicy.nextState(
            for: .restart,
            current: WatchdogState(downSince: tickEntry - 400, consecutiveCrashLoopRestarts: 1),
            now: tickEntry,
            crashLoopCount: 2)!
        #expect(WatchdogPolicy.crashLoopCount(
            current: stampedAtTickEntry,
            effectiveDownSince: tickEntry + 910) == 1,
            "the tick-entry stamp inflates apparent uptime past the bound")
        #expect(WatchdogPolicy.crashLoopCount(
            current: stampedAtKickstart,
            effectiveDownSince: kickstart + 310) == 3,
            "the kickstart stamp keeps the same crash inside the bound")
    }

    @Test("the shipped constants are the decided policy: 15 min bound, threshold 3")
    func shippedConstants() {
        #expect(WatchdogPolicy.crashLoopUptimeBoundSeconds == 900)
        #expect(WatchdogPolicy.crashLoopTripThreshold == 3)
        // The threshold deliberately equals the binary-rollback threshold —
        // the two automations watch the same restarts (see the trip site
        // in WatchdogRecoveryService for which one wins).
        #expect(WatchdogPolicy.crashLoopTripThreshold == UpdateRecoveryState.rollbackThreshold)
    }
}

// MARK: - Counter persistence through nextState

@Suite("Crash-loop counter persistence")
struct WatchdogCrashLoopNextStateTests {
    let now: Double = 1_000_000

    @Test("an issued restart persists the passed counter")
    func restartPersistsCount() {
        let s = WatchdogPolicy.nextState(
            for: .restart,
            current: WatchdogState(downSince: now - 400, consecutiveCrashLoopRestarts: 1),
            now: now,
            crashLoopCount: 2)
        #expect(s == WatchdogState(
            downSince: nil, lastRestartAt: now, consecutiveCrashLoopRestarts: 2))
    }

    @Test("a restart outcome that issued nothing keeps the current counter")
    func nilCountKeepsCurrent() {
        let s = WatchdogPolicy.nextState(
            for: .restart,
            current: WatchdogState(downSince: now - 400, consecutiveCrashLoopRestarts: 2),
            now: now,
            crashLoopCount: nil)
        #expect(s?.consecutiveCrashLoopRestarts == 2)
    }

    @Test("startGrace and disabled/notManaged carry the counter through untouched")
    func nonRestartDecisionsPreserveCounter() {
        let armed = WatchdogPolicy.nextState(
            for: .startGrace,
            current: WatchdogState(lastRestartAt: 42, consecutiveCrashLoopRestarts: 2),
            now: now)
        #expect(armed == WatchdogState(
            downSince: now, lastRestartAt: 42, consecutiveCrashLoopRestarts: 2))

        let disabled = WatchdogPolicy.nextState(
            for: .disabled,
            current: WatchdogState(downSince: 1, consecutiveCrashLoopRestarts: 2),
            now: now)
        #expect(disabled == WatchdogState(
            downSince: nil, lastRestartAt: nil, consecutiveCrashLoopRestarts: 2))
    }

    @Test("healthy resets the counter only after the uptime bound")
    func healthyResetsAfterBound() {
        let restartAt = now - WatchdogPolicy.crashLoopUptimeBoundSeconds - 1

        // Past the bound: reset (this is the ONLY write this state needs).
        let reset = WatchdogPolicy.nextState(
            for: .healthy,
            current: WatchdogState(lastRestartAt: restartAt, consecutiveCrashLoopRestarts: 2),
            now: now)
        #expect(reset == WatchdogState(
            downSince: nil, lastRestartAt: restartAt, consecutiveCrashLoopRestarts: 0))

        // Inside the bound: no reset, and nothing else to write ⇒ nil.
        let tooSoon = WatchdogPolicy.nextState(
            for: .healthy,
            current: WatchdogState(lastRestartAt: now - 60, consecutiveCrashLoopRestarts: 2),
            now: now)
        #expect(tooSoon == nil)

        // Counter already clear and no window armed: still a no-op.
        #expect(WatchdogPolicy.nextState(
            for: .healthy,
            current: WatchdogState(lastRestartAt: restartAt),
            now: now) == nil)
    }

    @Test("healthy still clears an armed window without touching a fresh counter")
    func healthyClearsWindowKeepsFreshCounter() {
        let s = WatchdogPolicy.nextState(
            for: .healthy,
            current: WatchdogState(
                downSince: now - 10, lastRestartAt: now - 60, consecutiveCrashLoopRestarts: 2),
            now: now)
        #expect(s == WatchdogState(
            downSince: nil, lastRestartAt: now - 60, consecutiveCrashLoopRestarts: 2))
    }

    @Test("pre-guard state files decode with a zero counter (no decode failure)")
    func legacyStateFileDecodes() throws {
        let legacy = #"{"down_since": 123.5, "last_restart_at": 456.75}"#
        let state = try JSONDecoder().decode(WatchdogState.self, from: Data(legacy.utf8))
        #expect(state == WatchdogState(
            downSince: 123.5, lastRestartAt: 456.75, consecutiveCrashLoopRestarts: 0))
    }

    @Test("the counter round-trips through the state store")
    func counterRoundTrips() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = WatchdogState(
            downSince: nil, lastRestartAt: 456.75, consecutiveCrashLoopRestarts: 2)
        #expect(WatchdogStateStore.write(original, to: url))
        #expect(WatchdogStateStore.read(from: url) == original)
    }
}

// MARK: - Guard record store

@Suite("KV-backend guard store")
struct KVBackendGuardStoreTests {
    private func tempEnv() -> (env: [String: String], url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-backend-guard-\(UUID().uuidString).json")
        return ([KVBackendGuardStore.pathEnvKey: url.path], url)
    }

    @Test("the record round-trips through disk")
    func roundTrip() {
        let (env, url) = tempEnv()
        defer { try? FileManager.default.removeItem(at: url) }
        let record = KVBackendGuard(
            trippedAt: 1_234.5, providerVersion: "0.8.0", crashCount: 3)
        #expect(KVBackendGuardStore.write(record, environment: env))
        #expect(KVBackendGuardStore.read(environment: env) == record)
    }

    @Test("missing file reads as no guard")
    func missingIsNil() {
        let (env, _) = tempEnv()
        #expect(KVBackendGuardStore.read(environment: env) == nil)
    }

    @Test("a corrupt/garbage file fails OPEN to no guard, not a crash")
    func corruptFailsOpen() throws {
        for garbage in ["", "not json at all", "{\"tripped_at\": \"words\"}", "[1,2,3]"] {
            let (env, url) = tempEnv()
            defer { try? FileManager.default.removeItem(at: url) }
            try Data(garbage.utf8).write(to: url)
            #expect(
                KVBackendGuardStore.read(environment: env) == nil,
                "garbage \(garbage.debugDescription) must read as no guard")
            // And the factory-facing predicate agrees: no record, no force.
            #expect(!EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
                record: KVBackendGuardStore.read(environment: env),
                runningVersion: ProviderCore.version))
        }
    }

    @Test("manual clear removes the record; clearing nothing succeeds")
    func manualClear() {
        let (env, url) = tempEnv()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(KVBackendGuardStore.clear(environment: env), "clearing an absent guard is success")
        KVBackendGuardStore.write(
            KVBackendGuard(trippedAt: 1, providerVersion: "0.8.0", crashCount: 3),
            environment: env)
        #expect(KVBackendGuardStore.read(environment: env) != nil)
        #expect(KVBackendGuardStore.clear(environment: env))
        #expect(KVBackendGuardStore.read(environment: env) == nil)
    }

    @Test("clearIfStale deletes only a version-mismatched record")
    func clearIfStale() {
        let (env, url) = tempEnv()
        defer { try? FileManager.default.removeItem(at: url) }
        let record = KVBackendGuard(trippedAt: 1, providerVersion: "0.7.9", crashCount: 3)
        KVBackendGuardStore.write(record, environment: env)

        // Same version: kept.
        #expect(KVBackendGuardStore.clearIfStale(
            runningVersion: "0.7.9", environment: env) == nil)
        #expect(KVBackendGuardStore.read(environment: env) == record)

        // New version: deleted, and the cleared record is reported back.
        #expect(KVBackendGuardStore.clearIfStale(
            runningVersion: "0.8.0", environment: env) == record)
        #expect(KVBackendGuardStore.read(environment: env) == nil)
    }
}

// MARK: - Activation predicate

@Suite("Crash-loop guard activation predicate")
struct CrashLoopGuardPredicateTests {
    @Test("no record never forces contiguous")
    func nilRecordInactive() {
        #expect(!EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
            record: nil, runningVersion: "0.8.0"))
    }

    @Test("a record binds exactly the version that tripped it")
    func versionScoping() {
        let record = KVBackendGuard(trippedAt: 1, providerVersion: "0.8.0", crashCount: 3)
        #expect(EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
            record: record, runningVersion: "0.8.0"))
        // A new release is the fleet's fix-delivery vector: the guard
        // self-clears by version inequality, in BOTH directions (an
        // upgrade past the trip, or a rollback below it).
        #expect(!EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
            record: record, runningVersion: "0.8.1"))
        #expect(!EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
            record: record, runningVersion: "0.7.15"))
    }
}

// MARK: - Trip action

@Suite("Crash-loop guard trip action")
struct CrashLoopGuardTripTests {
    private final class EventCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [TelemetryEvent] = []
        var events: [TelemetryEvent] { lock.withLock { _events } }
        func record(_ event: TelemetryEvent) { lock.withLock { _events.append(event) } }
    }

    @Test("trip persists the GUARDED version's record and emits ERROR engine_health")
    func tripWritesAndEmits() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-backend-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let env = [KVBackendGuardStore.pathEnvKey: url.path]
        let capture = EventCapture()

        let wrote = KVBackendCrashLoopGuard.trip(
            crashCount: 3,
            now: 5_000,
            guardedVersion: "0.8.3",
            lastKnownModel: "gemma-4-26b-qat-4bit",
            environment: env,
            emitTelemetry: { capture.record($0) })
        #expect(wrote)

        let record = KVBackendGuardStore.read(environment: env)
        #expect(record == KVBackendGuard(
            trippedAt: 5_000, providerVersion: "0.8.3", crashCount: 3))
        // The record it wrote is ACTIVE for the guarded (installed daemon)
        // binary — the whole point.
        #expect(EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
            record: record, runningVersion: "0.8.3"))

        #expect(capture.events.count == 1)
        let event = capture.events[0]
        #expect(event.severity == .error)
        #expect(event.kind == .engineHealth)
        #expect(event.fields?["operation"]?.description == "engine_v2_crash_loop_guard")
        #expect(event.fields?["reason"]?.description == "crash_loop_guard")
        #expect(event.fields?["model"]?.description == "gemma-4-26b-qat-4bit")
        // Box-wide event: the crashing slot's backend was never observed,
        // so the key is OMITTED, not guessed (EngineHealthEvent contract).
        #expect(event.fields?["kv_backend"] == nil)
        // The fleet dashboard groups trips by the version that was
        // crash-looping — the guarded version, not the watchdog image's.
        #expect(event.version == "0.8.3")
    }

    @Test("re-tripping the same version keeps the original trippedAt, raises crashCount")
    func retripPreservesTrippedAt() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-backend-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let env = [KVBackendGuardStore.pathEnvKey: url.path]

        KVBackendCrashLoopGuard.trip(
            crashCount: 3, now: 5_000, guardedVersion: "0.8.3", lastKnownModel: nil,
            environment: env, emitTelemetry: { _ in })
        KVBackendCrashLoopGuard.trip(
            crashCount: 4, now: 6_000, guardedVersion: "0.8.3", lastKnownModel: nil,
            environment: env, emitTelemetry: { _ in })

        let record = KVBackendGuardStore.read(environment: env)
        #expect(record?.trippedAt == 5_000, "age must report the FIRST trip")
        #expect(record?.crashCount == 4)
    }

    @Test("an unattributable trip reports model=unknown rather than guessing")
    func unknownModelAttribution() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-backend-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = EventCapture()
        KVBackendCrashLoopGuard.trip(
            crashCount: 3, now: 5_000, guardedVersion: "0.8.3", lastKnownModel: nil,
            environment: [KVBackendGuardStore.pathEnvKey: url.path],
            emitTelemetry: { capture.record($0) })
        #expect(capture.events.first?.fields?["model"]?.description == "unknown")
    }
}

// MARK: - Recovery-flow wiring

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
        log: ActionLog
    ) -> WatchdogRecoveryService {
        WatchdogRecoveryService(
            updater: updater,
            dependencies: .init(
                kickstartIfLoaded: {
                    log.append("kickstart")
                    return true
                },
                // Injected: tests must never shell out to the real
                // `launchctl print` for the host's provider job.
                launchSnapshot: { nil },
                processAlive: { _ in true },
                tripKVBackendGuard: { crashCount, _, guardedVersion in
                    log.append("trip(\(crashCount),v\(guardedVersion))")
                    return true
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
                now: 1_000)
        #expect(outcome == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        // No self-update has ever run in this fixture, so the installed
        // version IS the process version (the fixture's oldVersion).
        #expect(log.actions == ["trip(3,v\(fixture.oldVersion))", "kickstart"])
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
            now: 1_000)
        // Default 0: the healthy-path candidate re-entries, which handle a
        // RUNNING-but-inert process, not the launchd death loop.
        _ = await service.recoverDownProvider(autoUpdateEnabled: false, now: 2_000)
        #expect(log.actions == ["kickstart", "kickstart"])
    }

    @Test("a pending update candidate with a viable rollback path suppresses the trip")
    func candidateRollbackWins() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let mock = MockCoordinator(
            release: fixture.mockReleaseFixture(),
            releaseArtifact: fixture.artifact)
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }
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
        let first = await service.recoverDownProvider(
            autoUpdateEnabled: false, crashLoopRestartCount: 3, now: 200)
        let second = await service.recoverDownProvider(
            autoUpdateEnabled: false, crashLoopRestartCount: 4, now: 300)
        #expect(first == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        #expect(second == .restartIssued(updatedTo: nil, rolledBackTo: nil))

        // Third failure: the ROLLBACK fires. Still no trip — the rollback
        // just won, and a guard for a version that is leaving the box would
        // be a stranded record.
        let third = await service.recoverDownProvider(
            autoUpdateEnabled: false, crashLoopRestartCount: 5, now: 400)
        #expect(third == .restartIssued(updatedTo: nil, rolledBackTo: "1.0.0"))

        #expect(!log.actions.contains { $0.hasPrefix("trip") },
            "candidate rollback owns recovery end to end — the guard must never fire")
        #expect(log.actions.filter { $0 == "kickstart" }.count == 4)

        // AFTER the rollback the candidate is gone. If the rolled-back
        // binary somehow kept crash-looping, the guard may now trip.
        let postRollback = await service.recoverDownProvider(
            autoUpdateEnabled: false, crashLoopRestartCount: 6, now: 500)
        #expect(postRollback == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        // The rollback restored the predecessor, so the durable installed
        // record — and therefore the guarded version — is oldVersion again.
        #expect(log.actions.contains("trip(6,v\(fixture.oldVersion))"))
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
        let service = WatchdogRecoveryService(
            updater: updater,
            dependencies: .init(
                kickstartIfLoaded: { true },
                launchSnapshot: { nil },
                processAlive: { _ in true },
                tripKVBackendGuard: { crashCount, tripNow, guardedVersion in
                    KVBackendCrashLoopGuard.trip(
                        crashCount: crashCount, now: tripNow,
                        guardedVersion: guardedVersion, lastKnownModel: nil,
                        environment: env, emitTelemetry: { _ in })
                },
                log: { _ in }))

        let outcome = await service.recoverDownProvider(
            autoUpdateEnabled: false,
            crashLoopRestartCount: WatchdogPolicy.crashLoopTripThreshold,
            now: 1_000)
        #expect(outcome == .restartIssued(updatedTo: nil, rolledBackTo: nil))

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
}
