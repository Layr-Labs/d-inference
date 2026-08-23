import Foundation
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeGuestCommandEncoderTests: XCTestCase {
    func testEncodedCommandPreservesArgumentsWithoutShellInjection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-command-encoder-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let injectedPath = directory.appendingPathComponent("injected")
        let hostileArgument = "value'; touch '\(injectedPath.path)"
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: UUID(
                uuidString: "B57A4FA2-BCA8-45EF-A7D8-F4A20FE85DBA"
            )!,
            executable: "/usr/bin/printf",
            arguments: ["%s", hostileArgument],
            workingDirectory: directory.path,
            timeoutSeconds: 5
        )
        let encodedCommand = try LumeGuestCommandEncoder.encode(request)

        let result = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", encodedCommand],
            timeoutSeconds: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        let decoded = try LumeGuestCommandResultDecoder.decode(
            result.standardOutput
        )
        XCTAssertEqual(
            String(decoding: decoded.standardOutput, as: UTF8.self),
            hostileArgument
        )
        XCTAssertTrue(decoded.standardError.isEmpty)
        XCTAssertFalse(decoded.standardOutputTruncated)
        XCTAssertFalse(decoded.standardErrorTruncated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: injectedPath.path))
    }

    func testEnvelopeSeparatesStreamsAndPreservesExitCode() async throws {
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/bin/zsh",
            arguments: [
                "-c",
                "/usr/bin/printf stdout; /usr/bin/printf stderr >&2; exit 7",
            ],
            workingDirectory:
                FileManager.default.temporaryDirectory.path,
            timeoutSeconds: 5
        )
        let encodedCommand = try LumeGuestCommandEncoder.encode(request)

        let process = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", encodedCommand],
            timeoutSeconds: 5,
            maximumOutputBytes:
                LumeGuestCommandEnvelope.maximumEnvelopeBytes
        )
        let result = try LumeGuestCommandResultDecoder.decode(
            process.standardOutput
        )

        XCTAssertEqual(process.exitCode, 0)
        XCTAssertTrue(process.standardError.isEmpty)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.standardOutput, Data("stdout".utf8))
        XCTAssertEqual(result.standardError, Data("stderr".utf8))
        XCTAssertFalse(result.standardOutputTruncated)
        XCTAssertFalse(result.standardErrorTruncated)
    }

    func testGuestCommandCannotConsumeWrapperScriptFromStandardInput() async throws {
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/bin/cat",
            workingDirectory:
                FileManager.default.temporaryDirectory.path,
            timeoutSeconds: 5
        )
        let encodedCommand = try LumeGuestCommandEncoder.encode(request)

        let process = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", encodedCommand],
            timeoutSeconds: 5,
            maximumOutputBytes:
                LumeGuestCommandEnvelope.maximumEnvelopeBytes
        )
        let result = try LumeGuestCommandResultDecoder.decode(
            process.standardOutput
        )

        XCTAssertEqual(process.exitCode, 0)
        XCTAssertTrue(process.standardError.isEmpty)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.isEmpty)
        XCTAssertTrue(result.standardError.isEmpty)
        XCTAssertFalse(result.standardOutputTruncated)
        XCTAssertFalse(result.standardErrorTruncated)
    }

    func testCancellationStopsGuestJobBeforeDelayedSideEffect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-command-cancellation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("delayed-marker")
        let idempotencyKey = UUID()
        let cancellationFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Caches/dev.darkbloom.sandbox/commands",
                isDirectory: true
            )
            .appendingPathComponent(
                "\(idempotencyKey.uuidString.lowercased()).cancelled"
            )
        defer { try? FileManager.default.removeItem(at: cancellationFile) }
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: idempotencyKey,
            executable: "/bin/zsh",
            arguments: [
                "-c",
                "/bin/sleep 1; /usr/bin/touch -- \"$1\"",
                "darkbloom-test",
                marker.path,
            ],
            workingDirectory: directory.path,
            timeoutSeconds: 5
        )
        let runner = SandboxProcessRunner()
        let process = try runner.start(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-c",
                try LumeGuestCommandEncoder.encode(request),
            ],
            maximumOutputBytes:
                LumeGuestCommandEnvelope.maximumEnvelopeBytes
        )
        try await Task.sleep(for: .milliseconds(100))

        let cancellation = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-c",
                LumeGuestCommandEncoder.encodeCancellation(
                    idempotencyKey: idempotencyKey
                ),
            ],
            timeoutSeconds: 5
        )
        let execution = await process.wait()
        try await Task.sleep(for: .seconds(2))

        XCTAssertEqual(cancellation.exitCode, 0)
        XCTAssertEqual(execution.exitCode, 125)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testOneMiBBoundAvoidsArgumentLimitAndDrainsGuestOutput() async throws {
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/bin/dd",
            arguments: [
                "if=/dev/zero",
                "bs=\(LumeGuestCommandEnvelope.maximumStreamBytes)",
                "count=2",
            ],
            workingDirectory:
                FileManager.default.temporaryDirectory.path,
            timeoutSeconds: 5
        )
        let encodedCommand = try LumeGuestCommandEncoder.encode(request)

        let process = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", encodedCommand],
            timeoutSeconds: 5,
            maximumOutputBytes:
                LumeGuestCommandEnvelope.maximumEnvelopeBytes
        )
        guard process.exitCode == 0,
              !process.standardOutputTruncated,
              !process.standardErrorTruncated,
              process.standardError.isEmpty
        else {
            XCTFail(
                "wrapper failed before envelope decode: "
                    + "exit=\(process.exitCode), "
                    + "stdout_truncated=\(process.standardOutputTruncated), "
                    + "stderr="
                    + String(
                        decoding: process.standardError,
                        as: UTF8.self
                    )
            )
            return
        }
        XCTAssertGreaterThan(
            process.standardOutput.count,
            LumeGuestCommandEnvelope.maximumStreamBytes
        )
        let result = try LumeGuestCommandResultDecoder.decode(
            process.standardOutput
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            result.standardOutput,
            Data(
                repeating: 0,
                count: LumeGuestCommandEnvelope.maximumStreamBytes
            )
        )
        XCTAssertTrue(result.standardOutputTruncated)
        XCTAssertFalse(result.standardError.isEmpty)
        XCTAssertFalse(result.standardErrorTruncated)
    }

    func testLaunchDefinitionCarriesEnvironmentAndIdempotencyKey() async throws {
        let idempotencyKey = UUID(
            uuidString: "B57A4FA2-BCA8-45EF-A7D8-F4A20FE85DBA"
        )!
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: idempotencyKey,
            executable: "/usr/bin/env",
            environment: ["Z_KEY": "last", "A_KEY": "first"],
            workingDirectory:
                FileManager.default.temporaryDirectory.path,
            timeoutSeconds: 5
        )
        let encodedCommand = try LumeGuestCommandEncoder.encode(request)

        let process = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", encodedCommand],
            timeoutSeconds: 5,
            maximumOutputBytes:
                LumeGuestCommandEnvelope.maximumEnvelopeBytes
        )
        let result = try LumeGuestCommandResultDecoder.decode(
            process.standardOutput
        )
        let environment = String(decoding: result.standardOutput, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)

        XCTAssertEqual(process.exitCode, 0)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(environment.contains("A_KEY=first"))
        XCTAssertTrue(environment.contains("Z_KEY=last"))
        XCTAssertTrue(
            environment.contains(
                "DARKBLOOM_IDEMPOTENCY_KEY=b57a4fa2-bca8-45ef-a7d8-f4a20fe85dba"
            )
        )
    }
}
