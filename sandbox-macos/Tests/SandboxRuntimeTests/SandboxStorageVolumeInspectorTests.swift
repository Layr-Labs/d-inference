import Foundation
@testable import SandboxRuntime
import XCTest

final class SandboxStorageVolumeInspectorTests: XCTestCase {
    func testInspectsConfiguredStorageVolume() throws {
        let path = FileManager.default.temporaryDirectory

        let report = try SandboxStorageVolumeInspector().inspect(path: path)

        XCTAssertEqual(report.path, path.standardizedFileURL)
        XCTAssertGreaterThan(report.availableImportantBytes, 0)
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
