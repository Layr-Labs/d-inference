import Foundation
import SandboxRuntimeLume
import XCTest

final class LumeRuntimeContractTests: XCTestCase {
    func testRuntimePinMatchesAuditedLockFile() throws {
        let lockURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ThirdParty/lume.lock.json")
        let lock = try JSONDecoder().decode(
            LumeLock.self,
            from: Data(contentsOf: lockURL)
        )

        XCTAssertEqual(lock.commit, LumeRuntimeConfiguration.pinnedCommit)
        XCTAssertEqual(lock.version, LumeRuntimeConfiguration.pinnedVersion)
        XCTAssertEqual(lock.license, "MIT")
        XCTAssertEqual(lock.telemetry, "disabled")
    }

    func testPinnedRealLumeBinaryAndEmptyStorageContract() async throws {
        guard let executablePath = ProcessInfo.processInfo.environment[
            "DARKBLOOM_SANDBOX_LUME_PATH"
        ] else {
            throw XCTSkip(
                "set DARKBLOOM_SANDBOX_LUME_PATH for the pinned Lume contract test"
            )
        }

        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-lume-contract-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: storage) }

        let configuration = try LumeRuntimeConfiguration(
            executable: URL(fileURLWithPath: executablePath),
            storageDirectory: storage
        )
        let runtime = LumeVirtualMachineRuntime(configuration: configuration)

        let capabilities = try await runtime.capabilities()
        XCTAssertEqual(capabilities.runtime, "lume")
        XCTAssertEqual(capabilities.version, LumeRuntimeConfiguration.pinnedVersion)
        XCTAssertTrue(capabilities.supportsMacOS)
        XCTAssertFalse(capabilities.supportsPause)
        XCTAssertFalse(capabilities.supportsSnapshots)
        XCTAssertEqual(try await runtime.list(), [])
    }

    func testConfigurationRejectsRelativeStoragePath() {
        XCTAssertThrowsError(try LumeRuntimeConfiguration(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            storageDirectory: URL(fileURLWithPath: "relative", relativeTo: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ))
        ))
    }
}

private struct LumeLock: Decodable {
    let commit: String
    let version: String
    let license: String
    let telemetry: String
}
