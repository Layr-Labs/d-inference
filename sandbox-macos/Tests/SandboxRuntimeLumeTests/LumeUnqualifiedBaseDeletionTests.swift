import Foundation
import HostRuntimeCoordination
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeUnqualifiedBaseDeletionTests: XCTestCase, @unchecked Sendable {
    func testDiscardAndAbsentReplayPreserveOtherStorageAndRejectRecreatedInstallation() async throws {
        let f = try await fixture()
        defer { try? f.fixture.remove() }
        let sentinel = f.fixture.storage.appendingPathComponent("unrelated")
        try Data("preserved".utf8).write(to: sentinel)
        try await f.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.fixture.virtualMachineDirectory.path))
        XCTAssertNil(try LumeVirtualMachineDeletionIntent.load(workspace: f.workspace, name: f.name))
        try await f.discard()
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserved".utf8))
        try await f.runtime.create(f.specification)
        await requireRejected { try await f.discard() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.fixture.ownershipMarker.path))
    }

    func testWrongInstallationAndRunningStatePreserveBaseWithoutDeletionIntent() async throws {
        let f = try await fixture()
        defer { try? f.fixture.remove() }
        let ownership = try Data(contentsOf: f.fixture.ownershipMarker)
        await requireRejected { try await f.runtime.discardUnqualifiedBase(name: f.name, installationID: UUID()) }
        try Data("running\n".utf8).write(to: f.fixture.state)
        await requireRejected { try await f.discard() }
        XCTAssertEqual(try Data(contentsOf: f.fixture.ownershipMarker), ownership)
        XCTAssertNil(try LumeVirtualMachineDeletionIntent.load(workspace: f.workspace, name: f.name))
    }

    func testEvenMalformedReadinessAndGuestMaterialsPreventDiscard() async throws {
        for entry in [SandboxGuestTemplateReceipt.fileName, ".darkbloom-guest"] {
            let f = try await fixture()
            defer { try? f.fixture.remove() }
            let file = f.fixture.virtualMachineDirectory.appendingPathComponent(entry)
            try Data("retain even malformed evidence".utf8).write(to: file)
            await requireRejected { try await f.discard() }
            XCTAssertEqual(try Data(contentsOf: file), Data("retain even malformed evidence".utf8))
            XCTAssertNil(try LumeVirtualMachineDeletionIntent.load(workspace: f.workspace, name: f.name))
        }
    }

    func testLegacyAndUnownedVMsAreNotAdoptedForDiscard() async throws {
        let legacy = try FakeLumeFixture()
        defer { try? legacy.remove() }
        let runtime = try legacy.makeRuntime(hostRuntimeLease: legacy.makeTestHostRuntimeAuthority().acquireSandbox())
        let identity = try LumeVirtualMachineOwnership.requireOwned(name: legacy.virtualMachineName, owner: .baseTemplate, in: legacy.storage)
        await requireRejected { try await runtime.discardUnqualifiedBase(name: legacy.virtualMachineName, installationID: identity.installationID) }
        try FileManager.default.removeItem(at: legacy.ownershipMarker)
        await requireRejected { try await runtime.discardUnqualifiedBase(name: legacy.virtualMachineName, installationID: identity.installationID) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.virtualMachineDirectory.path))
    }

    func testExactDiscardIntentRecoversAfterNativeRemovedOwnershipAndInventory() async throws {
        let f = try await fixture()
        defer { try? f.fixture.remove() }
        let intent = try f.intent()
        try FileManager.default.removeItem(at: f.fixture.ownershipMarker)
        try FileManager.default.removeItem(at: f.fixture.state)
        let remaining = f.fixture.virtualMachineDirectory.appendingPathComponent("remaining-disk")
        try Data("partial native removal".utf8).write(to: remaining)
        await requireRejected { try await f.runtime.discardUnqualifiedBase(name: f.name, installationID: UUID()) }
        XCTAssertEqual(try LumeVirtualMachineDeletionIntent.load(workspace: f.workspace, name: f.name), intent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remaining.path))
        // A new actor/runtime resolves only the durable discard intent.
        let restarted = try f.fixture.makeRuntime(hostRuntimeLease: f.runtimeLease)
        try await restarted.discardUnqualifiedBase(name: f.name, installationID: f.installationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.fixture.virtualMachineDirectory.path))
        XCTAssertNil(try LumeVirtualMachineDeletionIntent.load(workspace: f.workspace, name: f.name))
    }

    func testReplacementDirectoryIsPreservedDuringDiscardRecovery() async throws {
        let f = try await fixture()
        defer { try? f.fixture.remove() }
        _ = try f.intent()
        let original = f.fixture.directory.appendingPathComponent("original-base")
        try FileManager.default.moveItem(at: f.fixture.virtualMachineDirectory, to: original)
        try FileManager.default.createDirectory(at: f.fixture.virtualMachineDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let sentinel = f.fixture.virtualMachineDirectory.appendingPathComponent("unrelated")
        try Data("preserve".utf8).write(to: sentinel)
        await requireRejected { try await f.discard() }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertNotNil(try LumeVirtualMachineDeletionIntent.load(workspace: f.workspace, name: f.name))
    }

    func testGenericDeletionIntentCannotBeReinterpretedAsFailedBaseDiscard() async throws {
        let f = try await fixture()
        defer { try? f.fixture.remove() }
        _ = try LumeVirtualMachineDeletionIntent.persist(workspace: f.workspace, name: f.name, scope: nil,
            installationID: f.installationID)
        await requireRejected { try await f.discard() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.fixture.ownershipMarker.path))
    }

    func testMachineAuthorityAndCandidateOperationLockAreRequired() async throws {
        let f = try await fixture()
        defer { try? f.fixture.remove() }
        let noAuthority = try f.fixture.makeRuntime()
        await requireRejected { try await noAuthority.discardUnqualifiedBase(name: f.name, installationID: f.installationID) }
        let preparation = try LumeBaseCandidateOperationGuard(name: f.name, storage: f.fixture.storage)
        await requireRejected { try await f.discard() }
        withExtendedLifetime(preparation) {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.fixture.ownershipMarker.path))
    }

    func testPendingRootMaintenanceBlocksFreshAndRecoveredDiscard() async throws {
        for recovering in [false, true] {
            let f = try await fixture()
            defer { try? f.fixture.remove() }
            if recovering { _ = try f.intent() }
            let fence = f.fixture.virtualMachineDirectory.appendingPathComponent(LumeOfflineOperationFence.fileName)
            try Data("root operation may still own an attached image".utf8).write(to: fence)
            await requireRejected { try await f.discard() }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fence.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.fixture.ownershipMarker.path))
            XCTAssertEqual(try LumeVirtualMachineDeletionIntent.load(workspace: f.workspace, name: f.name) != nil, recovering)
        }
    }

    private func fixture() async throws -> Fixture {
        let value = try FakeLumeFixture(initialState: nil)
        let lease = try value.makeTestHostRuntimeAuthority().acquireSandbox()
        let runtime = try value.makeRuntime(hostRuntimeLease: lease)
        let specification = try SandboxVirtualMachineSpecification(name: value.virtualMachineName,
            resources: .macOSSmall(), imageSource: .appleRestore(url: value.restoreImage),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte)
        do { try await runtime.create(specification) }
        catch { try? value.remove(); throw error }
        let identity = try LumeVirtualMachineOwnership.requireOwned(name: value.virtualMachineName, owner: .baseTemplate, in: value.storage)
        return Fixture(fixture: value, runtime: runtime, runtimeLease: lease, specification: specification,
            installationID: identity.installationID)
    }

    private func requireRejected(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("unsafe base discard succeeded", file: file, line: line) }
        catch {}
    }
}

private struct Fixture {
    let fixture: FakeLumeFixture
    let runtime: LumeVirtualMachineRuntime
    let runtimeLease: HostRuntimeLease
    let specification: SandboxVirtualMachineSpecification
    let installationID: UUID
    var name: String { fixture.virtualMachineName }
    var workspace: LumeRuntimeWorkspace { .init(storageDirectory: fixture.storage) }
    func discard() async throws { try await runtime.discardUnqualifiedBase(name: name, installationID: installationID) }
    func intent() throws -> LumeVirtualMachineDeletionIntent {
        try .persist(workspace: workspace, name: name, scope: nil, installationID: installationID, unqualifiedBase: true)
    }
}
