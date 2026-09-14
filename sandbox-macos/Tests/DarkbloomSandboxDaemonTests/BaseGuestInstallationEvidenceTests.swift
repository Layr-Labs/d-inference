import Foundation
import SandboxCore
@testable import DarkbloomSandboxDaemon
import XCTest

final class BaseGuestInstallationEvidenceTests: XCTestCase {
    private func fixture() throws -> BaseGuestPreparationTestFixture {
        let fixture = try BaseGuestPreparationTestFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.root) }
        return fixture
    }

    func testInstallationRecordDecodesLegacyAndAccountlessWithoutRelabeling() throws {
        let f = try fixture(), release = try f.release()
        let legacy = try JSONDecoder().decode(BaseGuestInstallationRecord.self,
            from: JSONEncoder().encode(f.receipt(release: release)))
        guard case .legacy(let old) = legacy else { return XCTFail("historical receipt was relabeled") }
        try old.validate(release: release)
        try f.writeOwnership(id: f.installationID, sourceKind: "apple_restore")
        let accountless = try f.accountlessTemplate(release: release).accountless!.installation
        let decoded = try JSONDecoder().decode(BaseGuestInstallationRecord.self, from: JSONEncoder().encode(accountless))
        guard case .accountless(let record) = decoded else { return XCTFail("new receipt was treated as legacy") }
        try record.validate(release: release, source: accountless.source)
        XCTAssertThrowsError(try JSONDecoder().decode(BaseGuestInstallationReceipt.self,
            from: JSONEncoder().encode(accountless)))
        var malformed = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(accountless)) as? [String: Any])
        malformed["schemaVersion"] = 1
        XCTAssertThrowsError(try JSONDecoder().decode(BaseGuestInstallationRecord.self,
            from: JSONSerialization.data(withJSONObject: malformed)))
    }

    func testAccountlessPublisherRequiresQualificationCleanupAndSeparatePublicationPath() throws {
        let f = try fixture(), release = try f.release()
        try f.writeOwnership(id: f.installationID, sourceKind: "apple_restore")
        let store = BaseGuestTemplateStore(directory: f.storage.appendingPathComponent("base"))
        let record = try f.accountlessTemplate(release: release)
        XCTAssertThrowsError(try store.publish(record), "legacy publisher cannot publish schema2")
        XCTAssertThrowsError(try store.publishAccountless(f.accountlessTemplate(release: release, cleanupComplete: false), release: release))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(BaseGuestTemplateStore.filename).path))
        try store.publishAccountless(record, release: release)
        let read = try XCTUnwrap(store.matching(name: "base", release: release))
        XCTAssertEqual(read, record)
        XCTAssertEqual(read.schemaVersion, 2); XCTAssertFalse(read.bootstrapRetired)
        XCTAssertThrowsError(try store.publishAccountless(record, release: release), "publication cannot overwrite existing evidence")
        try f.writeOwnership(id: f.installationID, sourceKind: "restore_image")
        XCTAssertThrowsError(try store.matching(name: "base", release: release))
    }

    func testAccountlessInstallationValidationBindsSourceAndCompletion() throws {
        let f = try fixture(), release = try f.release()
        try f.writeOwnership(id: f.installationID, sourceKind: "apple_restore")
        let record = try f.accountlessTemplate(release: release).accountless!.installation
        try record.validate(release: release, source: record.source)
        let different = SandboxGuestBaseSource(name: "base", installationID: UUID(), kind: .appleRestore,
            reference: record.source.reference, ownershipSHA256: record.source.ownershipSHA256)
        XCTAssertThrowsError(try record.validate(release: release, source: different))
        let partial = SandboxAccountlessInstallationReceipt(source: record.source, rootJobID: UUID(),
            phase: .rootJobStarted, payload: record.payload, guestOperatingSystemVersion: "26.0", guestArchitecture: "arm64",
            virtualizedRootObserved: true, signedInstallerVerified: true)
        XCTAssertThrowsError(try partial.validate(release: release, source: record.source))
    }

    func testPublisherRejectsChangedSignedGuestAndNeverWritesReadiness() throws {
        let f = try fixture(), release = try f.release()
        try f.writeOwnership(id: f.installationID, sourceKind: "apple_restore")
        let record = try f.accountlessTemplate(release: release)
        let changed = Data("different guest".utf8)
        try changed.write(to: f.releaseDirectory.appendingPathComponent("guest/darkbloom-sandbox-guest"))
        let manifestURL = f.releaseDirectory.appendingPathComponent("release-manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var files = try XCTUnwrap(manifest["files"] as? [String: String])
        files["guest/darkbloom-sandbox-guest"] = BaseGuestRelease.digest(changed)
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let store = BaseGuestTemplateStore(directory: f.storage.appendingPathComponent("base"))
        XCTAssertThrowsError(try store.publishAccountless(record, release: f.release()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(BaseGuestTemplateStore.filename).path))
    }
}
