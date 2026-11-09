import Foundation
import Testing
@testable import ProviderCore

struct AbsentProviderRecoveryTests {
    private var enabled: AbsentProviderRecovery.Snapshot {
        .init(autoRestart: true, loaded: false, running: false,
              installed: true, explicitlyEnabled: true)
    }
    private enum FixtureError: Error { case busy, failed }
    private var noGuard: AbsentProviderRecovery.StagedGuard { .init(undo: nil, emit: {}) }

    /// Baseline mode reproduces the exact old runTick policy inputs. Green
    /// mode calls the new production mapping seam, using the SAME snapshots.
    private func mapped(_ intent: AbsentProviderRecovery.Snapshot,
                        state: WatchdogState, now: Double) -> WatchdogDecision {
        #if ABSENT_JOB_BASELINE
        return WatchdogPolicy.decide(autoRestartEnabled: intent.autoRestart,
            providerLoaded: intent.loaded, providerRunning: intent.running,
            downSince: WatchdogPolicy.effectiveDownSince(state.downSince, bootTime: 0), now: now)
        #else
        return AbsentProviderRecovery.decision(snapshot: intent, state: state, now: now, bootTime: 0)
        #endif
    }

    @Test func intentMappingDistinguishesEnabledAbsenceFromStop() {
        let grace = WatchdogPolicy.defaultGraceSeconds
        #expect(mapped(enabled, state: .init(), now: 10) == .startGrace)
        #expect(mapped(enabled, state: .init(downSince: 10), now: 11) == .waiting(remaining: grace - 1))
        #expect(mapped(enabled, state: .init(downSince: 10), now: 11 + grace) == .restart)
        var stopped = enabled
        stopped.explicitlyEnabled = false
        #expect(mapped(stopped, state: .init(), now: 10) == .notManaged)
        #expect(mapped(stopped, state: .init(downSince: 10), now: 11 + grace) == .notManaged)
    }

