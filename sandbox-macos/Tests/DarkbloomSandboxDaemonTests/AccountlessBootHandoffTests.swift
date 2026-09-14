import Darwin
import Foundation
import SandboxRuntimeLume
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessBootHandoffTests: XCTestCase {
    func testHandoffClosesStagingPermanentlyAndReplaysOnlyExactPermit() async throws {
        let f = try await fixture()
        let snapshot: AccountlessStagingSnapshot
        do {
            let transition = try AccountlessStagingTransition(directory: f.journalDirectory)
            snapshot = try transition.snapshot()
            XCTAssertFalse(try transition.isClosed(for: snapshot, permitSHA256: digest("a")))
            try transition.close(for: snapshot, permitSHA256: digest("a"))
            try transition.close(for: snapshot, permitSHA256: digest("a"))
            XCTAssertTrue(try transition.isClosed(for: snapshot, permitSHA256: digest("a")))
            XCTAssertThrowsError(try transition.close(for: snapshot, permitSHA256: digest("b")))
        }
        XCTAssertThrowsError(try f.journal(), "a closed staging owner must not reopen")
        let reopened = try AccountlessStagingTransition(directory: f.journalDirectory)
        XCTAssertEqual(try reopened.snapshot(), snapshot)
        XCTAssertTrue(try reopened.isClosed(for: snapshot, permitSHA256: digest("a")))
    }

    func testIncompleteStagingCannotPublishBootIntent() async throws {
        let f = try await AccountlessOfflineOverlayTestFixture(); addTeardownBlock { f.remove() }
        do { _ = try f.journal() }
        let transition = try AccountlessStagingTransition(directory: f.journalDirectory)
        XCTAssertThrowsError(try transition.snapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journalDirectory.appendingPathComponent("boot-intent.json").path))
    }

    func testBootJournalBeforeHandoffCanResumeWithoutRepeatingStaging() async throws {
        let f = try await fixture(), boot = try bootDirectory(f)
        let snapshot: AccountlessStagingSnapshot
        do { snapshot = try AccountlessStagingTransition(directory: f.journalDirectory).snapshot() }
        let permit = try permit(snapshot), hash = BaseGuestRelease.digest(try permit.encoded())
        do { try AccountlessBootJournal(directory: boot).record(permit, staging: snapshot) }
        let original = try Data(contentsOf: boot.appendingPathComponent("boot-intent.json"))
        do {
            let staging = try f.journal()
            XCTAssertThrowsError(try staging.requireStagingAllowed(), "detach already forbids repeat IO")
        }
        do {
            let journal = try AccountlessBootJournal(directory: boot)
            try journal.record(permit, staging: snapshot)
            let transition = try AccountlessStagingTransition(directory: f.journalDirectory)
            try transition.close(for: snapshot, permitSHA256: hash)
        }
        XCTAssertEqual(try Data(contentsOf: boot.appendingPathComponent("boot-intent.json")), original)
        XCTAssertThrowsError(try f.journal())
    }

    func testCorruptOrReplacedCompletedRecordsCannotAdvance() async throws {
        for name in ["staged.json", "staging-detached.json", "boot-intent.json"] {
            let f = try await fixture()
            let path = f.journalDirectory.appendingPathComponent(name)
            try Data("{}".utf8).write(to: path); XCTAssertEqual(chmod(path.path, 0o600), 0)
            let transition = try AccountlessStagingTransition(directory: f.journalDirectory)
            if name == "boot-intent.json" {
                let snapshot = try transition.snapshot()
                XCTAssertThrowsError(try transition.close(for: snapshot, permitSHA256: digest("a")))
            } else { XCTAssertThrowsError(try transition.snapshot()) }
            XCTAssertEqual(try Data(contentsOf: path), Data("{}".utf8))
        }
    }

    func testPermitRejectsUnexpectedFieldsChangedIdentityAndOversizedInput() async throws {
        let f = try await fixture()
        let snapshot = try AccountlessStagingTransition(directory: f.journalDirectory).snapshot()
        let permit = try permit(snapshot), encoded = try permit.encoded()
        XCTAssertEqual(try AccountlessBootPermit.decode(encoded), permit)
        XCTAssertEqual(try permit.request().permitSHA256, BaseGuestRelease.digest(encoded))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root["unexpected"] = true
        XCTAssertThrowsError(try AccountlessBootPermit.decode(JSONSerialization.data(withJSONObject: root)))
        let duplicate = Data("{\"schemaVersion\":1,".utf8) + encoded.dropFirst()
        XCTAssertThrowsError(try AccountlessBootPermit.decode(duplicate))
        root.removeValue(forKey: "unexpected")
        root["maximumBootSeconds"] = 301
        XCTAssertThrowsError(try AccountlessBootPermit.decode(JSONSerialization.data(withJSONObject: root)))
        root["maximumBootSeconds"] = 300
        var user = try XCTUnwrap(root["hostUser"] as? [String: Any]); user["uid"] = 2001; root["hostUser"] = user
        XCTAssertThrowsError(try AccountlessBootPermit.decode(JSONSerialization.data(withJSONObject: root)))
        XCTAssertThrowsError(try AccountlessBootPermit.decode(Data(repeating: 32, count: 40 * 1024)))
    }

    func testPermitPublisherRequiresRootBeforeCreatingAnyFile() throws {
        guard geteuid() != 0 else { throw XCTSkip("requires an ordinary process") }
        XCTAssertThrowsError(try AccountlessBootPermitFile(path: URL(fileURLWithPath: "/not-created/permit.json")))
    }

    func testNewPermitPathRequiresOnlyItsParentToExistAndRejectsTraversal() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("new-permit.json")
        let resolved = try AccountlessBootPermitFile.creationPath(path)
        XCTAssertEqual(resolved.lastPathComponent, "new-permit.json")
        var expectedParent = stat(), actualParent = stat()
        XCTAssertEqual(lstat(root.path, &expectedParent), 0)
        XCTAssertEqual(lstat(resolved.deletingLastPathComponent().path, &actualParent), 0)
        XCTAssertEqual(actualParent.st_dev, expectedParent.st_dev)
        XCTAssertEqual(actualParent.st_ino, expectedParent.st_ino)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertThrowsError(try AccountlessBootPermitFile.creationPath(root.appendingPathComponent("missing/permit.json")))
        XCTAssertThrowsError(try AccountlessBootPermitFile.creationPath(URL(fileURLWithPath: root.path + "/../permit.json")))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(try AccountlessBootPermitFile.creationPath(alias.appendingPathComponent("permit.json")))
    }

    private func fixture() async throws -> AccountlessOfflineOverlayTestFixture {
        let f = try await AccountlessOfflineOverlayTestFixture(); addTeardownBlock { f.remove() }
        try f.stage()
        let object: [String: Any] = ["schemaVersion": 1, "imageFenceSHA256": digest("a"),
            "disk": try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.installation.candidate.disk))]
        let cleanup = try JSONDecoder().decode(LumeImageMaintenanceCleanup.self, from: JSONSerialization.data(withJSONObject: object))
        do { try f.journal().recordDetached(cleanup) }
        return f
    }
    private func bootDirectory(_ f: AccountlessOfflineOverlayTestFixture) throws -> URL {
        let path = f.journalDirectory.deletingLastPathComponent().appendingPathComponent("boot-journal")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return path
    }
    private func permit(_ snapshot: AccountlessStagingSnapshot) throws -> AccountlessBootPermit {
        try .init(schemaVersion: 1, hostID: UUID(), hostUser: .init(recordName: "operator", uid: 501, primaryGID: 20,
            generatedUID: UUID().uuidString, homeDirectory: "/Users/operator"), hostIdentityFile: "/Library/Darkbloom/host.json",
            storage: "/Volumes/Sandbox/vms", runtime: "/Library/Darkbloom/runtime/lume", runtimeSHA256: digest("b"),
            reservationData: AccountlessJournalJSON.encode(snapshot.candidate), stagedDisk: snapshot.cleanup.disk,
            stagingSnapshotSHA256: BaseGuestRelease.digest(AccountlessJournalJSON.encode(snapshot)), maximumBootSeconds: 300)
    }
    private func digest(_ character: Character) -> String { String(repeating: String(character), count: 64) }
}
