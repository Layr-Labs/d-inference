import Darwin
import Foundation
import SandboxCore
@testable import SandboxRuntimeLume
import XCTest

final class LumeAccountlessTemplateTests: XCTestCase {
    func testRawOwnerCannotUseLegacyGrandfatherReceipt() throws {
        let f = try LumeGuestTemplateTestFixture(accountless: true)
        defer { f.remove() }
        XCTAssertThrowsError(try f.requireReady())
    }

    func testQualifiedAccountlessTemplateReusesExactGuestAcrossHostOnlyUpgrade() throws {
        let f = try LumeGuestTemplateTestFixture(accountless: true)
        defer { f.remove() }
        try publish(f)
        XCTAssertNoThrow(try f.requireReady())
        let original = try Data(contentsOf: f.receipt)
        try f.writeManifest(hostVersion: "new-host")
        XCTAssertNoThrow(try f.requireReady())
        XCTAssertEqual(try Data(contentsOf: f.receipt), original)
        for artifact in LumeGuestTemplateTestFixture.guestNames {
            try f.writeManifest(changedGuest: artifact)
            XCTAssertThrowsError(try f.requireReady(), artifact)
        }
    }

    func testOwnershipSourceMutationCannotReuseQualificationEvenWithSameInstallationID() throws {
        let f = try LumeGuestTemplateTestFixture(accountless: true)
        defer { f.remove() }
        try publish(f)
        let owner = f.storage.appendingPathComponent("base/.darkbloom-ownership.json")
        let original = try Data(contentsOf: owner)
        for (field, value) in [("sourceReference", "/other.ipsw" as Any), ("installationID", UUID().uuidString), ("cpuCount", 8)] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            object[field] = value
            try JSONSerialization.data(withJSONObject: object).write(to: owner)
            XCTAssertThrowsError(try f.requireReady(), field)
        }
        try original.write(to: owner)
        XCTAssertNoThrow(try f.requireReady())
    }

    func testMissingNativeOrCleanupEvidenceNeverOpensNormalCloneGate() throws {
        let f = try LumeGuestTemplateTestFixture(accountless: true)
        defer { f.remove() }
        try publish(f)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.receipt)) as? [String: Any])
        for field in ["checks", "cleanup"] {
            var object = original
            var evidence = object["accountless"] as! [String: Any]
            var qualification = evidence["qualification"] as! [String: Any]
            qualification.removeValue(forKey: field)
            evidence["qualification"] = qualification; object["accountless"] = evidence
            try JSONSerialization.data(withJSONObject: object).write(to: f.receipt)
            XCTAssertThrowsError(try f.requireReady(), field)
        }
    }

    func testOwnershipSymlinkOrLegacySourceCannotAuthenticateAccountlessRecord() throws {
        let f = try LumeGuestTemplateTestFixture(accountless: true)
        defer { f.remove() }
        try publish(f)
        let owner = f.storage.appendingPathComponent("base/.darkbloom-ownership.json")
        let moved = f.storage.appendingPathComponent("base/original-owner.json")
        try FileManager.default.moveItem(at: owner, to: moved)
        try FileManager.default.createSymbolicLink(at: owner, withDestinationURL: moved)
        XCTAssertThrowsError(try f.requireReady())
        try FileManager.default.removeItem(at: owner)
        try FileManager.default.moveItem(at: moved, to: owner)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: owner)) as? [String: Any])
        object["sourceKind"] = "restore_image"; object["unattendedPreset"] = "tahoe"
        try JSONSerialization.data(withJSONObject: object).write(to: owner)
        XCTAssertThrowsError(try f.requireReady())
    }

    private func publish(_ f: LumeGuestTemplateTestFixture) throws {
        let legacy = try JSONDecoder().decode(SandboxGuestTemplateReceipt.self, from: Data(contentsOf: f.receipt))
        let source = try LumeGuestTemplateSource.load(name: "base", installationID: f.instanceID, storage: f.storage)
        let installation = SandboxAccountlessInstallationReceipt(source: source, rootJobID: UUID(), phase: .installationComplete,
            payload: legacy.payload, guestOperatingSystemVersion: "26.0", guestArchitecture: "arm64",
            virtualizedRootObserved: true, signedInstallerVerified: true, installerExitCode: 0,
            installedPayloadVerified: true, bootstrapAccountAbsent: true, tenantIdentityVerified: true)
        let cloneID = UUID()
        let qualification = SandboxGuestNativeQualification(qualificationID: UUID(), source: source, payload: legacy.payload,
            cloneName: "qualification", cloneInstallationID: cloneID,
            checks: .init(authenticatedGuest: true, tenantIdentity: true, commandExecution: true,
                workspaceRoundTrip: true, protectedPathDenied: true, controlDiskDenied: true, restart: true),
            cleanup: .init(cloneInstallationID: cloneID, materialsInstanceID: cloneID, cloneRemoved: true,
                materialsRemoved: true, capacityReleased: true, sourceStoppedReverified: true, sourceUnchangedReverified: true))
        let record = SandboxGuestTemplateReceipt(accountless: .init(installation: installation, qualification: qualification))
        try JSONEncoder().encode(record).write(to: f.receipt)
    }
}
