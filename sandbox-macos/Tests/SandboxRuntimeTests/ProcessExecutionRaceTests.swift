import Darwin
import Foundation
@testable import SandboxRuntime
import XCTest

final class ProcessExecutionRaceTests: XCTestCase {
    func testSignalRacingLeaderExitTargetsReservedGroupOnly() async throws {
        let fixture = try ProcessGroupFixture()
        let gate = DirectChildExitGate()
        let signals = ProcessGroupSignalRecorder()
        let execution = try fixture.startExecution(
            hooks: ProcessExecutionTestHooks(
                didObserveDirectChildExit: {
                    gate.blockReaperAfterObservation()
                },
                willSignalProcessGroup: { group, signal in
                    signals.record(group: group, signal: signal)
                }
            )
        )
        defer {
            gate.allowReaperToContinue()
            execution.forceStop()
            fixture.remove()
        }
        let leader = execution.processIdentifierForTesting
        let descendant = try await fixture.waitForDescendantIdentity()
        let unrelated = try UnrelatedProcess()
        defer { unrelated.stop() }

        try fixture.allowLeaderToExit()
        let exitWasObserved = await Task.detached {
            gate.waitUntilExitWasObserved()
        }.value
        XCTAssertTrue(exitWasObserved)

        execution.forceStop()
        gate.allowReaperToContinue()
        await execution.waitUntilExit()
        let result = execution.result()

        try await fixture.waitUntilIdentityIsGone(descendant)
        XCTAssertEqual(result.exitCode, 0)
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
        let gate = DisabledSignalAttemptGate()
        let signals = ProcessGroupSignalRecorder()
        let execution = try fixture.startExecution(
            hooks: ProcessExecutionTestHooks(
                didDisableSignalAttempts: {
                    gate.blockReaperWithExecutionLockHeld()
                },
                willSignalProcessGroup: { group, signal in
                    signals.record(group: group, signal: signal)
                }
            )
        )
        defer {
            gate.allowReaperToContinue()
            execution.forceStop()
            fixture.remove()
        }
        let leader = execution.processIdentifierForTesting
        let descendant = try await fixture.waitForDescendantIdentity()
        let unrelated = try UnrelatedProcess()
        defer { unrelated.stop() }

        try fixture.allowLeaderToExit()
        let attemptsWereDisabled = await Task.detached {
            gate.waitUntilSignalAttemptsWereDisabled()
        }.value
        XCTAssertTrue(attemptsWereDisabled)

        let signalAttempt = SignalAttemptCompletion()
        let racingSignal = Task.detached {
            execution.forceStop()
            signalAttempt.recordReturn()
        }
        let returnedBeforeCleanup = await Task.detached {
            signalAttempt.waitForReturn()
        }.value
        XCTAssertFalse(returnedBeforeCleanup)

        gate.allowReaperToContinue()
        await racingSignal.value
        await execution.waitUntilExit()
        let result = execution.result()

        try await fixture.waitUntilIdentityIsGone(descendant)
        XCTAssertEqual(result.exitCode, 0)
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

private final class SignalAttemptCompletion: @unchecked Sendable {
    private let returned = DispatchSemaphore(value: 0)

    func recordReturn() {
        returned.signal()
    }

    func waitForReturn() -> Bool {
        returned.wait(timeout: .now() + .milliseconds(100)) == .success
    }
}

private final class DisabledSignalAttemptGate: @unchecked Sendable {
    private let disabled = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)

    func blockReaperWithExecutionLockHeld() {
        disabled.signal()
        proceed.wait()
    }

    func waitUntilSignalAttemptsWereDisabled() -> Bool {
        disabled.wait(timeout: .now() + 5) == .success
    }

    func allowReaperToContinue() {
        proceed.signal()
    }
}

private final class DirectChildExitGate: @unchecked Sendable {
    private let observed = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)

    func blockReaperAfterObservation() {
        observed.signal()
        proceed.wait()
    }

    func waitUntilExitWasObserved() -> Bool {
        observed.wait(timeout: .now() + 5) == .success
    }

    func allowReaperToContinue() {
        proceed.signal()
    }
}

private final class ProcessGroupSignalRecorder: @unchecked Sendable {
    struct Entry: Equatable {
        let group: pid_t
        let signal: Int32
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    var snapshot: [Entry] {
        lock.withLock { entries }
    }

    func record(group: pid_t, signal: Int32) {
        lock.withLock {
            entries.append(Entry(group: group, signal: signal))
        }
    }
}

private struct ProcessGroupFixture {
    private let directory: URL
    private let descendantPID: URL
    private let leaderExit: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "darkbloom-process-race-\(UUID().uuidString)",
                isDirectory: true
            )
        descendantPID = directory.appendingPathComponent("descendant.pid")
        leaderExit = directory.appendingPathComponent("leader-exit")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
    }

    func startExecution(
        hooks: ProcessExecutionTestHooks
    ) throws -> ProcessExecution {
        let execution = try ProcessExecution(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                /bin/sh -c 'trap "" HUP TERM; while :; do /bin/sleep 1; done' &
                descendant=$!
                printf '%s' "$descendant" > "$1"
                while [ ! -e "$2" ]; do /bin/sleep 0.01; done
                exit 0
                """,
                "darkbloom-process-race",
                descendantPID.path,
                leaderExit.path,
            ],
            environment: [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "LANG": "en_US.UTF-8",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": NSTemporaryDirectory(),
            ],
            currentDirectory: nil,
            maximumOutputBytes:
                SandboxProcessRunner.defaultMaximumOutputBytes,
            testHooks: hooks
        )
        do {
            try execution.start()
        } catch {
            execution.cleanup()
            throw error
        }
        return execution
    }

    func allowLeaderToExit() throws {
        try Data().write(to: leaderExit, options: .withoutOverwriting)
    }

    func waitForDescendantIdentity() async throws -> ProcessBirthIdentity {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        repeat {
            if let value = try? String(
                contentsOf: descendantPID,
                encoding: .utf8
            ), let pid = pid_t(value),
               let identity = ProcessBirthIdentity.read(pid)
            {
                return identity
            }
            guard clock.now < deadline else {
                throw ProcessExecutionRaceTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        } while true
    }

    func waitUntilIdentityIsGone(
        _ identity: ProcessBirthIdentity
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while ProcessBirthIdentity.read(identity.pid) == identity {
            guard clock.now < deadline else {
                throw ProcessExecutionRaceTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func remove() {
        try? Data().write(to: leaderExit, options: .withoutOverwriting)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class UnrelatedProcess {
    let process: Process
    let identity: ProcessBirthIdentity

    init() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard let identity = ProcessBirthIdentity.read(
            process.processIdentifier
        ) else {
            process.terminate()
            process.waitUntilExit()
            throw ProcessExecutionRaceTestError.identityUnavailable
        }
        self.process = process
        self.identity = identity
    }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
    }
}

private enum ProcessExecutionRaceTestError: Error {
    case identityUnavailable
    case timedOut
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
