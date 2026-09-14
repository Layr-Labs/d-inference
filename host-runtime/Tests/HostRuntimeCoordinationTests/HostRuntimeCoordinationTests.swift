import Darwin
import Foundation
@testable import HostRuntimeCoordination
import XCTest

final class HostRuntimeCoordinationTests: XCTestCase {
    func testLegacyInferenceDoesNotCreateAuthority() throws {
        let fixture = try HostRuntimeTestFixture(createAuthority: false)
        defer { fixture.remove() }
        XCTAssertNil(try fixture.authority.acquireInferenceIfInstalled())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        XCTAssertThrowsError(try fixture.authority.acquireSandbox()) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .authorityMissing)
        }
    }

    func testExistingDirectoryWithMissingLockFailsClosedForBothRoles() throws {
        let fixture = try HostRuntimeTestFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.lock)
        XCTAssertThrowsError(try fixture.authority.acquireInferenceIfInstalled())
        XCTAssertThrowsError(try fixture.authority.acquireSandbox())
    }

    func testSharedInferenceProcessesExcludeSandboxUntilBothExit() throws {
        let fixture = try HostRuntimeTestFixture()
        defer { fixture.remove() }
        let first = try HostRuntimeTestProbe(fixture: fixture, role: "inference")
        defer { first.finish() }
        let second = try HostRuntimeTestProbe(fixture: fixture, role: "inference")
        defer { second.finish() }
        XCTAssertEqual(first.readiness, "acquired\n")
        XCTAssertEqual(second.readiness, "acquired\n")
        XCTAssertThrowsError(try fixture.authority.acquireSandbox()) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .occupied)
        }
        first.finish()
        XCTAssertThrowsError(try fixture.authority.acquireSandbox())
        second.finish()
        let lease = try fixture.authority.acquireSandbox()
        try lease.validate()
        withExtendedLifetime(lease) {}
    }

    func testSandboxProcessExcludesInferenceAndReleasesOnExit() throws {
        let fixture = try HostRuntimeTestFixture()
        defer { fixture.remove() }
        let sandbox = try HostRuntimeTestProbe(fixture: fixture, role: "sandbox")
        defer { sandbox.finish() }
        XCTAssertEqual(sandbox.readiness, "acquired\n")
        XCTAssertThrowsError(try fixture.authority.acquireInferenceIfInstalled()) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .occupied)
        }
        sandbox.finish()
        let lease = try XCTUnwrap(fixture.authority.acquireInferenceIfInstalled())
        try lease.validate()
    }

    func testRejectsSymlinksHardlinksAndWritableAuthority() throws {
        for mutation in ["symlink", "hardlink", "directory-write", "lock-mode"] {
            let fixture = try HostRuntimeTestFixture()
            defer { fixture.remove() }
            switch mutation {
            case "symlink":
                let original = fixture.directory.appendingPathComponent("original.lock")
                try FileManager.default.moveItem(at: fixture.lock, to: original)
                try FileManager.default.createSymbolicLink(at: fixture.lock, withDestinationURL: original)
            case "hardlink":
                try FileManager.default.linkItem(at: fixture.lock, to: fixture.directory.appendingPathComponent("alias"))
            case "directory-write":
                try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: fixture.directory.path)
            default:
                try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: fixture.lock.path)
            }
            XCTAssertThrowsError(try fixture.authority.acquireSandbox(), mutation)
        }
    }

    func testHeldLeaseDetectsLockAndDirectoryReplacement() throws {
        for replaceDirectory in [false, true] {
            let fixture = try HostRuntimeTestFixture()
            defer { fixture.remove() }
            let lease = try fixture.authority.acquireSandbox()
            if replaceDirectory {
                try FileManager.default.moveItem(at: fixture.directory,
                                                  to: fixture.root.appendingPathComponent("old-authority"))
                try fixture.createAuthority()
            } else {
                try FileManager.default.moveItem(at: fixture.lock,
                                                  to: fixture.directory.appendingPathComponent("old.lock"))
                try fixture.createLock()
            }
            XCTAssertThrowsError(try lease.validate()) {
                XCTAssertEqual($0 as? HostRuntimeOwnershipError, .authorityChanged)
            }
        }
    }

    func testProductionPolicyRejectsUserOwnedAuthority() throws {
        let fixture = try HostRuntimeTestFixture()
        defer { fixture.remove() }
        guard geteuid() != 0 else { throw XCTSkip("requires non-root fixture owner") }
        let production = HostRuntimeAuthority(directory: fixture.directory)
        XCTAssertThrowsError(try production.acquireSandbox())
    }

    func testInheritedVMLeaseSurvivesParentReleaseUntilChildExit() throws {
        let fixture = try HostRuntimeTestFixture()
        defer { fixture.remove() }
        var parentLease: HostRuntimeLease? = try fixture.authority.acquireSandbox()
        let child = try XCTUnwrap(parentLease).withInheritedDescriptor { descriptor in
            XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
            return try HostRuntimeInheritedTestProbe(descriptor: descriptor)
        }
        defer { child.finish() }
        XCTAssertEqual(child.readiness, "acquired\n")
        parentLease = nil
        XCTAssertThrowsError(try fixture.authority.acquireInferenceIfInstalled()) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .occupied)
        }
        child.finish()
        let inference = try XCTUnwrap(fixture.authority.acquireInferenceIfInstalled())
        try inference.validate()
    }

    func testSharedInferenceLeaseCannotAuthorizeVMInstallation() throws {
        let fixture = try HostRuntimeTestFixture()
        defer { fixture.remove() }
        let shared = try XCTUnwrap(fixture.authority.acquireInferenceIfInstalled())
        XCTAssertNoThrow(try shared.validate())
        XCTAssertThrowsError(try shared.validateExclusive()) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .insecureAuthority)
        }
    }

}
