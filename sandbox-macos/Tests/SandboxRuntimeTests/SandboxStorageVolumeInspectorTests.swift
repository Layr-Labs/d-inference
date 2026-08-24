import Darwin
import Foundation
@testable import SandboxRuntime
import XCTest

final class SandboxStorageVolumeInspectorTests: XCTestCase {
    func testInspectsConfiguredStorageVolume() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-storage-inspection-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: path,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: path) }

        let report = try SandboxStorageVolumeInspector().inspect(path: path)

        XCTAssertEqual(report.path, path.standardizedFileURL)
        XCTAssertEqual(report.identity.canonicalPath, path.path)
        XCTAssertGreaterThan(report.identity.inode, 0)
        XCTAssertGreaterThan(report.availableImportantBytes, 0)
    }

    func testRejectsSharedStorageDirectory() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-storage-shared-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: path,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o777]
        )
        guard chmod(path.path, 0o777) == 0 else {
            throw POSIXError(.EACCES)
        }
        defer { try? FileManager.default.removeItem(at: path) }

        XCTAssertThrowsError(
            try SandboxStorageVolumeInspector().inspect(path: path)
        ) { error in
            XCTAssertEqual(
                error as? SandboxStorageVolumeInspectionError,
                .unsafePath
            )
        }
    }

    func testRejectsRelativeStoragePath() {
        XCTAssertThrowsError(
            try SandboxStorageVolumeInspector().inspect(
                path: URL(fileURLWithPath: "relative", relativeTo: URL(
                    fileURLWithPath: "/tmp",
                    isDirectory: true
                ))
            )
        ) { error in
            XCTAssertEqual(
                error as? SandboxStorageVolumeInspectionError,
                .invalidPath
            )
        }
    }
}
