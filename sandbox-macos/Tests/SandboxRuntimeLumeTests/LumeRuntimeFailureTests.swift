import CryptoKit
import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeRuntimeFailureTests: XCTestCase {
    func testRejectsRuntimeWithoutAuditedProvenance() async throws {
        let fixture = try FakeLumeFixture(writeProvenance: false)
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        do {
            _ = try await runtime.capabilities()
            XCTFail("runtime without provenance should be rejected")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported("Lume provenance cannot be opened")
            )
        }
    }

    func testValidatesAuditedRuntimeInSystemTemporaryDirectory() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }

        let capabilities = try await fixture.makeRuntime().capabilities()

        XCTAssertEqual(
            capabilities.version,
            LumeRuntimeConfiguration.pinnedVersion
        )
    }

    func testRejectsExtendedACLOnRuntimeTreeAuthority() async throws {
        for target in ["directory", "file"] {
            let fixture = try FakeLumeFixture()
            defer { try? fixture.remove() }
            try addExtendedACL(
                to: target == "directory"
                    ? fixture.runtimeDirectory
                    : fixture.executable
            )

            do {
                _ = try await fixture.makeRuntime().capabilities()
                XCTFail("runtime \(target) ACL must be rejected")
            } catch let error as SandboxRuntimeError {
                guard case .unsupported(let detail) = error else {
                    XCTFail("unexpected runtime ACL error: \(error)")
                    continue
                }
                XCTAssertTrue(detail.contains("ACL"))
            }
        }
    }

    func testProductionRejectsSelfAuthenticatedAdHocRuntime() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let runtime = LumeVirtualMachineRuntime(
            configuration: try LumeRuntimeConfiguration(
                executable: fixture.executable,
                storageDirectory: fixture.storage,
                commandTimeoutSeconds: 1,
                createTimeoutSeconds: 1,
                trustPolicy: .production
            )
        )

        do {
            _ = try await runtime.capabilities()
            XCTFail("production must reject an ad-hoc self-authenticated runtime")
        } catch let error as SandboxRuntimeError {
            guard case .unsupported(let detail) = error else {
                XCTFail("expected unsupported signature error, got \(error)")
                return
            }
            XCTAssertTrue(detail.contains("production signature"))
        }
    }

    func testProductionRequirementPinsDarkbloomIdentifierAndTeam() {
        XCTAssertEqual(
            LumeRuntimeCodeSignature.designatedRequirement,
            "anchor apple generic and identifier "
                + "\"io.darkbloom.sandbox.lume\" "
                + "and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\""
        )
        XCTAssertEqual(
            LumeRuntimeCodeSignature.provenanceDesignatedRequirement,
            "anchor apple generic and identifier "
                + "\"io.darkbloom.sandbox.lume.provenance\" "
                + "and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\""
        )
    }

    func testProductionRuntimeTreeRequiresRootOwnership() {
        XCTAssertTrue(
            LumeRuntimeProvenanceValidator.acceptsOwner(
                0,
                policy: .production
            )
        )
        XCTAssertFalse(
            LumeRuntimeProvenanceValidator.acceptsOwner(
                501,
                policy: .production
            )
        )
        XCTAssertTrue(
            LumeRuntimeProvenanceValidator.acceptsOwner(
                geteuid(),
                policy: .developmentAdHoc
            )
        )
    }

    func testGuestCommandsRequireExplicitDevelopmentBootstrapPolicy()
        async throws
    {
        let fixture = try FakeLumeFixture(
            initialState: "running",
            behavior: "guest-command-success"
        )
        defer { try? fixture.remove() }
        let runtime = LumeVirtualMachineRuntime(
            configuration: try LumeRuntimeConfiguration(
                executable: fixture.executable,
                storageDirectory: fixture.storage,
                commandTimeoutSeconds: 30,
                createTimeoutSeconds: 30,
                trustPolicy: .developmentAdHoc
            )
        )

        do {
            _ = try await runtime.execute(
                name: fixture.virtualMachineName,
                request: SandboxGuestCommandRequest(
                    idempotencyKey: UUID(),
                    executable: "/usr/bin/true",
                    timeoutSeconds: 30
                )
            )
            XCTFail("bootstrap-credential guest execution must default to disabled")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported(
                    "guest commands are disabled until the signed guest-control agent is available"
                )
            )
        }
        XCTAssertFalse(fixture.guestCommandWasStarted)
        let state = try await runtime.inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(state, .running)
    }

    func testLeaseFencedRuntimeRejectsStaleAndMismatchedMutations() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let capacityDirectory = fixture.directory.appendingPathComponent(
            "capacity",
            isDirectory: true
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try SandboxHostCapacityArbiter(
            stateDirectory: capacityDirectory,
            policy: try SandboxCapacityPolicy(
                maximumReservedCPUCount: 8,
                maximumReservedMemoryBytes:
                    16 * SandboxResourcePolicy.gibibyte,
                maximumReservedGrowthBytes:
                    300 * SandboxResourcePolicy.gibibyte,
                storageHeadroomBytes:
                    20 * SandboxResourcePolicy.gibibyte
            ),
            storageIdentity: try SandboxStorageVolumeInspector().inspect(
                path: fixture.storage
            ).identity,
            currentDate: { clock.now() },
            availableStorageBytes: { UInt64.max }
        )
        _ = try arbiter.initialize()
        _ = try arbiter.setMode(.sandboxDedicated)
        let resources = try SandboxResourceSpecification.macOSSmall()
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: resources,
            expiresAt: now.addingTimeInterval(120)
        )
        try fixture.bindOwnership(to: lease.scope)
        let runtime = try LumeLeaseFencedVirtualMachineRuntime(
            configuration: try LumeRuntimeConfiguration(
                executable: fixture.executable,
                storageDirectory: fixture.storage,
                commandTimeoutSeconds: 1,
                createTimeoutSeconds: 1,
                trustPolicy: .developmentAdHoc
            ),
            capacityArbiter: arbiter
        )
        let staleScope = SandboxOperationScope(
            sandboxID: lease.scope.sandboxID,
            generation: lease.scope.generation,
            fencingToken: try XCTUnwrap(
                SandboxFencingToken(rawValue: UInt64.max)
            )
        )
        let nextGenerationMarker = SandboxOperationScope(
            sandboxID: lease.scope.sandboxID,
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 2)),
            fencingToken: lease.scope.fencingToken
        )

        try fixture.bindOwnership(to: nextGenerationMarker)
        do {
            _ = try await runtime.inspect(
                scope: lease.scope,
                name: fixture.virtualMachineName
            )
            XCTFail("a lease must not inspect a VM from another generation")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported(
                    "VM \(fixture.virtualMachineName) belongs to a different Darkbloom sandbox scope"
                )
            )
        }
        try fixture.bindOwnership(to: lease.scope)

        do {
            try await runtime.start(
                scope: staleScope,
                name: fixture.virtualMachineName
            )
            XCTFail("stale fencing token should reject VM mutation")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .staleFencingToken)
        }
        do {
            try await runtime.start(
                scope: lease.scope,
                name: "sandbox-other"
            )
            XCTFail("lease should not authorize another VM")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .leaseVirtualMachineMismatch)
        }
        clock.set(lease.expiresAt)
        do {
            try await runtime.start(
                scope: lease.scope,
                name: fixture.virtualMachineName
            )
            XCTFail("expired lease should reject start")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .leaseExpired)
        }

        try await runtime.stop(
            scope: lease.scope,
            name: fixture.virtualMachineName
        )
    }

    func testLeaseFencedInspectRejectsRenewedFenceWithoutBlockingRenewal()
        async throws
    {
        let fixture = try FakeLumeFixture(
            behavior: "block-first-list"
        )
        defer { try? fixture.remove() }
        defer { try? fixture.allowListToContinue() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try SandboxHostCapacityArbiter(
            stateDirectory: fixture.directory.appendingPathComponent(
                "capacity",
                isDirectory: true
            ),
            policy: try SandboxCapacityPolicy(
                maximumReservedCPUCount: 8,
                maximumReservedMemoryBytes:
                    16 * SandboxResourcePolicy.gibibyte,
                maximumReservedGrowthBytes:
                    300 * SandboxResourcePolicy.gibibyte,
                storageHeadroomBytes:
                    20 * SandboxResourcePolicy.gibibyte
            ),
            storageIdentity: try SandboxStorageVolumeInspector().inspect(
                path: fixture.storage
            ).identity,
            currentDate: { clock.now() },
            availableStorageBytes: { UInt64.max }
        )
        _ = try arbiter.initialize()
        _ = try arbiter.setMode(.sandboxDedicated)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(120)
        )
        try fixture.bindOwnership(to: lease.scope)
        let runtime = try LumeLeaseFencedVirtualMachineRuntime(
            configuration: try LumeRuntimeConfiguration(
                executable: fixture.executable,
                storageDirectory: fixture.storage,
                commandTimeoutSeconds: 30,
                createTimeoutSeconds: 30,
                trustPolicy: .developmentAdHoc
            ),
            capacityArbiter: arbiter
        )
        let inspection = Task {
            try await runtime.inspect(
                scope: lease.scope,
                name: fixture.virtualMachineName
            )
        }
        try await fixture.waitForListToStart()
        let status = LumeRenewalStatus()
        let renewal = Task.detached {
            await status.markStarted()
            let renewed = try arbiter.renew(
                scope: lease.scope,
                expiresAt: now.addingTimeInterval(240)
            )
            await status.markCompleted()
            return renewed
        }
        while !(await status.started) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let waitClock = ContinuousClock()
        let completionDeadline = waitClock.now.advanced(by: .seconds(2))
        while !(await status.completed),
              waitClock.now < completionDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        let completedWhileInspecting = await status.completed
        XCTAssertTrue(
            completedWhileInspecting,
            "inspection must not hold the lease lock across Lume I/O"
        )

        try fixture.allowListToContinue()
        let renewed = try await renewal.value
        XCTAssertGreaterThan(
            renewed.scope.fencingToken,
            lease.scope.fencingToken
        )
        do {
            _ = try await inspection.value
            XCTFail("inspection must discard an observation under a stale fence")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .staleFencingToken)
        }
    }

    func testLeaseFencedInspectBlocksConcurrentRelease()
        async throws
    {
        let fixture = try FakeLumeFixture(behavior: "block-first-list")
        defer { try? fixture.remove() }
        defer { try? fixture.allowListToContinue() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(120)
        )
        try fixture.bindOwnership(to: lease.scope)
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )
        let inspection = Task {
            try await runtime.inspect(
                scope: lease.scope,
                name: fixture.virtualMachineName
            )
        }
        try await fixture.waitForListToStart()

        do {
            try await runtime.release(
                scope: lease.scope,
                name: lease.virtualMachineName
            )
            XCTFail("release must not pass an active inspection")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .operationInProgress(
                    name: fixture.virtualMachineName,
                    operation: "inspect"
                )
            )
        }
        try fixture.allowListToContinue()

        let inspected = try await inspection.value
        XCTAssertNotNil(inspected)
        try await runtime.release(
            scope: lease.scope,
            name: lease.virtualMachineName
        )
    }

    func testLeaseFencedInspectRejectsListedVMWithoutOwnership() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(120)
        )
        try fixture.bindOwnership(to: lease.scope)
        try FileManager.default.removeItem(at: fixture.ownershipMarker)
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )

        do {
            _ = try await runtime.inspect(
                scope: lease.scope,
                name: fixture.virtualMachineName
            )
            XCTFail("listed VM without ownership must fail closed")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported(
                    "VM \(fixture.virtualMachineName) is not owned by Darkbloom"
                )
            )
        }
    }

    func testLeaseFencedInspectRejectsOwnershipWithoutListedVM()
        async throws
    {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(120)
        )
        try fixture.bindOwnership(to: lease.scope)
        try FileManager.default.removeItem(at: fixture.state)
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )

        do {
            _ = try await runtime.inspect(
                scope: lease.scope,
                name: fixture.virtualMachineName
            )
            XCTFail("ownership without a listed VM must fail closed")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported(
                    "VM \(fixture.virtualMachineName) runtime and ownership presence disagree"
                )
            )
        }
    }

    func testCreateRechecksStorageHeadroomBeforeLumeMutation() async throws {
        let fixture = try FakeLumeFixture(initialState: nil)
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let storage = LumeTestStorageAvailability(
            300 * SandboxResourcePolicy.gibibyte
        )
        let arbiter = try fixture.makeCapacityArbiter(
            clock: clock,
            availableStorageBytes: { storage.available() }
        )
        let resources = try SandboxResourceSpecification.macOSSmall()
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: resources,
            expiresAt: now.addingTimeInterval(120)
        )
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )
        let specification = try SandboxVirtualMachineSpecification(
            name: fixture.virtualMachineName,
            resources: resources,
            imageSource: .restoreImage(
                url: fixture.restoreImage,
                unattendedPreset: "tahoe"
            ),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte
        )
        storage.set(145 * SandboxResourcePolicy.gibibyte)

        do {
            try await runtime.create(
                scope: lease.scope,
                specification: specification
            )
            XCTFail("create must fail before Lume when headroom disappears")
        } catch let error as SandboxRuntimeError {
            XCTFail("storage rejection cleanup failed unexpectedly: \(error)")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(
                error,
                .insufficientHostStorage(
                    needed: 146 * SandboxResourcePolicy.gibibyte,
                    available: 145 * SandboxResourcePolicy.gibibyte
                )
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.createStarted.path
            )
        )
    }

    func testExpiredLeaseReconciliationStopsThenReleases() async throws {
        let fixture = try FakeLumeFixture(initialState: "running")
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(30)
        )
        try fixture.bindOwnership(to: lease.scope)
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )
        clock.set(lease.expiresAt)

        let results = try await runtime.reconcileExpiredLeases()

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].outcome, .released)
        XCTAssertEqual(results[0].lease.scope.sandboxID, lease.scope.sandboxID)
        XCTAssertGreaterThan(
            results[0].lease.scope.fencingToken,
            lease.scope.fencingToken
        )
        try await fixture.waitForState("stopped")
        XCTAssertTrue(try arbiter.snapshot().leases.isEmpty)
        let retryResults = try await runtime.reconcileExpiredLeases()
        XCTAssertTrue(retryResults.isEmpty)
    }

    func testExpiredLeaseReconciliationRecoversCrashAfterDurableFence()
        async throws
    {
        let fixture = try FakeLumeFixture(initialState: "running")
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(30)
        )
        try fixture.bindOwnership(to: lease.scope)
        clock.set(lease.expiresAt)
        let fenced = try arbiter.fenceExpiredLease(scope: lease.scope)

        let reopenedArbiter = try fixture.makeCapacityArbiter(clock: clock)
        let reopenedRuntime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: reopenedArbiter
        )
        let results = try await reopenedRuntime.reconcileExpiredLeases()

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].outcome, .released)
        XCTAssertGreaterThan(
            results[0].lease.scope.fencingToken,
            fenced.scope.fencingToken
        )
        try await fixture.waitForState("stopped")
        XCTAssertTrue(try reopenedArbiter.snapshot().leases.isEmpty)
    }

    func testExpiredLeaseReconciliationRecoversCrashAfterVerifiedStop()
        async throws
    {
        let fixture = try FakeLumeFixture(initialState: "running")
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(30)
        )
        try fixture.bindOwnership(to: lease.scope)
        clock.set(lease.expiresAt)
        let fenced = try arbiter.fenceExpiredLease(scope: lease.scope)
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )
        try await runtime.stop(
            scope: fenced.scope,
            name: fenced.virtualMachineName
        )

        let reopenedArbiter = try fixture.makeCapacityArbiter(clock: clock)
        let reopenedRuntime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: reopenedArbiter
        )
        let results = try await reopenedRuntime.reconcileExpiredLeases()

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].outcome, .released)
        XCTAssertTrue(try reopenedArbiter.snapshot().leases.isEmpty)
    }

    func testPublicReleaseStopsVirtualMachineBeforeReleasingCapacity()
        async throws
    {
        let fixture = try FakeLumeFixture(initialState: "running")
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(120)
        )
        try fixture.bindOwnership(to: lease.scope)
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )

        try await runtime.release(
            scope: lease.scope,
            name: fixture.virtualMachineName
        )

        try await fixture.waitForState("stopped")
        XCTAssertTrue(try arbiter.snapshot().leases.isEmpty)
    }

    func testPublicReleaseRetainsCapacityWhenVMLivenessIsUnknown()
        async throws
    {
        let fixture = try FakeLumeFixture(
            initialState: "unknown",
            behavior: "stop-liveness-inconclusive"
        )
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(120)
        )
        try fixture.bindOwnership(to: lease.scope)
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )

        do {
            try await runtime.release(
                scope: lease.scope,
                name: fixture.virtualMachineName
            )
            XCTFail("unknown VM liveness must retain reserved capacity")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .commandFailed(
                    command: "stop",
                    exitCode: 70,
                    stderr: "VM liveness is inconclusive"
                )
            )
        }

        XCTAssertEqual(
            try arbiter.snapshot().leases.map(\.scope),
            [lease.scope]
        )
        let state = try await runtime.inspect(
            scope: lease.scope,
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(state, .unknown)
    }

    func testPublicReleaseHoldsFencesThroughCapacityRemoval() async throws {
        let fixture = try FakeLumeFixture(
            initialState: "running",
            behavior: "block-first-list"
        )
        defer { try? fixture.remove() }
        defer { try? fixture.allowListToContinue() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(120)
        )
        try fixture.bindOwnership(to: lease.scope)
        let releasingRuntime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )
        let competingRuntime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )
        let release = Task {
            try await releasingRuntime.release(
                scope: lease.scope,
                name: fixture.virtualMachineName
            )
        }
        try await fixture.waitForListToStart()

        do {
            try await competingRuntime.start(
                scope: lease.scope,
                name: fixture.virtualMachineName
            )
            XCTFail("start must not pass a concurrent release")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .operationInProgress(
                    name: fixture.virtualMachineName,
                    operation: "start"
                )
            )
        }
        try fixture.allowListToContinue()
        try await release.value

        do {
            try await competingRuntime.start(
                scope: lease.scope,
                name: fixture.virtualMachineName
            )
            XCTFail("released capacity must fence every later start")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .leaseNotFound)
        }
        try await fixture.waitForState("stopped")
        XCTAssertTrue(try arbiter.snapshot().leases.isEmpty)
    }

    func testExpiredLeaseReconciliationRetainsLeaseOnOwnershipFailure()
        async throws
    {
        let fixture = try FakeLumeFixture(initialState: "running")
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(30)
        )
        let mismatchedScope = SandboxOperationScope(
            sandboxID: lease.scope.sandboxID,
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 2)),
            fencingToken: lease.scope.fencingToken
        )
        try fixture.bindOwnership(to: mismatchedScope)
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )
        clock.set(lease.expiresAt)

        let results = try await runtime.reconcileExpiredLeases()

        XCTAssertEqual(results.count, 1)
        guard case .retained(let detail) = results[0].outcome else {
            return XCTFail("ownership failure must retain the lease")
        }
        XCTAssertTrue(detail.contains("different Darkbloom sandbox scope"))
        let retained = try XCTUnwrap(arbiter.snapshot().leases.first)
        XCTAssertEqual(retained, results[0].lease)
        XCTAssertGreaterThan(
            retained.scope.fencingToken,
            lease.scope.fencingToken
        )
        try await fixture.waitForState("running")
    }

    func testExpiredLeaseReconciliationRetainsMissingVirtualMachine()
        async throws
    {
        let fixture = try FakeLumeFixture(initialState: nil)
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(30)
        )
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )
        clock.set(lease.expiresAt)

        let results = try await runtime.reconcileExpiredLeases()

        XCTAssertEqual(results.count, 1)
        guard case .retained(let detail) = results[0].outcome else {
            return XCTFail("missing VM must retain its capacity lease")
        }
        XCTAssertTrue(detail.contains("refusing to release capacity"))
        XCTAssertEqual(try arbiter.snapshot().leases, [results[0].lease])
    }

    func testFencedRuntimeRejectsDifferentStorageVolume() throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let arbiter = try fixture.makeCapacityArbiter(
            clock: LumeTestWallClock(
                Date(timeIntervalSince1970: 2_000_000_000)
            )
        )
        let otherStorage = fixture.directory.appendingPathComponent(
            "other-storage",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: otherStorage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        XCTAssertThrowsError(
            try LumeLeaseFencedVirtualMachineRuntime(
                configuration: LumeRuntimeConfiguration(
                    executable: fixture.executable,
                    storageDirectory: otherStorage,
                    commandTimeoutSeconds: 5,
                    createTimeoutSeconds: 5,
                    trustPolicy: .developmentAdHoc
                ),
                capacityArbiter: arbiter
            )
        ) { error in
            XCTAssertEqual(
                error as? SandboxCapacityError,
                .storageIdentityMismatch
            )
        }
    }

    func testFencedRuntimeRejectsReplacedStorageDirectory() async throws {
        let fixture = try FakeLumeFixture(initialState: "stopped")
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(120)
        )
        try fixture.bindOwnership(to: lease.scope)
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )
        let displaced = fixture.directory.appendingPathComponent(
            "storage-displaced",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: fixture.storage, to: displaced)
        try FileManager.default.createDirectory(
            at: fixture.storage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            try await runtime.start(
                scope: lease.scope,
                name: fixture.virtualMachineName
            )
            XCTFail("replaced runtime storage must fail closed")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .storageIdentityMismatch)
        }
    }

    func testEmptyReconciliationAndCapabilitiesRejectReplacedStorage()
        async throws
    {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let arbiter = try fixture.makeCapacityArbiter(
            clock: LumeTestWallClock(
                Date(timeIntervalSince1970: 2_000_000_000)
            )
        )
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )
        let displaced = fixture.directory.appendingPathComponent(
            "storage-before-replacement",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: fixture.storage, to: displaced)
        try FileManager.default.createDirectory(
            at: fixture.storage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            _ = try await runtime.capabilities()
            XCTFail("capability inspection must reject replaced storage")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .storageIdentityMismatch)
        }
        do {
            _ = try await runtime.reconcileExpiredLeases()
            XCTFail("empty reconciliation must reject replaced storage")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .storageIdentityMismatch)
        }
    }

    func testRejectedLeaseNameDoesNotCreateVirtualMachineLock() async throws {
        let fixture = try FakeLumeFixture(initialState: "running")
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(120)
        )
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )
        let rejectedName = "sandbox-unowned"

        do {
            try await runtime.start(scope: lease.scope, name: rejectedName)
            XCTFail("lease must not authorize another VM")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .leaseVirtualMachineMismatch)
        }
        let lockURL = LumeRuntimeWorkspace(
            storageDirectory: fixture.storage
        ).locksDirectory.appendingPathComponent("\(rejectedName).lock")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testRejectsProvenanceWithUnpinnedPatchDigest() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        try fixture.replacePatchDigest(String(repeating: "0", count: 64))

        do {
            _ = try await fixture.makeRuntime().capabilities()
            XCTFail("runtime with an unpinned patch digest should be rejected")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported("Lume provenance does not match the audited pin")
            )
        }
    }

    func testSuppressesDependencyDiagnosticsForMachineReadableOutput() async throws {
        let fixture = try FakeLumeFixture(behavior: "log-info-on-list")
        defer { try? fixture.remove() }

        let records = try await fixture.makeRuntime().list()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.name, fixture.virtualMachineName)
        XCTAssertEqual(records.first?.state, .stopped)
    }

    func testFixtureCleanupRemovesReadOnlyRuntimeTree() throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let directory = fixture.directory

        try fixture.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRejectsRuntimeChangedAfterValidation() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        let capabilities = try await runtime.capabilities()
        XCTAssertEqual(
            capabilities.version,
            LumeRuntimeConfiguration.pinnedVersion
        )
        guard chmod(fixture.executable.path, 0o755) == 0 else {
            throw POSIXError(.EACCES)
        }
        let handle = try FileHandle(forWritingTo: fixture.executable)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        guard chmod(fixture.executable.path, 0o555) == 0 else {
            throw POSIXError(.EACCES)
        }

        do {
            _ = try await runtime.capabilities()
            XCTFail("changed runtime should be rejected")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported("Lume runtime changed after validation")
            )
        }
    }

    func testRejectsRuntimeTreeEntryAddedAfterValidation() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()
        _ = try await runtime.capabilities()

        guard chmod(fixture.runtimeDirectory.path, 0o755) == 0 else {
            throw POSIXError(.EACCES)
        }
        let injected = fixture.runtimeDirectory.appendingPathComponent(
            "injected-resource"
        )
        try Data("untrusted".utf8).write(to: injected)
        guard chmod(injected.path, 0o444) == 0,
              chmod(fixture.runtimeDirectory.path, 0o555) == 0
        else {
            throw POSIXError(.EACCES)
        }

        do {
            _ = try await runtime.capabilities()
            XCTFail("an added runtime tree entry should be rejected")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported("Lume runtime changed after validation")
            )
        }
    }

    func testFailedReadinessStopsNewlyStartedVirtualMachine() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        do {
            try await runtime.start(name: fixture.virtualMachineName)
            XCTFail("guest that never becomes ready should time out")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .operationTimedOut(
                    "\(fixture.virtualMachineName) guest readiness"
                )
            )
        }
        let state = try await runtime.inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(
            state,
            .stopped
        )
    }

    func testCredentialedReadinessUsesBootstrapGuestCommandWrapper() throws {
        let idempotencyKey = UUID(
            uuidString: "B57A4FA2-BCA8-45EF-A7D8-F4A20FE85DBA"
        )!
        let expected = try LumeGuestCommandEncoder.encode(
            SandboxGuestCommandRequest(
                idempotencyKey: idempotencyKey,
                executable: "/usr/bin/true",
                timeoutSeconds:
                    LumeCredentialedGuestReadinessProbe.guestCommandTimeoutSeconds
            )
        )

        XCTAssertEqual(
            try LumeCredentialedGuestReadinessProbe.command(
                idempotencyKey: idempotencyKey
            ),
            expected
        )
        XCTAssertEqual(LumeCredentialedGuestReadinessProbe.lumeTimeoutSeconds, 35)
        XCTAssertEqual(
            LumeGuestReadinessPolicy.standard.attemptTimeoutSeconds,
            40
        )
    }

    func testStartWarmsBootstrapGuestCommandPathBeforeReturning() async throws {
        let fixture = try FakeLumeFixture(
            behavior: "credentialed-readiness-executor"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(
            commandTimeoutSeconds: 4,
            guestReadinessPolicy: LumeGuestReadinessPolicy(
                attemptTimeoutSeconds: 1,
                retryDelay: .milliseconds(10)
            )
        )

        try await runtime.start(name: fixture.virtualMachineName)

        XCTAssertTrue(fixture.guestExecutorProbeWasObserved)
        XCTAssertEqual(fixture.guestReadinessProbeAttempts, 1)
        XCTAssertFalse(fixture.invalidGuestReadinessProbeWasObserved)
        try await runtime.stop(name: fixture.virtualMachineName)
    }

    func testReadinessRejectsSSHSuccessWithoutGuestExecutorEnvelope()
        async throws
    {
        let fixture = try FakeLumeFixture(
            behavior: "credentialed-readiness-empty-first"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(
            commandTimeoutSeconds: 4,
            guestReadinessPolicy: LumeGuestReadinessPolicy(
                attemptTimeoutSeconds: 1,
                retryDelay: .milliseconds(10)
            )
        )

        try await runtime.start(name: fixture.virtualMachineName)

        XCTAssertEqual(fixture.guestReadinessProbeAttempts, 2)
        XCTAssertTrue(fixture.guestExecutorProbeWasObserved)
        XCTAssertFalse(fixture.invalidGuestReadinessProbeWasObserved)
        try await runtime.stop(name: fixture.virtualMachineName)
    }

    func testCredentialedReadinessRetriesTransientFailuresBeforeSuccess()
        async throws
    {
        let fixture = try FakeLumeFixture(
            behavior: "credentialed-readiness-transient"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(
            commandTimeoutSeconds: 4,
            guestReadinessPolicy: LumeGuestReadinessPolicy(
                attemptTimeoutSeconds: 1,
                retryDelay: .milliseconds(10)
            )
        )

        try await runtime.start(name: fixture.virtualMachineName)

        XCTAssertEqual(fixture.guestReadinessProbeAttempts, 4)
        XCTAssertFalse(fixture.invalidGuestReadinessProbeWasObserved)
        let timedOutProbeProcessIdentifier =
            try await fixture.waitForGuestReadinessProbeToStart()
        try await fixture.waitForProcessExit(
            timedOutProbeProcessIdentifier
        )
        let record = try await runtime.inspect(
            name: fixture.virtualMachineName
        )
        XCTAssertEqual(record?.state, .running)
        XCTAssertEqual(record?.guestReady, true)
        try await runtime.stop(name: fixture.virtualMachineName)
    }

    func testAlreadyRunningTCPReadyGuestStillRequiresCredentialedProbe()
        async throws
    {
        let fixture = try FakeLumeFixture(
            initialState: "ready",
            behavior: "credentialed-readiness-blocking"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(
            guestReadinessPolicy: LumeGuestReadinessPolicy(
                attemptTimeoutSeconds: 30,
                retryDelay: .milliseconds(10)
            )
        )

        do {
            try await runtime.start(name: fixture.virtualMachineName)
            XCTFail("TCP readiness must not bypass authentication")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .operationTimedOut(
                    "\(fixture.virtualMachineName) guest readiness"
                )
            )
        }

        XCTAssertEqual(fixture.guestReadinessProbeAttempts, 1)
        let probeProcessIdentifier =
            try await fixture.waitForGuestReadinessProbeToStart()
        try await fixture.waitForProcessExit(probeProcessIdentifier)
        let state = try await runtime.inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(state, .running)
        try await runtime.stop(name: fixture.virtualMachineName)
    }

    func testCredentialedReadinessDeadlineStopsNewlyStartedVirtualMachine()
        async throws
    {
        let fixture = try FakeLumeFixture(
            behavior: "credentialed-readiness-blocking"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(
            guestReadinessPolicy: LumeGuestReadinessPolicy(
                attemptTimeoutSeconds: 30,
                retryDelay: .milliseconds(10)
            )
        )
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            try await runtime.start(name: fixture.virtualMachineName)
            XCTFail("credentialed guest readiness must time out")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .operationTimedOut(
                    "\(fixture.virtualMachineName) guest readiness"
                )
            )
        }

        XCTAssertLessThan(clock.now - startedAt, .seconds(5))
        XCTAssertEqual(fixture.guestReadinessProbeAttempts, 1)
        XCTAssertFalse(fixture.invalidGuestReadinessProbeWasObserved)
        let probeProcessIdentifier =
            try await fixture.waitForGuestReadinessProbeToStart()
        try await fixture.waitForProcessExit(probeProcessIdentifier)
        let state = try await runtime.inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(state, .stopped)
    }

    func testCancelledCredentialedReadinessCleansUpProbeAndVirtualMachine()
        async throws
    {
        let fixture = try FakeLumeFixture(
            behavior: "credentialed-readiness-blocking"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(
            commandTimeoutSeconds: 30,
            guestReadinessPolicy: LumeGuestReadinessPolicy(
                attemptTimeoutSeconds: 30,
                retryDelay: .milliseconds(10)
            )
        )
        let start = Task {
            try await runtime.start(name: fixture.virtualMachineName)
        }
        let probeProcessIdentifier =
            try await fixture.waitForGuestReadinessProbeToStart()

        start.cancel()

        do {
            try await start.value
            XCTFail("cancelled readiness probe should throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        try await fixture.waitForProcessExit(probeProcessIdentifier)
        let state = try await runtime.inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(state, .stopped)
        XCTAssertFalse(fixture.invalidGuestReadinessProbeWasObserved)
    }

    func testCancelledStartStopsNewlyStartedVirtualMachine() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 30)
        let start = Task {
            try await runtime.start(name: fixture.virtualMachineName)
        }
        try await fixture.waitForState("running")
        start.cancel()

        do {
            try await start.value
            XCTFail("cancelled start should throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        let state = try await runtime.inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(
            state,
            .stopped
        )
    }

    func testCancelledExecuteDuringPreflightStopsVirtualMachine() async throws {
        let fixture = try FakeLumeFixture(
            initialState: "running",
            behavior: "block-first-list"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 30)
        let execution = Task {
            try await runtime.execute(
                name: fixture.virtualMachineName,
                request: try SandboxGuestCommandRequest(
                    idempotencyKey: UUID(),
                    executable: "/usr/bin/true",
                    timeoutSeconds: 30
                )
            )
        }
        try await fixture.waitForListToStart()
        execution.cancel()

        do {
            _ = try await execution.value
            XCTFail("cancelled execute should throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        let state = try await runtime.inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(state, .stopped)
        XCTAssertFalse(fixture.guestCommandWasStarted)
    }

    func testClaimAppearingAfterReplayStopsVirtualMachine() async throws {
        let fixture = try FakeLumeFixture(
            initialState: "running",
            behavior: "block-first-list"
        )
        defer { try? fixture.remove() }
        defer { try? fixture.allowListToContinue() }
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/true",
            timeoutSeconds: 30
        )
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 30)
        let execution = Task {
            try await runtime.execute(
                name: fixture.virtualMachineName,
                request: request
            )
        }
        try await fixture.waitForListToStart()
        let identity = try LumeVirtualMachineOwnership.requireOwned(
            name: fixture.virtualMachineName,
            owner: .baseTemplate,
            in: fixture.storage
        )
        let workspace = LumeRuntimeWorkspace(
            storageDirectory: fixture.storage
        )
        try workspace.prepare()
        _ = try LumeGuestCommandJournal(workspace: workspace).claim(
            installationID: identity.installationID,
            request: request
        )
        try fixture.allowListToContinue()

        do {
            _ = try await execution.value
            XCTFail("a claim race must fail closed")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                LumeGuestCommandJournal.outcomeUnavailable()
            )
        }

        let state = try await runtime.inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(state, .stopped)
        XCTAssertFalse(fixture.guestCommandWasStarted)
    }

    func testExecutePreflightFailureDoesNotCancelGuestCommand() async throws {
        let fixture = try FakeLumeFixture(initialState: "stopped")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        do {
            _ = try await runtime.execute(
                name: fixture.virtualMachineName,
                request: try SandboxGuestCommandRequest(
                    idempotencyKey: UUID(),
                    executable: "/usr/bin/true",
                    timeoutSeconds: 30
                )
            )
            XCTFail("execute should reject a stopped virtual machine")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported("guest commands require a running VM")
            )
        }

        XCTAssertFalse(fixture.guestCommandWasStarted)
    }

    func testGuestTransportFailureStopsVirtualMachineAfterCancellationAcknowledges()
        async throws
    {
        let fixture = try FakeLumeFixture(
            initialState: "running",
            behavior: "guest-command-transport-failure"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 30)

        do {
            _ = try await runtime.execute(
                name: fixture.virtualMachineName,
                request: SandboxGuestCommandRequest(
                    idempotencyKey: UUID(),
                    executable: "/usr/bin/true",
                    timeoutSeconds: 30
                )
            )
            XCTFail("an indeterminate guest command must fail closed")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .commandFailed(
                    command: "lume ssh",
                    exitCode: 69,
                    stderr: "simulated SSH transport failure"
                )
            )
        }

        let state = try await runtime.inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(fixture.guestReadinessProbeAttempts, 2)
    }

    func testExecuteReplaysCompletedIdempotencyKeyWithoutSecondSSH() async throws {
        let fixture = try FakeLumeFixture(
            initialState: "running",
            behavior: "guest-command-success"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 30)
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/true",
            timeoutSeconds: 30
        )

        let first = try await runtime.execute(
            name: fixture.virtualMachineName,
            request: request
        )
        let attemptsAfterFirstExecution = fixture.guestReadinessProbeAttempts
        let replay = try await runtime.execute(
            name: fixture.virtualMachineName,
            request: request
        )

        XCTAssertEqual(first, replay)
        XCTAssertEqual(attemptsAfterFirstExecution, 1)
        XCTAssertEqual(fixture.guestReadinessProbeAttempts, 1)
    }

    func testExecuteRejectsIdempotencyKeyReuseForDifferentRequest() async throws {
        let fixture = try FakeLumeFixture(
            initialState: "running",
            behavior: "guest-command-success"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 30)
        let idempotencyKey = UUID()
        _ = try await runtime.execute(
            name: fixture.virtualMachineName,
            request: SandboxGuestCommandRequest(
                idempotencyKey: idempotencyKey,
                executable: "/usr/bin/true",
                timeoutSeconds: 30
            )
        )

        do {
            _ = try await runtime.execute(
                name: fixture.virtualMachineName,
                request: SandboxGuestCommandRequest(
                    idempotencyKey: idempotencyKey,
                    executable: "/usr/bin/false",
                    timeoutSeconds: 30
                )
            )
            XCTFail("an idempotency key must commit to exactly one request")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported(
                    "guest command idempotency key was already used for a different request"
                )
            )
        }
        XCTAssertEqual(fixture.guestReadinessProbeAttempts, 1)
    }

    func testTimedOutReplayStopsVirtualMachineForMatchingAndConflictingRetry()
        async throws
    {
        let fixture = try FakeLumeFixture(
            initialState: "running",
            behavior: "guest-command-timeout"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 30)
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/bin/sleep",
            arguments: ["60"],
            timeoutSeconds: 1
        )

        for attempt in 1...2 {
            if attempt == 2 {
                try Data("running\n".utf8).write(to: fixture.state)
            }
            do {
                _ = try await runtime.execute(
                    name: fixture.virtualMachineName,
                    request: request
                )
                XCTFail("a timed-out command must throw")
            } catch let error as SandboxRuntimeError {
                XCTAssertEqual(
                    error,
                    .operationTimedOut(
                        "\(fixture.virtualMachineName) guest command"
                    )
                )
            }
            let state = try await runtime.inspect(
                name: fixture.virtualMachineName
            )?.state
            XCTAssertEqual(state, .stopped)
        }
        XCTAssertEqual(fixture.guestReadinessProbeAttempts, 2)

        try Data("running\n".utf8).write(to: fixture.state)
        do {
            _ = try await runtime.execute(
                name: fixture.virtualMachineName,
                request: SandboxGuestCommandRequest(
                    idempotencyKey: request.idempotencyKey,
                    executable: "/usr/bin/false",
                    timeoutSeconds: 1
                )
            )
            XCTFail("a conflicting retry must reconcile a timed-out result")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                LumeGuestCommandJournal.idempotencyConflict()
            )
        }
        let stateAfterConflict = try await runtime.inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(stateAfterConflict, .stopped)
        XCTAssertEqual(fixture.guestReadinessProbeAttempts, 2)
    }

    func testIncompleteClaimStopsRunningVirtualMachineWithoutReexecution()
        async throws
    {
        let fixture = try FakeLumeFixture(initialState: "running")
        defer { try? fixture.remove() }
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/true",
            timeoutSeconds: 30
        )
        let identity = try LumeVirtualMachineOwnership.requireOwned(
            name: fixture.virtualMachineName,
            owner: .baseTemplate,
            in: fixture.storage
        )
        let workspace = LumeRuntimeWorkspace(
            storageDirectory: fixture.storage
        )
        try workspace.prepare()
        _ = try LumeGuestCommandJournal(workspace: workspace).claim(
            installationID: identity.installationID,
            request: request
        )
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 30)

        do {
            _ = try await runtime.execute(
                name: fixture.virtualMachineName,
                request: request
            )
            XCTFail("an incomplete command claim must fail closed")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                LumeGuestCommandJournal.outcomeUnavailable()
            )
        }

        let state = try await runtime.inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(state, .stopped)
        XCTAssertFalse(fixture.guestCommandWasStarted)
    }

    func testConflictingRetryOfIncompleteClaimStopsVirtualMachine()
        async throws
    {
        let fixture = try FakeLumeFixture(initialState: "running")
        defer { try? fixture.remove() }
        let idempotencyKey = UUID()
        let original = try SandboxGuestCommandRequest(
            idempotencyKey: idempotencyKey,
            executable: "/usr/bin/true",
            timeoutSeconds: 30
        )
        let conflicting = try SandboxGuestCommandRequest(
            idempotencyKey: idempotencyKey,
            executable: "/usr/bin/false",
            timeoutSeconds: 30
        )
        let identity = try LumeVirtualMachineOwnership.requireOwned(
            name: fixture.virtualMachineName,
            owner: .baseTemplate,
            in: fixture.storage
        )
        let workspace = LumeRuntimeWorkspace(
            storageDirectory: fixture.storage
        )
        try workspace.prepare()
        _ = try LumeGuestCommandJournal(workspace: workspace).claim(
            installationID: identity.installationID,
            request: original
        )
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 30)

        do {
            _ = try await runtime.execute(
                name: fixture.virtualMachineName,
                request: conflicting
            )
            XCTFail("a conflicting retry must reconcile an incomplete claim")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                LumeGuestCommandJournal.outcomeUnavailable()
            )
        }

        let state = try await runtime.inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(state, .stopped)
        XCTAssertFalse(fixture.guestCommandWasStarted)
    }

    func testCancelledCreateRemovesNamedAndTemporaryArtifacts() async throws {
        let fixture = try FakeLumeFixture(
            initialState: nil,
            behavior: "block-create"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 30)
        let specification = try SandboxVirtualMachineSpecification(
            name: fixture.virtualMachineName,
            resources: SandboxResourceSpecification.macOSSmall(),
            imageSource: .restoreImage(
                url: fixture.restoreImage,
                unattendedPreset: "tahoe"
            ),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte
        )
        let create = Task {
            try await runtime.create(specification)
        }
        try await fixture.waitForCreateToStart()
        create.cancel()

        do {
            try await create.value
            XCTFail("cancelled create should throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.storage
                    .appendingPathComponent(fixture.virtualMachineName)
                    .path
            )
        )
        let operations = fixture.storage
            .appendingPathComponent(
                LumeRuntimeWorkspace.supportDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                LumeRuntimeWorkspace.operationsDirectoryName,
                isDirectory: true
            )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: operations.path),
            []
        )
    }

    func testCloneRejectsTemplateBootDiskMismatchBeforeMutation() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()
        let requestedDisk = 99 * SandboxResourcePolicy.gibibyte
        let specification = try SandboxVirtualMachineSpecification(
            name: "sandbox-clone-mismatch",
            resources: SandboxResourceSpecification.macOSSmall(),
            imageSource: .localTemplate(
                name: fixture.virtualMachineName
            ),
            diskBytes: requestedDisk,
            diskPolicy: SandboxDiskPolicy(
                bootDiskBytes: requestedDisk...requestedDisk
            )
        )

        do {
            try await runtime.create(specification)
            XCTFail("clone must reject a boot-disk mismatch before Lume")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .templateBootDiskMismatch(
                    template: fixture.virtualMachineName,
                    requested: requestedDisk,
                    actual: 100 * SandboxResourcePolicy.gibibyte
                )
            )
        }
    }

    func testDeleteRemovesStoppedOwnedVirtualMachine() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        try await runtime.delete(name: fixture.virtualMachineName)

        let record = try await runtime.inspect(
            name: fixture.virtualMachineName
        )
        XCTAssertNil(record)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.virtualMachineDirectory.path
            )
        )
    }

    func testDeleteMissingVirtualMachineIsIdempotent() async throws {
        let fixture = try FakeLumeFixture(initialState: nil)
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        try await runtime.delete(name: fixture.virtualMachineName)
        try await runtime.delete(name: fixture.virtualMachineName)

        let record = try await runtime.inspect(
            name: fixture.virtualMachineName
        )
        XCTAssertNil(record)
    }

    func testDeleteRefusesRunningVirtualMachine() async throws {
        let fixture = try FakeLumeFixture(initialState: "running")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        do {
            try await runtime.delete(name: fixture.virtualMachineName)
            XCTFail("a running VM must not be deleted")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported(
                    "refusing to delete VM \(fixture.virtualMachineName) while state is running"
                )
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.virtualMachineDirectory.path
            )
        )
    }

    func testDeleteRequiresOwnershipMarker() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        try FileManager.default.removeItem(at: fixture.ownershipMarker)
        let runtime = try fixture.makeRuntime()

        do {
            try await runtime.delete(name: fixture.virtualMachineName)
            XCTFail("an unowned VM must not be deleted")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported(
                    "VM \(fixture.virtualMachineName) is not owned by Darkbloom"
                )
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.virtualMachineDirectory.path
            )
        )
    }

    func testDeleteFailsClosedWhenVirtualMachineRemainsListed() async throws {
        let fixture = try FakeLumeFixture(behavior: "delete-noop")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        do {
            try await runtime.delete(name: fixture.virtualMachineName)
            XCTFail("delete must verify the VM disappeared")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .malformedOutput(
                    "Lume delete completed but VM still exists"
                )
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.virtualMachineDirectory.path
            )
        )
    }

    func testSeparateRuntimesCannotCreateSameVirtualMachine() async throws {
        let fixture = try FakeLumeFixture(
            initialState: nil,
            behavior: "block-create"
        )
        defer { try? fixture.remove() }
        let firstRuntime = try fixture.makeRuntime(commandTimeoutSeconds: 30)
        let secondRuntime = try fixture.makeRuntime(commandTimeoutSeconds: 30)
        let specification = try SandboxVirtualMachineSpecification(
            name: fixture.virtualMachineName,
            resources: SandboxResourceSpecification.macOSSmall(),
            imageSource: .restoreImage(
                url: fixture.restoreImage,
                unattendedPreset: "tahoe"
            ),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte
        )
        let firstCreate = Task {
            try await firstRuntime.create(specification)
        }
        try await fixture.waitForCreateToStart()

        do {
            try await secondRuntime.create(specification)
            XCTFail("a second runtime must not enter the same VM operation")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .operationInProgress(
                    name: fixture.virtualMachineName,
                    operation: "create"
                )
            )
        }

        firstCreate.cancel()
        do {
            try await firstCreate.value
            XCTFail("cancelled create should throw")
        } catch is CancellationError {
        }
    }

    func testOwnershipWriteReplacesMarkerInheritedFromClone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-ownership-replacement-\(UUID().uuidString)",
            isDirectory: true
        )
        let name = "sandbox-clone"
        let virtualMachineDirectory = root.appendingPathComponent(
            name,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: virtualMachineDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = virtualMachineDirectory.appendingPathComponent(
            LumeVirtualMachineOwnership.fileName
        )
        try Data("inherited-template-marker".utf8).write(to: marker)
        let specification = try SandboxVirtualMachineSpecification(
            name: name,
            resources: SandboxResourceSpecification.macOSSmall(),
            imageSource: .localTemplate(name: "sandbox-base"),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte
        )

        try LumeVirtualMachineOwnership.write(
            specification: specification,
            owner: .baseTemplate,
            sourceInstallationID: UUID(),
            to: virtualMachineDirectory
        )

        XCTAssertTrue(
            LumeVirtualMachineOwnership.matches(
                specification: specification,
                owner: .baseTemplate,
                in: root
            )
        )
    }

    func testOwnershipBindsSandboxIdentityAndGenerationAcrossRenewal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-ownership-scope-\(UUID().uuidString)",
            isDirectory: true
        )
        let name = "sandbox-scoped"
        let virtualMachineDirectory = root.appendingPathComponent(
            name,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: virtualMachineDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let specification = try SandboxVirtualMachineSpecification(
            name: name,
            resources: SandboxResourceSpecification.macOSSmall(),
            imageSource: .localTemplate(name: "sandbox-base"),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte
        )
        let sandboxID = SandboxID()
        let generation = try XCTUnwrap(SandboxGeneration(rawValue: 4))
        let initialScope = SandboxOperationScope(
            sandboxID: sandboxID,
            generation: generation,
            fencingToken: try XCTUnwrap(SandboxFencingToken(rawValue: 8))
        )
        let renewedScope = SandboxOperationScope(
            sandboxID: sandboxID,
            generation: generation,
            fencingToken: try XCTUnwrap(SandboxFencingToken(rawValue: 9))
        )
        let nextGenerationScope = SandboxOperationScope(
            sandboxID: sandboxID,
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 5)),
            fencingToken: try XCTUnwrap(SandboxFencingToken(rawValue: 10))
        )

        try LumeVirtualMachineOwnership.write(
            specification: specification,
            owner: .init(operationScope: initialScope),
            sourceInstallationID: UUID(),
            to: virtualMachineDirectory
        )

        XCTAssertTrue(
            LumeVirtualMachineOwnership.matches(
                specification: specification,
                owner: .init(operationScope: renewedScope),
                in: root
            )
        )
        XCTAssertFalse(
            LumeVirtualMachineOwnership.matches(
                specification: specification,
                owner: .init(operationScope: nextGenerationScope),
                in: root
            )
        )
        XCTAssertFalse(
            LumeVirtualMachineOwnership.matches(
                specification: specification,
                owner: .baseTemplate,
                in: root
            )
        )
        XCTAssertThrowsError(
            try LumeVirtualMachineOwnership.requireOwned(
                name: name,
                owner: .init(operationScope: nextGenerationScope),
                in: root
            )
        ) { error in
            XCTAssertEqual(
                error as? SandboxRuntimeError,
                .unsupported(
                    "VM \(name) belongs to a different Darkbloom sandbox scope"
                )
            )
        }
        let marker = try String(
            contentsOf: virtualMachineDirectory.appendingPathComponent(
                LumeVirtualMachineOwnership.fileName
            ),
            encoding: .utf8
        )
        XCTAssertFalse(marker.contains("fencingToken"))
    }

    func testOwnershipRejectsLegacyUnscopedMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-ownership-legacy-\(UUID().uuidString)",
            isDirectory: true
        )
        let name = "sandbox-legacy"
        let virtualMachineDirectory = root.appendingPathComponent(
            name,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: virtualMachineDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = virtualMachineDirectory.appendingPathComponent(
            LumeVirtualMachineOwnership.fileName
        )
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "installationID": UUID().uuidString,
            "name": name,
            "cpuCount": 4,
            "memoryBytes": 8 * SandboxResourcePolicy.gibibyte,
            "diskBytes": 100 * SandboxResourcePolicy.gibibyte,
            "sourceKind": "local_template",
            "sourceReference": "base",
        ]
        try JSONSerialization.data(
            withJSONObject: legacy,
            options: [.sortedKeys]
        ).write(to: marker)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: marker.path
        )

        XCTAssertThrowsError(
            try LumeVirtualMachineOwnership.requireOwned(
                name: name,
                owner: .baseTemplate,
                in: root
            )
        ) { error in
            XCTAssertEqual(
                error as? SandboxRuntimeError,
                .unsupported(
                    "VM \(name) ownership marker has an unsupported version"
                )
            )
        }
    }

    func testOwnershipRejectsACLHardlinkAndPublicDirectoryAuthority() throws {
        enum Mutation {
            case acl
            case hardlink
            case markerACL
            case publicDirectory
        }
        for mutation in [
            Mutation.acl,
            .hardlink,
            .markerACL,
            .publicDirectory,
        ] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "darkbloom-ownership-authority-\(UUID().uuidString)",
                    isDirectory: true
                )
            let name = "sandbox-authority"
            let virtualMachineDirectory = root.appendingPathComponent(
                name,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: virtualMachineDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let specification = try SandboxVirtualMachineSpecification(
                name: name,
                resources: SandboxResourceSpecification.macOSSmall(),
                imageSource: .localTemplate(name: "sandbox-base"),
                diskBytes: 100 * SandboxResourcePolicy.gibibyte
            )
            try LumeVirtualMachineOwnership.write(
                specification: specification,
                owner: .baseTemplate,
                sourceInstallationID: UUID(),
                to: virtualMachineDirectory
            )

            switch mutation {
            case .acl:
                try addExtendedACL(to: virtualMachineDirectory)
            case .hardlink:
                try FileManager.default.linkItem(
                    at: virtualMachineDirectory.appendingPathComponent(
                        LumeVirtualMachineOwnership.fileName
                    ),
                    to: root.appendingPathComponent("marker-alias")
                )
            case .markerACL:
                try addExtendedACL(
                    to: virtualMachineDirectory.appendingPathComponent(
                        LumeVirtualMachineOwnership.fileName
                    )
                )
            case .publicDirectory:
                guard chmod(virtualMachineDirectory.path, 0o755) == 0 else {
                    throw POSIXError(.EACCES)
                }
            }

            XCTAssertFalse(
                LumeVirtualMachineOwnership.matches(
                    specification: specification,
                    owner: .baseTemplate,
                    in: root
                )
            )
            XCTAssertThrowsError(
                try LumeVirtualMachineOwnership.requireOwned(
                    name: name,
                    owner: .baseTemplate,
                    in: root
                )
            )
        }
    }

    func testWorkspaceAndOperationLockRejectExtendedACLAuthority() throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let workspace = LumeRuntimeWorkspace(
            storageDirectory: fixture.storage
        )
        try workspace.prepare()
        try addExtendedACL(to: workspace.locksDirectory)

        XCTAssertThrowsError(
            try LumeVirtualMachineOperationLock(
                workspace: workspace,
                name: fixture.virtualMachineName,
                operation: "test"
            )
        )
    }

    func testOperationLockRejectsHardlinkedLockFile() throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let workspace = LumeRuntimeWorkspace(
            storageDirectory: fixture.storage
        )
        try workspace.prepare()
        do {
            let lock = try LumeVirtualMachineOperationLock(
                workspace: workspace,
                name: fixture.virtualMachineName,
                operation: "test"
            )
            withExtendedLifetime(lock) {}
        }
        let lockFile = workspace.locksDirectory.appendingPathComponent(
            "\(fixture.virtualMachineName).lock"
        )
        try FileManager.default.linkItem(
            at: lockFile,
            to: fixture.directory.appendingPathComponent("lock-alias")
        )

        XCTAssertThrowsError(
            try LumeVirtualMachineOperationLock(
                workspace: workspace,
                name: fixture.virtualMachineName,
                operation: "test"
            )
        )
    }

    func testWorkspaceRejectsSymlinkedStorageAncestor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-workspace-symlink-\(UUID().uuidString)",
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

        XCTAssertThrowsError(
            try LumeRuntimeWorkspace(
                storageDirectory: alias.appendingPathComponent(
                    "vms",
                    isDirectory: true
                )
            ).prepare()
        )
    }

    private func addExtendedACL(to url: URL) throws {
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            )
        )
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = [
            "+a",
            isDirectory.boolValue
                ? "everyone allow read,write,execute,file_inherit,directory_inherit"
                : "everyone allow read,write",
            url.path,
        ]
        try chmod.run()
        chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
    }
}

