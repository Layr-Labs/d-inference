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
                    16 * SandboxResourcePolicy.gibibyte
            ),
            currentDate: { clock.now() }
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
        let runtime = LumeLeaseFencedVirtualMachineRuntime(
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

    func testAuthenticatedReadinessUsesProductionGuestCommandWrapper() throws {
        let idempotencyKey = UUID(
            uuidString: "B57A4FA2-BCA8-45EF-A7D8-F4A20FE85DBA"
        )!
        let expected = try LumeGuestCommandEncoder.encode(
            SandboxGuestCommandRequest(
                idempotencyKey: idempotencyKey,
                executable: "/usr/bin/true",
                timeoutSeconds:
                    LumeGuestReadinessProbe.guestCommandTimeoutSeconds
            )
        )

        XCTAssertEqual(
            try LumeGuestReadinessProbe.command(
                idempotencyKey: idempotencyKey
            ),
            expected
        )
        XCTAssertEqual(LumeGuestReadinessProbe.lumeTimeoutSeconds, 35)
        XCTAssertEqual(
            LumeGuestReadinessPolicy.production.attemptTimeoutSeconds,
            40
        )
    }

    func testStartWarmsProductionGuestCommandPathBeforeReturning() async throws {
        let fixture = try FakeLumeFixture(
            behavior: "authenticated-readiness-executor"
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
            behavior: "authenticated-readiness-empty-first"
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

    func testAuthenticatedReadinessRetriesTransientFailuresBeforeSuccess()
        async throws
    {
        let fixture = try FakeLumeFixture(
            behavior: "authenticated-readiness-transient"
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

    func testAlreadyRunningTCPReadyGuestStillRequiresAuthenticatedProbe()
        async throws
    {
        let fixture = try FakeLumeFixture(
            initialState: "ready",
            behavior: "authenticated-readiness-blocking"
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

    func testAuthenticatedReadinessDeadlineStopsNewlyStartedVirtualMachine()
        async throws
    {
        let fixture = try FakeLumeFixture(
            behavior: "authenticated-readiness-blocking"
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
            XCTFail("unauthenticated guest readiness must time out")
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

    func testCancelledAuthenticatedReadinessCleansUpProbeAndVirtualMachine()
        async throws
    {
        let fixture = try FakeLumeFixture(
            behavior: "authenticated-readiness-blocking"
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
                withIntermediateDirectories: false
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
        guestReadinessPolicy: LumeGuestReadinessPolicy = .production
    ) throws -> LumeVirtualMachineRuntime {
        LumeVirtualMachineRuntime(
            configuration: try LumeRuntimeConfiguration(
                executable: executable,
                storageDirectory: storage,
                commandTimeoutSeconds: commandTimeoutSeconds,
                createTimeoutSeconds: commandTimeoutSeconds,
                trustPolicy: .developmentAdHoc
            ),
            guestReadinessPolicy: guestReadinessPolicy
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
        object["patches"] = [
            LumeRuntimeConfiguration.pinnedPatchPath: digest
        ]
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
            "patches": [
                LumeRuntimeConfiguration.pinnedPatchPath:
                    LumeRuntimeConfiguration.pinnedPatchSHA256
            ],
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
          while :; do :; done
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
            authenticated-readiness-*)
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
          authenticated-readiness-*)
            expected_probe_prefix="/usr/bin/printf '%s' '"
            expected_probe_suffix="' | /usr/bin/base64 -D | /bin/zsh"
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
              printf '%s\\n' "invalid authenticated readiness probe" >&2
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
              authenticated-readiness-transient)
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
              authenticated-readiness-blocking)
                printf '%s\\n' "$$" > "$root/guest-readiness-probe-pid"
                : > "$root/guest-readiness-probe-started"
                while :; do :; done
                ;;
              authenticated-readiness-empty-first)
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
