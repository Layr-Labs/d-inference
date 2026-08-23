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

        let result = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", LumeGuestCommandEncoder.encode(request)],
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
            timeoutSeconds: 5
        )

        let process = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", LumeGuestCommandEncoder.encode(request)],
            timeoutSeconds: 5,
            maximumOutputBytes:
                LumeGuestCommandEnvelope.maximumEnvelopeBytes
        )
        let result = try LumeGuestCommandResultDecoder.decode(
            process.standardOutput
        )

        XCTAssertEqual(process.exitCode, 0)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.standardOutput, Data("stdout".utf8))
        XCTAssertEqual(result.standardError, Data("stderr".utf8))
        XCTAssertFalse(result.standardOutputTruncated)
        XCTAssertFalse(result.standardErrorTruncated)
    }

    func testEnvelopeBoundsAndDrainsGuestOutput() async throws {
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/bin/dd",
            arguments: [
                "if=/dev/zero",
                "bs=\(LumeGuestCommandEnvelope.maximumStreamBytes)",
                "count=2",
            ],
            timeoutSeconds: 5
        )

        let process = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", LumeGuestCommandEncoder.encode(request)],
            timeoutSeconds: 5,
            maximumOutputBytes:
                LumeGuestCommandEnvelope.maximumEnvelopeBytes
        )
        let result = try LumeGuestCommandResultDecoder.decode(
            process.standardOutput
        )

        XCTAssertEqual(process.exitCode, 0)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            result.standardOutput.count,
            LumeGuestCommandEnvelope.maximumStreamBytes
        )
        XCTAssertTrue(result.standardOutputTruncated)
        XCTAssertFalse(result.standardError.isEmpty)
        XCTAssertFalse(result.standardErrorTruncated)
    }

    func testScriptCarriesDeterministicEnvironmentAndIdempotencyKey() throws {
        let idempotencyKey = UUID(
            uuidString: "B57A4FA2-BCA8-45EF-A7D8-F4A20FE85DBA"
        )!
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: idempotencyKey,
            executable: "/usr/bin/env",
            environment: ["Z_KEY": "last", "A_KEY": "first"],
            timeoutSeconds: 5
        )

        let script = LumeGuestCommandEncoder.script(request)
        let aIndex = try XCTUnwrap(script.range(of: "'A_KEY=first'")?.lowerBound)
        let zIndex = try XCTUnwrap(script.range(of: "'Z_KEY=last'")?.lowerBound)

        XCTAssertLessThan(aIndex, zIndex)
        XCTAssertTrue(
            script.contains(
                "'DARKBLOOM_IDEMPOTENCY_KEY=b57a4fa2-bca8-45ef-a7d8-f4a20fe85dba'"
            )
        )
        XCTAssertFalse(script.contains("exec /usr/bin/env"))
    }
}
