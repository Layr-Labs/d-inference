import Foundation
@testable import DarkbloomSandboxDaemon
import XCTest

final class ServeCommandTests: XCTestCase {
    func testParsesProductionServeConfiguration() throws {
        let options = try ServeCommand.Options([
            "--coordinator", "wss://api.example.test/ws/sandbox-host",
            "--host-id", "aaaaaaaa-0000-0000-0000-000000000001",
            "--token-file", "/var/db/darkbloom/token",
            "--lume", "/opt/darkbloom/lume",
            "--storage", "/var/lib/darkbloom/vms",
            "--capacity-dir", "/var/lib/darkbloom/capacity",
            "--base-images", "macos-tahoe-v1,macos-sequoia-v1",
            "--max-cpu", "12",
            "--max-memory-gib", "32",
        ])

        XCTAssertEqual(
            options.coordinatorURL.absoluteString,
            "wss://api.example.test/ws/sandbox-host"
        )
        XCTAssertEqual(
            options.hostID.uuidString.lowercased(),
            "aaaaaaaa-0000-0000-0000-000000000001"
        )
        XCTAssertEqual(options.maximumCPUCount, 12)
        XCTAssertEqual(options.maximumMemoryBytes, 32 * 1_073_741_824)
        XCTAssertEqual(options.maximumGrowthBytes, 320 * 1_073_741_824)
        XCTAssertEqual(options.storageHeadroomBytes, 20 * 1_073_741_824)
        XCTAssertEqual(
            options.baseImageIDs,
            ["macos-tahoe-v1", "macos-sequoia-v1"]
        )
        XCTAssertFalse(options.developmentAdHocLume)
        XCTAssertFalse(options.allowInsecureLoopback)
    }

    func testRejectsIncompleteRelativeDuplicateAndOverflowingOptions() {
        XCTAssertThrowsError(try ServeCommand.Options([
            "--coordinator", "wss://api.example.test/ws/sandbox-host",
            "--host-id", UUID().uuidString,
            "--token-file", "relative-token",
            "--lume", "/lume",
            "--storage", "/storage",
            "--capacity-dir", "/capacity",
            "--base-images", "macos-tahoe-v1",
            "--max-cpu", "8",
            "--max-memory-gib", "16",
        ]))
        XCTAssertThrowsError(try ServeCommand.Options([
            "--coordinator", "wss://api.example.test/ws/sandbox-host",
            "--host-id", UUID().uuidString,
            "--token-file", "/token",
            "--lume", "/lume",
            "--lume", "/other",
            "--storage", "/storage",
            "--capacity-dir", "/capacity",
            "--base-images", "macos-tahoe-v1",
            "--max-cpu", "8",
            "--max-memory-gib", "16",
        ]))
        XCTAssertThrowsError(try ServeCommand.Options([
            "--coordinator", "wss://api.example.test/ws/sandbox-host",
            "--host-id", UUID().uuidString,
            "--token-file", "/token",
            "--lume", "/lume",
            "--storage", "/storage",
            "--capacity-dir", "/capacity",
            "--base-images", "macos-tahoe-v1",
            "--max-cpu", "8",
            "--max-memory-gib", String(UInt64.max),
        ]))
    }

    func testReadsOnlyPrivateStableTokenFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-host-token-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let token = root.appendingPathComponent("token")
        try Data("sandbox-host-token-0000000000000001\n".utf8).write(to: token)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: token.path
        )

        XCTAssertEqual(
            try SandboxHostTokenFile.read(token),
            "sandbox-host-token-0000000000000001"
        )

        let alias = root.appendingPathComponent("token-alias")
        try FileManager.default.linkItem(at: token, to: alias)
        XCTAssertThrowsError(try SandboxHostTokenFile.read(token))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: token.path
        )
        XCTAssertThrowsError(try SandboxHostTokenFile.read(token))
    }
}
