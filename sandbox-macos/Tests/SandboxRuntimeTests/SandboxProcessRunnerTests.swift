import Darwin
import Foundation
import SandboxRuntime
import XCTest

final class SandboxProcessRunnerTests: XCTestCase {
    func testCapturesOutputAndExitStatusWithoutShell() async throws {
        let result = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["sandbox-output"],
            timeoutSeconds: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self),
            "sandbox-output"
        )
        XCTAssertTrue(result.standardError.isEmpty)
        XCTAssertFalse(result.standardOutputTruncated)
        XCTAssertFalse(result.standardErrorTruncated)
    }

    func testReturnsNonzeroExitStatusForCallerClassification() async throws {
        let result = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            timeoutSeconds: 5
        )

        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testWaitsForNaturallyExitingDelayedProcess() async throws {
        let started = ContinuousClock.now

        let result = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["1"],
            timeoutSeconds: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(900))
    }

    func testBoundsCapturedOutput() async throws {
        let result = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["0123456789abcdef"],
            timeoutSeconds: 5,
            maximumOutputBytes: 8
        )

        XCTAssertEqual(result.standardOutput, Data("01234567".utf8))
        XCTAssertTrue(result.standardOutputTruncated)
    }

    func testDrainsLargeOutputWithoutGrowingCapture() async throws {
        let result = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "i=0; while [ \"$i\" -lt 20000 ]; do "
                    + "printf 0123456789abcdef; "
                    + "printf fedcba9876543210 >&2; "
                    + "i=$((i + 1)); done",
            ],
            timeoutSeconds: 10,
            maximumOutputBytes: 1_024
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.count, 1_024)
        XCTAssertEqual(result.standardError.count, 1_024)
        XCTAssertTrue(result.standardOutputTruncated)
        XCTAssertTrue(result.standardErrorTruncated)
    }

    func testTerminatesProcessAtDeadline() async throws {
        let started = ContinuousClock.now

        do {
            _ = try await SandboxProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeoutSeconds: 1
            )
            XCTFail("sleep should have timed out")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(error, .operationTimedOut("sleep"))
        }

        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    func testCancellationTerminatesProcessPromptly() async throws {
        let started = ContinuousClock.now
        let task = Task {
            try await SandboxProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeoutSeconds: 60
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled process should not return a result")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(3))
    }

    func testManagedProcessSupportsConcurrentWaiters() async throws {
        let process = try SandboxProcessRunner().start(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["1"]
        )

        async let first = process.wait()
        async let second = process.wait()
        let (firstResult, secondResult) = await (first, second)

        XCTAssertEqual(firstResult.exitCode, 0)
        XCTAssertEqual(secondResult.exitCode, 0)
    }

    func testDoesNotLeakParentEnvironment() async throws {
        let secretKey = "DARKBLOOM_PROCESS_RUNNER_PARENT_SECRET"
        setenv(secretKey, "must-not-leak", 1)
        defer { unsetenv(secretKey) }

        let result = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            environment: ["DARKBLOOM_EXPLICIT": "present"],
            timeoutSeconds: 5
        )
        let output = String(decoding: result.standardOutput, as: UTF8.self)

        XCTAssertFalse(output.contains("\(secretKey)="))
        XCTAssertTrue(output.contains("DARKBLOOM_EXPLICIT=present"))
    }

    func testTimeoutTerminatesDescendantProcessGroup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "darkbloom-process-group-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")

        do {
            _ = try await SandboxProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "/bin/sleep 30 & child=$!; "
                        + "printf '%s\\n' \"$child\" > \"$1\"; wait \"$child\"",
                    "darkbloom-process-group-test",
                    pidFile.path,
                ],
                timeoutSeconds: 1
            )
            XCTFail("process group should time out")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(error, .operationTimedOut("sh"))
        }

        let value = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(value))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while Darwin.kill(pid, 0) == 0 && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
