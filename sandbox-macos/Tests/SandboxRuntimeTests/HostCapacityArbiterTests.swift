import Darwin
import Foundation
import SandboxCore
@testable import SandboxRuntime
import XCTest

final class HostCapacityArbiterTests: XCTestCase {
    func testPersistsHostModeAndRequiresDrainingTransitions() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)

        assertCapacityError(.uninitialized) {
            _ = try arbiter.snapshot()
        }
        XCTAssertEqual(try arbiter.initialize().mode, .draining)
        XCTAssertEqual(try arbiter.setMode(.sandboxDedicated).mode, .sandboxDedicated)
        assertCapacityError(
            .invalidModeTransition(from: .sandboxDedicated, to: .inference)
        ) {
            _ = try arbiter.setMode(.inference)
        }
        XCTAssertEqual(try arbiter.setMode(.draining).mode, .draining)
        XCTAssertEqual(try arbiter.setMode(.inference).mode, .inference)

        let reopened = try makeArbiter(stateDirectory: stateDirectory)
        XCTAssertEqual(
            try reopened.initialize().mode,
            .inference,
            "initialization must not overwrite durable host mode"
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: stateDirectory.appendingPathComponent("capacity.json").path
        )
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        ).uint16Value
        XCTAssertEqual(permissions & 0o077, 0)
    }

    func testEnforcesTwoGuestAndAggregateResourceCapacity() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = TestWallClock(now)
        let arbiter = try makeArbiter(
            stateDirectory: stateDirectory,
            clock: clock
        )
        _ = try arbiter.initialize()
        let resources = try makeResources()
        let firstID = SandboxID()

        assertCapacityError(.hostNotAcceptingSandboxes(.draining)) {
            _ = try arbiter.reserve(
                sandboxID: firstID,
                generation: try generation(1),
                virtualMachineName: "sandbox-a",
                resources: resources,
                expiresAt: now.addingTimeInterval(120)
            )
        }
        _ = try arbiter.setMode(.sandboxDedicated)
        let first = try arbiter.reserve(
            sandboxID: firstID,
            generation: try generation(1),
            virtualMachineName: "sandbox-a",
            resources: resources,
            expiresAt: now.addingTimeInterval(120)
        )
        XCTAssertEqual(first.issuedAt, now)
        XCTAssertEqual(first.workspaceBytes, resources.workspaceBytes)
        XCTAssertEqual(
            first.bootDiskBytes,
            SandboxDiskPolicy.alpha.bootDiskBytes.lowerBound
        )
        XCTAssertEqual(
            first.reservedGrowthBytes,
            126 * SandboxResourcePolicy.gibibyte
        )
        XCTAssertEqual(
            try arbiter.reserve(
                sandboxID: firstID,
                generation: try generation(1),
                virtualMachineName: "sandbox-a",
                resources: resources,
                expiresAt: now.addingTimeInterval(180)
            ),
            first,
            "reservation retries must return the original lease"
        )
        assertCapacityError(.duplicateVirtualMachineName) {
            _ = try arbiter.reserve(
                sandboxID: SandboxID(),
                generation: try generation(1),
                virtualMachineName: "sandbox-a",
                resources: resources,
                expiresAt: now.addingTimeInterval(120)
            )
        }
        assertCapacityError(.staleFencingToken) {
            _ = try arbiter.reserve(
                sandboxID: firstID,
                generation: try generation(1),
                virtualMachineName: "sandbox-a",
                resources: try makeResources(cpuCount: 2),
                expiresAt: now.addingTimeInterval(120)
            )
        }
        _ = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-b",
            resources: resources,
            expiresAt: now.addingTimeInterval(120)
        )
        assertCapacityError(.capacityExhausted) {
            _ = try arbiter.reserve(
                sandboxID: SandboxID(),
                generation: try generation(1),
                virtualMachineName: "sandbox-c",
                resources: resources,
                expiresAt: now.addingTimeInterval(120)
            )
        }
        clock.set(now.addingTimeInterval(121))
        XCTAssertEqual(
            try arbiter.expiredLeases().count,
            2
        )
        XCTAssertEqual(
            try arbiter.snapshot().leases.count,
            2,
            "expiry discovery must not reclaim capacity before VM cleanup"
        )
    }

    func testEnforcesAggregateBootAndWorkspaceGrowthReservation() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let arbiter = try makeArbiter(
            stateDirectory: stateDirectory,
            maximumGrowthGiB: 151
        )
        try initializeDedicated(arbiter)
        _ = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-workspace-a",
            resources: try makeResources(workspaceGiB: 50),
            expiresAt: now.addingTimeInterval(120)
        )

        assertCapacityError(.capacityExhausted) {
            _ = try arbiter.reserve(
                sandboxID: SandboxID(),
                generation: try generation(1),
                virtualMachineName: "sandbox-workspace-b",
                resources: try makeResources(workspaceGiB: 25),
                expiresAt: now.addingTimeInterval(120)
            )
        }
    }

    func testStorageHeadroomIsRevalidatedAgainstLiveAvailability() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = TestWallClock(now)
        let storage = TestStorageAvailability(
            300 * SandboxResourcePolicy.gibibyte
        )
        let arbiter = try SandboxHostCapacityArbiter(
            stateDirectory: stateDirectory,
            policy: SandboxCapacityPolicy(
                maximumReservedCPUCount: 8,
                maximumReservedMemoryBytes:
                    16 * SandboxResourcePolicy.gibibyte,
                maximumReservedGrowthBytes:
                    300 * SandboxResourcePolicy.gibibyte,
                storageHeadroomBytes:
                    20 * SandboxResourcePolicy.gibibyte
            ),
            currentDate: { clock.now() },
            availableStorageBytes: { storage.available() }
        )
        try initializeDedicated(arbiter)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-storage-headroom",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )
        XCTAssertEqual(
            try arbiter.validateStorageHeadroom().reservedGrowthBytes,
            lease.reservedGrowthBytes
        )
        storage.set(145 * SandboxResourcePolicy.gibibyte)

        assertCapacityError(.insufficientHostStorage(
            needed: 146 * SandboxResourcePolicy.gibibyte,
            available: 145 * SandboxResourcePolicy.gibibyte
        )) {
            _ = try arbiter.validateStorageHeadroom()
        }
    }

    func testPersistedStorageIdentityRejectsAnotherRuntimeVolume() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        _ = try arbiter.initialize()
        let differentIdentity = SandboxStorageVolumeIdentity(
            canonicalPath: "/private/var/db/darkbloom/other-storage",
            device: 99,
            inode: 101
        )
        let reopened = try SandboxHostCapacityArbiter(
            stateDirectory: stateDirectory,
            policy: SandboxCapacityPolicy(
                maximumReservedCPUCount: 8,
                maximumReservedMemoryBytes:
                    16 * SandboxResourcePolicy.gibibyte,
                maximumReservedGrowthBytes:
                    300 * SandboxResourcePolicy.gibibyte,
                storageHeadroomBytes:
                    20 * SandboxResourcePolicy.gibibyte
            ),
            storageIdentity: differentIdentity,
            currentDate: { Date(timeIntervalSince1970: 2_000_000_000) },
            availableStorageBytes: { UInt64.max }
        )

        assertCapacityError(.storageIdentityMismatch) {
            _ = try reopened.snapshot()
        }
    }

    func testRejectedIdentifiersDoNotCreateDurableLeaseLocks() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        _ = try arbiter.initialize()
        let rejectedID = SandboxID()
        let scope = SandboxOperationScope(
            sandboxID: rejectedID,
            generation: try generation(1),
            fencingToken: try fencingToken(1)
        )

        assertCapacityError(.hostNotAcceptingSandboxes(.draining)) {
            _ = try arbiter.reserve(
                sandboxID: rejectedID,
                generation: scope.generation,
                virtualMachineName: "sandbox-rejected",
                resources: try makeResources(),
                expiresAt: Date(timeIntervalSince1970: 2_000_000_120)
            )
        }
        assertCapacityError(.leaseNotFound) {
            _ = try arbiter.renew(
                scope: scope,
                expiresAt: Date(timeIntervalSince1970: 2_000_000_120)
            )
        }

        let lockFiles = try FileManager.default.contentsOfDirectory(
            atPath: stateDirectory.path
        ).filter { $0.hasPrefix("lease-slot-") }
        XCTAssertTrue(lockFiles.isEmpty)
    }

    func testFencingRejectsStaleCommandsAndSurvivesRestart() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        try initializeDedicated(arbiter)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let sandboxID = SandboxID()
        let firstGeneration = try generation(1)
        let secondGeneration = try generation(2)
        let first = try arbiter.reserve(
            sandboxID: sandboxID,
            generation: firstGeneration,
            virtualMachineName: "sandbox-fenced",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )

        assertCapacityError(.activeSandboxGeneration(
            existing: firstGeneration,
            requested: secondGeneration
        )) {
            _ = try arbiter.reserve(
                sandboxID: sandboxID,
                generation: secondGeneration,
                virtualMachineName: "sandbox-replacement",
                resources: try makeResources(),
                expiresAt: now.addingTimeInterval(120)
            )
        }
        let unissuedScope = SandboxOperationScope(
            sandboxID: sandboxID,
            generation: firstGeneration,
            fencingToken: try fencingToken(UInt64.max)
        )
        assertCapacityError(.staleFencingToken) {
            _ = try arbiter.renew(
                scope: unissuedScope,
                expiresAt: now.addingTimeInterval(180)
            )
        }
        let renewed = try arbiter.renew(
            scope: first.scope,
            expiresAt: now.addingTimeInterval(180)
        )
        XCTAssertEqual(renewed.expiresAt, now.addingTimeInterval(180))
        XCTAssertGreaterThan(
            renewed.scope.fencingToken,
            first.scope.fencingToken
        )
        assertCapacityError(.invalidLeaseDeadline) {
            _ = try arbiter.renew(
                scope: renewed.scope,
                expiresAt: now.addingTimeInterval(170)
            )
        }
        assertCapacityError(.staleFencingToken) {
            try arbiter.release(scope: unissuedScope)
        }
        assertCapacityError(.staleFencingToken) {
            try arbiter.release(scope: first.scope)
        }
        try arbiter.release(scope: renewed.scope)

        let reopened = try makeArbiter(stateDirectory: stateDirectory)
        assertCapacityError(.staleSandboxGeneration(
            highest: firstGeneration,
            requested: firstGeneration
        )) {
            _ = try reopened.reserve(
                sandboxID: sandboxID,
                generation: firstGeneration,
                virtualMachineName: "sandbox-replayed-generation",
                resources: try makeResources(),
                expiresAt: now.addingTimeInterval(120)
            )
        }
        let second = try reopened.reserve(
            sandboxID: sandboxID,
            generation: secondGeneration,
            virtualMachineName: "sandbox-replacement",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )
        XCTAssertGreaterThan(
            second.scope.fencingToken,
            first.scope.fencingToken,
            "released fencing tokens must never be reused after restart"
        )
        try reopened.release(scope: second.scope)
        let reopenedAgain = try makeArbiter(stateDirectory: stateDirectory)
        assertCapacityError(.staleSandboxGeneration(
            highest: secondGeneration,
            requested: secondGeneration
        )) {
            _ = try reopenedAgain.reserve(
                sandboxID: sandboxID,
                generation: secondGeneration,
                virtualMachineName: "sandbox-replayed-second-generation",
                resources: try makeResources(),
                expiresAt: now.addingTimeInterval(120)
            )
        }
    }

    func testMutationAuthorizationBindsLeaseScopeNameResourcesAndLifetime() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = TestWallClock(now)
        let arbiter = try makeArbiter(
            stateDirectory: stateDirectory,
            clock: clock
        )
        try initializeDedicated(arbiter)
        let resources = try makeResources()
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-authorized",
            resources: resources,
            expiresAt: now.addingTimeInterval(120)
        )

        XCTAssertEqual(
            try arbiter.authorize(
                scope: lease.scope,
                virtualMachineName: lease.virtualMachineName,
                operation: .create,
                resources: resources
            ),
            lease
        )
        assertCapacityError(.leaseVirtualMachineMismatch) {
            _ = try arbiter.authorize(
                scope: lease.scope,
                virtualMachineName: "sandbox-other",
                operation: .start
            )
        }
        assertCapacityError(.leaseResourceMismatch) {
            _ = try arbiter.authorize(
                scope: lease.scope,
                virtualMachineName: lease.virtualMachineName,
                operation: .create,
                resources: try makeResources(cpuCount: 2)
            )
        }
        assertCapacityError(.leaseResourceMismatch) {
            _ = try arbiter.authorize(
                scope: lease.scope,
                virtualMachineName: lease.virtualMachineName,
                operation: .create,
                resources: try makeResources(workspaceGiB: 50)
            )
        }
        assertCapacityError(.leaseResourceMismatch) {
            _ = try arbiter.authorize(
                scope: lease.scope,
                virtualMachineName: lease.virtualMachineName,
                operation: .create,
                bootDiskBytes: 99 * SandboxResourcePolicy.gibibyte
            )
        }
        let staleScope = SandboxOperationScope(
            sandboxID: lease.scope.sandboxID,
            generation: lease.scope.generation,
            fencingToken: try fencingToken(UInt64.max)
        )
        assertCapacityError(.staleFencingToken) {
            _ = try arbiter.authorize(
                scope: staleScope,
                virtualMachineName: lease.virtualMachineName,
                operation: .execute
            )
        }
        clock.set(lease.expiresAt)
        assertCapacityError(.leaseExpired) {
            _ = try arbiter.authorize(
                scope: lease.scope,
                virtualMachineName: lease.virtualMachineName,
                operation: .execute
            )
        }
        XCTAssertEqual(
            try arbiter.authorize(
                scope: lease.scope,
                virtualMachineName: lease.virtualMachineName,
                operation: .stop
            ),
            lease,
            "expired leases must retain cleanup authority"
        )

        _ = try arbiter.setMode(.draining)
        assertCapacityError(.hostNotAcceptingSandboxes(.draining)) {
            _ = try arbiter.authorize(
                scope: lease.scope,
                virtualMachineName: lease.virtualMachineName,
                operation: .inspect
            )
        }
        XCTAssertEqual(
            try arbiter.authorize(
                scope: lease.scope,
                virtualMachineName: lease.virtualMachineName,
                operation: .delete
            ),
            lease,
            "draining hosts must retain cleanup authority"
        )
    }

    func testConcurrentReservationsCannotOverbookHost() async throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        try initializeDedicated(arbiter)
        let resources = try makeResources()
        let generation = try generation(1)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        let outcomes = await withTaskGroup(
            of: ReservationOutcome.self,
            returning: [ReservationOutcome].self
        ) { group in
            for index in 0..<8 {
                group.addTask {
                    do {
                        _ = try arbiter.reserve(
                            sandboxID: SandboxID(),
                            generation: generation,
                            virtualMachineName: "sandbox-concurrent-\(index)",
                            resources: resources,
                            expiresAt: now.addingTimeInterval(120)
                        )
                        return .reserved
                    } catch let error as SandboxCapacityError {
                        if error == .capacityExhausted {
                            return .exhausted
                        }
                        return .failed(error.description)
                    } catch {
                        return .failed(String(describing: error))
                    }
                }
            }
            var outcomes: [ReservationOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }

        XCTAssertEqual(outcomes.filter { $0 == .reserved }.count, 2)
        XCTAssertEqual(outcomes.filter { $0 == .exhausted }.count, 6)
        XCTAssertFalse(outcomes.contains {
            if case .failed = $0 {
                return true
            }
            return false
        }, "\(outcomes)")
        XCTAssertEqual(try arbiter.snapshot().leases.count, 2)
    }

    func testRenewRejectsExpiredLeaseAndDrainingHost() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = TestWallClock(now)
        let arbiter = try makeArbiter(
            stateDirectory: stateDirectory,
            clock: clock
        )
        try initializeDedicated(arbiter)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-renewal",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )

        clock.set(now.addingTimeInterval(121))
        assertCapacityError(.leaseExpired) {
            _ = try arbiter.renew(
                scope: lease.scope,
                expiresAt: now.addingTimeInterval(240)
            )
        }
        assertCapacityError(.leaseExpired) {
            _ = try arbiter.reserve(
                sandboxID: lease.scope.sandboxID,
                generation: lease.scope.generation,
                virtualMachineName: lease.virtualMachineName,
                resources: try makeResources(),
                expiresAt: now.addingTimeInterval(240)
            )
        }
        _ = try arbiter.setMode(.draining)
        assertCapacityError(.hostNotAcceptingSandboxes(.draining)) {
            _ = try arbiter.renew(
                scope: lease.scope,
                expiresAt: now.addingTimeInterval(180)
            )
        }
    }

    func testExpiryFenceRotatesAuthorityBeforeCleanup() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = TestWallClock(now)
        let arbiter = try makeArbiter(
            stateDirectory: stateDirectory,
            clock: clock
        )
        try initializeDedicated(arbiter)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-expiry-fence",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )
        assertCapacityError(.leaseNotExpired) {
            _ = try arbiter.fenceExpiredLease(scope: lease.scope)
        }
        clock.set(lease.expiresAt)

        let fenced = try arbiter.fenceExpiredLease(scope: lease.scope)

        XCTAssertEqual(fenced.expiresAt, lease.expiresAt)
        XCTAssertGreaterThan(
            fenced.scope.fencingToken,
            lease.scope.fencingToken
        )
        assertCapacityError(.staleFencingToken) {
            try arbiter.release(scope: lease.scope)
        }
        XCTAssertEqual(
            try arbiter.authorize(
                scope: fenced.scope,
                virtualMachineName: fenced.virtualMachineName,
                operation: .stop
            ),
            fenced
        )
        XCTAssertEqual(
            try XCTUnwrap(arbiter.expiredLeases().first),
            fenced
        )
        let refenced = try arbiter.fenceExpiredLease(scope: fenced.scope)
        XCTAssertGreaterThan(
            refenced.scope.fencingToken,
            fenced.scope.fencingToken,
            "a crash retry must durably revoke the prior cleanup attempt"
        )
    }

    func testRenewReportsUncertainPublicationAfterDirectorySyncError() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = TestWallClock(now)
        let synchronizer = TestDirectorySynchronizer()
        let arbiter = try SandboxHostCapacityArbiter(
            stateDirectory: stateDirectory,
            policy: SandboxCapacityPolicy(
                maximumReservedCPUCount: 8,
                maximumReservedMemoryBytes:
                    16 * SandboxResourcePolicy.gibibyte,
                maximumReservedGrowthBytes:
                    300 * SandboxResourcePolicy.gibibyte,
                storageHeadroomBytes:
                    20 * SandboxResourcePolicy.gibibyte
            ),
            currentDate: { clock.now() },
            availableStorageBytes: { UInt64.max },
            directorySynchronizationError: {
                synchronizer.synchronizationError(for: $0)
            }
        )
        try initializeDedicated(arbiter)
        let initial = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-sync-recovery",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )
        synchronizer.fail(with: EIO)

        assertCapacityError(.publicationUncertain(EIO)) {
            _ = try arbiter.renew(
                scope: initial.scope,
                expiresAt: now.addingTimeInterval(240)
            )
        }
        let visible = try XCTUnwrap(arbiter.snapshot().leases.first)
        XCTAssertNotEqual(
            visible.scope.fencingToken,
            initial.scope.fencingToken,
            "visible state does not make the failed durability barrier safe"
        )
    }

    func testRenewalWaitsForAuthorizedMutationToReleaseFence() async throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = TestWallClock(now)
        let arbiter = try makeArbiter(
            stateDirectory: stateDirectory,
            clock: clock
        )
        try initializeDedicated(arbiter)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-linearized",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )
        var authorization: SandboxLeaseMutationAuthorization? =
            try arbiter.authorizeMutation(
                scope: lease.scope,
                virtualMachineName: lease.virtualMachineName,
                operation: .execute
            )
        assertCapacityError(.leaseOperationInProgress) {
            _ = try arbiter.authorizeMutation(
                scope: lease.scope,
                virtualMachineName: "sandbox-other-name",
                operation: .start
            )
        }
        let status = RenewalStatus()
        let renewal = Task.detached {
            await status.markStarted()
            do {
                let renewed = try arbiter.renew(
                    scope: lease.scope,
                    expiresAt: now.addingTimeInterval(180)
                )
                await status.markCompleted()
                return renewed
            } catch {
                await status.markCompleted()
                throw error
            }
        }

        while !(await status.started) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let completedWhileAuthorized = await status.completed
        XCTAssertFalse(
            completedWhileAuthorized,
            "renewal must not rotate a fence during an authorized mutation"
        )
        XCTAssertNotNil(authorization)
        authorization = nil

        let renewed = try await renewal.value
        XCTAssertGreaterThan(
            renewed.scope.fencingToken,
            lease.scope.fencingToken
        )
        let completedAfterRelease = await status.completed
        XCTAssertTrue(completedAfterRelease)
    }

    func testBlockedRenewalSamplesAuthoritativeTimeAfterFence() async throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = TestWallClock(now)
        let arbiter = try makeArbiter(
            stateDirectory: stateDirectory,
            clock: clock
        )
        try initializeDedicated(arbiter)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-expiring-fence",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )
        var authorization: SandboxLeaseMutationAuthorization? =
            try arbiter.authorizeMutation(
                scope: lease.scope,
                virtualMachineName: lease.virtualMachineName,
                operation: .execute
            )
        let status = RenewalStatus()
        let renewal = Task.detached {
            await status.markStarted()
            return try arbiter.renew(
                scope: lease.scope,
                expiresAt: now.addingTimeInterval(180)
            )
        }

        while !(await status.started) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        clock.set(lease.expiresAt)
        XCTAssertNotNil(authorization)
        authorization = nil

        do {
            _ = try await renewal.value
            XCTFail("renewal blocked past expiry must fail")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .leaseExpired)
        }
        XCTAssertEqual(
            try arbiter.snapshot().leases.first,
            lease,
            "failed renewal must not rotate the fencing token or deadline"
        )
    }

    func testRejectsInsecureAndCorruptPersistentState() throws {
        let insecureDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: insecureDirectory) }
        try FileManager.default.createDirectory(
            at: insecureDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: insecureDirectory.path
        )
        let insecure = try makeArbiter(stateDirectory: insecureDirectory)
        assertCapacityError(.unsafeStatePath) {
            _ = try insecure.initialize()
        }

        let corruptDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: corruptDirectory) }
        let corrupt = try makeArbiter(stateDirectory: corruptDirectory)
        _ = try corrupt.initialize()
        let stateURL = corruptDirectory.appendingPathComponent("capacity.json")
        try Data("{}".utf8).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )
        assertCapacityError(.corruptState) {
            _ = try corrupt.snapshot()
        }
    }

    func testRejectsSymlinkedStateAncestor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-capacity-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        let target = root.appendingPathComponent("target", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: target
        )
        let arbiter = try makeArbiter(
            stateDirectory: alias.appendingPathComponent(
                "capacity",
                isDirectory: true
            )
        )

        assertCapacityError(.unsafeStatePath) {
            _ = try arbiter.initialize()
        }
    }

    func testRejectsWritableStateAncestor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-capacity-ancestor-\(UUID().uuidString)",
            isDirectory: true
        )
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(
            at: shared,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777]
        )
        guard chmod(shared.path, 0o777) == 0 else {
            throw POSIXError(.EACCES)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let arbiter = try makeArbiter(
            stateDirectory: shared.appendingPathComponent(
                "capacity",
                isDirectory: true
            )
        )

        assertCapacityError(.unsafeStatePath) {
            _ = try arbiter.initialize()
        }
    }

    func testRejectsExtendedACLOnStateDirectory() throws {
        let stateDirectory = temporaryStateDirectory()
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        try addInheritableACL(to: stateDirectory)
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)

        assertCapacityError(.unsafeStatePath) {
            _ = try arbiter.initialize()
        }
    }

    func testRejectsHardlinkedStateFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-capacity-hardlink-\(UUID().uuidString)",
            isDirectory: true
        )
        let stateDirectory = root.appendingPathComponent(
            "state",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        _ = try arbiter.initialize()
        try FileManager.default.linkItem(
            at: stateDirectory.appendingPathComponent("capacity.json"),
            to: root.appendingPathComponent("capacity.json.alias")
        )

        assertCapacityError(.unsafeStatePath) {
            _ = try arbiter.snapshot()
        }
    }

    func testRejectsHardlinkedLeaseLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-lease-lock-hardlink-\(UUID().uuidString)",
            isDirectory: true
        )
        let stateDirectory = root.appendingPathComponent(
            "state",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        try initializeDedicated(arbiter)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let sandboxID = SandboxID()
        let lease = try arbiter.reserve(
            sandboxID: sandboxID,
            generation: try generation(1),
            virtualMachineName: "sandbox-lock-hardlink",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )
        let lockName = SandboxCapacityStateStore.leaseOperationLockName(
            for: sandboxID
        )
        try FileManager.default.linkItem(
            at: stateDirectory.appendingPathComponent(lockName),
            to: root.appendingPathComponent("\(lockName).alias")
        )

        assertCapacityError(.unsafeStatePath) {
            _ = try arbiter.renew(
                scope: lease.scope,
                expiresAt: now.addingTimeInterval(240)
            )
        }
    }

    func testRejectsInferenceModeWithPersistedLease() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        try initializeDedicated(arbiter)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-active",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )

        let stateURL = stateDirectory.appendingPathComponent("capacity.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        object["mode"] = SandboxHostMode.inference.rawValue
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )

        assertCapacityError(.corruptState) {
            _ = try arbiter.snapshot()
        }
    }

    func testRejectsLegacyActiveStateWithoutCompleteGenerationHistory() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        try initializeDedicated(arbiter)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try generation(3),
            virtualMachineName: "sandbox-legacy-generation",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )
        let stateURL = stateDirectory.appendingPathComponent("capacity.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        object["schemaVersion"] = 1
        object.removeValue(forKey: "generationHighWatermarks")
        var legacyLeases = try XCTUnwrap(
            object["leases"] as? [[String: Any]]
        )
        legacyLeases[0].removeValue(forKey: "workspaceBytes")
        legacyLeases[0].removeValue(forKey: "bootDiskBytes")
        legacyLeases[0].removeValue(forKey: "reservedGrowthBytes")
        object["leases"] = legacyLeases
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )

        let reopened = try makeArbiter(stateDirectory: stateDirectory)
        assertCapacityError(.corruptState) {
            _ = try reopened.snapshot()
        }
    }

    func testRejectsLegacyEmptyStateWithoutGenerationHistory() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        _ = try arbiter.initialize()
        let stateURL = stateDirectory.appendingPathComponent("capacity.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        object["schemaVersion"] = 1
        object.removeValue(forKey: "generationHighWatermarks")
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )

        assertCapacityError(.corruptState) {
            _ = try arbiter.snapshot()
        }
    }

    func testGenerationHistoryCapacityFailsClosed() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        try initializeDedicated(arbiter)
        let firstGeneration = try generation(1)
        let state = SandboxCapacityState(
            mode: .sandboxDedicated,
            nextFencingToken: 1,
            leases: [],
            generationHighWatermarks: (
                0..<SandboxCapacityState.maximumGenerationHighWatermarks
            ).map { _ in
                SandboxGenerationHighWatermark(
                    sandboxID: SandboxID(),
                    generation: firstGeneration
                )
            },
            storageIdentity: testStorageIdentity(for: stateDirectory)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let stateURL = stateDirectory.appendingPathComponent("capacity.json")
        try encoder.encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )

        assertCapacityError(.generationHistoryExhausted) {
            _ = try arbiter.reserve(
                sandboxID: SandboxID(),
                generation: try generation(1),
                virtualMachineName: "sandbox-history-full",
                resources: try makeResources(),
                expiresAt: Date(timeIntervalSince1970: 2_000_000_120)
            )
        }
    }

    private func makeArbiter(
        stateDirectory: URL,
        maximumCPUCount: UInt16 = 8,
        maximumMemoryGiB: UInt64 = 16,
        maximumGrowthGiB: UInt64 = 300,
        availableStorageBytes: UInt64 = UInt64.max,
        clock: TestWallClock? = nil
    ) throws -> SandboxHostCapacityArbiter {
        let clock = clock ?? TestWallClock(
            Date(timeIntervalSince1970: 2_000_000_000)
        )
        return try SandboxHostCapacityArbiter(
            stateDirectory: stateDirectory,
            policy: SandboxCapacityPolicy(
                maximumReservedCPUCount: maximumCPUCount,
                maximumReservedMemoryBytes: maximumMemoryGiB
                    * SandboxResourcePolicy.gibibyte,
                maximumReservedGrowthBytes: maximumGrowthGiB
                    * SandboxResourcePolicy.gibibyte,
                storageHeadroomBytes:
                    20 * SandboxResourcePolicy.gibibyte
            ),
            currentDate: { clock.now() },
            availableStorageBytes: { availableStorageBytes }
        )
    }

    private func makeResources(
        cpuCount: UInt16 = 4,
        memoryGiB: UInt64 = 8,
        workspaceGiB: UInt64 = 25
    ) throws -> SandboxResourceSpecification {
        try SandboxResourceSpecification(
            cpuCount: cpuCount,
            memoryBytes: memoryGiB * SandboxResourcePolicy.gibibyte,
            workspaceBytes: workspaceGiB * SandboxResourcePolicy.gibibyte,
            commandTimeoutSeconds: 900
        )
    }

    private func testStorageIdentity(
        for stateDirectory: URL
    ) -> SandboxStorageVolumeIdentity {
        SandboxStorageVolumeIdentity(
            canonicalPath: stateDirectory.standardizedFileURL.path
                + "/test-storage",
            device: 0,
            inode: 0
        )
    }

    private func initializeDedicated(
        _ arbiter: SandboxHostCapacityArbiter
    ) throws {
        _ = try arbiter.initialize()
        _ = try arbiter.setMode(.sandboxDedicated)
    }

    private func generation(_ value: UInt64) throws -> SandboxGeneration {
        try XCTUnwrap(SandboxGeneration(rawValue: value))
    }

    private func fencingToken(_ value: UInt64) throws -> SandboxFencingToken {
        try XCTUnwrap(SandboxFencingToken(rawValue: value))
    }

    private func temporaryStateDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-capacity-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func addInheritableACL(to url: URL) throws {
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = [
            "+a",
            "everyone allow read,write,execute,file_inherit,directory_inherit",
            url.path,
        ]
        try chmod.run()
        chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
    }

    private func assertCapacityError(
        _ expected: SandboxCapacityError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(
            try operation(),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? SandboxCapacityError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

private enum ReservationOutcome: Equatable, Sendable {
    case reserved
    case exhausted
    case failed(String)
}

private actor RenewalStatus {
    private(set) var started = false
    private(set) var completed = false

    func markStarted() {
        started = true
    }

    func markCompleted() {
        completed = true
    }
}

private final class TestWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private final class TestStorageAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    func available() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: UInt64) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private final class TestDirectorySynchronizer: @unchecked Sendable {
    private let lock = NSLock()
    private var injectedError: Int32?

    func fail(with error: Int32) {
        lock.lock()
        injectedError = error
        lock.unlock()
    }

    func synchronizationError(for descriptor: Int32) -> Int32? {
        lock.lock()
        let error = injectedError
        lock.unlock()
        if let error {
            return error
        }
        while fsync(descriptor) != 0 {
            guard errno == EINTR else {
                return errno
            }
        }
        return nil
    }
}
