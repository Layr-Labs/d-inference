import Darwin
import Foundation
import SandboxCore
@testable import SandboxRuntimeLume
import XCTest

/// Readback fixtures intentionally construct synthetic native observations. They
/// exercise publication verification, not issuance of a native-check result.
final class LumeQualificationPublicationTests: XCTestCase {
    func testReadbackRequiresExactPublishedReceiptAndRetainsTheSourceGuard() async throws {
        let f = try await fixture()
        let record = try await recordAfterDeletion(f)
        await rejects { try await f.capability.issuingRuntime.verifyQualificationPublication(record, capability: f.capability) }
        try f.base.write(record, name: SandboxGuestTemplateReceipt.fileName)
        try await f.capability.issuingRuntime.verifyQualificationPublication(record, capability: f.capability)
        XCTAssertThrowsError(try LumeBaseCandidateOperationGuard(name: f.base.source.name, storage: f.base.vm.storage))
        let original = try Data(contentsOf: f.base.path(SandboxGuestTemplateReceipt.fileName))
        try await f.capability.issuingRuntime.verifyQualificationPublication(record, capability: f.capability)
        XCTAssertEqual(try Data(contentsOf: f.base.path(SandboxGuestTemplateReceipt.fileName)), original)
    }

    func testChangedReceiptDiskOrUnresolvedCloneCannotPassReadback() async throws {
        for mutation in ["receipt", "disk", "clone", "linked"] {
            let f = try await fixture(), record = try await recordAfterDeletion(f)
            try f.base.write(record, name: SandboxGuestTemplateReceipt.fileName)
            let path = f.base.path(SandboxGuestTemplateReceipt.fileName)
            switch mutation {
            case "receipt":
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
                object["stoppedVerified"] = false
                try JSONSerialization.data(withJSONObject: object).write(to: path)
            case "disk":
                let file = try FileHandle(forWritingTo: f.base.path("disk.img"))
                try file.write(contentsOf: Data([1])); try file.close()
            case "clone": try Data().write(to: f.clone)
            default: XCTAssertEqual(link(path.path, f.base.path("receipt-alias").path), 0)
            }
            await rejects { try await f.capability.issuingRuntime.verifyQualificationPublication(record, capability: f.capability) }
        }
    }

    private func recordAfterDeletion(_ f: LumeQualificationCleanupFixture) async throws -> SandboxGuestTemplateReceipt {
        try f.prepareMaterials(); try f.setRunning(true)
        let observation = try await f.observe()
        try await f.deleteAndRelease()
        let cleanup = try await f.base.runtime.verifyQualificationCleanup(observation)
        let checks = SandboxGuestNativeChecks(authenticatedGuest: true, tenantIdentity: true, commandExecution: true,
            workspaceRoundTrip: true, protectedPathDenied: true, controlDiskDenied: true, restart: true)
        let qualification = SandboxGuestNativeQualification(qualificationID: f.capability.qualificationID,
            source: f.base.source, payload: f.capability.checkpoint.payload, cloneName: f.base.specification.name,
            cloneInstallationID: observation.cloneInstallationID, checks: checks, cleanup: cleanup)
        return .init(accountless: .init(installation: f.capability.snapshot.installation, qualification: qualification))
    }
    private func fixture() async throws -> LumeQualificationCleanupFixture {
        let value = try await LumeQualificationCleanupFixture(); addTeardownBlock { value.remove() }; return value
    }
    private func rejects(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("invalid qualification publication accepted", file: file, line: line) } catch {}
    }
}
