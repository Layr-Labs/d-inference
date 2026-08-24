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

    func testCooperativeEOFIsStickyWhenStopImmediatelyFollowsSpawn()
        async throws
    {
        let fixture = try ProcessControlFixture()
        defer { fixture.remove() }
        let process = try fixture.startEOFCooperativeProcess(
            preReadDelay: "0.2"
        )

        let result = await process.stop(
            cooperativeGracePeriod: .seconds(2),
            signalGracePeriod: .milliseconds(100)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self),
            "cooperative-eof"
        )
        XCTAssertFalse(fixture.signalMarkerExists)
    }

    func testOrdinaryCooperativeStopDoesNotUseSignalFallback() async throws {
        let fixture = try ProcessControlFixture()
        defer { fixture.remove() }
        let process = try fixture.startEOFCooperativeProcess()
        try await fixture.waitUntilReady()

        let result = await process.stop(
            cooperativeGracePeriod: .seconds(2),
            signalGracePeriod: .milliseconds(100)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(fixture.signalMarkerExists)
    }

    func testCooperativeStopRetainsBoundedSignalFallback() async throws {
        let fixture = try ProcessControlFixture()
        defer { fixture.remove() }
        let process = try fixture.startUncooperativeProcess()
        try await fixture.waitUntilReady()

        let result = await process.stop(
            cooperativeGracePeriod: .milliseconds(100),
            signalGracePeriod: .seconds(1)
        )

        XCTAssertEqual(result.exitCode, 128 + SIGKILL)
        XCTAssertTrue(fixture.signalMarkerExists)
    }

    func testManagedProcessDeinitClosesCooperativeEndpoint() async throws {
        let fixture = try ProcessControlFixture()
        defer { fixture.remove() }
        var process: SandboxManagedProcess? =
            try fixture.startEOFCooperativeProcess()
        try await fixture.waitUntilReady()

        process = nil
        _ = process

        try await fixture.waitUntilExitedCooperatively()
        XCTAssertFalse(fixture.signalMarkerExists)
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

    func testSpawnedChildDoesNotInheritAmbientDescriptors() async throws {
        let source = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard source >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { Darwin.close(source) }
        let ambientDescriptor = fcntl(source, F_DUPFD, 200)
        guard ambientDescriptor >= 200 else {
            throw POSIXError(.EIO)
        }
        defer { Darwin.close(ambientDescriptor) }
        let flags = fcntl(ambientDescriptor, F_GETFD)
        guard flags >= 0,
              fcntl(
                  ambientDescriptor,
                  F_SETFD,
                  flags & ~FD_CLOEXEC
              ) == 0
        else {
            throw POSIXError(.EIO)
        }

        let result = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "test ! -e \"/dev/fd/$1\"",
                "darkbloom-fd-probe",
                String(ambientDescriptor),
            ],
            timeoutSeconds: 5
        )

        XCTAssertEqual(result.exitCode, 0)
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

private struct ProcessControlFixture {
    private static let environmentVariable =
        "DARKBLOOM_TEST_PROCESS_CONTROL_FD"

    let directory: URL
    let ready: URL
    let signal: URL
    let cooperativeExit: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "darkbloom-process-control-\(UUID().uuidString)",
                isDirectory: true
            )
        ready = directory.appendingPathComponent("ready")
        signal = directory.appendingPathComponent("signal")
        cooperativeExit = directory.appendingPathComponent(
            "cooperative-exit"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
    }

    var signalMarkerExists: Bool {
        FileManager.default.fileExists(atPath: signal.path)
    }

    func startEOFCooperativeProcess(
        preReadDelay: String? = nil
    ) throws -> SandboxManagedProcess {
        let delay = preReadDelay.map { "/bin/sleep \($0);" } ?? ""
        return try SandboxProcessRunner().start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                trap 'printf signal > "$2"; exit 91' TERM
                printf ready > "$1"
                \(delay)
                descriptor="${\(Self.environmentVariable)}"
                eval "/bin/cat <&$descriptor" >/dev/null
                printf cooperative-eof
                printf exited > "$3"
                """,
                "darkbloom-process-control",
                ready.path,
                signal.path,
                cooperativeExit.path,
            ],
            cooperativeControl: SandboxCooperativeProcessControl(
                environmentVariable: Self.environmentVariable
            )
        )
    }

    func startUncooperativeProcess() throws -> SandboxManagedProcess {
        try SandboxProcessRunner().start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                trap 'printf signal > "$2"' TERM
                printf ready > "$1"
                while :; do :; done
                """,
                "darkbloom-process-control",
                ready.path,
                signal.path,
            ],
            cooperativeControl: SandboxCooperativeProcessControl(
                environmentVariable: Self.environmentVariable
            )
        )
    }

    func waitUntilReady() async throws {
        try await waitForMarker(ready)
    }

    func waitUntilExitedCooperatively() async throws {
        try await waitForMarker(cooperativeExit)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitForMarker(_ marker: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: marker.path) {
            guard clock.now < deadline else {
                throw SandboxRuntimeError.operationTimedOut(
                    marker.lastPathComponent
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
