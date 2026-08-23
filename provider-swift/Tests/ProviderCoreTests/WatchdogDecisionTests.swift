import Foundation
import Testing

@testable import ProviderCore

/// The crash-recovery policy: the exact rules that decide whether to relaunch a
/// downed provider. Pure, so every branch is pinned here.
@Suite("Watchdog decision")
struct WatchdogDecisionTests {
    let now: Double = 1_000_000
    let grace: Double = 300

    @Test("config opt-out wins over everything")
    func disabledOptsOut() {
        let d = WatchdogPolicy.decide(
            autoRestartEnabled: false, providerLoaded: true, providerRunning: false,
            downSince: now - 9_999, now: now, graceSeconds: grace
        )
        #expect(d == .disabled)
    }

    @Test("an unloaded provider (stopped / uninstalled) is never restarted")
    func notManagedWhenUnloaded() {
        let d = WatchdogPolicy.decide(
            autoRestartEnabled: true, providerLoaded: false, providerRunning: false,
            downSince: now - 9_999, now: now, graceSeconds: grace
        )
        #expect(d == .notManaged)
    }

    @Test("a running provider is healthy")
    func healthyWhenRunning() {
        let d = WatchdogPolicy.decide(
            autoRestartEnabled: true, providerLoaded: true, providerRunning: true,
            downSince: now - 100, now: now, graceSeconds: grace
        )
        #expect(d == .healthy)
    }

    @Test("first observation of a down provider arms the grace window")
    func startsGraceOnFirstDown() {
        let d = WatchdogPolicy.decide(
            autoRestartEnabled: true, providerLoaded: true, providerRunning: false,
            downSince: nil, now: now, graceSeconds: grace
        )
        #expect(d == .startGrace)
    }

    @Test("within the grace window the watchdog waits")
    func waitsInsideGrace() {
        let d = WatchdogPolicy.decide(
            autoRestartEnabled: true, providerLoaded: true, providerRunning: false,
            downSince: now - 100, now: now, graceSeconds: grace
        )
        #expect(d == .waiting(remaining: 200))
    }

    @Test("at or past the grace window the watchdog restarts")
    func restartsAtGraceBoundary() {
        let exactly = WatchdogPolicy.decide(
            autoRestartEnabled: true, providerLoaded: true, providerRunning: false,
            downSince: now - 300, now: now, graceSeconds: grace
        )
        #expect(exactly == .restart)

        let past = WatchdogPolicy.decide(
            autoRestartEnabled: true, providerLoaded: true, providerRunning: false,
            downSince: now - 600, now: now, graceSeconds: grace
        )
        #expect(past == .restart)
    }

    @Test("default grace period is five minutes")
    func defaultGraceIsFiveMinutes() {
        #expect(WatchdogPolicy.defaultGraceSeconds == 300)
    }
}

/// The reboot guard: a downSince armed in a previous uptime must not survive to
/// trigger an instant post-reboot restart.
@Suite("Watchdog reboot guard")
struct WatchdogEffectiveDownSinceTests {
    @Test("a downSince from before boot is discarded")
    func staleAcrossBootDropped() {
        #expect(WatchdogPolicy.effectiveDownSince(50, bootTime: 100) == nil)
    }

    @Test("a downSince after boot is kept")
    func freshKept() {
        #expect(WatchdogPolicy.effectiveDownSince(150, bootTime: 100) == 150)
    }

    @Test("unknown boot time passes the value through unchanged")
    func unknownBootPassesThrough() {
        #expect(WatchdogPolicy.effectiveDownSince(150, bootTime: nil) == 150)
        #expect(WatchdogPolicy.effectiveDownSince(nil, bootTime: 100) == nil)
    }
}

@Suite("Provider auto_restart config")
struct ProviderAutoRestartConfigTests {
    @Test("auto_restart defaults to true when absent")
    func defaultsTrue() {
        let config = ConfigManager.parse("""
        [provider]
        name = "test-provider"
        """)
        #expect(config.provider.autoRestart)
    }

    @Test("auto_restart = false is honoured")
    func explicitFalse() {
        let config = ConfigManager.parse("""
        [provider]
        name = "test-provider"
        auto_restart = false
        """)
        #expect(!config.provider.autoRestart)
    }

    @Test("auto_restart survives a serialize round-trip")
    func roundTrips() {
        let original = ProviderConfig(
            provider: ProviderSettings(name: "test-provider", autoRestart: false)
        )
        let decoded = ConfigManager.parse(ConfigManager.serialize(original))
        #expect(!decoded.provider.autoRestart)
    }
}

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

    @Test("version scoping: same version keeps the chain, a change resets it to 1")
    func versionScopingDecisionTable() {
        // Continuity: the chain counted THIS version's restarts.
        #expect(WatchdogPolicy.versionScopedCrashLoopCount(
            3, recordedVersion: "0.8.0", installedVersion: "0.8.0") == 3)
        // A promotion (or rollback) landed since the last restart: the new
        // binary's first crash is 1, never old-chain + 1 — otherwise the
        // release shipped to FIX the loop would be guarded on its first
        // short-lived crash, defeating release-clears-the-guard.
        #expect(WatchdogPolicy.versionScopedCrashLoopCount(
            4, recordedVersion: "0.8.0", installedVersion: "0.8.1") == 1)
        #expect(WatchdogPolicy.versionScopedCrashLoopCount(
            4, recordedVersion: "0.8.0", installedVersion: "0.7.15") == 1,
            "a rollback is a version change too")
        // A legacy state file records no version: continuity is unprovable,
        // so it resets rather than risking a cross-version chain.
        #expect(WatchdogPolicy.versionScopedCrashLoopCount(
            3, recordedVersion: nil, installedVersion: "0.8.0") == 1)
        // No-chain callers (healthy-path re-entries pass 0) stay at 0 —
        // scoping must never manufacture a chain.
        #expect(WatchdogPolicy.versionScopedCrashLoopCount(
            0, recordedVersion: nil, installedVersion: "0.8.0") == 0)
    }

    @Test("the counter arithmetic is total: Int.max saturates, negatives clamp — never a trap")
    func counterArithmeticSaturates() {
        // `WatchdogStateStore.read` rejects these as corrupt files, but the
        // pure function must be total regardless of its callers' hygiene: a
        // trapping `+ 1` would crash the watchdog, and launchd would relaunch
        // it against the same state file into the same trap — a permanent
        // watchdog crash loop from one corrupt write.
        #expect(WatchdogPolicy.crashLoopCount(
            current: WatchdogState(lastRestartAt: 1_000, consecutiveCrashLoopRestarts: Int.max),
            effectiveDownSince: 1_060) == Int.max)
        #expect(WatchdogPolicy.crashLoopCount(
            current: WatchdogState(lastRestartAt: 1_000, consecutiveCrashLoopRestarts: -7),
            effectiveDownSince: 1_060) == 1,
            "a negative counter clamps to a fresh chain, not a nonsense value")
        // A plausible-but-large counter (a long-suffering box) still just
        // increments.
        #expect(WatchdogPolicy.crashLoopCount(
            current: WatchdogState(lastRestartAt: 1_000, consecutiveCrashLoopRestarts: 500_000),
            effectiveDownSince: 1_060) == 500_001)
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

