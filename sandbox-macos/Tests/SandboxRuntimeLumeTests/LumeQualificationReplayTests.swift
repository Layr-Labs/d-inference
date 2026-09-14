import Foundation
import SandboxCore
@testable import SandboxRuntimeLume
import XCTest

final class LumeQualificationReplayTests: XCTestCase {
    func testReadsOnlyAlreadyPublishedExactQualificationWithRootBindings() async throws {
        let f = try await LumeQualificationFixture(); defer { f.remove() }
        let installation = try JSONDecoder().decode(SandboxAccountlessInstallationReceipt.self,
            from: Data(contentsOf: f.path(LumeInstalledCandidateCheckpoint.installationFileName)))
        let disk = try LumeInstalledCandidateStore(name: f.source.name, storage: f.vm.storage).diskIdentity()
        let runtimeHash = LumeInstalledCandidateStore.digest(try Data(contentsOf: f.vm.executable))
        let request = LumeInstallerBootRequest(reservationData: try Data(contentsOf: f.path(LumeInstalledCandidateCheckpoint.reservationFileName)),
            stagedDisk: disk, runtimeSHA256: runtimeHash, maximumBootSeconds: 300, permitSHA256: String(repeating: "b", count: 64))
        let cloneID = UUID()
        let cleanup = SandboxGuestQualificationCleanup(cloneInstallationID: cloneID, materialsInstanceID: cloneID,
            cloneRemoved: true, materialsRemoved: true, capacityReleased: true, sourceStoppedReverified: true, sourceUnchangedReverified: true)
        let checks = SandboxGuestNativeChecks(authenticatedGuest: true, tenantIdentity: true, commandExecution: true,
            workspaceRoundTrip: true, protectedPathDenied: true, controlDiskDenied: true, restart: true)
        let receipt = SandboxGuestTemplateReceipt(accountless: .init(installation: installation,
            qualification: .init(qualificationID: f.qualificationID, source: f.source, payload: installation.payload,
                cloneName: "completed-clone", cloneInstallationID: cloneID, checks: checks, cleanup: cleanup)))
        let runtime = LumeVirtualMachineRuntime(configuration: f.configuration)
        try LumeInstallerBootClaim.publish(request, name: f.source.name, storage: f.vm.storage)
        await rejects { try await runtime.verifyPublishedQualification(request: request, expectedDisk: disk, installation: installation, receipt: receipt) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path(SandboxGuestTemplateReceipt.fileName).path))
        // Deliberately synthetic historical evidence; this test observes no guest.
        try f.write(receipt, name: SandboxGuestTemplateReceipt.fileName)
        let bytes = try Data(contentsOf: f.path(SandboxGuestTemplateReceipt.fileName))
        try await runtime.verifyPublishedQualification(request: request, expectedDisk: disk, installation: installation, receipt: receipt)
        XCTAssertEqual(try Data(contentsOf: f.path(SandboxGuestTemplateReceipt.fileName)), bytes)
        let wrong = LumeInstallerBootRequest(reservationData: request.reservationData, stagedDisk: disk,
            runtimeSHA256: String(repeating: "0", count: 64), maximumBootSeconds: 300, permitSHA256: request.permitSHA256)
        await rejects { try await runtime.verifyPublishedQualification(request: wrong, expectedDisk: disk, installation: installation, receipt: receipt) }
        let image = try FileHandle(forWritingTo: f.path("disk.img")); try image.write(contentsOf: Data([1])); try image.close()
        await rejects { try await runtime.verifyPublishedQualification(request: request, expectedDisk: disk, installation: installation, receipt: receipt) }
        XCTAssertEqual(try Data(contentsOf: f.path(SandboxGuestTemplateReceipt.fileName)), bytes)
    }
    private func rejects(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("invalid published replay accepted", file: file, line: line) } catch {}
    }
}
