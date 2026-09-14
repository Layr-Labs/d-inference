import Darwin
import Foundation
@testable import HostRuntimeCoordination
import XCTest

final class HostRuntimeMaintenanceTests: XCTestCase {
    func testAlternateAuthorityCannotBeUsedForPrivilegedBaseOperations() throws {
        let f = try HostRuntimeTestFixture(); defer { f.remove() }
        let lease = try f.authority.acquireSandbox()
        try lease.validateExclusive()
        XCTAssertThrowsError(try lease.validateSystemExclusive()) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .insecureAuthority)
        }
    }

    private func intent() throws -> HostRuntimeMaintenanceIntent {
        try .init(operationID: UUID(), journalSHA256: String(repeating: "a", count: 64))
    }

    func testFencePersistsAfterScopeReleaseAndExactRootRecoveryClearsIt() throws {
        let f = try HostRuntimeTestFixture(); defer { f.remove() }
        let intent = try intent()
        var original = stat(); XCTAssertEqual(lstat(f.lock.path, &original), 0)
        do {
            let lease = try f.authority.acquireSandbox()
            let scope = try lease.beginRootMaintenance(intent)
            try scope.validate()
            try lease.validateExclusive()
            assertAdmissionFenced(f)
            XCTAssertThrowsError(try lease.beginRootMaintenance(intent))
        }
        assertAdmissionFenced(f)
        do {
            let recovered = try f.authority.recoverRootMaintenance(intent)
            try recovered.validate()
            try recovered.finishAfterVerifiedCleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.maintenance.path))
            XCTAssertThrowsError(try recovered.validate()) {
                XCTAssertEqual($0 as? HostRuntimeOwnershipError, .maintenanceFinished)
            }
            XCTAssertThrowsError(try f.authority.acquireInferenceIfInstalled()) {
                XCTAssertEqual($0 as? HostRuntimeOwnershipError, .occupied)
            }
        }
        let inference = try XCTUnwrap(f.authority.acquireInferenceIfInstalled())
        try inference.validate()
        var current = stat(); XCTAssertEqual(lstat(f.lock.path, &current), 0)
        XCTAssertEqual(current.st_ino, original.st_ino)
        XCTAssertEqual(current.st_size, 0)
    }

    func testAbruptProcessExitReleasesKernelLockButKeepsAdmissionFenced() throws {
        let f = try HostRuntimeTestFixture(); defer { f.remove() }
        let intent = try intent()
        let child = try HostRuntimeTestProbe(fixture: f, role: "maintenance", intent: intent)
        defer { child.finish() }
        XCTAssertEqual(child.readiness, "acquired\n")
        let live = open(f.lock.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(live, 0)
        if live >= 0 {
            XCTAssertNotEqual(flock(live, LOCK_EX | LOCK_NB), 0, "the live child must still hold EX")
            close(live)
        }
        child.finish()
        XCTAssertEqual(child.process.terminationStatus, 86)
        let direct = open(f.lock.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(direct, 0)
        if direct >= 0 {
            XCTAssertEqual(flock(direct, LOCK_EX | LOCK_NB), 0, "the dead child's kernel lock should be gone")
            close(direct)
        }
        assertAdmissionFenced(f)
        let scope = try f.authority.recoverRootMaintenance(intent)
        try scope.validate()
    }

    func testWrongOperationOrJournalCannotRecoverOrRemoveFence() throws {
        let f = try HostRuntimeTestFixture(); defer { f.remove() }
        let correct = try intent()
        do { _ = try f.authority.acquireSandbox().beginRootMaintenance(correct) }
        let original = try Data(contentsOf: f.maintenance)
        for wrong in [try intent(), try .init(operationID: correct.operationID, journalSHA256: String(repeating: "b", count: 64))] {
            XCTAssertThrowsError(try f.authority.recoverRootMaintenance(wrong)) {
                XCTAssertEqual($0 as? HostRuntimeOwnershipError, .maintenanceChanged)
            }
            XCTAssertEqual(try Data(contentsOf: f.maintenance), original)
            assertAdmissionFenced(f)
        }
        let recovered = try f.authority.recoverRootMaintenance(correct)
        try recovered.validate()
    }

    func testMalformedSpecialAndSharedRecordsRemainFencedWithoutBlockingReads() throws {
        for mutation in ["empty", "json", "fifo", "symlink", "hardlink", "shared", "directory"] {
            let f = try HostRuntimeTestFixture(); defer { f.remove() }
            let intent = try intent()
            switch mutation {
            case "fifo": XCTAssertEqual(mkfifo(f.maintenance.path, 0o600), 0)
            case "directory": try FileManager.default.createDirectory(at: f.maintenance, withIntermediateDirectories: false)
            case "symlink": try FileManager.default.createSymbolicLink(at: f.maintenance, withDestinationURL: f.lock)
            default:
                let data = mutation == "empty" ? Data() : mutation == "json" ? Data("{".utf8) : try intent.encoded()
                try data.write(to: f.maintenance)
                XCTAssertEqual(chmod(f.maintenance.path, mutation == "shared" ? 0o644 : 0o600), 0)
                if mutation == "hardlink" { try FileManager.default.linkItem(at: f.maintenance, to: f.directory.appendingPathComponent("alias")) }
            }
            assertAdmissionFenced(f)
            XCTAssertThrowsError(try f.authority.recoverRootMaintenance(intent), mutation)
            var info = stat(); XCTAssertEqual(lstat(f.maintenance.path, &info), 0)
        }
    }

    func testLiveScopeRejectsReplacementEvenWithIdenticalIntentBytes() throws {
        let f = try HostRuntimeTestFixture(); defer { f.remove() }
        let scope = try f.authority.acquireSandbox().beginRootMaintenance(intent())
        let old = f.directory.appendingPathComponent("old-maintenance.json")
        try FileManager.default.moveItem(at: f.maintenance, to: old)
        try Data(contentsOf: old).write(to: f.maintenance)
        XCTAssertEqual(chmod(f.maintenance.path, 0o600), 0)
        XCTAssertThrowsError(try scope.validate())
        XCTAssertThrowsError(try scope.finishAfterVerifiedCleanup())
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.maintenance.path))
    }

    func testReplacedAuthorityDirectoryCannotRemoveAReplacementFence() throws {
        let f = try HostRuntimeTestFixture(); defer { f.remove() }
        let expected = try intent()
        let scope = try f.authority.acquireSandbox().beginRootMaintenance(expected)
        try FileManager.default.moveItem(at: f.directory, to: f.root.appendingPathComponent("old-authority"))
        try f.createAuthority()
        try expected.encoded().write(to: f.maintenance); XCTAssertEqual(chmod(f.maintenance.path, 0o600), 0)
        XCTAssertThrowsError(try scope.finishAfterVerifiedCleanup())
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.maintenance.path))
    }

    func testSharedLeaseCannotBeginMaintenance() throws {
        let f = try HostRuntimeTestFixture(); defer { f.remove() }
        let shared = try XCTUnwrap(f.authority.acquireInferenceIfInstalled())
        XCTAssertThrowsError(try shared.beginRootMaintenance(intent())) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .insecureAuthority)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.maintenance.path))
    }

    func testProductionRecoveryRequiresRootBeforeAccessingAuthority() throws {
        guard geteuid() != 0 else { throw XCTSkip("requires an unprivileged test process") }
        let f = try HostRuntimeTestFixture(); defer { f.remove() }
        XCTAssertThrowsError(try HostRuntimeAuthority(directory: f.directory).recoverRootMaintenance(intent())) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .rootMaintenanceRequired)
        }
    }

    func testInvalidOrDecodedUnknownIntentCannotPublishAFence() throws {
        let f = try HostRuntimeTestFixture(); defer { f.remove() }
        let lease = try f.authority.acquireSandbox()
        XCTAssertThrowsError(try HostRuntimeMaintenanceIntent(operationID: UUID(), journalSHA256: "bad"))
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: intent().encoded()) as? [String: Any])
        value["schemaVersion"] = 2
        let unknown = try JSONDecoder().decode(HostRuntimeMaintenanceIntent.self,
            from: JSONSerialization.data(withJSONObject: value))
        XCTAssertThrowsError(try lease.beginRootMaintenance(unknown))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.maintenance.path))
    }

    private func assertAdmissionFenced(_ f: HostRuntimeTestFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try f.authority.acquireSandbox(), file: file, line: line) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .maintenancePending, file: file, line: line)
        }
        XCTAssertThrowsError(try f.authority.acquireInferenceIfInstalled(), file: file, line: line) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .maintenancePending, file: file, line: line)
        }
    }
}
