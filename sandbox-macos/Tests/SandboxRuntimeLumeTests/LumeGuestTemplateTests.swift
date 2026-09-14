import CryptoKit
import Darwin
import Foundation
import SandboxCore
@testable import SandboxRuntimeLume
import XCTest

final class LumeGuestTemplateTests: XCTestCase {
    func testHostOnlySignedManifestUpgradeReusesGuestWithoutChangingProvenance() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.requireReady()
        let originalReceipt = try Data(contentsOf: fixture.receipt)
        let originalManifest = try Data(contentsOf: fixture.manifest)
        try fixture.writeManifest(hostVersion: "new-host-and-lume")
        XCTAssertNotEqual(try Data(contentsOf: fixture.manifest), originalManifest)
        try fixture.requireReady()
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), originalReceipt)
    }

    func testEachChangedGuestArtifactInSignedManifestRequiresNewQualification() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for name in Fixture.guestNames {
            try fixture.writeManifest(changedGuest: name)
            XCTAssertThrowsError(try fixture.requireReady(), name)
        }
        try fixture.writeManifest()
        XCTAssertNoThrow(try fixture.requireReady())
    }

    func testReplacedUnsignedAndSymlinkedManifestCannotQualifyTemplate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeManifest(hostVersion: "unsigned", sign: false)
        XCTAssertThrowsError(try fixture.requireReady())
        try fixture.writeManifest()
        let moved = fixture.release.appendingPathComponent("original-manifest.json")
        try FileManager.default.moveItem(at: fixture.manifest, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.manifest, withDestinationURL: moved)
        XCTAssertThrowsError(try fixture.requireReady())
    }

    func testGuestIdentityStoppedProofAndRetirementRemainRequiredAcrossHostUpgrade() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.receipt)
        try fixture.writeManifest(hostVersion: "host-only-upgrade")
        for (key, value) in [("installationID", UUID().uuidString as Any), ("name", "other-base"),
                             ("stoppedVerified", false), ("bootstrapRetired", false),
                             ("guestArchitecture", "x86_64"), ("schemaVersion", 2),
                             ("releaseManifestSHA256", "unqualified")] {
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            record[key] = value
            try JSONSerialization.data(withJSONObject: record).write(to: fixture.receipt)
            XCTAssertThrowsError(try fixture.requireReady(), key)
        }
        try original.write(to: fixture.receipt)
        XCTAssertNoThrow(try fixture.requireReady())
    }

    private typealias Fixture = LumeGuestTemplateTestFixture
}