private struct FakeLumeFixture {
    let directory: URL
    let runtimeDirectory: URL
    let executable: URL
    let storage: URL
    let state: URL
    let behavior: URL
    let createStarted: URL
    let listStarted: URL
    let listContinue: URL
    let guestCommandStarted: URL
    let guestReadinessProbeAttemptsFile: URL
    let guestReadinessProbeStarted: URL
    let guestReadinessProbeProcessIdentifier: URL
    let invalidGuestReadinessProbe: URL
    let guestExecutorProbeObserved: URL
    let restoreImage: URL
    let virtualMachineName = "sandbox-failure-test"

    var virtualMachineDirectory: URL {
        storage.appendingPathComponent(
            virtualMachineName,
            isDirectory: true
        )
    }

    var ownershipMarker: URL {
        virtualMachineDirectory.appendingPathComponent(
            LumeVirtualMachineOwnership.fileName
        )
    }

    var provenanceFile: URL {
        runtimeDirectory.appendingPathComponent("lume.provenance.json")
    }

    init(
        writeProvenance: Bool = true,
        initialState: String? = "stopped",
        behavior: String = "normal"
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-fake-lume-\(UUID().uuidString)",
            isDirectory: true
        )
        runtimeDirectory = directory.appendingPathComponent(
            "runtime",
            isDirectory: true
        )
        executable = runtimeDirectory.appendingPathComponent("lume")
        storage = directory.appendingPathComponent("vms", isDirectory: true)
        state = directory.appendingPathComponent("state")
        self.behavior = directory.appendingPathComponent("behavior")
        createStarted = directory.appendingPathComponent("create-started")
        listStarted = directory.appendingPathComponent("list-started")
        listContinue = directory.appendingPathComponent("list-continue")
        guestCommandStarted = directory.appendingPathComponent(
            "guest-command-started"
        )
        guestReadinessProbeAttemptsFile = directory.appendingPathComponent(
            "guest-readiness-probe-attempts"
        )
        guestReadinessProbeStarted = directory.appendingPathComponent(
            "guest-readiness-probe-started"
        )
        guestReadinessProbeProcessIdentifier = directory.appendingPathComponent(
            "guest-readiness-probe-pid"
        )
        invalidGuestReadinessProbe = directory.appendingPathComponent(
            "invalid-guest-readiness-probe"
        )
        guestExecutorProbeObserved = directory.appendingPathComponent(
            "guest-executor-probe-observed"
        )
        restoreImage = directory.appendingPathComponent("restore.ipsw")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        if let initialState {
            try Data("\(initialState)\n".utf8).write(to: state)
            let virtualMachineDirectory = storage.appendingPathComponent(
                virtualMachineName,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: virtualMachineDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try Self.writeOwnershipMarker(
                to: virtualMachineDirectory,
                name: virtualMachineName
            )
        }
        try Data("\(behavior)\n".utf8).write(to: self.behavior)
        try Data().write(to: restoreImage)
        try Data(Self.script.utf8).write(to: executable)
        guard chmod(executable.path, 0o555) == 0 else {
            throw POSIXError(.EACCES)
        }
        if writeProvenance {
            try Self.writeProvenance(
                beside: executable,
                binaryDigest: Self.sha256(of: executable)
            )
        }
        guard chmod(runtimeDirectory.path, 0o555) == 0 else {
            throw POSIXError(.EACCES)
        }
    }

