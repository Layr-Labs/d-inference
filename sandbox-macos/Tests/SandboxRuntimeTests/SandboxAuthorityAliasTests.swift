import Darwin
import Foundation
@testable import SandboxRuntime
import XCTest

final class SandboxAuthorityAliasTests: XCTestCase {
    func testCreatesAndReopensThroughBothSystemTemporarySpellings() throws {
        let name = "darkbloom-alias-" + UUID().uuidString
        let physical = URL(fileURLWithPath: "/private/tmp/" + name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: physical) }
        let created = try SandboxAuthorityFileSystem.openPrivateDirectory(at: physical, createIfMissing: true)
        defer { close(created) }
        let alias = URL(fileURLWithPath: "/tmp/" + name, isDirectory: true)
        let reopened = try SandboxAuthorityFileSystem.openPrivateDirectory(at: alias, createIfMissing: false)
        defer { close(reopened) }
        XCTAssertTrue(SandboxAuthorityFileSystem.sameIdentity(
            try SandboxAuthorityFileSystem.fileMetadata(created),
            try SandboxAuthorityFileSystem.fileMetadata(reopened)))
        let link = physical.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: physical)
        XCTAssertThrowsError(try SandboxAuthorityFileSystem.openPrivateDirectory(
            at: link.appendingPathComponent("child"), createIfMissing: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: physical.appendingPathComponent("child").path))
    }
}
