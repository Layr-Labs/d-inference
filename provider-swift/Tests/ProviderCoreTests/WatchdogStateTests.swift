import Foundation
import Testing

@testable import ProviderCore

/// The pure persistence mapping the watchdog command uses after deciding.
@Suite("Watchdog persistence")
struct WatchdogNextStateTests {
    let now: Double = 1_000_000

    @Test("restart records the attempt and clears the window")
    func restartState() {
        let s = WatchdogPolicy.nextState(for: .restart, current: WatchdogState(downSince: now - 400), now: now)
        #expect(s == WatchdogState(downSince: nil, lastRestartAt: now))
    }

    @Test("startGrace arms downSince, preserving lastRestartAt")
    func startGraceState() {
        let s = WatchdogPolicy.nextState(for: .startGrace, current: WatchdogState(lastRestartAt: 42), now: now)
        #expect(s == WatchdogState(downSince: now, lastRestartAt: 42))
    }

    @Test("waiting writes nothing")
    func waitingState() {
        let s = WatchdogPolicy.nextState(for: .waiting(remaining: 60), current: WatchdogState(downSince: now - 60), now: now)
        #expect(s == nil)
    }

    @Test("healthy clears an armed window but no-ops when already clear")
    func healthyState() {
        let cleared = WatchdogPolicy.nextState(for: .healthy, current: WatchdogState(downSince: now - 10, lastRestartAt: 7), now: now)
        #expect(cleared == WatchdogState(downSince: nil, lastRestartAt: 7))
        #expect(WatchdogPolicy.nextState(for: .healthy, current: WatchdogState(), now: now) == nil)
    }

    @Test("disabled / notManaged clear an armed window, else no-op")
    func disabledNotManagedState() {
        #expect(WatchdogPolicy.nextState(for: .disabled, current: WatchdogState(downSince: 1), now: now) == WatchdogState(downSince: nil))
        #expect(WatchdogPolicy.nextState(for: .notManaged, current: WatchdogState(), now: now) == nil)
    }
}


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

    @Test("an issued restart stamps the resolved installed version; nil preserves it")
    func restartStampsVersion() {
        // The recovery flow resolved a version: stamp it (here, across a
        // promotion — the version moves with the chain reset).
        let promoted = WatchdogPolicy.nextState(
            for: .restart,
            current: WatchdogState(
                downSince: now - 400, lastRestartVersion: "0.8.0",
                consecutiveCrashLoopRestarts: 3),
            now: now,
            crashLoopCount: 1,
            crashLoopVersion: "0.8.1")
        #expect(promoted == WatchdogState(
            downSince: nil, lastRestartAt: now, lastRestartVersion: "0.8.1",
            consecutiveCrashLoopRestarts: 1))

        // The degraded session-less restart resolved no version: preserve
        // the recorded one — erasing it would read as "cannot prove
        // continuity" and reset a genuine chain on the next crash.
        let degraded = WatchdogPolicy.nextState(
            for: .restart,
            current: WatchdogState(
                downSince: now - 400, lastRestartVersion: "0.8.0",
                consecutiveCrashLoopRestarts: 1),
            now: now,
            crashLoopCount: 2,
            crashLoopVersion: nil)
        #expect(degraded?.lastRestartVersion == "0.8.0")

        // Non-restart decisions carry the version through untouched.
        let armed = WatchdogPolicy.nextState(
            for: .startGrace,
            current: WatchdogState(
                lastRestartAt: 42, lastRestartVersion: "0.8.0",
                consecutiveCrashLoopRestarts: 2),
            now: now)
        #expect(armed?.lastRestartVersion == "0.8.0")
        let healthyReset = WatchdogPolicy.nextState(
            for: .healthy,
            current: WatchdogState(
                lastRestartAt: now - WatchdogPolicy.crashLoopUptimeBoundSeconds - 1,
                lastRestartVersion: "0.8.0",
                consecutiveCrashLoopRestarts: 2),
            now: now)
        #expect(healthyReset?.lastRestartVersion == "0.8.0")
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

    @Test("pre-guard state files decode with a zero counter and nil version (no decode failure)")
    func legacyStateFileDecodes() throws {
        let legacy = #"{"down_since": 123.5, "last_restart_at": 456.75}"#
        let state = try JSONDecoder().decode(WatchdogState.self, from: Data(legacy.utf8))
        #expect(state == WatchdogState(
            downSince: 123.5, lastRestartAt: 456.75, lastRestartVersion: nil,
            consecutiveCrashLoopRestarts: 0))
        // And a nil version scopes any recorded chain to a reset —
        // "legacy state file treated as reset".
        #expect(WatchdogPolicy.versionScopedCrashLoopCount(
            3, recordedVersion: state.lastRestartVersion, installedVersion: "0.8.0") == 1)
    }
}