    func makeRuntime(
        commandTimeoutSeconds: UInt32 = 1,
        guestReadinessPolicy: LumeGuestReadinessPolicy = .standard
    ) throws -> LumeVirtualMachineRuntime {
        LumeVirtualMachineRuntime(
            configuration: try LumeRuntimeConfiguration(
                executable: executable,
                storageDirectory: storage,
                commandTimeoutSeconds: commandTimeoutSeconds,
                createTimeoutSeconds: commandTimeoutSeconds,
                trustPolicy: .developmentAdHoc,
                guestCommandPolicy: .baseImagePreparationAndDevelopment
            ),
            guestReadinessPolicy: guestReadinessPolicy
        )
    }

    func makeCapacityArbiter(
        clock: LumeTestWallClock,
        availableStorageBytes:
            @escaping @Sendable () throws -> UInt64 = { UInt64.max }
    ) throws -> SandboxHostCapacityArbiter {
        let storageIdentity = try SandboxStorageVolumeInspector().inspect(
            path: storage
        ).identity
        let arbiter = try SandboxHostCapacityArbiter(
            stateDirectory: directory.appendingPathComponent(
                "capacity",
                isDirectory: true
            ),
            policy: SandboxCapacityPolicy(
                maximumReservedCPUCount: 8,
                maximumReservedMemoryBytes:
                    16 * SandboxResourcePolicy.gibibyte,
                maximumReservedGrowthBytes:
                    300 * SandboxResourcePolicy.gibibyte,
                storageHeadroomBytes:
                    20 * SandboxResourcePolicy.gibibyte
            ),
            storageIdentity: storageIdentity,
            currentDate: { clock.now() },
            availableStorageBytes: availableStorageBytes
        )
        _ = try arbiter.initialize()
        _ = try arbiter.setMode(.sandboxDedicated)
        return arbiter
    }

