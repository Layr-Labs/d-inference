import Foundation
import SandboxRuntime
import XCTest

final class SandboxAuthorityFileSystemTests: XCTestCase {
    func testCanonicalPathAcceptsTemporaryAliasAndPrivateCanonicalPath() throws {
        let name = "darkbloom-authority-\(UUID().uuidString)"
        let aliasPath = "/tmp/\(name)"
        let canonicalPath = "/private\(aliasPath)"
        try FileManager.default.createDirectory(
            atPath: aliasPath,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(atPath: aliasPath) }

        XCTAssertEqual(
            SandboxAuthorityFileSystem.canonicalPath(
                for: URL(fileURLWithPath: aliasPath, isDirectory: true)
            ),
            canonicalPath
        )
        XCTAssertEqual(
            SandboxAuthorityFileSystem.canonicalPath(
                for: URL(fileURLWithPath: canonicalPath, isDirectory: true)
            ),
            canonicalPath
        )
    }

    func testCanonicalPathRejectsNonSystemSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-authority-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        let target = root.appendingPathComponent("target", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: target
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(SandboxAuthorityFileSystem.canonicalPath(for: alias))
    }
}
