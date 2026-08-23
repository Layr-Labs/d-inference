import Foundation
import SandboxRuntime
import XCTest

final class LumeListJSONContractTests: XCTestCase {
    func testPinnedLumeKeepsJSONCleanWhenRemovingStaleSession() async throws {
        guard let executablePath = ProcessInfo.processInfo.environment[
            "DARKBLOOM_SANDBOX_LUME_PATH"
        ] else {
            throw XCTSkip(
                "set DARKBLOOM_SANDBOX_LUME_PATH for the pinned Lume contract test"
            )
        }
        let fixture = try LumeListJSONFixture()
        defer { fixture.remove() }

        let result = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: executablePath),
            arguments: [
                "ls",
                "--format", "json",
                "--storage", fixture.storage.path,
            ],
            environment: [
                "LUME_LOG_LEVEL": "error",
                "LUME_TELEMETRY_ENABLED": "false",
            ],
            timeoutSeconds: 30
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.standardOutputTruncated)
        XCTAssertTrue(result.standardError.isEmpty)
        let records = try JSONDecoder().decode(
            [LumeListJSONRecord].self,
            from: result.standardOutput
        )
        XCTAssertEqual(records, [
            LumeListJSONRecord(
                name: LumeListJSONFixture.virtualMachineName,
                status: "stopped"
            ),
        ])
    }
}

private struct LumeListJSONRecord: Decodable, Equatable {
    let name: String
    let status: String
}

private struct LumeListJSONFixture {
    static let virtualMachineName = "darkbloom-json-contract"

    let storage: URL

    init() throws {
        storage = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "darkbloom-lume-list-json-\(UUID().uuidString)",
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
