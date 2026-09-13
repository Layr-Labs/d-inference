import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeDeletionRecoveryTests: XCTestCase, @unchecked Sendable {
    func testPartialDeletionBeforeExpiryRetainsCapacityAndFreshBrokerRetries() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let clock = LumeTestWallClock(Date(timeIntervalSince1970: 2_000_000_000))
        let capacity = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try reserve(fixture, capacity: capacity, clock: clock)
        let intent = try stoppedIntent(fixture, scope: lease.scope)
        // Simulate Lume having removed its inventory and ownership marker before
        // crashing halfway through recursive deletion.
        try FileManager.default.removeItem(at: fixture.state)
        try FileManager.default.removeItem(at: fixture.ownershipMarker)
        let target = fixture.directory.appendingPathComponent("unrelated")
        try Data("preserved".utf8).write(to: target)
        let link = fixture.virtualMachineDirectory.appendingPathComponent("unsafe-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let first = try await fixture.makeLeaseFencedRuntime(capacityArbiter: capacity).reconcileExpiredLeases()
        XCTAssertEqual(first.count, 1)
        guard case .retained = first[0].outcome else { return XCTFail("incomplete deletion must retain capacity") }
        XCTAssertEqual(try capacity.snapshot().leases, [lease])
        XCTAssertEqual(try Data(contentsOf: target), Data("preserved".utf8))
        XCTAssertEqual(try LumeVirtualMachineDeletionIntent.load(workspace: workspace(fixture), name: fixture.virtualMachineName), intent)

        try FileManager.default.removeItem(at: link)
        let restarted = try fixture.makeLeaseFencedRuntime(capacityArbiter: capacity)
        let second = try await restarted.reconcileExpiredLeases()
        XCTAssertEqual(second.map(\.outcome), [.released])
        XCTAssertTrue(try capacity.snapshot().leases.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.virtualMachineDirectory.path))
        XCTAssertNil(try LumeVirtualMachineDeletionIntent.load(workspace: workspace(fixture), name: fixture.virtualMachineName))
        try await restarted.release(scope: lease.scope, name: fixture.virtualMachineName)
    }

    func testCrashAfterTreeRemovalBeforeCapacityReleaseRecoversWithoutOwnershipMarker() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let clock = LumeTestWallClock(Date(timeIntervalSince1970: 2_000_000_000))
        let capacity = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try reserve(fixture, capacity: capacity, clock: clock)
        let intent = try stoppedIntent(fixture, scope: lease.scope)
        try intent.removeOwnedTree(workspace: workspace(fixture))
        try FileManager.default.removeItem(at: fixture.state)
        XCTAssertEqual(try capacity.snapshot().leases, [lease])
        let result = try await fixture.makeLeaseFencedRuntime(capacityArbiter: capacity).reconcileExpiredLeases()
        XCTAssertEqual(result.map(\.outcome), [.released])
        XCTAssertTrue(try capacity.snapshot().leases.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.virtualMachineDirectory.path))
    }

    func testUncertainCapacityPublicationRetainsIntentUntilDurableOrphanRecoveryWithRotatedFence() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let clock = LumeTestWallClock(Date(timeIntervalSince1970: 2_000_000_000))
        let fault = SynchronizationFault()
        let capacity = try SandboxHostCapacityArbiter(
            stateDirectory: fixture.directory.appendingPathComponent("capacity"),
            policy: SandboxCapacityPolicy(maximumReservedCPUCount: 8,
                maximumReservedMemoryBytes: 16 * SandboxResourcePolicy.gibibyte,
                maximumReservedGrowthBytes: 300 * SandboxResourcePolicy.gibibyte,
                storageHeadroomBytes: 20 * SandboxResourcePolicy.gibibyte),
            storageIdentity: SandboxStorageVolumeInspector().inspect(path: fixture.storage).identity,
            currentDate: { clock.now() }, availableStorageBytes: { UInt64.max },
            directorySynchronizationError: { descriptor in fault.synchronize(descriptor) })
        _ = try capacity.initialize()
        _ = try capacity.setMode(.sandboxDedicated)
        let lease = try reserve(fixture, capacity: capacity, clock: clock)
        _ = try stoppedIntent(fixture, scope: lease.scope)
        clock.set(lease.expiresAt)
        let fenced = try capacity.fenceExpiredLease(scope: lease.scope)
        try FileManager.default.removeItem(at: fixture.state)
        fault.setFailure(true)

        for _ in 0..<2 {
            do {
                try await fixture.makeLeaseFencedRuntime(capacityArbiter: capacity)
                    .deleteAndRelease(scope: fenced.scope, name: fixture.virtualMachineName)
                XCTFail("visible release must not conceal failed directory synchronization")
            } catch let error as SandboxCapacityError {
                XCTAssertEqual(error, .publicationUncertain(EIO))
            }
            XCTAssertTrue(try capacity.snapshot().leases.isEmpty)
            XCTAssertNotNil(try LumeVirtualMachineDeletionIntent.load(workspace: workspace(fixture), name: fixture.virtualMachineName))
        }
        // No active lease remains to drive the normal expiry scan. Enumerating
        // release intents must recover with the newer durable fencing token.
        fault.setFailure(false)
        let result = try await fixture.makeLeaseFencedRuntime(capacityArbiter: capacity).reconcileExpiredLeases()
        XCTAssertTrue(result.isEmpty)
        XCTAssertNil(try LumeVirtualMachineDeletionIntent.load(workspace: workspace(fixture), name: fixture.virtualMachineName))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.virtualMachineDirectory.path))
    }

    func testPendingDeletionFencesCreateStartAndCommandBeforeExpiry() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let clock = LumeTestWallClock(Date(timeIntervalSince1970: 2_000_000_000))
        let capacity = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try reserve(fixture, capacity: capacity, clock: clock)
        _ = try stoppedIntent(fixture, scope: lease.scope)
        let runtime = try fixture.makeLeaseFencedRuntime(capacityArbiter: capacity,
            guestCommandPolicy: .baseImagePreparationAndDevelopment)
        for operation in 0..<3 {
            do {
                switch operation {
                case 0:
                    try await runtime.create(scope: lease.scope,
                        specification: SandboxVirtualMachineSpecification(name: fixture.virtualMachineName,
                            resources: SandboxResourceSpecification.macOSSmall(),
                            imageSource: .restoreImage(url: fixture.restoreImage, unattendedPreset: "tahoe"),
                            diskBytes: 100 * SandboxResourcePolicy.gibibyte))
                case 1: try await runtime.start(scope: lease.scope, name: fixture.virtualMachineName)
                default:
                    _ = try await runtime.execute(scope: lease.scope, name: fixture.virtualMachineName,
                        request: SandboxGuestCommandRequest(idempotencyKey: UUID(), executable: "/usr/bin/true"))
                }
                XCTFail("pending deletion must reject new work")
            } catch {
                XCTAssertTrue(String(describing: error).contains("pending deletion"), "\(error)")
            }
        }
        XCTAssertEqual(try capacity.snapshot().leases, [lease])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.guestCommandStarted.path))
    }

    private func workspace(_ fixture: FakeLumeFixture) -> LumeRuntimeWorkspace {
        LumeRuntimeWorkspace(storageDirectory: fixture.storage)
    }

    private func reserve(_ fixture: FakeLumeFixture, capacity: SandboxHostCapacityArbiter,
                         clock: LumeTestWallClock) throws -> SandboxCapacityLease {
        let lease = try capacity.reserve(sandboxID: SandboxID(), generation: SandboxGeneration(rawValue: 1)!,
            virtualMachineName: fixture.virtualMachineName, resources: SandboxResourceSpecification.macOSSmall(),
            expiresAt: clock.now().addingTimeInterval(60))
        try fixture.bindOwnership(to: lease.scope)
        return lease
    }

    private func stoppedIntent(_ fixture: FakeLumeFixture, scope: SandboxOperationScope) throws -> LumeVirtualMachineDeletionIntent {
        let ownership = try LumeVirtualMachineOwnership.requireOwned(name: fixture.virtualMachineName,
            owner: .init(operationScope: scope), in: fixture.storage)
        return try LumeVirtualMachineDeletionIntent.persist(workspace: workspace(fixture),
            name: fixture.virtualMachineName, scope: scope, installationID: ownership.installationID)
    }
}

private final class SynchronizationFault: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    func setFailure(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }
    func synchronize(_ descriptor: Int32) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        if failing { return EIO }
        return fsync(descriptor) == 0 ? nil : errno
    }
}
