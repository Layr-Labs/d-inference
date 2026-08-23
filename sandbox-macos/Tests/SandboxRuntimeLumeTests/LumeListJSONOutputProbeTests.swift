import Foundation
import SandboxRuntime
import SandboxRuntimeLume
import XCTest

final class LumeListJSONOutputProbeTests: XCTestCase {
    func testPinnedLumeListJSONDuringStaleHeadlessSessionCleanup() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["DARKBLOOM_SANDBOX_LUME_LIST_JSON_PROBE"] == "1",
            "set DARKBLOOM_SANDBOX_LUME_LIST_JSON_PROBE=1 for the focused Lume JSON probe"
        )
        let executablePath = try XCTUnwrap(
            environment["DARKBLOOM_SANDBOX_LUME_PATH"]
        )
        let fixture = try LumeListJSONProbeFixture()
        defer { fixture.remove() }

        let result = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: executablePath),
            arguments: [
                "ls",
                "--format", "json",
                "--storage", fixture.storage.path,
            ],
            environment: [
                "LUME_LOG_LEVEL": "info",
                "LUME_TELEMETRY_ENABLED": "false",
            ],
            timeoutSeconds: 30
        )

        guard result.exitCode == 0 else {
            let artifact = try preserveFailure(
                result: result,
                error: "lume exited with status \(result.exitCode)"
            )
            XCTFail("focused Lume JSON probe failed; raw output: \(artifact.path)")
            return
        }

        do {
            let records = try JSONDecoder().decode(
                [LumeListJSONProbeRecord].self,
                from: result.standardOutput
            )
            XCTAssertEqual(records, [
                LumeListJSONProbeRecord(
                    name: LumeListJSONProbeFixture.virtualMachineName,
                    status: "stopped"
                ),
            ])
            XCTAssertTrue(result.standardError.isEmpty)
        } catch {
            let artifact = try preserveFailure(
                result: result,
                error: String(reflecting: error)
            )
            XCTFail(
                "Lume ls --format json emitted malformed stdout during "
                    + "stale headless-session cleanup; raw output: \(artifact.path)"
            )
        }
    }

    private func preserveFailure(
        result: SandboxProcessResult,
        error: String
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "darkbloom-lume-list-json-failure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let stdout = directory.appendingPathComponent("stdout.bin")
        let stderr = directory.appendingPathComponent("stderr.bin")
        let metadata = directory.appendingPathComponent("metadata.json")
        try result.standardOutput.write(to: stdout, options: .atomic)
        try result.standardError.write(to: stderr, options: .atomic)
        try JSONSerialization.data(
            withJSONObject: [
                "decodeError": error,
                "exitCode": Int(result.exitCode),
                "stderrBytes": result.standardError.count,
                "stderrTruncated": result.standardErrorTruncated,
                "stdoutBytes": result.standardOutput.count,
                "stdoutTruncated": result.standardOutputTruncated,
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: metadata, options: .atomic)
        for file in [stdout, stderr, metadata] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: file.path
            )
        }
        return directory
    }
}

private struct LumeListJSONProbeRecord: Decodable, Equatable {
    let name: String
    let status: String
}

private struct LumeListJSONProbeFixture {
    static let virtualMachineName = "darkbloom-json-probe"

    let storage: URL

    init() throws {
        storage = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "darkbloom-lume-list-json-probe-\(UUID().uuidString)",
                isDirectory: true
            )
        let virtualMachine = storage.appendingPathComponent(
            Self.virtualMachineName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: virtualMachine,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONSerialization.data(
            withJSONObject: [
                "cpuCount": 4,
                "diskSize": 100 * 1_073_741_824,
                "display": "1024x768",
                "macAddress": "02:00:00:00:00:01",
                "memorySize": 8 * 1_073_741_824,
                "networkMode": "nat",
                "os": "macOS",
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(
            to: virtualMachine.appendingPathComponent("config.json"),
            options: .atomic
        )
        try Data().write(
            to: virtualMachine.appendingPathComponent("disk.img")
        )
        try Data().write(
            to: virtualMachine.appendingPathComponent("nvram.bin")
        )
        try JSONSerialization.data(
            withJSONObject: [
                "pid": Int(Int32.max),
                "startedAt": 0,
                "vncEnabled": false,
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(
            to: virtualMachine.appendingPathComponent("sessions.json"),
            options: .atomic
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: storage)
    }
}