    @Test func controlsPreventRecovery() {
        var controls: [AbsentProviderRecovery.Snapshot] = []
        var s = enabled; s.autoRestart = false; controls.append(s)
        s = enabled; s.loaded = true; controls.append(s)
        s = enabled; s.running = true; controls.append(s)
        s = enabled; s.installed = false; controls.append(s)
        s = enabled; s.explicitlyEnabled = false; controls.append(s)
        for control in controls { #expect(!control.eligible) }
    }

    @Test func enableOverrideMustBeExplicitAndUnambiguous() {
        for value in ["false", "enabled"] {
            #expect(AbsentProviderRecovery.explicitlyEnabled(
                "disabled services = { \"provider\" => \(value) }", label: "provider"))
        }
        for output in ["", "{}", "disabled services = { }",
                       "disabled services = { \"provider\" => true }",
                       "disabled services = { \"provider\" => disabled }",
                       "disabled services = { \"provider\" => nonsense }",
                       "disabled services = { \"provider\" => false \"provider\" => true }",
                       "disabled services = { garbage \"provider\" => false }"] {
            #expect(!AbsentProviderRecovery.explicitlyEnabled(output, label: "provider"))
        }
    }

    @Test func entireGraceTransitionIsFencedAndReadsFreshState() throws {
        var events: [String] = []
        var disk: WatchdogState? = .init(downSince: 1)
        var intent = enabled
        let result = try AbsentProviderRecovery.performTick(acquire: {
            // stop won the race BEFORE acquisition: disable and remove state.
            intent.explicitlyEnabled = false
            disk = nil
            events.append("acquire")
            return { events.append("release") }
        }, snapshot: { events.append("snapshot"); return intent },
        prepare: { events.append("prepare"); return "v1" },
        readState: { events.append("read"); return disk ?? .init() },
        writeState: { disk = $0; events.append("write"); return true },
        bootstrap: { events.append("bootstrap"); return .issued }, stageGuard: { _, _, _ in noGuard },
        clock: { 1000 }, bootTime: 0)
        #expect(result == .ineligible)
        #expect(disk == nil)
        #expect(events == ["acquire", "snapshot", "read", "release"])
    }

    @Test func graceWriteAndIssuedVersionCountRemainInsideLease() throws {
        var held = false
        var disk = WatchdogState()
        var now = 10.0
        var version = "v1"
        var issued = 0
        var stagedCounts: [Int] = []
        func tick() throws -> AbsentProviderRecovery.Outcome {
            try AbsentProviderRecovery.performTick(acquire: {
                held = true; return { held = false }
            }, snapshot: { #expect(held); return enabled }, prepare: { #expect(held); return version },
            readState: { #expect(held); return disk }, writeState: {
                #expect(held); disk = $0; return true
            }, bootstrap: { #expect(held); issued += 1; return .issued }, stageGuard: { count, _, v in
                #expect(held); #expect(v == version); stagedCounts.append(count); return noGuard
            }, clock: { now }, bootTime: 0)
        }
        #expect(try tick() == .startGrace)
        #expect(disk.downSince == 10)
        now += WatchdogPolicy.defaultGraceSeconds + 1
        #expect(try tick() == .issued)
        #expect(disk.lastRestartAt == now)
        #expect(disk.lastRestartVersion == "v1")
        #expect(disk.consecutiveCrashLoopRestarts == 1)
        for expected in [2, 3] {
            now += 1
            #expect(try tick() == .startGrace)
            now += WatchdogPolicy.defaultGraceSeconds + 1
            #expect(try tick() == .issued)
            #expect(disk.consecutiveCrashLoopRestarts == expected)
        }
        #expect(stagedCounts == [3])
        version = "v2"
        now += 1
        #expect(try tick() == .startGrace)
        now += WatchdogPolicy.defaultGraceSeconds + 1
        #expect(try tick() == .issued)
        #expect(disk.lastRestartVersion == "v2")
        #expect(disk.consecutiveCrashLoopRestarts == 1)
        #expect(issued == 4)
        #expect(!held)
    }

    @Test func busyOrCandidateHasNoEffects() throws {
        var calls = 0
        do {
            _ = try AbsentProviderRecovery.performTick(acquire: { throw FixtureError.busy },
                snapshot: { calls += 1; return enabled }, prepare: { calls += 1; return "v1" },
                readState: { calls += 1; return .init() }, writeState: { _ in calls += 1; return true },
                bootstrap: { calls += 1; return .issued }, stageGuard: { _, _, _ in calls += 1; return noGuard },
                clock: { 1000 }, bootTime: 0)
            Issue.record("busy lease unexpectedly succeeded")
        } catch {}
        #expect(calls == 0)
        var released = false
        let result = try AbsentProviderRecovery.performTick(acquire: { { released = true } },
            snapshot: { calls += 1; return enabled }, prepare: { nil },
            readState: { calls += 1; return .init() }, writeState: { _ in calls += 1; return true },
            bootstrap: { calls += 1; return .issued }, stageGuard: { _, _, _ in calls += 1; return noGuard },
            clock: { 1000 }, bootTime: 0)
        #expect(result == .deferred)
        #expect(released)
        #expect(calls == 1)
    }

    @Test func definiteNonissuanceUndoesGuardWithoutAdvancingState() throws {
        var disk = WatchdogState(downSince: 10, lastRestartAt: 9,
                                lastRestartVersion: "v1", consecutiveCrashLoopRestarts: 2)
        let original = disk
        var undone = false
        var emitted = false
        var released = false
        let outcome = try AbsentProviderRecovery.performTick(acquire: { { released = true } },
            snapshot: { enabled }, prepare: { "v1" }, readState: { disk },
            writeState: { disk = $0; return true }, bootstrap: { .definitelyNotIssued },
            stageGuard: { _, _, _ in .init(undo: { undone = true }, emit: { emitted = true }) },
            clock: { 1000 }, bootTime: 0)
        #expect(outcome == .deferred)
        #expect(released)
        #expect(undone)
        #expect(!emitted)
        #expect(disk == original)
    }

    @Test func commandTimeoutReleasesLeaseWithoutWritingState() {
        var released = false
        var writes = 0
        do {
            _ = try AbsentProviderRecovery.performTick(acquire: { { released = true } },
                snapshot: { throw FixtureError.failed }, prepare: { "v1" }, readState: { .init() },
                writeState: { _ in writes += 1; return true }, bootstrap: { .issued },
                stageGuard: { _, _, _ in noGuard }, clock: { 1000 }, bootTime: 0)
            Issue.record("snapshot failure unexpectedly succeeded")
        } catch {}
        #expect(released)
        #expect(writes == 0)
    }

    @Test func ambiguousBootstrapRetainsGuardWithoutInventingIssuedAccounting() throws {
        for throwsAfterAcceptance in [false, true] {
            var disk = WatchdogState(downSince: 10, lastRestartAt: 9,
                                    lastRestartVersion: "v1", consecutiveCrashLoopRestarts: 2)
            let original = disk
            var undone = false
            var emitted = false
            var released = false
            var accepted = false
            let outcome = try AbsentProviderRecovery.performTick(acquire: { { released = true } },
                snapshot: { enabled }, prepare: { "v1" }, readState: { disk },
                writeState: { disk = $0; return true }, bootstrap: {
                    accepted = true
                    if throwsAfterAcceptance { throw FixtureError.failed }
                    return .unknown
                }, stageGuard: { _, _, _ in .init(undo: { undone = true }, emit: { emitted = true }) },
                clock: { 1000 }, bootTime: 0)
            #expect(accepted)
            #expect(outcome == .unknown)
            #expect(released)
            #expect(!undone)
            #expect(!emitted)
            #expect(disk == original)
        }
    }


    @Test func optedOutServiceNeverPreparesUpdateRecovery() throws {
        var intent = enabled
        intent.autoRestart = false
        var prepared = false
        var released = false
        let outcome = try AbsentProviderRecovery.performTick(acquire: { { released = true } },
            snapshot: { intent }, prepare: { prepared = true; return "v1" },
            readState: { .init() }, writeState: { _ in Issue.record("unexpected write"); return true },
            bootstrap: { Issue.record("unexpected bootstrap"); return .issued },
            stageGuard: { _, _, _ in noGuard }, clock: { 1000 }, bootTime: 0)
        #expect(outcome == .ineligible)
        #expect(!prepared)
        #expect(released)
    }

}

