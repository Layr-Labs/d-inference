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
}
