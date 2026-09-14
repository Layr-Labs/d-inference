import Darwin
import Foundation
@testable import SandboxRuntime
import XCTest

final class ProcessExecutionRaceTests: XCTestCase {
    func testMissedReleaseHasBoundedGateAndCompletionWaits() async throws {
        let gate = ProcessRaceGate(maximumWait: .milliseconds(20))
        let returned = ProcessRaceCompletion()
        defer { gate.release() }
        DispatchQueue.global().async { gate.blockReaper(); returned.record() }
        try await gate.waitUntilObserved()
        let didReturn = await returned.wait(seconds: 1)
        XCTAssertTrue(didReturn)
        XCTAssertTrue(gate.didExpire)
        let neverSignalled = ProcessRaceCompletion()
        let unexpectedlyCompleted = await neverSignalled.wait(seconds: 0.02)
        XCTAssertFalse(unexpectedlyCompleted)
    }

    func testUnrelatedControlStopsAndReapsWithoutFoundationProcessMonitor() throws {
        let child = try ProcessRaceUnrelatedChild()
        defer { XCTAssertNoThrow(try child.stop()) }
        XCTAssertEqual(ProcessBirthIdentity.read(child.identity.pid), child.identity)
        try child.stop()
        XCTAssertNotEqual(ProcessBirthIdentity.read(child.identity.pid), child.identity)
        XCTAssertNoThrow(try child.stop())
    }

    func testSignalRacingLeaderExitTargetsReservedGroupOnly() async throws {
        let fixture = try ProcessGroupFixture()
        let gate = ProcessRaceGate()
        let signals = ProcessGroupSignalRecorder()
        let execution = try fixture.startExecution(
            hooks: ProcessExecutionTestHooks(
                didObserveDirectChildExit: {
                    gate.blockReaper()
                },
                willSignalProcessGroup: { group, signal in
                    signals.record(group: group, signal: signal)
                }
            )
        )
        defer {
            gate.release()
            execution.forceStop()
            fixture.remove()
        }
        let leader = execution.processIdentifierForTesting
        let descendant = try await fixture.waitForDescendantIdentity()
        let unrelated = try ProcessRaceUnrelatedChild()
        defer { XCTAssertNoThrow(try unrelated.stop()) }

        try fixture.allowLeaderToExit()
        try await gate.waitUntilObserved()

        execution.forceStop()
        gate.release()
        try await ProcessRaceCompletion.waitForExit(execution)
        XCTAssertFalse(gate.didExpire, "test coordination exceeded the bounded reaper gate")

        try await fixture.waitUntilIdentityIsGone(descendant)
        XCTAssertEqual(execution.terminationStatus, 0)
        XCTAssertTrue(
            signals.snapshot.contains {
                $0.group == leader && $0.signal == SIGKILL
            }
        )
        XCTAssertTrue(signals.snapshot.allSatisfy { $0.group == leader })
        XCTAssertEqual(
            ProcessBirthIdentity.read(unrelated.identity.pid),
            unrelated.identity
        )
    }

    func testExitTransitionDisablesRacingSignalsBeforeDescendantCleanup()
        async throws
    {
        let fixture = try ProcessGroupFixture()
        let gate = ProcessRaceGate()
        let signals = ProcessGroupSignalRecorder()
        let execution = try fixture.startExecution(
            hooks: ProcessExecutionTestHooks(
                didDisableSignalAttempts: {
                    gate.blockReaper()
                },
                willSignalProcessGroup: { group, signal in
                    signals.record(group: group, signal: signal)
                }
            )
        )
        defer {
            gate.release()
            execution.forceStop()
            fixture.remove()
        }
        let leader = execution.processIdentifierForTesting
        let descendant = try await fixture.waitForDescendantIdentity()
        let unrelated = try ProcessRaceUnrelatedChild()
        defer { XCTAssertNoThrow(try unrelated.stop()) }

        try fixture.allowLeaderToExit()
        try await gate.waitUntilObserved()

        let signalAttempt = ProcessRaceCompletion()
        DispatchQueue.global().async {
            execution.forceStop()
            signalAttempt.record()
        }
        let returnedBeforeCleanup = await signalAttempt.wait(seconds: 0.1)
        XCTAssertFalse(returnedBeforeCleanup)

        gate.release()
        let racingSignalReturned = await signalAttempt.wait(seconds: 5)
        XCTAssertTrue(racingSignalReturned)
        try await ProcessRaceCompletion.waitForExit(execution)
        XCTAssertFalse(gate.didExpire, "test coordination exceeded the bounded reaper gate")

        try await fixture.waitUntilIdentityIsGone(descendant)
        XCTAssertEqual(execution.terminationStatus, 0)
        XCTAssertEqual(
            signals.snapshot.map(\.signal),
            [SIGTERM, SIGKILL]
        )
        XCTAssertTrue(signals.snapshot.allSatisfy { $0.group == leader })
        XCTAssertEqual(
            ProcessBirthIdentity.read(unrelated.identity.pid),
            unrelated.identity
        )
    }
}