struct AbsentProviderProbeClassificationTests {
    private let label = "io.darkbloom.provider"

    private func classify(_ status: Int32, _ stderr: String) throws -> Bool {
        #if ABSENCE_LABEL_BASELINE
        // Exact previous result predicate from jobIsLoaded, isolated from I/O.
        if status == 0 { return true }
        guard [Int32(3), Int32(113)].contains(status),
              stderr.localizedCaseInsensitiveContains("could not find service") else {
            throw AbsentProviderRecovery.RecoveryError.unrecognizedLaunchdResult
        }
        return false
        #else
        return try AbsentProviderRecovery.jobIsLoadedResult(status: status, stderr: stderr, label: label)
        #endif
    }

    @Test func differentOrUnidentifiedServiceIsNotConfirmedAbsence() {
        for message in [
            "Could not find service \"io.darkbloom.provider.other\" in domain for user gui:501",
            "Could not find service \"provider\" in domain for user gui:501",
            "unrecognized diagnostic: could not find service"
        ] {
            #expect(throws: AbsentProviderRecovery.RecoveryError.self) { try classify(113, message) }
        }
    }

    @Test func exactTargetAbsenceAndLoadedPositiveControls() throws {
        for status in [Int32(3), Int32(113)] {
            #expect(try classify(status, "Could not find service \"io.darkbloom.provider\" in domain for user gui:501") == false)
            #expect(try classify(status, "  Could not find service \"io.darkbloom.provider\"\n") == false)
        }
        #expect(try classify(0, "") == true)
    }

    @Test func permissionOrUnknownStatusIsNotAbsence() {
        #expect(throws: AbsentProviderRecovery.RecoveryError.self) { try classify(113, "Operation not permitted") }
        #expect(throws: AbsentProviderRecovery.RecoveryError.self) {
            try classify(1, "Could not find service \"io.darkbloom.provider\"")
        }
    }
}
