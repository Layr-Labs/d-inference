// Contract under test: `Status.runtimeIntegrityStatusLine(state:now:)`
// (Sources/darkbloom/StatusCommand.swift), alongside
// `bootSecurityStatusLine`/`daemonHealthLine` (same style: an unqualified --
// default internal access -- instance method, directly callable on a parsed
// `Status` in tests):
//
//     func runtimeIntegrityStatusLine(state: DaemonState, now: Double) -> String?
//
// nil when `state.runtimeIntegrity` is nil (absent state prints nothing
// new). Otherwise a line naming the runtime as outdated and excluded from
// routing, with the fix -- the line must contain "outdated", "excluded from
// routing" and "darkbloom update".
//
// The coordinator never sends `verified:true`, so the recorded state is not
// cleared by an explicit "verified" message -- it expires by age instead.
// This is why the helper above takes a `now:` parameter: nil is also
// returned once `now - state.runtimeIntegrity!.receivedAt > 900` (15
// minutes, in seconds).
//
// Boundary decision (read as a strict inequality): at exactly 900s old the
// record is not yet older than 15 minutes, so the line still prints;
// anything past 900s (900.000...1s and up) is cleared. i.e. the check is
// `age > 900` clears, `age <= 900` still prints. `fifteenMinuteBoundaryStillPrints`
// below pins the exact-900s case to that decision.
//
// `printDaemonStatus` is expected to `print()` this line (when non-nil)
// alongside the other daemon-state lines it already prints (trust, warm
// models, etc), passing the wall-clock `now` it already computes for
// `daemonHealthLine`.

import ArgumentParser
import ProviderCore
import Testing
@testable import darkbloom

@Test("runtime-integrity status line names the outdated runtime, exclusion and the fix")
func runtimeIntegrityLinePresentNamesOutdatedAndFix() throws {
    let status = try Status.parse([])
    var state = DaemonState(pid: 1, version: "0.9.0", writtenAt: 100, startedAt: 50)
    state.runtimeIntegrity = DaemonState.RuntimeIntegrity(
        status: "outdated",
        mismatchCount: 2,
        mismatches: [RuntimeMismatch(component: "binary_hash", expected: "a", got: "b")],
        receivedAt: 100)

    let line = status.runtimeIntegrityStatusLine(state: state, now: 100)
    #expect(line?.contains("outdated") == true)
    #expect(line?.contains("excluded from routing") == true)
    #expect(line?.contains("darkbloom update") == true)
}

@Test("absent runtime-integrity state prints nothing new")
func runtimeIntegrityLineAbsentPrintsNothing() throws {
    let status = try Status.parse([])
    let state = DaemonState(pid: 1, version: "0.9.0", writtenAt: 100, startedAt: 50)
    #expect(state.runtimeIntegrity == nil)
    #expect(status.runtimeIntegrityStatusLine(state: state, now: 100) == nil)
}

// The 15-minute expiry, evaluated at read time via `now:`.
@Suite("runtime-integrity status line: 15-minute expiry")
struct RuntimeIntegrityStatusLineExpiryTests {
    private func stateWithMismatch(receivedAt: Double) -> DaemonState {
        var state = DaemonState(pid: 1, version: "0.9.0", writtenAt: receivedAt, startedAt: 50)
        state.runtimeIntegrity = DaemonState.RuntimeIntegrity(
            status: "outdated",
            mismatchCount: 1,
            mismatches: [RuntimeMismatch(component: "binary_hash", expected: "a", got: "b")],
            receivedAt: receivedAt)
        return state
    }

    @Test("a 14-minute-old record still prints")
    func fourteenMinutesStillPrints() throws {
        let status = try Status.parse([])
        let state = stateWithMismatch(receivedAt: 1_000)
        let line = status.runtimeIntegrityStatusLine(state: state, now: 1_000 + 14 * 60)
        #expect(line?.contains("outdated") == true)
    }

    @Test("exactly 900s (15 min) old still prints -- the boundary is inclusive")
    func fifteenMinuteBoundaryStillPrints() throws {
        let status = try Status.parse([])
        let state = stateWithMismatch(receivedAt: 1_000)
        let line = status.runtimeIntegrityStatusLine(state: state, now: 1_000 + 900)
        #expect(line != nil)
    }

    @Test("older than 900s (15 min) prints nothing")
    func olderThanFifteenMinutesPrintsNothing() throws {
        let status = try Status.parse([])
        let state = stateWithMismatch(receivedAt: 1_000)
        let line = status.runtimeIntegrityStatusLine(state: state, now: 1_000 + 901)
        #expect(line == nil)
    }
}
