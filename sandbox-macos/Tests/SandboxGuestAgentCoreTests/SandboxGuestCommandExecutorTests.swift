import Foundation
import SandboxGuestProtocol
import XCTest

@testable import SandboxGuestAgentCore

/// Exercises the real spawn, capture and deadline paths by running real
/// commands. Nothing here is mocked: a mocked executor would hide exactly the
/// bugs that matter (a pipe that deadlocks, a deadline that does not reach a
/// grandchild, an environment a command can override).
final class SandboxGuestCommandExecutorTests: XCTestCase {
    private let executor = SandboxGuestCommandExecutor(home: "/tmp")

    private func wire(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String] = [:],
        timeoutSeconds: UInt32 = 30
    ) -> SandboxGuestCommandWire {
        SandboxGuestCommandWire(
            idempotencyKey: UUID().uuidString,
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: "/tmp",
            timeoutSeconds: timeoutSeconds
        )
    }

    func testEchoProducesExactStdoutAndZeroExit() {
        let result = executor.execute(wire("/bin/echo", ["hello", "world"]))
        XCTAssertTrue(result.isSelfConsistent)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self),
            "hello world\n"
        )
        XCTAssertTrue(result.standardError.isEmpty)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.standardOutputTruncated)
    }

    func testExitCodesArePreserved() {
        XCTAssertEqual(executor.execute(wire("/usr/bin/false")).exitCode, 1)
        XCTAssertEqual(
            executor.execute(wire("/bin/sh", ["-c", "exit 42"])).exitCode,
            42
        )
    }

    func testStreamsStaySeparate() {
        let result = executor.execute(
            wire("/bin/sh", ["-c", "echo out; echo err 1>&2"])
        )
        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self),
            "out\n"
        )
        XCTAssertEqual(
            String(decoding: result.standardError, as: UTF8.self),
            "err\n"
        )
    }

    func testOversizedOutputIsCappedFlaggedAndDoesNotDeadlock() {
        // Two MiB through a pipe whose buffer is far smaller: the drain has to
        // keep reading past the cap or the command never exits.
        let result = executor.execute(
            wire(
                "/bin/sh",
                ["-c", "/usr/bin/yes 0123456789 | /usr/bin/head -c 2097152"],
                timeoutSeconds: 120
            )
        )
        XCTAssertTrue(result.isSelfConsistent)
        XCTAssertEqual(
            result.standardOutput.count,
            SandboxGuestLimits.maximumStreamBytes
        )
        XCTAssertTrue(result.standardOutputTruncated)
        XCTAssertFalse(result.standardErrorTruncated)
        XCTAssertFalse(result.timedOut)
    }

    func testDeadlineReportsTimeoutAndReturnsPromptly() {
        let started = Date()
        let result = executor.execute(wire("/bin/sleep", ["30"], timeoutSeconds: 2))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.isSelfConsistent)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, SandboxGuestCommandExecutor.timeoutExitCode)
        XCTAssertLessThan(elapsed, 20, "must not wait out the full sleep")
    }

    func testDeadlineKillsTheWholeProcessGroup() {
        // The direct child exits quickly but leaves a grandchild holding the
        // pipe. Only a process-group kill ends this.
        let started = Date()
        let result = executor.execute(
            wire("/bin/sh", ["-c", "/bin/sleep 30 & wait"], timeoutSeconds: 2)
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(elapsed, 20, "grandchild must be killed too")
    }

    func testReservedEnvironmentKeysAreRefusedNotOverridden() {
        // The host rejects these at construction, so a request carrying one is
        // a buggy host or a hostile peer. The agent must refuse rather than
        // silently override — its validator must never be weaker than the
        // host's.
        for key in ["PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "ENV",
                    "BASH_ENV", "ZDOTDIR", "DYLD_INSERT_LIBRARIES",
                    "DARKBLOOM_IDEMPOTENCY_KEY"] {
            let result = executor.execute(
                wire("/bin/echo", ["x"], environment: [key: "/evil"])
            )
            XCTAssertEqual(
                result.exitCode, 70,
                "\(key) must be refused before the spawn"
            )
        }
    }

    func testInvalidEnvironmentKeysAreRefused() {
        for key in ["bad-key", "1LEADING", "has space", ""] {
            let result = executor.execute(
                wire("/bin/echo", ["x"], environment: [key: "v"])
            )
            XCTAssertEqual(result.exitCode, 70, "'\(key)' must be refused")
        }
    }

    func testOversizedAggregateInputIsRefusedBeforeSpawn() {
        // Without this the spawn fails deep inside posix_spawn as an opaque
        // E2BIG instead of a clean validation refusal.
        let huge = String(repeating: "a", count: 16_000)
        var environment: [String: String] = [:]
        for index in 0..<10 { environment["VAR\(index)"] = huge }
        let result = executor.execute(wire("/bin/echo", ["x"], environment: environment))
        XCTAssertEqual(result.exitCode, 70)
    }

    func testFixedEnvironmentIsAppliedAndCallerValuesPassThrough() {
        let result = executor.execute(
            wire(
                "/bin/sh",
                ["-c", "printf '%s|%s|%s' \"$PATH\" \"$HOME\" \"$USER_DEFINED\""],
                environment: ["USER_DEFINED": "kept"]
            )
        )
        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self),
            "/usr/bin:/bin:/usr/sbin:/sbin|/tmp|kept"
        )
    }

    func testIdempotencyKeyIsExposedToTheCommand() {
        let request = wire("/bin/sh", ["-c", "printf '%s' \"$DARKBLOOM_IDEMPOTENCY_KEY\""])
        let result = executor.execute(request)
        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self),
            request.idempotencyKey
        )
    }

    func testDeadlineFiresEvenWhenTheCommandClosesBothStreams() {
        // Regression: the deadline used to live only in the drain loop, so a
        // command that closed stdout and stderr reached EOF immediately and
        // then ran unbounded inside waitpid. A session serves one command at a
        // time, so that wedged the whole agent.
        let started = Date()
        let result = executor.execute(
            wire(
                "/bin/sh",
                ["-c", "exec 1>&- 2>&-; /bin/sleep 20; exit 3"],
                timeoutSeconds: 2
            )
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.timedOut, "the deadline must bound the process, not the pipes")
        XCTAssertEqual(result.exitCode, SandboxGuestCommandExecutor.timeoutExitCode)
        XCTAssertLessThan(elapsed, 15, "must not run to the command's own completion")
    }

    func testFastExitWithABackgroundChildIsNotReportedAsATimeout() {
        // Regression: a grandchild holding the pipe open kept the drain running
        // to the deadline, so `cmd & exit 7` — the commonest shell idiom there
        // is — was reported as a 124 timeout with its real exit code discarded.
        let started = Date()
        let result = executor.execute(
            wire(
                "/bin/sh",
                ["-c", "echo done; /bin/sleep 30 & exit 7"],
                timeoutSeconds: 8
            )
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(result.timedOut, "the command finished; it did not time out")
        XCTAssertEqual(result.exitCode, 7, "the real exit code must survive")
        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self),
            "done\n",
            "output written before exit must still be captured"
        )
        XCTAssertLessThan(elapsed, 6, "must not wait out the orphan")
    }

    func testMalformedRequestIsRefusedWithoutSpawning() {
        let result = executor.execute(
            SandboxGuestCommandWire(
                idempotencyKey: "k",
                executable: "echo",  // relative: never legal
                arguments: [],
                environment: [:],
                workingDirectory: "/tmp",
                timeoutSeconds: 30
            )
        )
        XCTAssertEqual(result.exitCode, 70)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.isSelfConsistent)
    }

    func testMissingExecutableFailsClosedRatherThanHanging() {
        let result = executor.execute(
            wire("/nonexistent/definitely-not-here", [], timeoutSeconds: 10)
        )
        XCTAssertTrue(result.isSelfConsistent)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testWorkingDirectoryIsHonoured() {
        let result = executor.execute(wire("/bin/pwd"))
        let text = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // /tmp is a symlink to /private/tmp on macOS.
        XCTAssertTrue(
            text == "/tmp" || text == "/private/tmp",
            "expected the configured working directory, got \(text)"
        )
    }

    func testStdinIsClosedSoCommandsCannotBlockOnIt() {
        // Reading stdin must hit EOF immediately rather than waiting forever.
        let started = Date()
        let result = executor.execute(wire("/bin/cat", [], timeoutSeconds: 10))
        XCTAssertFalse(
            result.timedOut,
            "cat with no stdin must exit on EOF, not run to the deadline"
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }
}

final class BoundedSinkTests: XCTestCase {
    func testKeepsEverythingUnderTheLimit() {
        var sink = BoundedSink(limit: 10)
        sink.append([UInt8]("abc".utf8))
        sink.append([UInt8]("de".utf8))
        XCTAssertEqual(sink.bytes, Data("abcde".utf8))
        XCTAssertFalse(sink.truncated)
    }

    func testFlagsAndClipsAtTheLimit() {
        var sink = BoundedSink(limit: 4)
        sink.append([UInt8]("abcdef".utf8))
        XCTAssertEqual(sink.bytes, Data("abcd".utf8))
        XCTAssertTrue(sink.truncated)
    }

    func testFurtherAppendsAfterTheLimitStayFlagged() {
        var sink = BoundedSink(limit: 2)
        sink.append([UInt8]("ab".utf8))
        XCTAssertFalse(sink.truncated, "exactly at the limit is not truncation")
        sink.append([UInt8]("c".utf8))
        XCTAssertTrue(sink.truncated)
        XCTAssertEqual(sink.bytes.count, 2)
    }

    func testEmptyAppendAtTheLimitDoesNotFlag() {
        var sink = BoundedSink(limit: 1)
        sink.append([UInt8]("a".utf8))
        sink.append([UInt8]())
        XCTAssertFalse(sink.truncated)
    }
}

final class SandboxGuestProcessSpawnTests: XCTestCase {
    func testExitStatusDecoding() {
        // Normal exit: code in the high byte.
        XCTAssertEqual(SandboxGuestProcessSpawn.exitCode(from: 0), 0)
        XCTAssertEqual(SandboxGuestProcessSpawn.exitCode(from: 1 << 8), 1)
        XCTAssertEqual(SandboxGuestProcessSpawn.exitCode(from: 42 << 8), 42)
        // Signalled: shell convention, clamped into the envelope's legal range.
        XCTAssertEqual(SandboxGuestProcessSpawn.exitCode(from: SIGKILL), 137)
        XCTAssertEqual(SandboxGuestProcessSpawn.exitCode(from: SIGTERM), 143)
        XCTAssertEqual(SandboxGuestProcessSpawn.exitCode(from: 0x7F), 255)
    }
}
