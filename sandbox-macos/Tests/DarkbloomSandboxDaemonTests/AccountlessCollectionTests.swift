import Darwin
import Foundation
import SandboxRuntime
import SandboxRuntimeLume
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessCollectionTests: XCTestCase {
    func testCollectsBeforeRemovalPreservesInstalledPayloadAndRequiresDetachForPublication() async throws {
        let f = try await fixture(), journal = try f.journal()
        try f.collector(journal).collect(dataDirectory: f.data, volumeUUID: f.volumeUUID)
        XCTAssertTrue(try journal.removed())
        XCTAssertEqual(try journal.resultData(), f.resultData)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("installer.log")), Data())
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.overlay.stageDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.overlay.job.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.data.appendingPathComponent("usr/local/libexec/darkbloom-sandbox-guest").path))
        XCTAssertEqual(try Data(contentsOf: f.data.appendingPathComponent("Library/preserve.txt")), Data("unrelated guest file".utf8))
        XCTAssertThrowsError(try AccountlessCollectionRecord.make(journal: journal))
        try journal.recordDetached(f.boot.staging.cleanup, aborted: false)
        let record = try AccountlessCollectionRecord.make(journal: journal)
        try record.validate(permit: f.boot.permit)
        XCTAssertTrue(record.installation.installationComplete)
        XCTAssertTrue(record.cleanup.temporaryPayloadRemoved && record.cleanup.temporaryJobRemoved)
        XCTAssertThrowsError(try journal.requireActive())
    }

    func testInterruptedRemovalResumesAfterReceiptItselfWasRemoved() async throws {
        let f = try await fixture()
        do {
            let journal = try f.journal()
            XCTAssertThrowsError(try f.collector(journal, didRemove: { path in
                if path.hasSuffix("/result/receipt.json") { throw POSIXError(.EINTR) }
            }).collect(dataDirectory: f.data, volumeUUID: f.volumeUUID))
            XCTAssertNotNil(try journal.removalPlan()); XCTAssertFalse(try journal.removed())
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.overlay.stageDirectory.appendingPathComponent("result/receipt.json").path))
        let journal = try f.journal()
        try f.collector(journal).collect(dataDirectory: f.data, volumeUUID: f.volumeUUID)
        XCTAssertTrue(try journal.removed()); XCTAssertEqual(try journal.resultData(), f.resultData)
    }

    func testIncompleteReceiptAndUnexpectedFilesNeverAuthorizeDeletion() async throws {
        for extraFile in [false, true] {
            let f = try await fixture(), journal = try f.journal()
            if extraFile {
                try AccountlessCollectionTestFixture.write(Data("preserve".utf8), to: f.overlay.stageDirectory.appendingPathComponent("foreign"), mode: 0o600)
            } else {
                try AccountlessCollectionTestFixture.write(Data("{}".utf8), to: f.overlay.stageDirectory.appendingPathComponent("result/receipt.json"), mode: 0o600)
            }
            XCTAssertThrowsError(try f.collector(journal).collect(dataDirectory: f.data, volumeUUID: f.volumeUUID))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.overlay.job.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.overlay.stageDirectory.appendingPathComponent("first-boot.zsh").path))
            XCTAssertNil(try journal.removalPlan())
        }
    }

    func testChangedTemporaryFileAfterInterruptedRemovalIsPreserved() async throws {
        let f = try await fixture()
        do {
            let journal = try f.journal()
            XCTAssertThrowsError(try f.collector(journal, didRemove: { _ in throw POSIXError(.EINTR) }).collect(dataDirectory: f.data, volumeUUID: f.volumeUUID))
            XCTAssertNotNil(try journal.removalPlan())
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.overlay.job.path))
        }
        let path = f.overlay.stageDirectory.appendingPathComponent("first-boot.zsh")
        XCTAssertEqual(chmod(path.path, 0o600), 0)
        try Data("changed\n".utf8).write(to: path)
        XCTAssertEqual(chmod(path.path, 0o500), 0)
        let journal = try f.journal()
        XCTAssertThrowsError(try f.collector(journal).collect(dataDirectory: f.data, volumeUUID: f.volumeUUID))
        XCTAssertEqual(try Data(contentsOf: path), Data("changed\n".utf8))
        XCTAssertFalse(try journal.removed())
    }

    func testInstalledPayloadMismatchPreventsReceiptAcceptanceAndDeletion() async throws {
        let f = try await fixture(), journal = try f.journal()
        let path = f.data.appendingPathComponent("usr/local/libexec/darkbloom-sandbox-guest")
        try Data("other binary".utf8).write(to: path)
        XCTAssertThrowsError(try f.collector(journal).collect(dataDirectory: f.data, volumeUUID: f.volumeUUID))
        XCTAssertNil(try journal.resultData())
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.overlay.job.path))
    }

    func testRemovalSurvivesAttachmentDeviceRenumberingButRejectsAnotherVolume() async throws {
        let f = try await fixture(), journal = try f.journal()
        let root = try AccountlessOfflineDirectory(path: f.data)
        let captured = try AccountlessCollectionRemovalPlan.capture(data: root, boot: f.boot, volumeUUID: f.volumeUUID)
        // Model a previous attachment with a different st_dev; APFS inode and
        // timestamps stay the same. Cross-mount IO remains checked by root.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(captured)) as? [String: Any])
        var files = try XCTUnwrap(object["files"] as? [String: [String: Any]])
        for key in files.keys {
            var identity = try XCTUnwrap(files[key]?["identity"] as? [String: Any])
            identity["device"] = captured.files[key]!.identity.device + 1
            files[key]?["identity"] = identity
        }
        var directories = try XCTUnwrap(object["directories"] as? [String: [String: Any]])
        for key in directories.keys { directories[key]?["device"] = captured.directories[key]!.device + 1 }
        object["files"] = files; object["directories"] = directories
        let plan = try JSONDecoder().decode(AccountlessCollectionRemovalPlan.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        try journal.recordResult(f.resultData, logs: ["installer.log": Data(), "helper.log": Data("identity verified\n".utf8)])
        try journal.recordRemovalPlan(plan)
        XCTAssertThrowsError(try f.collector(journal).collect(dataDirectory: f.data, volumeUUID: UUID()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.overlay.job.path))
        try f.collector(journal).collect(dataDirectory: f.data, volumeUUID: f.volumeUUID)
        XCTAssertTrue(try journal.removed())
    }

    func testReplacedOrLinkedDirectoryAfterInterruptedRemovalIsPreserved() async throws {
        for symlink in [false, true] {
            let f = try await fixture()
            do {
                let journal = try f.journal()
                XCTAssertThrowsError(try f.collector(journal, didRemove: { _ in throw POSIXError(.EINTR) })
                    .collect(dataDirectory: f.data, volumeUUID: f.volumeUUID))
                XCTAssertNotNil(try journal.removalPlan())
            }
            let original = f.overlay.stageDirectory.appendingPathComponent("result")
            let retained = f.overlay.stageDirectory.appendingPathComponent("retained-result")
            try FileManager.default.moveItem(at: original, to: retained)
            if symlink { try FileManager.default.createSymbolicLink(at: original, withDestinationURL: retained) }
            else {
                try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
            let journal = try f.journal()
            XCTAssertThrowsError(try f.collector(journal).collect(dataDirectory: f.data, volumeUUID: f.volumeUUID))
            XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("receipt.json")), f.resultData)
            XCTAssertFalse(try journal.removed())
        }
    }

    func testExplicitAbortClosesTransactionWithoutProducingInstallationEvidence() async throws {
        let f = try await fixture(), journal = try f.journal()
        try journal.recordDetached(f.boot.staging.cleanup, aborted: true)
        XCTAssertTrue(try XCTUnwrap(journal.completion()).aborted)
        XCTAssertThrowsError(try AccountlessCollectionRecord.make(journal: journal))
        XCTAssertThrowsError(try journal.requireActive())
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.overlay.job.path))
    }

    private func fixture() async throws -> AccountlessCollectionTestFixture {
        let value = try await AccountlessCollectionTestFixture(); addTeardownBlock { value.remove() }; return value
    }
}
