import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeQualificationCleanupTests: XCTestCase {
    func testDeletionReceiptVerifiesAfterLeaseReleaseWithoutPublishingReadiness() async throws {
        let f = try await fixture()
        try f.prepareMaterials(); try f.setRunning(true)
        let observation = try await f.observe()
        await rejects { _ = try await f.base.runtime.verifyQualificationCleanup(observation) }
        XCTAssertEqual(try f.base.arbiter.snapshot().leases, [f.base.lease])
        try await f.deleteAndRelease()
        XCTAssertTrue(try f.base.arbiter.deletionConfirmed(scope: f.base.lease.scope, virtualMachineName: f.base.specification.name))
        let cleanup = try await f.base.runtime.verifyQualificationCleanup(observation)
        XCTAssertTrue(cleanup.complete)
        XCTAssertEqual(cleanup.cloneInstallationID, observation.cloneInstallationID)
        XCTAssertEqual(cleanup.materialsInstanceID, observation.materialsInstanceID)
        XCTAssertTrue(try f.base.arbiter.snapshot().leases.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.clone.path))
        let replay = try await f.base.runtime.verifyQualificationCleanup(observation)
        XCTAssertEqual(cleanup, replay)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.path(SandboxGuestTemplateReceipt.fileName).path))
        XCTAssertThrowsError(try LumeBaseCandidateOperationGuard(name: f.base.source.name, storage: f.base.vm.storage))
    }

    func testCloneMustBeCreatedRunningAndHaveMatchingMaterialsBeforeObservation() async throws {
        let base = try await LumeQualificationFixture(); defer { base.remove() }
        let unused = try await base.issue()
        await rejects { _ = try await base.runtime.observeQualificationClone(unused) }
        for mutation in ["missing", "stopped", "wrong-instance", "changed-control"] {
            let f = try await fixture()
            if mutation != "missing" { try f.prepareMaterials(instanceID: mutation == "wrong-instance" ? UUID() : nil) }
            if mutation != "stopped" { try f.setRunning(true) }
            if mutation == "changed-control" {
                let path = f.materialRoot.appendingPathComponent("control.cdr")
                XCTAssertEqual(chmod(path.path, 0o600), 0)
                let file = try FileHandle(forWritingTo: path); try file.write(contentsOf: Data([1])); try file.close()
                XCTAssertEqual(chmod(path.path, 0o400), 0)
            }
            await rejects { _ = try await f.observe() }
            XCTAssertEqual(try f.base.arbiter.snapshot().leases, [f.base.lease])
        }
    }

    func testMissingVMAndGenericCapacityReleaseAreNotDeletionEvidence() async throws {
        let f = try await fixture()
        try f.prepareMaterials(); try f.setRunning(true)
        let observation = try await f.observe()
        try FileManager.default.removeItem(at: f.clone)
        await rejects { _ = try await f.base.runtime.verifyQualificationCleanup(observation) }
        do {
            let authorization = try f.base.arbiter.authorizeMutation(scope: f.base.lease.scope,
                virtualMachineName: f.base.specification.name, operation: .delete)
            try f.base.arbiter.release(scope: f.base.lease.scope, holding: authorization)
        }
        XCTAssertTrue(try f.base.arbiter.snapshot().leases.isEmpty)
        XCTAssertFalse(try f.base.arbiter.deletionConfirmed(scope: f.base.lease.scope, virtualMachineName: f.base.specification.name))
        await rejects { _ = try await f.base.runtime.verifyQualificationCleanup(observation) }
    }

    func testReappearedPathChangedSourceAndAnotherRuntimeCannotReuseCleanup() async throws {
        for mutation in ["empty-file", "symlink", "source", "running-source", "runtime"] {
            let f = try await fixture()
            try f.prepareMaterials(); try f.setRunning(true)
            let observation = try await f.observe()
            try await f.deleteAndRelease()
            switch mutation {
            case "empty-file": try Data().write(to: f.clone)
            case "symlink": try FileManager.default.createSymbolicLink(at: f.clone, withDestinationURL: f.base.vm.directory)
            case "source":
                let file = try FileHandle(forWritingTo: f.base.path("disk.img"))
                try file.write(contentsOf: Data([1])); try file.close()
            case "running-source": try Data("running\n".utf8).write(to: f.base.vm.state)
            default:
                let other = try LumeLeaseFencedVirtualMachineRuntime(configuration: f.base.configuration, capacityArbiter: f.base.arbiter)
                await rejects { _ = try await other.verifyQualificationCleanup(observation) }
                continue
            }
            await rejects { _ = try await f.base.runtime.verifyQualificationCleanup(observation) }
            XCTAssertTrue(try f.base.arbiter.snapshot().leases.isEmpty)
        }
    }

    private func fixture() async throws -> LumeQualificationCleanupFixture {
        let value = try await LumeQualificationCleanupFixture()
        addTeardownBlock { value.remove() }
        return value
    }

    private func rejects(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("invalid qualification cleanup accepted", file: file, line: line) } catch {}
    }
}
