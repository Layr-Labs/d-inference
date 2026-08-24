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

    func testLeaseFencedOperationsRejectOwnershipResourceDrift() async throws {
        let fixture = try FakeLumeFixture(
            initialState: "running",
            behavior: "guest-command-success"
        )
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let leaseResources = try SandboxResourceSpecification(
            cpuCount: 2,
            memoryBytes: 8 * SandboxResourcePolicy.gibibyte,
            workspaceBytes: 25 * SandboxResourcePolicy.gibibyte,
            commandTimeoutSeconds: 900
        )
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: leaseResources,
            expiresAt: now.addingTimeInterval(120)
        )
        try fixture.bindOwnership(to: lease.scope)
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter,
            guestCommandPolicy: .baseImagePreparationAndDevelopment
        )

        do {
            _ = try await runtime.inspect(
                scope: lease.scope,
                name: lease.virtualMachineName
            )
            XCTFail("inspect must reject lease/ownership resource drift")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .leaseResourceMismatch)
        }
        do {
            try await runtime.start(
                scope: lease.scope,
                name: lease.virtualMachineName
            )
            XCTFail("start must reject lease/ownership resource drift")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .leaseResourceMismatch)
        }
        do {
            _ = try await runtime.execute(
                scope: lease.scope,
                name: lease.virtualMachineName,
                request: try SandboxGuestCommandRequest(
                    idempotencyKey: UUID(),
                    executable: "/usr/bin/true",
                    timeoutSeconds: 30
                )
            )
            XCTFail("execute must reject lease/ownership resource drift")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .leaseResourceMismatch)
        }
        do {
            try await runtime.stop(
                scope: lease.scope,
                name: lease.virtualMachineName
            )
            XCTFail("stop must reject lease/ownership resource drift")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .leaseResourceMismatch)
        }
        do {
            try await runtime.release(
                scope: lease.scope,
                name: lease.virtualMachineName
            )
            XCTFail("release must reject lease/ownership resource drift")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .leaseResourceMismatch)
        }

        XCTAssertFalse(fixture.guestCommandWasStarted)
        XCTAssertEqual(try arbiter.snapshot().leases, [lease])
        let retainedState = try await fixture.makeRuntime().inspect(
            name: lease.virtualMachineName
        )?.state
        XCTAssertEqual(retainedState, .running)
    }

    func testLeaseFencedInspectRejectsObservedResourceDrift() async throws {
        let fixture = try FakeLumeFixture(initialState: "stopped")
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LumeTestWallClock(now)
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let committedResources = try SandboxResourceSpecification(
            cpuCount: 2,
            memoryBytes: 8 * SandboxResourcePolicy.gibibyte,
            workspaceBytes: 25 * SandboxResourcePolicy.gibibyte,
            commandTimeoutSeconds: 900
        )
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: committedResources,
            expiresAt: now.addingTimeInterval(120)
        )
        try fixture.bindOwnership(
            to: lease.scope,
            resources: committedResources
        )
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )

        do {
            _ = try await runtime.inspect(
                scope: lease.scope,
                name: lease.virtualMachineName
            )
            XCTFail("inspect must reject observed VM resource drift")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .leaseResourceMismatch)
        }
        XCTAssertEqual(try arbiter.snapshot().leases, [lease])
    }

    func testExpiredReconciliationRetainsResourceMismatchedLease()
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
            resources: try SandboxResourceSpecification(
                cpuCount: 2,
                memoryBytes: 8 * SandboxResourcePolicy.gibibyte,
                workspaceBytes: 25 * SandboxResourcePolicy.gibibyte,
                commandTimeoutSeconds: 900
            ),
            expiresAt: now.addingTimeInterval(30)
        )
        try fixture.bindOwnership(to: lease.scope)
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )
        clock.set(lease.expiresAt)

        let results = try await runtime.reconcileExpiredLeases()

        XCTAssertEqual(results.count, 1)
        guard case .retained(let detail) = results[0].outcome else {
            return XCTFail("resource mismatch must retain capacity")
        }
        XCTAssertTrue(detail.contains("does not authorize these resources"))
        let retained = try XCTUnwrap(arbiter.snapshot().leases.first)
        XCTAssertGreaterThan(
            retained.scope.fencingToken,
            lease.scope.fencingToken
        )
        let state = try await fixture.makeRuntime().inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(state, .running)
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

    func testExpiredLeaseReconciliationReleasesAfterBrokerCrashStopsChild()
        async throws
    {
        let fixture = try FakeLumeFixture(
            behavior: "pause-run-before-state-publication"
        )
        var startHolder: Process?
        defer {
            try? fixture.allowRunToPublishState()
            try? fixture.forceControlledRunState("stopped")
            if let process = startHolder, process.isRunning {
                process.terminate()
            }
            fixture.terminateControlledRunIfNeeded()
            try? fixture.remove()
        }
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
        let launchedStartHolder =
            try fixture.launchStartHolderSubprocess(now: now)
        startHolder = launchedStartHolder
        let controlledRunProcessIdentifier =
            try await fixture.waitForControlledRunToLaunch(
                startHolder: launchedStartHolder
            )

        try fixture.crashStartHolder()
        try await fixture.waitForStartHolderCrash(
            startHolder: launchedStartHolder,
            controlledRunProcessIdentifier: controlledRunProcessIdentifier
        )
        try await fixture.waitForState("stopped")
        clock.set(lease.expiresAt)
        let reopenedArbiter = try fixture.makeCapacityArbiter(clock: clock)
        let reopenedRuntime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: reopenedArbiter
        )

        let results = try await reopenedRuntime.reconcileExpiredLeases()

        XCTAssertEqual(results.count, 1)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.outcome, .released)
        XCTAssertGreaterThan(
            result.lease.scope.fencingToken,
            lease.scope.fencingToken
        )
        XCTAssertTrue(try reopenedArbiter.snapshot().leases.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.startIntentFile.path
            )
        )
    }

    func testUnpublishedStartCrashHolderSubprocess() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath =
            environment[FakeLumeFixture.startHolderFixtureEnvironmentKey],
            let nowValue =
            environment[FakeLumeFixture.startHolderNowEnvironmentKey],
            let nowInterval = TimeInterval(nowValue)
        else {
            throw XCTSkip("subprocess-only lifecycle crash harness")
        }
        let fixture = FakeLumeFixture(
            existingDirectory: URL(fileURLWithPath: fixturePath)
        )
        let clock = LumeTestWallClock(
            Date(timeIntervalSince1970: nowInterval)
        )
        let arbiter = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try XCTUnwrap(arbiter.snapshot().leases.first)
        let runtime = try fixture.makeLeaseFencedRuntime(
            capacityArbiter: arbiter
        )

        try await runtime.start(
            scope: lease.scope,
            name: lease.virtualMachineName
        )
        XCTFail("the parent test must crash this runtime before start returns")
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
                    command: "lume stop",
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

    func testSignalFallbackRetainsCapacityWithoutStoppedProof()
        async throws
    {
        let fixture = try FakeLumeFixture(
            behavior: "credentialed-readiness-uncooperative"
        )
        defer {
            fixture.terminateControlledRunIfNeeded()
            try? fixture.remove()
        }
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
            capacityArbiter: arbiter,
            commandTimeoutSeconds: 1
        )
        try await runtime.start(
            scope: lease.scope,
            name: lease.virtualMachineName
        )

        do {
            try await runtime.release(
                scope: lease.scope,
                name: lease.virtualMachineName
            )
            XCTFail("fallback termination cannot release unproven capacity")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .commandFailed(
                    command: "lume stop",
                    exitCode: 70,
                    stderr: "VM liveness is inconclusive"
                )
            )
        }

        XCTAssertEqual(try arbiter.snapshot().leases, [lease])
        XCTAssertTrue(fixture.crossProcessStopWasInvoked)
    }

    func testPublicReleaseResolvesUnresolvedStartOnlyWithStoppedProof()
        async throws
    {
        for unresolvedState in ["stopped", "unknown", "absent"] {
            let fixture = try FakeLumeFixture()
            defer { try? fixture.remove() }
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            let clock = LumeTestWallClock(now)
            let arbiter = try fixture.makeCapacityArbiter(clock: clock)
            let lease = try arbiter.reserve(
                sandboxID: SandboxID(),
                generation: try XCTUnwrap(
                    SandboxGeneration(rawValue: 1)
                ),
                virtualMachineName: fixture.virtualMachineName,
                resources: try SandboxResourceSpecification.macOSSmall(),
                expiresAt: now.addingTimeInterval(120)
            )
            try fixture.bindOwnership(to: lease.scope)
            _ = try fixture.persistStartIntent(scope: lease.scope)
            if unresolvedState == "absent" {
                try FileManager.default.removeItem(at: fixture.state)
            } else {
                try Data("\(unresolvedState)\n".utf8).write(
                    to: fixture.state
                )
            }
            let runtime = try fixture.makeLeaseFencedRuntime(
                capacityArbiter: arbiter
            )

            if unresolvedState == "stopped" {
                try await runtime.release(
                    scope: lease.scope,
                    name: lease.virtualMachineName
                )
                XCTAssertTrue(try arbiter.snapshot().leases.isEmpty)
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: fixture.startIntentFile.path
                    )
                )
                continue
            }
            do {
                try await runtime.release(
                    scope: lease.scope,
                    name: lease.virtualMachineName
                )
                XCTFail(
                    "\(unresolvedState) must retain unresolved start capacity"
                )
            } catch let error as SandboxRuntimeError {
                XCTAssertEqual(
                    error,
                    .unsupported(
                        "VM \(fixture.virtualMachineName) has an unresolved start intent"
                    )
                )
            }
            XCTAssertEqual(try arbiter.snapshot().leases, [lease])
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.startIntentFile.path
                )
            )
        }
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

    func testStartPersistsIntentBeforeSpawnAndClearsAfterRunningProof()
        async throws
    {
        let fixture = try FakeLumeFixture(
            behavior: "credentialed-readiness-start-intent"
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

        XCTAssertTrue(fixture.startIntentWasObserved)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.startIntentFile.path
            )
        )
        try await runtime.stop(name: fixture.virtualMachineName)
    }

    func testFailedStartClearsIntentOnlyAfterProvenStopped() async throws {
        let fixture = try FakeLumeFixture(
            behavior: "failed-start-before-state-publication"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 1)

        do {
            try await runtime.start(name: fixture.virtualMachineName)
            XCTFail("start must time out before Lume publishes running")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .operationTimedOut(
                    "\(fixture.virtualMachineName) -> running"
                )
            )
        }

        XCTAssertTrue(fixture.startIntentWasObserved)
        let stoppedRecord = try await runtime.inspect(
            name: fixture.virtualMachineName
        )
        XCTAssertEqual(
            stoppedRecord?.state,
            .stopped
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.startIntentFile.path
            )
        )
    }

    func testSpawnFailureClearsIntentBecauseNoChildExists() async throws {
        let fixture = try FakeLumeFixture(
            behavior: "disable-executable-after-list"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        do {
            try await runtime.start(name: fixture.virtualMachineName)
            XCTFail("start must fail when the executable disappears before spawn")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .executableNotFound(fixture.executable.path)
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.startIntentFile.path
            )
        )
    }

    func testStartIntentClearFailureSurfacesAndRetainsCapacity()
        async throws
    {
        let fixture = try FakeLumeFixture(
            behavior: "hardlink-start-intent-before-running"
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
            try await runtime.start(
                scope: lease.scope,
                name: lease.virtualMachineName
            )
            XCTFail("unsafe intent authority must fail start and cleanup")
        } catch let error as SandboxRuntimeError {
            guard case .cleanupFailed(_, _, let cleanup) = error else {
                return XCTFail("expected cleanup failure, got \(error)")
            }
            XCTAssertTrue(
                cleanup.contains(
                    "start intent failed ownership, mode, ACL, link, size, or stability checks"
                )
            )
        }

        XCTAssertEqual(try arbiter.snapshot().leases, [lease])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.startIntentFile.path
            )
        )
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

    func testCancelledExecuteStopsLocallyManagedRunThroughCooperativeOwner()
        async throws
    {
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
        try fixture.resetGuestCommandObservation()
        try fixture.setBehavior(
            "block-first-list-stop-liveness-inconclusive"
        )
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
        XCTAssertFalse(
            fixture.crossProcessStopWasInvoked,
            "a locally owned run must stop through inherited EOF"
        )
    }

    func testStopUsesRecordThatSatisfiedTerminalStateWait() async throws {
        let fixture = try FakeLumeFixture(
            initialState: "running",
            behavior: "regress-after-first-stopped-observation"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 4)

        try await runtime.stop(name: fixture.virtualMachineName)

        XCTAssertTrue(fixture.stopStateProofWasConsumed)
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

    func testDeleteAndRecreateCannotBypassUnresolvedStartIntent()
        async throws
    {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        _ = try fixture.persistStartIntent()
        let runtime = try fixture.makeRuntime()
        let expectedError = SandboxRuntimeError.unsupported(
            "VM \(fixture.virtualMachineName) has an unresolved start intent"
        )

        do {
            try await runtime.delete(name: fixture.virtualMachineName)
            XCTFail("delete must not remove an unresolved start intent")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(error, expectedError)
        }
        do {
            try await runtime.create(
                SandboxVirtualMachineSpecification(
                    name: fixture.virtualMachineName,
                    resources: SandboxResourceSpecification.macOSSmall(),
                    imageSource: .localTemplate(name: "base"),
                    diskBytes: 100 * SandboxResourcePolicy.gibibyte
                )
            )
            XCTFail("idempotent create must not bypass a start intent")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(error, expectedError)
        }
        let listedRecord = try await runtime.inspect(
            name: fixture.virtualMachineName
        )
        XCTAssertNotNil(listedRecord)

        try FileManager.default.removeItem(at: fixture.state)
        do {
            try await runtime.create(
                SandboxVirtualMachineSpecification(
                    name: fixture.virtualMachineName,
                    resources: SandboxResourceSpecification.macOSSmall(),
                    imageSource: .localTemplate(name: "base"),
                    diskBytes: 100 * SandboxResourcePolicy.gibibyte
                )
            )
            XCTFail("reforge must not bypass an unlisted start intent")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(error, expectedError)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.startIntentFile.path
            )
        )
        let unlistedRecord = try await runtime.inspect(
            name: fixture.virtualMachineName
        )
        XCTAssertNil(unlistedRecord)
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
