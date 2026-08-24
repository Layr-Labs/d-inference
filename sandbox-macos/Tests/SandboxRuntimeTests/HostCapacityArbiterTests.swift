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
        assertCapacityError(.storageIdentityMismatch) {
            _ = try SandboxHostCapacityArbiter(
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
                currentDate: {
                    Date(timeIntervalSince1970: 2_000_000_000)
                },
                availableStorageBytes: { UInt64.max }
            )
        }
    }

    func testReducedPolicyDurablyDrainsExistingLeases() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let original = try makeArbiter(stateDirectory: stateDirectory)
        try initializeDedicated(original)
        let first = try original.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-policy-a",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )
        let second = try original.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-policy-b",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )

        let reduced = try makeArbiter(
            stateDirectory: stateDirectory,
            maximumCPUCount: 4
        )

        XCTAssertEqual(try reduced.snapshot().mode, .draining)
        assertCapacityError(.hostNotAcceptingSandboxes(.draining)) {
            _ = try reduced.authorize(
                scope: first.scope,
                virtualMachineName: first.virtualMachineName,
                operation: .start
            )
        }
        assertCapacityError(.hostNotAcceptingSandboxes(.draining)) {
            _ = try reduced.renew(
                scope: first.scope,
                expiresAt: now.addingTimeInterval(180)
            )
        }
        XCTAssertEqual(
            try reduced.authorize(
                scope: first.scope,
                virtualMachineName: first.virtualMachineName,
                operation: .stop
            ),
            first,
            "policy fencing must retain cleanup authority"
        )
        assertCapacityError(.policyWideningRequiresExplicitAdoption) {
            _ = try makeArbiter(
                stateDirectory: stateDirectory,
                maximumCPUCount: 8
            )
        }
        XCTAssertEqual(
            try reduced.snapshot().mode,
            .draining,
            "implicit widening must leave the reduced policy and drain intact"
        )
        try releaseLease(first, using: reduced)
        try releaseLease(second, using: reduced)
        XCTAssertEqual(
            try reduced.setMode(.sandboxDedicated).mode,
            .sandboxDedicated,
            "a human may re-enable admission only after fenced leases are gone"
        )

        let reducedSnapshot = try reduced.snapshot()
        let widened = try makeArbiter(
            stateDirectory: stateDirectory,
            maximumCPUCount: 8,
            policyAdoption: .allowWidening(
                expectedPolicyRevision: reducedSnapshot.policyRevision
            )
        )
        XCTAssertEqual(
            try widened.snapshot().mode,
            .sandboxDedicated,
            "explicit widening must not alter an operator-restored host mode"
        )
        XCTAssertEqual(
            try widened.snapshot().effectivePolicy.maximumReservedCPUCount,
            8
        )
    }

    func testStaleArbiterCannotReserveAgainstReducedPolicy() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let original = try SandboxHostCapacityArbiter(
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
            currentDate: { now },
            availableStorageBytes: { UInt64.max }
        )
        try initializeDedicated(original)
        let resources = try makeResources(cpuCount: 8)
        let firstGeneration = try generation(1)

        let reduced = try makeArbiter(
            stateDirectory: stateDirectory,
            maximumCPUCount: 4
        )
        XCTAssertEqual(
            try reduced.snapshot().mode,
            .sandboxDedicated,
            "a fitting empty host need not drain when its limit is reduced"
        )

        assertCapacityError(.capacityExhausted) {
            _ = try original.reserve(
                sandboxID: SandboxID(),
                generation: firstGeneration,
                virtualMachineName: "sandbox-policy-adoption-race",
                resources: resources,
                expiresAt: now.addingTimeInterval(120)
            )
        }
        XCTAssertEqual(
            try reduced.snapshot().mode,
            .sandboxDedicated,
            "rejected stale work must not force an otherwise fitting host to drain"
        )
        XCTAssertTrue(try reduced.snapshot().leases.isEmpty)
    }

    func testConcurrentUninitializedArbitersSerializePolicyAdoption()
        async throws
    {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let publication = OneShotBlockingDirectorySynchronization()
        let contention = LeaseOperationLockContentionProbe()
        defer { publication.resume() }
        let broad = try SandboxHostCapacityArbiter(
            stateDirectory: stateDirectory,
            policy: makePolicy(maximumCPUCount: 8),
            currentDate: { now },
            availableStorageBytes: { UInt64.max },
            directorySynchronizationError: {
                publication.synchronizationError(for: $0)
            }
        )
        let reduced = try SandboxHostCapacityArbiter(
            stateDirectory: stateDirectory,
            policy: makePolicy(maximumCPUCount: 4),
            currentDate: { now },
            availableStorageBytes: { UInt64.max },
            leaseOperationLockContentionObserver: {
                contention.observe(lockName: $0)
            }
        )
        let broadInitialization = Task.detached {
            policyInitializationOutcome(broad)
        }
        guard publication.waitUntilBlocked() else {
            publication.resume()
            _ = await broadInitialization.value
            return XCTFail(
                "broad initialization did not reach its publication barrier"
            )
        }

        let reducedInitialization = Task.detached {
            policyInitializationOutcome(reduced)
        }
        guard contention.waitUntilObserved() else {
            publication.resume()
            let broadResult = await broadInitialization.value
            let reducedResult = await reducedInitialization.value
            return XCTFail(
                "reduced initialization never contended with broad adoption: "
                    + "\(broadResult), \(reducedResult)"
            )
        }
        XCTAssertEqual(contention.firstObservedLock, "lease-slot-0.lock")
        publication.resume()

        let broadResult = await broadInitialization.value
        let reducedResult = await reducedInitialization.value

        XCTAssertEqual(broadResult, .initialized)
        XCTAssertEqual(reducedResult, .initialized)
        let snapshot = try reduced.snapshot()
        XCTAssertEqual(snapshot.effectivePolicy.maximumReservedCPUCount, 4)
        XCTAssertEqual(snapshot.mode, .draining)
    }

    func testReservationRevalidatesReducedPolicyAfterStalePreview()
        async throws
    {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let storage = OneShotBlockingStorageAvailability(UInt64.max)
        let stale = try SandboxHostCapacityArbiter(
            stateDirectory: stateDirectory,
            policy: makePolicy(maximumCPUCount: 8),
            currentDate: { now },
            availableStorageBytes: { storage.available() }
        )
        try initializeDedicated(stale)
        storage.arm()
        defer { storage.resume() }
        let reservation = Task.detached {
            try stale.reserve(
                sandboxID: SandboxID(),
                generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
                virtualMachineName: "sandbox-policy-adoption-race",
                resources: try SandboxResourceSpecification(
                    cpuCount: 8,
                    memoryBytes: 8 * SandboxResourcePolicy.gibibyte,
                    workspaceBytes: 25 * SandboxResourcePolicy.gibibyte,
                    commandTimeoutSeconds: 900
                ),
                expiresAt: now.addingTimeInterval(120)
            )
        }
        guard storage.waitUntilBlocked() else {
            storage.resume()
            _ = try? await reservation.value
            return XCTFail(
                "stale reservation did not reach its preview storage probe"
            )
        }

        let reduced = try makeArbiter(
            stateDirectory: stateDirectory,
            maximumCPUCount: 4
        )
        let adopted = try reduced.snapshot()
        XCTAssertEqual(adopted.effectivePolicy.maximumReservedCPUCount, 4)
        XCTAssertEqual(adopted.mode, .sandboxDedicated)
        XCTAssertTrue(adopted.leases.isEmpty)
        storage.resume()

        do {
            _ = try await reservation.value
            XCTFail("stale broad-policy reservation must be rejected")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .capacityExhausted)
        }
        let snapshot = try reduced.snapshot()
        XCTAssertEqual(snapshot.effectivePolicy.maximumReservedCPUCount, 4)
        XCTAssertEqual(snapshot.mode, .sandboxDedicated)
        XCTAssertTrue(snapshot.leases.isEmpty)
    }

    func testReducedPolicyFenceWaitsForActiveLeaseMutation() async throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = TestWallClock(now)
        let original = try makeArbiter(
            stateDirectory: stateDirectory,
            clock: clock
        )
        try initializeDedicated(original)
        let lease = try original.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-policy-linearized",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )
        var authorization: SandboxLeaseMutationAuthorization? =
            try original.authorizeMutation(
                scope: lease.scope,
                virtualMachineName: lease.virtualMachineName,
                operation: .start
            )
        let contention = LeaseOperationLockContentionProbe()
        let reduction = Task.detached {
            try SandboxHostCapacityArbiter(
                stateDirectory: stateDirectory,
                policy: SandboxCapacityPolicy(
                    maximumReservedCPUCount: 2,
                    maximumReservedMemoryBytes:
                        16 * SandboxResourcePolicy.gibibyte,
                    maximumReservedGrowthBytes:
                        300 * SandboxResourcePolicy.gibibyte,
                    storageHeadroomBytes:
                        20 * SandboxResourcePolicy.gibibyte
                ),
                currentDate: { clock.now() },
                availableStorageBytes: { UInt64.max },
                leaseOperationLockContentionObserver: {
                    contention.observe(lockName: $0)
                }
            )
        }

        guard contention.waitUntilObserved() else {
            authorization = nil
            _ = try? await reduction.value
            return XCTFail(
                "policy adoption never encountered the held lease-mutation lock"
            )
        }
        XCTAssertEqual(
            contention.firstObservedLock,
            SandboxCapacityStateStore.leaseOperationLockName(
                for: lease.scope.sandboxID
            )
        )
        XCTAssertEqual(try original.snapshot().mode, .sandboxDedicated)
        XCTAssertNotNil(authorization)
        authorization = nil

        let reduced = try await reduction.value
        XCTAssertEqual(try reduced.snapshot().mode, .draining)
    }

    func testReducedMemoryAndGrowthPoliciesAlsoDrain() throws {
        let cases: [(name: String, memoryGiB: UInt64, growthGiB: UInt64)] = [
            ("memory", 4, 300),
            ("growth", 16, 125),
        ]
        for testCase in cases {
            let stateDirectory = temporaryStateDirectory()
            defer { try? FileManager.default.removeItem(at: stateDirectory) }
            let original = try makeArbiter(stateDirectory: stateDirectory)
            try initializeDedicated(original)
            _ = try original.reserve(
                sandboxID: SandboxID(),
                generation: try generation(1),
                virtualMachineName: "sandbox-policy-\(testCase.name)",
                resources: try makeResources(),
                expiresAt: Date(timeIntervalSince1970: 2_000_000_120)
            )

            let reduced = try makeArbiter(
                stateDirectory: stateDirectory,
                maximumMemoryGiB: testCase.memoryGiB,
                maximumGrowthGiB: testCase.growthGiB
            )

            XCTAssertEqual(
                try reduced.snapshot().mode,
                .draining,
                "\(testCase.name) reduction must durably fence existing work"
            )
        }
    }

    func testStaleRenewalUsesDurableLeaseDurationPolicy() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let original = try makeArbiter(stateDirectory: stateDirectory)
        try initializeDedicated(original)
        let lease = try original.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-policy-renewal",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(20)
        )
        let reduced = try makeArbiter(
            stateDirectory: stateDirectory,
            maximumLeaseDurationSeconds: 30
        )

        XCTAssertEqual(try reduced.snapshot().mode, .sandboxDedicated)
        assertCapacityError(.invalidLeaseDeadline) {
            _ = try original.renew(
                scope: lease.scope,
                expiresAt: now.addingTimeInterval(120)
            )
        }
        XCTAssertEqual(
            try original.authorize(
                scope: lease.scope,
                virtualMachineName: lease.virtualMachineName,
                operation: .start
            ),
            lease,
            "a fitting lease remains active under the reduced durable policy"
        )
    }

    func testDurableStoragePolicyFieldsGovernStaleArbiter() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let available = 200 * SandboxResourcePolicy.gibibyte
        let original = try makeArbiter(
            stateDirectory: stateDirectory,
            availableStorageBytes: available
        )
        try initializeDedicated(original)
        _ = try original.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-storage-policy",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )

        let reduced = try makeArbiter(
            stateDirectory: stateDirectory,
            maximumGrowthGiB: 150,
            storageHeadroomGiB: 80,
            availableStorageBytes: available
        )
        let snapshot = try reduced.snapshot()
        XCTAssertEqual(
            snapshot.mode,
            .draining,
            "stricter durable headroom must drain over-limit commitments"
        )
        XCTAssertEqual(
            snapshot.effectivePolicy.maximumReservedGrowthBytes,
            150 * SandboxResourcePolicy.gibibyte
        )
        XCTAssertEqual(
            snapshot.effectivePolicy.storageHeadroomBytes,
            80 * SandboxResourcePolicy.gibibyte
        )
        assertCapacityError(.insufficientHostStorage(
            needed: 206 * SandboxResourcePolicy.gibibyte,
            available: available
        )) {
            _ = try original.validateStorageHeadroom()
        }

        let object = try persistedStateObject(in: stateDirectory)
        let storedPolicy = try XCTUnwrap(
            object["effectivePolicy"] as? [String: Any]
        )
        XCTAssertEqual(
            (storedPolicy["maximumReservedGrowthBytes"] as? NSNumber)?
                .uint64Value,
            150 * SandboxResourcePolicy.gibibyte
        )
        XCTAssertEqual(
            (storedPolicy["storageHeadroomBytes"] as? NSNumber)?.uint64Value,
            80 * SandboxResourcePolicy.gibibyte
        )
    }

    func testExplicitWideningRequiresCurrentPolicyRevision() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let original = try makeArbiter(
            stateDirectory: stateDirectory,
            maximumCPUCount: 8
        )
        _ = try original.initialize()
        let reduced = try makeArbiter(
            stateDirectory: stateDirectory,
            maximumCPUCount: 4
        )
        let reducedSnapshot = try reduced.snapshot()

        assertCapacityError(.policyWideningRequiresExplicitAdoption) {
            _ = try makeArbiter(
                stateDirectory: stateDirectory,
                maximumCPUCount: 8
            )
        }
        assertCapacityError(.stalePolicyRevision(
            expected: reducedSnapshot.policyRevision - 1,
            actual: reducedSnapshot.policyRevision
        )) {
            _ = try makeArbiter(
                stateDirectory: stateDirectory,
                maximumCPUCount: 8,
                policyAdoption: .allowWidening(
                    expectedPolicyRevision:
                        reducedSnapshot.policyRevision - 1
                )
            )
        }
        XCTAssertEqual(
            try reduced.snapshot().effectivePolicy.maximumReservedCPUCount,
            4,
            "rejected widening must not partially update durable limits"
        )

        let widened = try makeArbiter(
            stateDirectory: stateDirectory,
            maximumCPUCount: 8,
            policyAdoption: .allowWidening(
                expectedPolicyRevision: reducedSnapshot.policyRevision
            )
        )
        XCTAssertEqual(
            try widened.snapshot().effectivePolicy.maximumReservedCPUCount,
            8
        )
        XCTAssertGreaterThan(
            try widened.snapshot().policyRevision,
            reducedSnapshot.policyRevision
        )
    }

    func testV3StateMigratesIntoDurableDrainingQuarantine() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let original = try makeArbiter(stateDirectory: stateDirectory)
        try initializeDedicated(original)
        let lease = try original.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-policy-migration",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120)
        )
        try downgradePersistedStateToV3(in: stateDirectory)

        let migrated = try makeArbiter(
            stateDirectory: stateDirectory,
            maximumCPUCount: 4
        )
        let snapshot = try migrated.snapshot()
        XCTAssertEqual(snapshot.mode, .draining)
        XCTAssertEqual(snapshot.leases, [lease])
        XCTAssertEqual(snapshot.effectivePolicy.maximumReservedCPUCount, 4)
        XCTAssertEqual(snapshot.policyRevision, 1)
        let object = try persistedStateObject(in: stateDirectory)
        XCTAssertEqual(
            (object["schemaVersion"] as? NSNumber)?.uint16Value,
            SandboxCapacityState.schemaVersion
        )
        XCTAssertNotNil(object["effectivePolicy"])
        XCTAssertNotNil(object["policyRevision"])
    }

    func testV3MigrationPublicationUncertaintyRemainsQuarantined()
        throws
    {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let original = try makeArbiter(stateDirectory: stateDirectory)
        try initializeDedicated(original)
        try downgradePersistedStateToV3(in: stateDirectory)
        let synchronizer = TestDirectorySynchronizer()
        synchronizer.fail(with: EIO)
        let policy = try makePolicy(maximumCPUCount: 4)

        assertCapacityError(.publicationUncertain(EIO)) {
            _ = try SandboxHostCapacityArbiter(
                stateDirectory: stateDirectory,
                policy: policy,
                currentDate: {
                    Date(timeIntervalSince1970: 2_000_000_000)
                },
                availableStorageBytes: { UInt64.max },
                directorySynchronizationError: {
                    synchronizer.synchronizationError(for: $0)
                }
            )
        }

        let reopened = try makeArbiter(
            stateDirectory: stateDirectory,
            maximumCPUCount: 4
        )
        XCTAssertEqual(try reopened.snapshot().mode, .draining)
        XCTAssertEqual(
            try reopened.snapshot().effectivePolicy.maximumReservedCPUCount,
            4
        )
    }

    func testRejectedIdentifiersDoNotGrowDurableLeaseLockSet() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        _ = try arbiter.initialize()
        let initialLockFiles = try FileManager.default.contentsOfDirectory(
            atPath: stateDirectory.path
        ).filter { $0.hasPrefix("lease-slot-") }.sorted()
        XCTAssertEqual(initialLockFiles.count, 64)
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
        ).filter { $0.hasPrefix("lease-slot-") }.sorted()
        XCTAssertEqual(lockFiles, initialLockFiles)
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
            _ = try arbiter.authorizeMutation(
                scope: unissuedScope,
                virtualMachineName: first.virtualMachineName,
                operation: .stop
            )
        }
        assertCapacityError(.staleFencingToken) {
            _ = try arbiter.authorizeMutation(
                scope: first.scope,
                virtualMachineName: first.virtualMachineName,
                operation: .stop
            )
        }
        try releaseLease(renewed, using: arbiter)

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
        try releaseLease(second, using: reopened)
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
            _ = try arbiter.authorizeMutation(
                scope: lease.scope,
                virtualMachineName: lease.virtualMachineName,
                operation: .stop
            )
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
                virtualMachineName: lease.virtualMachineName,
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
        assertCapacityError(.unsafeStatePath) {
            _ = try makeArbiter(stateDirectory: insecureDirectory)
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
        assertCapacityError(.unsafeStatePath) {
            _ = try makeArbiter(
                stateDirectory: alias.appendingPathComponent(
                    "capacity",
                    isDirectory: true
                )
            )
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
        assertCapacityError(.unsafeStatePath) {
            _ = try makeArbiter(
                stateDirectory: shared.appendingPathComponent(
                    "capacity",
                    isDirectory: true
                )
            )
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
        assertCapacityError(.unsafeStatePath) {
            _ = try makeArbiter(stateDirectory: stateDirectory)
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

        assertCapacityError(.corruptState) {
            _ = try makeArbiter(stateDirectory: stateDirectory)
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
            effectivePolicy: try makePolicy(),
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
        storageHeadroomGiB: UInt64 = 20,
        maximumLeaseDurationSeconds: TimeInterval = 300,
        policyAdoption: SandboxCapacityPolicyAdoption = .restrictOnly,
        availableStorageBytes: UInt64 = UInt64.max,
        clock: TestWallClock? = nil
    ) throws -> SandboxHostCapacityArbiter {
        let clock = clock ?? TestWallClock(
            Date(timeIntervalSince1970: 2_000_000_000)
        )
        return try SandboxHostCapacityArbiter(
            stateDirectory: stateDirectory,
            policy: makePolicy(
                maximumCPUCount: maximumCPUCount,
                maximumMemoryGiB: maximumMemoryGiB,
                maximumGrowthGiB: maximumGrowthGiB,
                storageHeadroomGiB: storageHeadroomGiB,
                maximumLeaseDurationSeconds: maximumLeaseDurationSeconds
            ),
            policyAdoption: policyAdoption,
            currentDate: { clock.now() },
            availableStorageBytes: { availableStorageBytes }
        )
    }

    private func makePolicy(
        maximumCPUCount: UInt16 = 8,
        maximumMemoryGiB: UInt64 = 16,
        maximumGrowthGiB: UInt64 = 300,
        storageHeadroomGiB: UInt64 = 20,
        maximumLeaseDurationSeconds: TimeInterval = 300
    ) throws -> SandboxCapacityPolicy {
        try SandboxCapacityPolicy(
            maximumReservedCPUCount: maximumCPUCount,
            maximumReservedMemoryBytes: maximumMemoryGiB
                * SandboxResourcePolicy.gibibyte,
            maximumReservedGrowthBytes: maximumGrowthGiB
                * SandboxResourcePolicy.gibibyte,
            storageHeadroomBytes: storageHeadroomGiB
                * SandboxResourcePolicy.gibibyte,
            maximumLeaseDurationSeconds: maximumLeaseDurationSeconds
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

    private func persistedStateObject(
        in stateDirectory: URL
    ) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: stateDirectory.appendingPathComponent(
                        "capacity.json"
                    )
                )
            ) as? [String: Any]
        )
    }

    private func downgradePersistedStateToV3(
        in stateDirectory: URL
    ) throws {
        let stateURL = stateDirectory.appendingPathComponent("capacity.json")
        var object = try persistedStateObject(in: stateDirectory)
        object["schemaVersion"] = 3
        object.removeValue(forKey: "effectivePolicy")
        object.removeValue(forKey: "policyRevision")
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )
    }

    private func initializeDedicated(
        _ arbiter: SandboxHostCapacityArbiter
    ) throws {
        _ = try arbiter.initialize()
        _ = try arbiter.setMode(.sandboxDedicated)
    }

    private func releaseLease(
        _ lease: SandboxCapacityLease,
        using arbiter: SandboxHostCapacityArbiter
    ) throws {
        let authorization = try arbiter.authorizeMutation(
            scope: lease.scope,
            virtualMachineName: lease.virtualMachineName,
            operation: .stop
        )
        try arbiter.release(
            scope: lease.scope,
            holding: authorization
        )
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

private enum PolicyInitializationOutcome: Equatable, Sendable {
    case initialized
    case rejected(SandboxCapacityError)
    case unexpected(String)
}

private func policyInitializationOutcome(
    _ arbiter: SandboxHostCapacityArbiter
) -> PolicyInitializationOutcome {
    do {
        _ = try arbiter.initialize()
        return .initialized
    } catch let error as SandboxCapacityError {
        return .rejected(error)
    } catch {
        return .unexpected(String(describing: error))
    }
}

private final class OneShotBlockingDirectorySynchronization:
    @unchecked Sendable
{
    private let stateLock = NSLock()
    private let blocked = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    private var hasBlocked = false

    func synchronizationError(for descriptor: Int32) -> Int32? {
        stateLock.lock()
        let shouldBlock = !hasBlocked
        hasBlocked = true
        stateLock.unlock()
        if shouldBlock {
            blocked.signal()
            proceed.wait()
        }
        while fsync(descriptor) != 0 {
            guard errno == EINTR else {
                return errno
            }
        }
        return nil
    }

    func waitUntilBlocked() -> Bool {
        blocked.wait(timeout: .now() + 5) == .success
    }

    func resume() {
        proceed.signal()
    }
}

private final class OneShotBlockingStorageAvailability: @unchecked Sendable {
    private let stateLock = NSLock()
    private let blocked = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    private let value: UInt64
    private var armed = false
    private var hasBlocked = false

    init(_ value: UInt64) {
        self.value = value
    }

    func arm() {
        stateLock.lock()
        armed = true
        stateLock.unlock()
    }

    func available() -> UInt64 {
        stateLock.lock()
        let shouldBlock = armed && !hasBlocked
        if shouldBlock {
            hasBlocked = true
        }
        stateLock.unlock()
        if shouldBlock {
            blocked.signal()
            proceed.wait()
        }
        return value
    }

    func waitUntilBlocked() -> Bool {
        blocked.wait(timeout: .now() + 5) == .success
    }

    func resume() {
        proceed.signal()
    }
}

private final class LeaseOperationLockContentionProbe: @unchecked Sendable {
    private let stateLock = NSLock()
    private let observed = DispatchSemaphore(value: 0)
    private var observedLock: String?

    var firstObservedLock: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return observedLock
    }

    func observe(lockName: String) {
        stateLock.lock()
        let isFirstObservation = observedLock == nil
        if isFirstObservation {
            observedLock = lockName
        }
        stateLock.unlock()
        if isFirstObservation {
            observed.signal()
        }
    }

    func waitUntilObserved() -> Bool {
        observed.wait(timeout: .now() + 5) == .success
    }
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
