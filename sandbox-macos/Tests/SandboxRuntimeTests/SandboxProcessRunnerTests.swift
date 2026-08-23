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
}