    func makeLeaseFencedRuntime(
        capacityArbiter: SandboxHostCapacityArbiter
    ) throws -> LumeLeaseFencedVirtualMachineRuntime {
        try LumeLeaseFencedVirtualMachineRuntime(
            configuration: try LumeRuntimeConfiguration(
                executable: executable,
                storageDirectory: storage,
                commandTimeoutSeconds: 5,
                createTimeoutSeconds: 5,
                trustPolicy: .developmentAdHoc
            ),
            capacityArbiter: capacityArbiter
        )
    }

    func bindOwnership(to scope: SandboxOperationScope) throws {
        try Self.writeOwnershipMarker(
            to: virtualMachineDirectory,
            name: virtualMachineName,
            owner: .init(operationScope: scope)
        )
    }

    func waitForState(_ expected: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        repeat {
            let contents = try? String(contentsOf: state, encoding: .utf8)
            let value = contents?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if value == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline
        throw FakeLumeFixtureError.stateTimeout(expected)
    }

    func waitForCreateToStart() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        repeat {
            if FileManager.default.fileExists(atPath: createStarted.path) {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline
        throw FakeLumeFixtureError.createStartTimeout
    }

    func waitForListToStart() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        repeat {
            if FileManager.default.fileExists(atPath: listStarted.path) {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline
        throw FakeLumeFixtureError.listStartTimeout
    }

    func allowListToContinue() throws {
        try Data().write(to: listContinue)
    }

    var guestCommandWasStarted: Bool {
        FileManager.default.fileExists(atPath: guestCommandStarted.path)
    }

    var guestReadinessProbeAttempts: Int {
        guard let contents = try? String(
            contentsOf: guestReadinessProbeAttemptsFile,
            encoding: .utf8
        ) else {
            return 0
        }
        return Int(
            contents.trimmingCharacters(in: .whitespacesAndNewlines)
        ) ?? 0
    }

    var invalidGuestReadinessProbeWasObserved: Bool {
        FileManager.default.fileExists(
            atPath: invalidGuestReadinessProbe.path
        )
    }

    var guestExecutorProbeWasObserved: Bool {
        FileManager.default.fileExists(
            atPath: guestExecutorProbeObserved.path
        )
    }

    func waitForGuestReadinessProbeToStart() async throws -> pid_t {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        repeat {
            if FileManager.default.fileExists(
                atPath: guestReadinessProbeStarted.path
            ),
               let contents = try? String(
                   contentsOf: guestReadinessProbeProcessIdentifier,
                   encoding: .utf8
               ),
               let processIdentifier = Int32(
                   contents.trimmingCharacters(
                       in: .whitespacesAndNewlines
                   )
               )
            {
                return processIdentifier
            }
            try await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline
        throw FakeLumeFixtureError.guestReadinessProbeStartTimeout
    }

    func waitForProcessExit(_ processIdentifier: pid_t) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        repeat {
            if kill(processIdentifier, 0) != 0, errno == ESRCH {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline
        throw FakeLumeFixtureError.processExitTimeout(processIdentifier)
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: runtimeDirectory.path
        )
        try FileManager.default.removeItem(at: directory)
    }

    func replacePatchDigest(_ digest: String) throws {
        let data = try Data(contentsOf: provenanceFile)
        guard var object = try JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any]
        else {
            throw POSIXError(.EINVAL)
        }
        guard var patches = object["patches"] as? [String: String] else {
            throw POSIXError(.EINVAL)
        }
        patches[LumeRuntimeConfiguration.pinnedPatchPath] = digest
        object["patches"] = patches
        let replacement = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        guard chmod(provenanceFile.path, 0o644) == 0 else {
            throw POSIXError(.EACCES)
        }
        let handle = try FileHandle(forWritingTo: provenanceFile)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.close()
        guard chmod(provenanceFile.path, 0o444) == 0 else {
            throw POSIXError(.EACCES)
        }
    }

    private static func writeProvenance(
        beside executable: URL,
        binaryDigest: String
    ) throws {
        let object: [String: Any] = [
            "schema_version": 3,
            "repository": LumeRuntimeConfiguration.pinnedRepository,
            "commit": LumeRuntimeConfiguration.pinnedCommit,
            "source_path": LumeRuntimeConfiguration.pinnedSourcePath,
            "version": LumeRuntimeConfiguration.pinnedVersion,
            "patches": LumeRuntimeConfiguration.pinnedPatches,
            "directories": [],
            "files": ["lume": binaryDigest],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let destination = executable
            .deletingLastPathComponent()
            .appendingPathComponent("lume.provenance.json")
        try data.write(
            to: destination
        )
        guard chmod(destination.path, 0o444) == 0 else {
            throw POSIXError(.EACCES)
        }
    }

    private static func writeOwnershipMarker(
        to virtualMachineDirectory: URL,
        name: String,
        owner: LumeVirtualMachineOwnership.Owner = .baseTemplate
    ) throws {
        try LumeVirtualMachineOwnership.write(
            specification: SandboxVirtualMachineSpecification(
                name: name,
                resources: SandboxResourceSpecification.macOSSmall(),
                imageSource: .localTemplate(name: "base"),
                diskBytes: 100 * SandboxResourcePolicy.gibibyte
            ),
            owner: owner,
            sourceInstallationID: UUID(),
            to: virtualMachineDirectory
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let script = """
    #!/bin/sh
    set -eu
    root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
    state_file="$root/state"
    behavior="$(tr -d '\\n' < "$root/behavior")"
    command="${1:-}"
    case "$command" in
      --version)
        printf '%s\\n' "0.5.3"
        ;;
      ls)
        storage=""
        shift
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --storage)
              storage="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        if [ "$behavior" = "block-first-list" ] && [ ! -f "$root/list-started" ]; then
          : > "$root/list-started"
          while [ ! -f "$root/list-continue" ]; do
            /bin/sleep 0.01
          done
        fi
        if [ ! -f "$state_file" ] || [ ! -d "$storage/sandbox-failure-test" ]; then
          printf '%s\\n' '[]'
          exit 0
        fi
        if [ "$behavior" = "log-info-on-list" ] && [ "${LUME_LOG_LEVEL:-info}" != "error" ]; then
          printf '%s\\n' '[2026-08-23T02:50:37Z] INFO: dependency diagnostic'
        fi
        state="$(tr -d '\\n' < "$state_file")"
        ready=false
        if [ "$state" = "ready" ]; then
          ready=true
          state=running
        elif [ "$state" = "running" ]; then
          case "$behavior" in
            credentialed-readiness-*)
              ready=true
              ;;
          esac
        fi
        printf '[{"name":"sandbox-failure-test","cpuCount":4,'
        printf '"memorySize":8589934592,"diskSize":{"total":107374182400},'
        printf '"status":"%s","sshAvailable":%s}]\\n' "$state" "$ready"
        ;;
      run)
        trap 'printf "%s\\n" "stopped" > "$state_file"; exit 0' EXIT HUP INT TERM
        printf '%s\\n' "running" > "$state_file"
        while IFS= read -r current_state < "$state_file"; do
          if [ "$current_state" = "stopped" ]; then
            exit 0
          fi
        done
        ;;
      ssh)
        : > "$root/guest-command-started"
        case "$behavior" in
          guest-command-success)
            command_attempts=0
            if [ -f "$root/guest-readiness-probe-attempts" ]; then
              command_attempts="$(tr -d '\\n' < "$root/guest-readiness-probe-attempts")"
            fi
            command_attempts=$((command_attempts + 1))
            printf '%s\\n' "$command_attempts" \
              > "$root/guest-readiness-probe-attempts"
            printf '%s\\n' '{"magic":"darkbloom_guest_result","schema_version":2,"exit_code":0,"stdout_length":0,"stderr_length":0,"stdout_truncated":false,"stderr_truncated":false,"timed_out":false,"stdout_base64":"","stderr_base64":""}'
            exit 0
            ;;
          guest-command-transport-failure)
            command_attempts=0
            if [ -f "$root/guest-readiness-probe-attempts" ]; then
              command_attempts="$(tr -d '\\n' < "$root/guest-readiness-probe-attempts")"
            fi
            command_attempts=$((command_attempts + 1))
            printf '%s\\n' "$command_attempts" \
              > "$root/guest-readiness-probe-attempts"
            if [ "$command_attempts" -eq 1 ]; then
              printf '%s\\n' "simulated SSH transport failure" >&2
              exit 69
            fi
            exit 0
            ;;
          guest-command-timeout)
            command_attempts=0
            if [ -f "$root/guest-readiness-probe-attempts" ]; then
              command_attempts="$(tr -d '\\n' < "$root/guest-readiness-probe-attempts")"
            fi
            command_attempts=$((command_attempts + 1))
            printf '%s\\n' "$command_attempts" \
              > "$root/guest-readiness-probe-attempts"
            if [ "$command_attempts" -eq 1 ]; then
              printf '%s\\n' '{"magic":"darkbloom_guest_result","schema_version":2,"exit_code":124,"stdout_length":0,"stderr_length":0,"stdout_truncated":false,"stderr_truncated":false,"timed_out":true,"stdout_base64":"","stderr_base64":""}'
            fi
            exit 0
            ;;
          credentialed-readiness-*)
            expected_probe_prefix="/usr/bin/printf '%s' '"
            expected_probe_suffix="' | /usr/bin/base64 -D | /bin/zsh -f"
            valid_probe_command=false
            case "$8" in
              "$expected_probe_prefix"*"$expected_probe_suffix")
                valid_probe_command=true
                ;;
            esac
            if [ "$#" -ne 8 ] \
              || [ "$2" != "sandbox-failure-test" ] \
              || [ "$3" != "--storage" ] \
              || [ "$4" != "$root/vms" ] \
              || [ "$5" != "--timeout" ] \
              || [ "$6" != "35" ] \
              || [ "$7" != "--nio-only" ] \
              || [ "$valid_probe_command" != "true" ] \
              || [ "${LUME_HOME:-}" != "$root/vms/.darkbloom-runtime" ] \
              || [ "${LUME_LOG_LEVEL:-}" != "error" ] \
              || [ "${LUME_TELEMETRY_ENABLED:-}" != "false" ] \
              || [ "${LANG:-}" != "C" ] \
              || [ "${LC_ALL:-}" != "C" ] \
              || [ "${NO_COLOR:-}" != "1" ] \
              || [ "${XDG_CACHE_HOME:-}" != "$root/vms/.darkbloom-runtime/cache" ] \
              || [ "${XDG_CONFIG_HOME:-}" != "$root/vms/.darkbloom-runtime/config" ]; then
              : > "$root/invalid-guest-readiness-probe"
              printf '%s\\n' "invalid credentialed readiness probe" >&2
              exit 64
            fi
            : > "$root/guest-executor-probe-observed"
            probe_attempts=0
            if [ -f "$root/guest-readiness-probe-attempts" ]; then
              probe_attempts="$(tr -d '\\n' < "$root/guest-readiness-probe-attempts")"
            fi
            probe_attempts=$((probe_attempts + 1))
            printf '%s\\n' "$probe_attempts" \
              > "$root/guest-readiness-probe-attempts"
            case "$behavior" in
              credentialed-readiness-transient)
                case "$probe_attempts" in
                  1)
                    printf '%s\\n' "SSH authentication failed" >&2
                    exit 69
                    ;;
                  2)
                    printf '%s\\n' "$$" > "$root/guest-readiness-probe-pid"
                    : > "$root/guest-readiness-probe-started"
                    while :; do :; done
                    ;;
                  3)
                    /bin/dd if=/dev/zero bs=8192 count=1 2>/dev/null
                    exit 0
                    ;;
                esac
                ;;
              credentialed-readiness-blocking)
                printf '%s\\n' "$$" > "$root/guest-readiness-probe-pid"
                : > "$root/guest-readiness-probe-started"
                while :; do :; done
                ;;
              credentialed-readiness-empty-first)
                if [ "$probe_attempts" -eq 1 ]; then
                  exit 0
                fi
                ;;
            esac
            printf '%s\\n' '{"magic":"darkbloom_guest_result","schema_version":2,"exit_code":0,"stdout_length":0,"stderr_length":0,"stdout_truncated":false,"stderr_truncated":false,"timed_out":false,"stdout_base64":"","stderr_base64":""}'
            exit 0
            ;;
        esac
        printf '%s\\n' "unexpected fake Lume guest command" >&2
        exit 64
        ;;
      stop)
        if [ "$behavior" = "stop-liveness-inconclusive" ]; then
          printf '%s\\n' "VM liveness is inconclusive" >&2
          exit 70
        fi
        printf '%s\\n' "stopped" > "$state_file"
        ;;
      create)
        name="$2"
        shift 2
        storage=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --storage)
              storage="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        test -n "$storage"
        mkdir -p "$storage/$name"
        printf '%s\\n' "provisioning" > "$state_file"
        operation_root="$(dirname "${XDG_CONFIG_HOME:?}")"
        mkdir -p "$operation_root/temporary-vms/fake-install"
        : > "$root/create-started"
        if [ "$behavior" = "block-create" ]; then
          while :; do :; done
        fi
        rm -rf "$operation_root/temporary-vms/fake-install"
        printf '%s\\n' "stopped" > "$state_file"
        ;;
      delete)
        name="$2"
        shift 2
        storage=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --storage)
              storage="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        if [ "$behavior" = "delete-noop" ]; then
          exit 0
        fi
        rm -rf "$storage/$name"
        rm -f "$state_file"
        ;;
      *)
        printf '%s\\n' "unsupported fake Lume command: $command" >&2
        exit 64
        ;;
    esac
    """
}

private enum FakeLumeFixtureError: Error {
    case stateTimeout(String)
    case createStartTimeout
    case listStartTimeout
    case guestReadinessProbeStartTimeout
    case processExitTimeout(pid_t)
}

private final class LumeTestWallClock: @unchecked Sendable {
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

private final class LumeTestStorageAvailability: @unchecked Sendable {
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

private actor LumeRenewalStatus {
    private(set) var started = false
    private(set) var completed = false

    func markStarted() {
        started = true
    }

    func markCompleted() {
        completed = true
    }
}
