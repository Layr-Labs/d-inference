import Darwin
import Foundation
import SandboxRuntime
@testable import SandboxGuestRuntime
import XCTest

final class GuestSchedulerPolicyTests: XCTestCase {
    func testDaemonOwnedSystemSpoolCanBeInspectedWithoutChangingIt() throws {
        let path = URL(fileURLWithPath: "/private/var/at")
        var before = stat(), after = stat()
        XCTAssertEqual(lstat(path.path, &before), 0)
        let descriptor = try GuestSchedulerFiles.openInitialDirectory(at: path, ownerUID: 0, initialOwnerUID: 1)
        defer { close(descriptor) }
        XCTAssertEqual(lstat(path.path, &after), 0)
        let opened = try SandboxAuthorityFileSystem.fileMetadata(descriptor)
        XCTAssertTrue(SandboxAuthorityFileSystem.sameIdentity(before, opened))
        XCTAssertEqual(before.st_uid, after.st_uid)
        XCTAssertEqual(before.st_mode, after.st_mode)
    }

    func testInitialOwnerExceptionIsLeafScopedAndCannotFollowSymlinks() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o750])
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        XCTAssertThrowsError(try GuestSchedulerFiles.provision(in: alias, ownerUID: geteuid(), initialOwnerUID: geteuid()))
        var metadata = stat()
        XCTAssertEqual(lstat(target.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o750)
        if geteuid() != 0 && geteuid() != 1 {
            XCTAssertThrowsError(try GuestSchedulerFiles.openInitialDirectory(at: target, ownerUID: 0, initialOwnerUID: 1))
        }
    }

    func testMissingEnabledAmbiguousAndLookalikeServiceOverridesAreRejected() {
        let valid = "\t\"com.vix.cron\" => disabled\n\t\"com.apple.atrun\" => disabled\n"
        XCTAssertTrue(GuestSchedulerPolicy.explicitlyDisabled(valid))
        XCTAssertTrue(GuestSchedulerPolicy.explicitlyDisabled(valid.replacingOccurrences(of: "disabled", with: "true")))
        for invalid in ["", valid.replacingOccurrences(of: "cron", with: "cron.other"),
                        valid.replacingOccurrences(of: "disabled", with: "enabled"),
                        valid + "\"com.vix.cron\" => disabled\n"] {
            XCTAssertFalse(GuestSchedulerPolicy.explicitlyDisabled(invalid))
        }
    }

    func testAbsenceRequiresExactDomainIdentityAndErrorNotPermissionFailure() {
        let domain = "gui/2001"
        let error = "Bad request.\nCould not find domain for user gui: 2001\n"
        XCTAssertTrue(GuestTenantDomains.absent(result(112, error), domain: domain))
        XCTAssertFalse(GuestTenantDomains.absent(result(1, "Could not print domain: 1: Operation not permitted\n"), domain: domain))
        XCTAssertFalse(GuestTenantDomains.absent(result(112, error), domain: "user/2001"))
        XCTAssertFalse(GuestTenantDomains.absent(result(112, error, truncated: true), domain: domain))
        XCTAssertFalse(GuestTenantDomains.absent(result(0, error), domain: domain))
        let serviceError = "Could not find service \"com.vix.cron\" in domain for system\n"
        XCTAssertTrue(GuestSchedulerPolicy.serviceAbsent(result(113, serviceError), label: "com.vix.cron"))
        XCTAssertFalse(GuestSchedulerPolicy.serviceAbsent(result(1, serviceError), label: "com.vix.cron"))
        XCTAssertFalse(GuestSchedulerPolicy.serviceAbsent(result(113, serviceError), label: "com.apple.atrun"))
    }

    func testRootOnlyAllowlistIsCreatedAndUnknownPolicyRetained() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try GuestSchedulerFiles.validate(in: root, ownerUID: geteuid()))
        try GuestSchedulerFiles.provision(in: root, ownerUID: geteuid(), initialOwnerUID: geteuid())
        try GuestSchedulerFiles.validate(in: root, ownerUID: geteuid())
        for name in ["cron.allow", "at.allow"] {
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8), "root\n")
        }
        let modified = root.appendingPathComponent("cron.allow")
        try Data("darkbloomtenant\n".utf8).write(to: modified)
        XCTAssertThrowsError(try GuestSchedulerFiles.provision(in: root, ownerUID: geteuid(), initialOwnerUID: geteuid()))
        XCTAssertEqual(try String(contentsOf: modified, encoding: .utf8), "darkbloomtenant\n")
    }

    func testSymlinkAndWritablePolicyAreRejectedWithoutChangingTargets() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try Data("untouched\n".utf8).write(to: outside)
        let policy = root.appendingPathComponent("cron.allow")
        try FileManager.default.createSymbolicLink(at: policy, withDestinationURL: outside)
        XCTAssertThrowsError(try GuestSchedulerFiles.provision(in: root, ownerUID: geteuid(), initialOwnerUID: geteuid()))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched\n")
        try FileManager.default.removeItem(at: policy)
        try GuestSchedulerFiles.provision(in: root, ownerUID: geteuid(), initialOwnerUID: geteuid())
        XCTAssertEqual(chmod(policy.path, 0o666), 0)
        XCTAssertThrowsError(try GuestSchedulerFiles.validate(in: root, ownerUID: geteuid()))
    }

    private func result(_ code: Int32, _ error: String, truncated: Bool = false) -> SandboxProcessResult {
        SandboxProcessResult(exitCode: code, standardOutput: Data(), standardError: Data(error.utf8),
            standardOutputTruncated: false, standardErrorTruncated: truncated)
    }

    private func fixture() throws -> URL {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("scheduler-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return directory
    }
}
