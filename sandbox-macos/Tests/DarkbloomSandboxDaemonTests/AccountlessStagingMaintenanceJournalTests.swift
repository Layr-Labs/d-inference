import Darwin
import Foundation
import SandboxRuntimeLume
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessStagingMaintenanceJournalTests: XCTestCase {
    func testExactJournalIntentSurvivesCompletionAndReopenWhileWritesStayClosed() async throws {
        let f = try await fixture()
        try f.stage()
        let cleanup = try cleanup(f)
        var digest: String?
        do {
            let journal = try f.journal()
            let intent = try journal.maintenanceIntent()
            digest = intent.journalSHA256
            XCTAssertEqual(intent.operationID, f.installation.candidate.bootstrapAttemptID)
            let actual = try Data(contentsOf: f.journalDirectory.appendingPathComponent("staging-intent.json"))
            XCTAssertEqual(intent.journalSHA256, BaseGuestRelease.digest(actual))
            try journal.recordDetached(cleanup)
            XCTAssertEqual(try journal.detachedCleanup(), cleanup)
            XCTAssertThrowsError(try journal.requireStagingAllowed())
        }
        let journal = try f.journal()
        XCTAssertEqual(try journal.maintenanceIntent().journalSHA256, digest)
        XCTAssertEqual(try journal.detachedCleanup(), cleanup)
        try journal.recordDetached(cleanup)
        XCTAssertThrowsError(try journal.requireStagingAllowed())
        XCTAssertThrowsError(try f.overlay.stage(dataDirectory: f.data,
            payloadDirectory: f.installation.destination, journal: journal))
    }

    func testCannotRecordDetachWithoutStagingOrWithDifferentDisk() async throws {
        let f = try await fixture()
        do {
            let journal = try f.journal()
            XCTAssertThrowsError(try journal.recordDetached(cleanup(f)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: completion(f).path))
        try f.stage()
        let journal = try f.journal()
        for mutation in ["disk", "schemaVersion", "imageFenceSHA256"] {
            var value = try cleanupObject(f)
            if mutation == "disk" {
                var disk = try XCTUnwrap(value["disk"] as? [String: Any]); disk["inode"] = 0
                value["disk"] = disk
            } else if mutation == "schemaVersion" { value[mutation] = 2 }
            else { value[mutation] = "bad" }
            let invalid = try JSONDecoder().decode(LumeImageMaintenanceCleanup.self,
                from: JSONSerialization.data(withJSONObject: value))
            XCTAssertThrowsError(try journal.recordDetached(invalid), mutation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: completion(f).path))
        }
    }

    func testOrphanedCompletionDoesNotRecreateIntentOrStagingReceipt() async throws {
        for missing in ["staging-intent.json", "staged.json"] {
            let f = try await fixture(); try f.stage()
            do { try f.journal().recordDetached(cleanup(f)) }
            let path = f.journalDirectory.appendingPathComponent(missing)
            try FileManager.default.removeItem(at: path)
            XCTAssertThrowsError(try f.journal())
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: completion(f).path))
        }
    }

    func testMissingLiveIntentAndCorruptCompletionCloseMaintenanceAdmission() async throws {
        let f = try await fixture(); try f.stage()
        let journal = try f.journal(), path = f.journalDirectory.appendingPathComponent("staging-intent.json")
        let original = try Data(contentsOf: path)
        try FileManager.default.removeItem(at: path)
        XCTAssertThrowsError(try journal.maintenanceIntent())
        XCTAssertThrowsError(try journal.recordDetached(cleanup(f)))
        try original.write(to: path); XCTAssertEqual(chmod(path.path, 0o600), 0)
        let duplicate = Data("{\"schemaVersion\":1,".utf8) + (try JSONEncoder().encode(cleanup(f))).dropFirst()
        try duplicate.write(to: completion(f)); XCTAssertEqual(chmod(completion(f).path, 0o600), 0)
        XCTAssertThrowsError(try journal.maintenanceIntent())
        XCTAssertThrowsError(try journal.detachedCleanup())
        XCTAssertEqual(try Data(contentsOf: completion(f)), duplicate)
    }

    private func fixture() async throws -> AccountlessOfflineOverlayTestFixture {
        let f = try await AccountlessOfflineOverlayTestFixture(); addTeardownBlock { f.remove() }; return f
    }
    private func completion(_ f: AccountlessOfflineOverlayTestFixture) -> URL { f.journalDirectory.appendingPathComponent("staging-detached.json") }
    private func cleanup(_ f: AccountlessOfflineOverlayTestFixture) throws -> LumeImageMaintenanceCleanup {
        try JSONDecoder().decode(LumeImageMaintenanceCleanup.self, from: JSONSerialization.data(withJSONObject: cleanupObject(f)))
    }
    private func cleanupObject(_ f: AccountlessOfflineOverlayTestFixture) throws -> [String: Any] {
        ["schemaVersion": 1, "imageFenceSHA256": String(repeating: "a", count: 64),
         "disk": try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.installation.candidate.disk))]
    }
}
