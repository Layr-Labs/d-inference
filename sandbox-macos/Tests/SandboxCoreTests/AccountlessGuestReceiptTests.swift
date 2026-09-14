import Foundation
import SandboxCore
import XCTest

final class AccountlessGuestReceiptTests: XCTestCase {
    func testSchema2RoundTripRequiresQualificationAndDoesNotClaimRetirement() throws {
        let f = Fixture(), record = f.receipt()
        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["bootstrapRetired"])
        XCTAssertFalse(record.bootstrapRetired)
        XCTAssertTrue(record.isReady(for: f.source, guestFiles: f.files))
        XCTAssertEqual(try JSONDecoder().decode(SandboxGuestTemplateReceipt.self, from: data), record)
    }

    func testLegacySchema1RoundTripsWithoutAccountlessEvidenceAndCannotQualifyRawSource() throws {
        let f = Fixture()
        let record = SandboxGuestTemplateReceipt(schemaVersion: 1, name: f.source.name,
            installationID: f.source.installationID, releaseManifestSHA256: f.payload.releaseManifestSHA256,
            guestSHA256: f.payload.guestSHA256, bootstrapSHA256: f.payload.bootstrapSHA256,
            launchdSHA256: f.payload.launchdSHA256, installerSHA256: f.payload.installerSHA256,
            guestOperatingSystemVersion: "26.0", guestArchitecture: "arm64", bootstrapRetired: true, stoppedVerified: true)
        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["bootstrapRetired"] as? Bool, true); XCTAssertNil(json["accountless"])
        let legacySource = SandboxGuestBaseSource(name: f.source.name, installationID: f.source.installationID,
            kind: .legacyRestoreImage, reference: f.source.reference, ownershipSHA256: f.source.ownershipSHA256)
        XCTAssertTrue(record.isReady(for: legacySource, guestFiles: f.files))
        XCTAssertFalse(record.isReady(for: f.source, guestFiles: f.files))
        XCTAssertEqual(try JSONDecoder().decode(SandboxGuestTemplateReceipt.self, from: data), record)
    }

    func testRootJobStartAndInstallationCompletionAreNotNativeQualification() throws {
        let f = Fixture()
        let started = SandboxAccountlessInstallationReceipt(source: f.source, rootJobID: UUID(),
            phase: .rootJobStarted, payload: f.payload, guestOperatingSystemVersion: "26.0",
            guestArchitecture: "arm64", virtualizedRootObserved: true, signedInstallerVerified: false)
        XCTAssertTrue(started.isValidStartedRecord); XCTAssertFalse(started.installationComplete)
        let data = try JSONEncoder().encode(started)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["installerExitCode"]); XCTAssertNil(object["bootstrapRetired"])
        XCTAssertFalse(f.qualification().qualifies(started))
        XCTAssertTrue(f.installation().installationComplete)
        XCTAssertFalse(try mutated(f.receipt(), path: ["accountless", "qualification", "checks", "authenticatedGuest"], value: false)
            .isReady(for: f.source, guestFiles: f.files))
    }

    func testEveryNativeObservationAndCleanupProofIsRequired() throws {
        let f = Fixture()
        for key in ["authenticatedGuest", "tenantIdentity", "commandExecution", "workspaceRoundTrip",
                    "protectedPathDenied", "controlDiskDenied", "restart"] {
            let record = try mutated(f.receipt(), path: ["accountless", "qualification", "checks", key], value: false)
            XCTAssertFalse(record.isReady(for: f.source, guestFiles: f.files), key)
        }
        for key in ["cloneRemoved", "materialsRemoved", "capacityReleased", "sourceStoppedReverified", "sourceUnchangedReverified"] {
            let record = try mutated(f.receipt(), path: ["accountless", "qualification", "cleanup", key], value: false)
            XCTAssertFalse(record.isReady(for: f.source, guestFiles: f.files), key)
        }
    }

    func testQualificationScopeAndVersionCannotBeReplayedOntoAnotherSourceOrClone() throws {
        let f = Fixture()
        let changes: [([String], Any)] = [
            (["version"], 2), (["profile"], "development"), (["cloneName"], f.source.name),
            (["cloneInstallationID"], f.source.installationID.uuidString),
            (["qualificationID"], f.source.installationID.uuidString),
            (["source", "installationID"], UUID().uuidString), (["source", "reference"], "/other.ipsw"),
            (["source", "ownershipSHA256"], String(repeating: "e", count: 64)),
            (["cleanup", "cloneInstallationID"], UUID().uuidString), (["cleanup", "materialsInstanceID"], UUID().uuidString)
        ]
        for (path, value) in changes {
            let record = try mutated(f.receipt(), path: ["accountless", "qualification"] + path, value: value)
            XCTAssertFalse(record.isReady(for: f.source, guestFiles: f.files), path.joined(separator: "."))
        }
    }

    func testIncompleteOrWrongInstallationEvidenceIsRejected() throws {
        let f = Fixture()
        let changes: [(String, Any)] = [("schemaVersion", 1), ("bootstrapAccountPolicy", "retired"),
            ("phase", "rootJobStarted"), ("virtualizedRootObserved", false), ("signedInstallerVerified", false),
            ("installerExitCode", 78), ("installedPayloadVerified", false), ("bootstrapAccountAbsent", false),
            ("tenantIdentityVerified", false), ("guestArchitecture", "x86_64")]
        for (key, value) in changes {
            let record = try mutated(f.receipt(), path: ["accountless", "installation", key], value: value)
            XCTAssertFalse(record.isReady(for: f.source, guestFiles: f.files), key)
        }
        for key in ["installerExitCode", "installedPayloadVerified", "bootstrapAccountAbsent", "tenantIdentityVerified"] {
            let record = try mutated(f.receipt(), path: ["accountless", "installation", key], value: NSNull())
            XCTAssertFalse(record.isReady(for: f.source, guestFiles: f.files), key)
        }
    }

    func testMalformedRelabelingAndUnknownMethodFailClosed() throws {
        let f = Fixture()
        for value in [true as Any, false as Any, NSNull()] {
            let record = try mutated(f.receipt(), path: ["bootstrapRetired"], value: value)
            XCTAssertFalse(record.isReady(for: f.source, guestFiles: f.files))
            let roundTrip = try JSONDecoder().decode(SandboxGuestTemplateReceipt.self, from: JSONEncoder().encode(record))
            XCTAssertFalse(roundTrip.isReady(for: f.source, guestFiles: f.files))
            XCTAssertThrowsError(try mutated(f.receipt(), path: ["accountless", "installation", "bootstrapRetired"], value: value))
        }
        XCTAssertThrowsError(try mutated(f.receipt(), path: ["accountless", "installation", "method"], value: "ssh"))
        XCTAssertThrowsError(try mutated(f.receipt(), path: ["accountless", "installation", "source", "kind"], value: "unknown"))
        XCTAssertFalse(try mutated(f.receipt(), path: ["schemaVersion"], value: 1).isReady(for: f.source, guestFiles: f.files))
        XCTAssertFalse(try mutated(f.receipt(), path: ["accountless"], value: NSNull()).isReady(for: f.source, guestFiles: f.files))
    }

    func testExactGuestHashesAndOriginalManifestStayBoundAcrossProofs() throws {
        let f = Fixture()
        for field in ["guestSHA256", "bootstrapSHA256", "launchdSHA256", "installerSHA256", "releaseManifestSHA256"] {
            let record = try mutated(f.receipt(), path: ["accountless", "qualification", "payload", field], value: String(repeating: "e", count: 64))
            XCTAssertFalse(record.isReady(for: f.source, guestFiles: f.files), field)
        }
        for key in f.files.keys {
            var changed = f.files; changed[key] = String(repeating: "e", count: 64)
            XCTAssertFalse(f.receipt().isReady(for: f.source, guestFiles: changed), key)
        }
    }

    private func mutated(_ receipt: SandboxGuestTemplateReceipt, path: [String], value: Any) throws -> SandboxGuestTemplateReceipt {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        func replace(_ object: inout [String: Any], keys: ArraySlice<String>) {
            let key = keys.first!
            if keys.count == 1 { object[key] = value; return }
            var child = object[key] as! [String: Any]
            replace(&child, keys: keys.dropFirst()); object[key] = child
        }
        replace(&object, keys: path[...])
        return try JSONDecoder().decode(SandboxGuestTemplateReceipt.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private struct Fixture {
        let source = SandboxGuestBaseSource(name: "base", installationID: UUID(), kind: .appleRestore,
            reference: "/image.ipsw", ownershipSHA256: String(repeating: "a", count: 64))
        let payload = SandboxGuestPayloadIdentity(releaseManifestSHA256: String(repeating: "b", count: 64),
            guestSHA256: String(repeating: "c", count: 64), bootstrapSHA256: String(repeating: "d", count: 64),
            launchdSHA256: String(repeating: "f", count: 64), installerSHA256: String(repeating: "1", count: 64))
        let cloneID = UUID()
        var files: [String: String] { ["guest/darkbloom-sandbox-guest": payload.guestSHA256,
            "guest/darkbloom-sandbox-bootstrap.sh": payload.bootstrapSHA256,
            "guest/io.darkbloom.sandbox.guest.plist": payload.launchdSHA256,
            "guest/install-sandbox-guest.sh": payload.installerSHA256] }
        func installation() -> SandboxAccountlessInstallationReceipt {
            .init(source: source, rootJobID: UUID(), phase: .installationComplete, payload: payload,
                guestOperatingSystemVersion: "26.0", guestArchitecture: "arm64", virtualizedRootObserved: true,
                signedInstallerVerified: true, installerExitCode: 0, installedPayloadVerified: true,
                bootstrapAccountAbsent: true, tenantIdentityVerified: true)
        }
        func qualification() -> SandboxGuestNativeQualification {
            .init(qualificationID: UUID(), source: source, payload: payload, cloneName: "qualification", cloneInstallationID: cloneID,
                checks: .init(authenticatedGuest: true, tenantIdentity: true, commandExecution: true,
                    workspaceRoundTrip: true, protectedPathDenied: true, controlDiskDenied: true, restart: true),
                cleanup: .init(cloneInstallationID: cloneID, materialsInstanceID: cloneID, cloneRemoved: true,
                    materialsRemoved: true, capacityReleased: true, sourceStoppedReverified: true, sourceUnchangedReverified: true))
        }
        func receipt() -> SandboxGuestTemplateReceipt { .init(accountless: .init(installation: installation(), qualification: qualification())) }
    }
}
