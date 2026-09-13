import Darwin
import Foundation
import SandboxRuntime
@testable import SandboxGuestRuntime
import XCTest

final class GuestBootstrapDiagnosticTests: XCTestCase {
    func testBootstrapDiagnosticNamesFixedStageAndBoundedSystemError() throws {
        XCTAssertThrowsError(try GuestBootstrapDiagnostic.run(.workspaceMountpoint) {
            throw SandboxAuthorityFileSystemError.unsafePath
        }) { error in
            XCTAssertEqual((error as? GuestBootstrapDiagnostic)?.code,
                           "guest_bootstrap.workspace_mountpoint.unsafe_authority")
        }
        XCTAssertThrowsError(try GuestBootstrapDiagnostic.run(.schedulerSpool) {
            throw SandboxAuthorityFileSystemError.io(EACCES)
        }) { error in
            XCTAssertEqual((error as? GuestBootstrapDiagnostic)?.code,
                           "guest_bootstrap.scheduler_spool.filesystem_io errno=13")
        }
    }

    func testArbitraryUnderlyingErrorContentsAreNeverFormatted() async {
        do {
            let _: Void = try await GuestBootstrapDiagnostic.runAsync(.schedulerValidation) {
                throw NSError(domain: "credential=private", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "instance.json contains secret bytes"])
            }
            XCTFail("expected a diagnostic")
        } catch {
            XCTAssertEqual((error as? GuestBootstrapDiagnostic)?.code,
                           "guest_bootstrap.scheduler_validation.unavailable")
        }
    }

    func testVarDatabaseAuthorityUsesPhysicalSpellingWithoutMutations() throws {
        XCTAssertEqual(try GuestConfiguration.canonicalRootAuthorityPath("/var/db"), "/private/var/db")
        XCTAssertEqual(try GuestConfiguration.canonicalRootAuthorityPath("/private/var/db"), "/private/var/db")
        let descriptor = try SandboxAuthorityFileSystem.openExistingDirectory(at: URL(fileURLWithPath: "/var/db"))
        defer { close(descriptor) }
        var expected = stat()
        XCTAssertEqual(stat("/private/var/db", &expected), 0)
        XCTAssertTrue(SandboxAuthorityFileSystem.sameIdentity(expected, try SandboxAuthorityFileSystem.fileMetadata(descriptor)))
    }

    func testGuestAuthorityDoesNotAcceptAnArbitrarySymlinkToEtc() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("guest-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("etc")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "/private/etc")
        XCTAssertThrowsError(try GuestConfiguration.canonicalRootAuthorityPath(alias.path))
    }
}
