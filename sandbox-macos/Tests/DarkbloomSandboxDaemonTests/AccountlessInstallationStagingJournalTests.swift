import Darwin
import Foundation
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessInstallationStagingJournalTests: XCTestCase {
    func testDurableIntentAndExclusiveLockRemainBoundAcrossReopen() async throws {
        let f = try await fixture()
        let path = f.journalDirectory.appendingPathComponent("staging-intent.json")
        do {
            let journal = try f.journal()
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
            XCTAssertThrowsError(try f.journal()) { error in
                guard case AccountlessInstallationError.stagingInProgress = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
            try journal.requireStagingAllowed()
        }
        let before = try Data(contentsOf: path)
        let reopened = try f.journal()
        try reopened.requireStagingAllowed()
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.staged.path))
    }

    func testDifferentCandidateCannotReuseJournal() async throws {
        let f = try await fixture(), other = try await fixture()
        do { let journal = try f.journal(); try journal.requireStagingAllowed() }
        let path = f.journalDirectory.appendingPathComponent("staging-intent.json")
        let before = try Data(contentsOf: path)
        XCTAssertThrowsError(try AccountlessInstallationStagingJournal(directory: f.journalDirectory,
            candidate: other.installation.candidate, plan: other.plan))
        XCTAssertEqual(try Data(contentsOf: path), before)
    }

    func testUnknownOrRedirectedPayloadPathsAreRejectedBeforeJournalCreation() async throws {
        let f = try await fixture()
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.plan)) as! [String: Any]
        for key in ["guestStagePath", "guestLaunchDaemonPath", "guestReceiptPath", "maximumBootSeconds", "files"] {
            var value = original
            if key == "files" {
                var files = f.plan.files
                files["Library/LaunchDaemons/another.plist"] = String(repeating: "a", count: 64)
                value[key] = files
            } else if key == "maximumBootSeconds" { value[key] = 301 }
            else { value[key] = "/Library/LaunchDaemons/another.plist" }
            let plan = try JSONDecoder().decode(AccountlessInstallationPayloadPlan.self,
                from: JSONSerialization.data(withJSONObject: value))
            XCTAssertThrowsError(try AccountlessInstallationStagingJournal(directory: f.journalDirectory,
                candidate: f.installation.candidate, plan: plan), key)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.journalDirectory.path), [])
    }

    func testOrphanedOrCorruptStagedReceiptDoesNotCreateOrRepairIntent() async throws {
        let f = try await fixture()
        try f.stage()
        let intent = f.journalDirectory.appendingPathComponent("staging-intent.json")
        let original = try Data(contentsOf: intent)
        try FileManager.default.removeItem(at: intent)
        XCTAssertThrowsError(try f.journal())
        XCTAssertFalse(FileManager.default.fileExists(atPath: intent.path))
        try original.write(to: intent); XCTAssertEqual(chmod(intent.path, 0o600), 0)
        try Data("changed".utf8).write(to: f.staged)
        XCTAssertThrowsError(try f.journal())
        XCTAssertEqual(try String(contentsOf: f.staged, encoding: .utf8), "changed")
    }

    func testSpecialSharedOrLinkedIntentIsRejectedWithoutBlocking() async throws {
        for kind in ["fifo", "shared", "link"] {
            let f = try await fixture()
            let intent = f.journalDirectory.appendingPathComponent("staging-intent.json")
            if kind == "fifo" { XCTAssertEqual(mkfifo(intent.path, 0o600), 0) }
            else {
                do { let journal = try f.journal(); try journal.requireStagingAllowed() }
                if kind == "shared" { XCTAssertEqual(chmod(intent.path, 0o644), 0) }
                else { try FileManager.default.linkItem(at: intent, to: f.journalDirectory.appendingPathComponent("alias")) }
            }
            XCTAssertThrowsError(try f.journal(), kind)
        }
    }

    func testReplacedLockOrDirectoryInvalidatesLiveJournal() async throws {
        for replaceDirectory in [false, true] {
            let f = try await fixture()
            let journal = try f.journal()
            let target = replaceDirectory ? f.journalDirectory : f.journalDirectory.appendingPathComponent("staging.lock")
            try FileManager.default.moveItem(at: target, to: target.appendingPathExtension("old"))
            if replaceDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            } else {
                try Data().write(to: target)
                XCTAssertEqual(chmod(target.path, 0o600), 0)
            }
            XCTAssertThrowsError(try journal.requireStagingAllowed())
            XCTAssertThrowsError(try journal.recordStaged())
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.staged.path))
        }
    }

    private func fixture() async throws -> AccountlessOfflineOverlayTestFixture {
        let f = try await AccountlessOfflineOverlayTestFixture()
        addTeardownBlock { f.remove() }; return f
    }
}
