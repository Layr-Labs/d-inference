import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeGuestCommandLifecycleTests: XCTestCase {
    func testLeaseFencedExecuteSucceedsWithExplicitDevelopmentPolicy()
        async throws
    {
        let fixture = try FakeLumeFixture(
            initialState: "running",
            behavior: "guest-command-success"
        )
        defer { try? fixture.remove() }
        let context = try makeLeaseContext(fixture: fixture)
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/true",
            timeoutSeconds: 30
        )

        let result = try await context.runtime.execute(
            scope: context.lease.scope,
            name: context.lease.virtualMachineName,
            request: request
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.isEmpty)
        XCTAssertTrue(result.standardError.isEmpty)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(fixture.guestCommandExecutionAttempts, 1)
        XCTAssertEqual(fixture.guestCommandCancellationAttempts, 0)
        XCTAssertEqual(
            try context.arbiter.snapshot().leases,
            [context.lease]
        )
        let record = try await context.runtime.inspect(
            scope: context.lease.scope,
            name: context.lease.virtualMachineName
        )
        XCTAssertEqual(record?.state, .running)
    }

    func testCancellingLeaseFencedExecuteAfterDispatchCancelsHostChildStopsVMAndRetainsLease()
        async throws
    {
        let fixture = try FakeLumeFixture(
            initialState: "running",
            behavior: "guest-command-blocking"
        )
        defer { try? fixture.remove() }
        let context = try makeLeaseContext(fixture: fixture)
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/true",
            timeoutSeconds: 30
        )
        let runtime = context.runtime
        let scope = context.lease.scope
        let name = context.lease.virtualMachineName
        let execution = Task {
            try await runtime.execute(
                scope: scope,
                name: name,
                request: request
            )
        }
        let executionProcessIdentifier: pid_t
        do {
            executionProcessIdentifier =
                try await fixture.waitForGuestCommandExecutionToStart()
        } catch {
            execution.cancel()
            _ = try? await execution.value
            throw error
        }

        execution.cancel()

        do {
            _ = try await execution.value
            XCTFail("cancelled guest execution should throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        let cancellationProcessIdentifier =
            try await fixture.waitForGuestCommandCancellationToStart()
        try await fixture.waitForProcessExit(executionProcessIdentifier)
        try await fixture.waitForProcessExit(cancellationProcessIdentifier)

        XCTAssertNotEqual(
            executionProcessIdentifier,
            cancellationProcessIdentifier
        )
        XCTAssertEqual(fixture.guestCommandExecutionAttempts, 1)
        XCTAssertEqual(fixture.guestCommandCancellationAttempts, 1)
        XCTAssertTrue(fixture.guestCommandCancellationWasAcknowledged)
        XCTAssertTrue(fixture.crossProcessStopWasInvoked)
        let record = try await context.runtime.inspect(
            scope: context.lease.scope,
            name: context.lease.virtualMachineName
        )
        XCTAssertEqual(record?.state, .stopped)
        XCTAssertEqual(
            try context.arbiter.snapshot().leases,
            [context.lease],
            "execute cleanup must stop the VM without releasing capacity"
        )
    }

    func testCancellationAndStopFailuresComposeCleanupErrorAndRetainLease()
        async throws
    {
        let fixture = try FakeLumeFixture(
            initialState: "running",
            behavior: "guest-command-blocking-cancel-and-stop-failure"
        )
        defer { try? fixture.remove() }
        let context = try makeLeaseContext(fixture: fixture)
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/true",
            timeoutSeconds: 30
        )
        let runtime = context.runtime
        let scope = context.lease.scope
        let name = context.lease.virtualMachineName
        let execution = Task {
            try await runtime.execute(
                scope: scope,
                name: name,
                request: request
            )
        }
        let executionProcessIdentifier: pid_t
        do {
            executionProcessIdentifier =
                try await fixture.waitForGuestCommandExecutionToStart()
        } catch {
            execution.cancel()
            _ = try? await execution.value
            throw error
        }

        execution.cancel()

        let failure: SandboxRuntimeError
        do {
            _ = try await execution.value
            XCTFail("failed cancellation cleanup should throw")
            return
        } catch let error as SandboxRuntimeError {
            failure = error
        } catch {
            XCTFail("expected SandboxRuntimeError, got \(error)")
            return
        }
        let cancellationProcessIdentifier =
            try await fixture.waitForGuestCommandCancellationToStart()
        try await fixture.waitForProcessExit(executionProcessIdentifier)
        try await fixture.waitForProcessExit(cancellationProcessIdentifier)

        guard case .cleanupFailed(
            let operation,
            let primary,
            let cleanup
        ) = failure else {
            XCTFail("expected cleanupFailed, got \(failure)")
            return
        }
        XCTAssertEqual(
            operation,
            "execute \(context.lease.virtualMachineName)"
        )
        XCTAssertTrue(primary.contains("CancellationError"))
        XCTAssertTrue(cleanup.contains("guest cancellation failed"))
        XCTAssertTrue(cleanup.contains("simulated cancellation SSH failure"))
        XCTAssertTrue(cleanup.contains("VM stop failed"))
        XCTAssertTrue(cleanup.contains("simulated VM stop failure"))
        XCTAssertEqual(fixture.guestCommandExecutionAttempts, 1)
        XCTAssertEqual(fixture.guestCommandCancellationAttempts, 1)
        XCTAssertFalse(fixture.guestCommandCancellationWasAcknowledged)
        XCTAssertTrue(fixture.crossProcessStopWasInvoked)
        let record = try await context.runtime.inspect(
            scope: context.lease.scope,
            name: context.lease.virtualMachineName
        )
        XCTAssertEqual(record?.state, .running)
        XCTAssertEqual(
            try context.arbiter.snapshot().leases,
            [context.lease],
            "ambiguous cleanup must retain reserved capacity"
        )
    }

    private func makeLeaseContext(
        fixture: FakeLumeFixture
    ) throws -> LeaseContext {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let arbiter = try fixture.makeCapacityArbiter(
            clock: LumeTestWallClock(now)
        )
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(120)
        )
        try fixture.bindOwnership(to: lease.scope)
        return LeaseContext(
            arbiter: arbiter,
            lease: lease,
            runtime: try fixture.makeLeaseFencedRuntime(
                capacityArbiter: arbiter,
                commandTimeoutSeconds: 30,
                guestCommandPolicy:
                    .baseImagePreparationAndDevelopment
            )
        )
    }
}

private struct LeaseContext {
    let arbiter: SandboxHostCapacityArbiter
    let lease: SandboxCapacityLease
    let runtime: LumeLeaseFencedVirtualMachineRuntime
}
