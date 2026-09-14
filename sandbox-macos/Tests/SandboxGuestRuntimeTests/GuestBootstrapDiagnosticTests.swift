import Darwin
import Foundation
import SandboxRuntime
import SandboxGuestProtocol
@testable import SandboxGuestRuntime
import XCTest

final class GuestBootstrapDiagnosticTests: XCTestCase {
    func testAsyncCleanupDiagnosticsKeepTheirFixedStageWithoutUnderlyingContents() async throws {
        for stage in [GuestBootstrapDiagnostic.Stage.guestPolicy, .tenantDomainRemoval, .tenantCleanupWorker,
                      .tenantProcessInventory, .tenantDomainVerification] {
            do {
                let _: Void = try await GuestBootstrapDiagnostic.runAsync(stage) {
                    throw NSError(domain: "private-configuration", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "secret=not-for-logs"])
                }
                XCTFail("expected diagnostic")
            } catch {
                XCTAssertEqual((error as? GuestBootstrapDiagnostic)?.code, "guest_bootstrap.\(stage.rawValue).unavailable")
            }
        }
        let observed = try await GuestBootstrapDiagnostic.runAsync(.tenantCleanupWorker) { 42 }
        XCTAssertEqual(observed, 42)
    }

    func testNestedCleanupFailureRetainsTheMoreSpecificStage() async {
        do {
            let _: Void = try await GuestBootstrapDiagnostic.runAsync(.guestPolicy) {
                try GuestBootstrapDiagnostic.run(.tenantDomainVerification) { throw GuestProtocolError.cleanupUncertain }
            }
            XCTFail("expected diagnostic")
        } catch {
            XCTAssertEqual((error as? GuestBootstrapDiagnostic)?.code,
                           "guest_bootstrap.tenant_domain_verification.policy_mismatch")
        }
    }

    func testBootstrapDiagnosticNamesFixedStageAndBoundedSystemError() throws {
        XCTAssertThrowsError(try GuestBootstrapDiagnostic.run(.workspaceMountpoint) {
            throw SandboxAuthorityFileSystemError.unsafePath
        }) { error in
            XCTAssertEqual((error as? GuestBootstrapDiagnostic)?.code,
                           "guest_bootstrap.workspace_mountpoint.unsafe_authority")
        }
        XCTAssertThrowsError(try GuestBootstrapDiagnostic.run(.numericIdentity) {
            throw GuestNumericIdentityError.lookupFailed(EACCES)
        }) { error in
            XCTAssertEqual((error as? GuestBootstrapDiagnostic)?.code,
                           "guest_bootstrap.numeric_identity.lookup_failed errno=13")
        }
    }

    func testArbitraryUnderlyingErrorContentsAreNeverFormatted() {
        do {
            let _: Void = try GuestBootstrapDiagnostic.run(.numericIdentity) {
                throw NSError(domain: "credential=private", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "instance.json contains secret bytes"])
            }
            XCTFail("expected a diagnostic")
        } catch {
            XCTAssertEqual((error as? GuestBootstrapDiagnostic)?.code,
                           "guest_bootstrap.numeric_identity.unavailable")
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
