import Foundation
import SandboxCore
import SandboxHostControl
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class SandboxHostProductionAdapterTests: XCTestCase {
    func testStartPreservesWorkspaceLeaseAndSupportsReplayAfterAdapterRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let prepare = try fixture.preparePayload(fencingToken: 51)
        _ = try await fixture.adapter.handle(.prepare(fixture.envelope(payload: prepare, type: .prepare)))
        let stop = SandboxWireOperation(operationID: UUID(), scope: prepare.scope)
        _ = try await fixture.adapter.handle(.stop(fixture.envelope(payload: stop, type: .stop)))
        let operation = SandboxWireStart(operationID: UUID(), scope: prepare.scope,
            requestedFencingToken: try XCTUnwrap(SandboxFencingToken(rawValue: 52)),
            leaseExpiresAt: prepare.leaseExpiresAt)
        let before = try fixture.capacity.snapshot()
        let restarted = fixture.restartedAdapter()
        let admission = try await restarted.admit(.start(fixture.envelope(payload: operation, type: .start)))
        let duringStart = try await restarted.heartbeat()
        XCTAssertEqual(duringStart.leases.first?.state, .booting)
        guard case .operation(let result) = try await admission.complete() else {
            return XCTFail("expected start response")
        }
        XCTAssertEqual(result.operation, "start")
        XCTAssertEqual(result.operationID, operation.operationID)
        XCTAssertEqual(result.scope.sandboxID, operation.scope.sandboxID)
        XCTAssertEqual(result.scope.generation, operation.scope.generation)
        XCTAssertEqual(result.scope.fencingToken, operation.requestedFencingToken)
        XCTAssertEqual(result.state, .ready)
        let afterStart = try fixture.capacity.snapshot()
        XCTAssertEqual(afterStart.leases.count, before.leases.count)
        XCTAssertEqual(afterStart.leases.first?.expiresAt, before.leases.first?.expiresAt)
        XCTAssertEqual(afterStart.leases.first?.issuedAt, before.leases.first?.issuedAt)
        XCTAssertEqual(afterStart.leases.first?.reservedGrowthBytes, before.leases.first?.reservedGrowthBytes)
        XCTAssertEqual(afterStart.leases.first?.cpuCount, before.leases.first?.cpuCount)
        XCTAssertEqual(afterStart.leases.first?.memoryBytes, before.leases.first?.memoryBytes)
        XCTAssertEqual(afterStart.nextFencingToken, 53)
        XCTAssertThrowsError(try fixture.capacity.authorize(
            scope: stop.scope.operationScope,
            virtualMachineName: Fixture.virtualMachineName(for: stop.scope), operation: .stop
        )) { XCTAssertEqual($0 as? SandboxCapacityError, .staleFencingToken) }
        guard case .operation(let replay) = try await fixture.restartedAdapter().handle(
            .start(fixture.envelope(payload: operation, type: .start))
        ) else { return XCTFail("expected replay response") }
        XCTAssertEqual(replay, result)
        XCTAssertEqual(try fixture.capacity.snapshot(), afterStart)
        let events = await fixture.runtime.events()
        XCTAssertEqual(events.filter { $0.hasPrefix("create:") }.count, 1)
    }

    func testStartRejectsDrainedOrStaleAuthorityBeforeRuntimeSideEffects() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let prepare = try fixture.preparePayload(fencingToken: 61)
        _ = try await fixture.adapter.handle(.prepare(fixture.envelope(payload: prepare, type: .prepare)))
        let before = await fixture.runtime.events()
        let stale = SandboxWireStart(operationID: UUID(), scope: Fixture.scope(fencingToken: 60),
            requestedFencingToken: try XCTUnwrap(SandboxFencingToken(rawValue: 62)),
            leaseExpiresAt: prepare.leaseExpiresAt)
        guard case .operation(let rejected) = try await fixture.adapter.handle(
            .start(fixture.envelope(payload: stale, type: .start))
        ) else { return XCTFail("expected stale rejection") }
        XCTAssertEqual(rejected.errorCode, "stale_authority")
        _ = try fixture.capacity.setMode(.draining)
        let current = SandboxWireStart(operationID: UUID(), scope: prepare.scope,
            requestedFencingToken: try XCTUnwrap(SandboxFencingToken(rawValue: 62)),
            leaseExpiresAt: prepare.leaseExpiresAt)
        guard case .operation(let drained) = try await fixture.adapter.handle(
            .start(fixture.envelope(payload: current, type: .start))
        ) else { return XCTFail("expected drain rejection") }
        XCTAssertEqual(drained.errorCode, "host_draining")
        let after = await fixture.runtime.events()
        XCTAssertEqual(after, before)
    }

    func testStartCannotExtendLeaseAndReplayCannotOverrideLaterFence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let prepare = try fixture.preparePayload(fencingToken: 71)
        _ = try await fixture.adapter.handle(.prepare(fixture.envelope(payload: prepare, type: .prepare)))
        let before = try fixture.capacity.snapshot()
        let extended = SandboxWireStart(operationID: UUID(), scope: prepare.scope,
            requestedFencingToken: try XCTUnwrap(SandboxFencingToken(rawValue: 72)),
            leaseExpiresAt: Fixture.timestamp(fixture.now.addingTimeInterval(180)))
        guard case .operation(let rejected) = try await fixture.adapter.handle(
            .start(fixture.envelope(payload: extended, type: .start))
        ) else { return XCTFail("expected expiry rejection") }
        XCTAssertEqual(rejected.state, .failed)
        XCTAssertEqual(try fixture.capacity.snapshot(), before)
        let first = SandboxWireStart(operationID: UUID(), scope: prepare.scope,
            requestedFencingToken: extended.requestedFencingToken, leaseExpiresAt: prepare.leaseExpiresAt)
        guard case .operation(let resumed) = try await fixture.adapter.handle(
            .start(fixture.envelope(payload: first, type: .start))
        ) else { return XCTFail("expected start") }
        _ = try fixture.capacity.renew(scope: resumed.scope.operationScope,
            fencingToken: try XCTUnwrap(SandboxFencingToken(rawValue: 73)),
            expiresAt: fixture.now.addingTimeInterval(180))
        let events = await fixture.runtime.events()
        guard case .operation(let stale) = try await fixture.adapter.handle(
            .start(fixture.envelope(payload: first, type: .start))
        ) else { return XCTFail("expected stale replay rejection") }
        XCTAssertEqual(stale.errorCode, "stale_authority")
        let after = await fixture.runtime.events()
        XCTAssertEqual(after, events)
        XCTAssertEqual(try fixture.capacity.snapshot().leases.first?.scope.fencingToken.rawValue, 73)
    }

    func testRejectedStartReplayStopsPossiblyRunningVMBeforeReportingFailure() async throws {
        for stopFails in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let prepare = try fixture.preparePayload(fencingToken: 81)
            _ = try await fixture.adapter.handle(.prepare(fixture.envelope(payload: prepare, type: .prepare)))
            let start = SandboxWireStart(operationID: UUID(), scope: prepare.scope,
                requestedFencingToken: try XCTUnwrap(SandboxFencingToken(rawValue: 82)),
                leaseExpiresAt: prepare.leaseExpiresAt)
            _ = try await fixture.adapter.handle(.start(fixture.envelope(payload: start, type: .start)))
            _ = try fixture.capacity.setMode(.draining)
            if stopFails {
                await fixture.runtime.failStops(with: .operationTimedOut("test stop"))
            }
            guard case .operation(let result) = try await fixture.restartedAdapter().handle(
                .start(fixture.envelope(payload: start, type: .start))
            ) else { return XCTFail("expected failed replay") }
            XCTAssertEqual(result.state, .failed)
            XCTAssertEqual(result.scope.fencingToken, start.requestedFencingToken)
            XCTAssertEqual(result.errorCode, stopFails ? "runtime_cleanup_failed" : "host_draining")
            let record = await fixture.runtime.record(name: Fixture.virtualMachineName(for: start.scope))
            XCTAssertEqual(record?.state, stopFails ? .running : .stopped)
            XCTAssertEqual(try fixture.capacity.snapshot().leases.count, 1)
        }
    }

    func testStartFailureAfterAdmissionStillRequiresStoppedProof() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let prepare = try fixture.preparePayload(fencingToken: 91)
        _ = try await fixture.adapter.handle(.prepare(fixture.envelope(payload: prepare, type: .prepare)))
        let start = SandboxWireStart(operationID: UUID(), scope: prepare.scope,
            requestedFencingToken: try XCTUnwrap(SandboxFencingToken(rawValue: 92)),
            leaseExpiresAt: prepare.leaseExpiresAt)
        let admission = try await fixture.adapter.admit(.start(fixture.envelope(payload: start, type: .start)))
        await fixture.runtime.failStartsAfterRunning(with: .unsupported("authority changed before runtime start"))
        guard case .operation(let result) = try await admission.complete() else {
            return XCTFail("expected failed start")
        }
        XCTAssertEqual(result.state, .failed)
        let record = await fixture.runtime.record(name: Fixture.virtualMachineName(for: start.scope))
        XCTAssertEqual(record?.state, .stopped)
    }

    func testPrepareAdoptsCoordinatorFenceAndReportsDurableHighWatermark()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = try fixture.preparePayload(fencingToken: 40)

        let response = try await fixture.adapter.handle(.prepare(
            fixture.envelope(payload: payload, type: .prepare)
        ))
        guard case .operation(let status) = response else {
            return XCTFail("expected prepare operation response")
        }
        XCTAssertEqual(status.operationID, payload.operationID)
        XCTAssertEqual(status.operation, "prepare")
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.scope, payload.scope)

        let snapshot = try fixture.capacity.snapshot()
        XCTAssertEqual(snapshot.nextFencingToken, 41)
        XCTAssertEqual(snapshot.leases.count, 1)
        let heartbeat = try await fixture.adapter.heartbeat()
        XCTAssertEqual(heartbeat.nextFencingToken, 41)
        XCTAssertEqual(heartbeat.availableCPU, 4)
        XCTAssertEqual(
            heartbeat.availableMemoryBytes,
            8 * SandboxResourcePolicy.gibibyte
        )
        XCTAssertEqual(heartbeat.leases.count, 1)
        XCTAssertEqual(heartbeat.leases[0].state, .ready)
        XCTAssertEqual(
            heartbeat.leases[0].resources.commandTimeoutSeconds,
            900
        )
        let events = await fixture.runtime.events()
        XCTAssertEqual(
            events,
            [
                "create:\(Fixture.virtualMachineName(for: payload.scope))",
                "start:\(Fixture.virtualMachineName(for: payload.scope))",
            ]
        )
    }

    func testRestartedAdapterReportsFailedForLeaseWithoutVirtualMachine()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = try fixture.preparePayload(fencingToken: 41)
        let resources = try XCTUnwrap(payload.resources.resourceSpecification)
        _ = try fixture.capacity.reserve(
            authoritativeScope: payload.scope.operationScope,
            virtualMachineName: Fixture.virtualMachineName(for: payload.scope),
            resources: resources,
            bootDiskBytes: SandboxDiskPolicy.alpha.bootDiskBytes.lowerBound,
            expiresAt: fixture.now.addingTimeInterval(120)
        )

        let restarted = fixture.restartedAdapter()
        let heartbeat = try await restarted.heartbeat()

        XCTAssertEqual(heartbeat.leases.count, 1)
        XCTAssertEqual(
            heartbeat.leases[0].state,
            .failed,
            "a durable lease without a VM after restart must not remain preparing forever"
        )
    }

    func testAdmittedPrepareReportsPreparingBeforeVirtualMachineCreation()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = try fixture.preparePayload(fencingToken: 42)
        let admission = try await fixture.adapter.admit(.prepare(
            fixture.envelope(payload: payload, type: .prepare)
        ))

        let heartbeat = try await fixture.adapter.heartbeat()

        XCTAssertEqual(heartbeat.leases.count, 1)
        XCTAssertEqual(heartbeat.leases[0].state, .preparing)
        guard case .operation(let completed) = try await admission.complete() else {
            return XCTFail("expected prepare operation response")
        }
        XCTAssertEqual(completed.state, .ready)
    }

    func testPrepareFailsClosedBeforeReservingWithoutIsolationGates()
        async throws
    {
        let fixture = try Fixture(isolationReadiness: .unavailable)
        defer { fixture.remove() }
        let payload = try fixture.preparePayload(fencingToken: 1)

        let response = try await fixture.adapter.handle(.prepare(
            fixture.envelope(payload: payload, type: .prepare)
        ))
        guard case .operation(let status) = response else {
            return XCTFail("expected failed prepare operation response")
        }
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.errorCode, "isolation_unavailable")
        XCTAssertTrue(try fixture.capacity.snapshot().leases.isEmpty)
        let heartbeat = try await fixture.adapter.heartbeat()
        XCTAssertEqual(heartbeat.mode, SandboxHostMode.draining.rawValue)
        XCTAssertEqual(heartbeat.availableCPU, 8)
        XCTAssertEqual(
            heartbeat.availableMemoryBytes,
            16 * SandboxResourcePolicy.gibibyte
        )
        let events = await fixture.runtime.events()
        XCTAssertTrue(events.isEmpty)
    }

    func testRenewReturnsNewFenceAndRoutesDeleteAndRelease() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let prepare = try fixture.preparePayload(fencingToken: 20)
        _ = try await fixture.adapter.handle(.prepare(
            fixture.envelope(payload: prepare, type: .prepare)
        ))
        let renew = SandboxWireLeaseRenew(
            operationID: UUID(),
            scope: prepare.scope,
            requestedFencingToken: SandboxFencingToken(rawValue: 21)!,
            leaseExpiresAt: Fixture.timestamp(
                fixture.now.addingTimeInterval(240)
            )
        )

        let renewedResponse = try await fixture.adapter.handle(.leaseRenew(
            fixture.envelope(payload: renew, type: .leaseRenew)
        ))
        guard case .operation(let renewed) = renewedResponse else {
            return XCTFail("expected renewal operation response")
        }
        XCTAssertEqual(renewed.operation, "renew")
        XCTAssertEqual(renewed.state, .ready)
        XCTAssertEqual(renewed.scope.fencingToken.rawValue, 21)

        let deletion = SandboxWireOperation(
            operationID: UUID(),
            scope: renewed.scope
        )
        let deletedResponse = try await fixture.adapter.handle(.delete(
            fixture.envelope(payload: deletion, type: .delete)
        ))
        guard case .operation(let deleted) = deletedResponse else {
            return XCTFail("expected delete operation response")
        }
        XCTAssertEqual(deleted.state, .deleted)
        let events = await fixture.runtime.events()
        XCTAssertEqual(
            events.last,
            "delete:\(Fixture.virtualMachineName(for: renewed.scope))"
        )
    }

    func testFailedPrepareCleanupStopsRunningVMBeforeDelete() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await fixture.runtime.failStartsAfterRunning(
            with: .cleanupFailed(
                operation: "start test",
                primary: "guest readiness failed",
                cleanup: "VM remained running"
            )
        )
        let prepare = try fixture.preparePayload(fencingToken: 30)
        let prepareResponse = try await fixture.adapter.handle(.prepare(
            fixture.envelope(payload: prepare, type: .prepare)
        ))
        guard case .operation(let failedPrepare) = prepareResponse else {
            return XCTFail("expected failed prepare operation response")
        }
        XCTAssertEqual(failedPrepare.state, .failed)
        XCTAssertEqual(failedPrepare.errorCode, "runtime_cleanup_failed")
        let name = Fixture.virtualMachineName(for: prepare.scope)
        let running = await fixture.runtime.record(name: name)
        XCTAssertEqual(running?.state, .running)

        let deletion = SandboxWireOperation(
            operationID: UUID(),
            scope: prepare.scope
        )
        let deleteResponse = try await fixture.adapter.handle(.delete(
            fixture.envelope(payload: deletion, type: .delete)
        ))

        guard case .operation(let deleted) = deleteResponse else {
            return XCTFail("expected delete operation response")
        }
        XCTAssertEqual(deleted.state, .deleted)
        let deletedRecord = await fixture.runtime.record(name: name)
        XCTAssertNil(deletedRecord)
        let events = await fixture.runtime.events()
        XCTAssertEqual(
            events,
            ["create:\(name)", "start:\(name)", "stop:\(name)", "delete:\(name)"]
        )
    }

    func testDeleteReplayAfterReleasedLeaseReturnsDeleted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await fixture.runtime.fenceInspectionsAfterRelease()
        let prepare = try fixture.preparePayload(fencingToken: 31)
        let prepareResponse = try await fixture.adapter.handle(.prepare(
            fixture.envelope(payload: prepare, type: .prepare)
        ))
        guard case .operation(let prepared) = prepareResponse else {
            return XCTFail("expected prepare operation response")
        }
        XCTAssertEqual(prepared.state, .ready)
        let deletion = SandboxWireOperation(
            operationID: UUID(),
            scope: prepare.scope
        )

        let firstResponse = try await fixture.adapter.handle(.delete(
            fixture.envelope(payload: deletion, type: .delete)
        ))
        guard case .operation(let firstDelete) = firstResponse else {
            return XCTFail("expected first delete operation response")
        }
        XCTAssertEqual(firstDelete.state, .deleted)

        let replayResponse = try await fixture.adapter.handle(.delete(
            fixture.envelope(payload: deletion, type: .delete)
        ))
        guard case .operation(let replayedDelete) = replayResponse else {
            return XCTFail("expected replayed delete operation response")
        }
        XCTAssertEqual(replayedDelete.state, .deleted)
        let name = Fixture.virtualMachineName(for: prepare.scope)
        let events = await fixture.runtime.events()
        XCTAssertEqual(
            events,
            [
                "create:\(name)",
                "start:\(name)",
                "stop:\(name)",
                "delete:\(name)",
                "delete:\(name)",
            ]
        )
    }

    func testDeleteMissingVirtualMachineRemainsPossible() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scope = Fixture.scope(fencingToken: 31)
        let deletion = SandboxWireOperation(
            operationID: UUID(),
            scope: scope
        )

        let response = try await fixture.adapter.handle(.delete(
            fixture.envelope(payload: deletion, type: .delete)
        ))

        guard case .operation(let deleted) = response else {
            return XCTFail("expected delete operation response")
        }
        XCTAssertEqual(deleted.state, .deleted)
        let events = await fixture.runtime.events()
        XCTAssertEqual(
            events,
            ["delete:\(Fixture.virtualMachineName(for: scope))"]
        )
    }

    func testCommandLimitProducesStableWireErrorWithoutReleasingLease() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.capacity.snapshot()
        await fixture.runtime.failCommands(with: .commandLimitReached)
        let command = SandboxWireCommand(commandID: UUID(), idempotencyKey: UUID().uuidString.lowercased(),
            scope: Fixture.scope(fencingToken: 7), arguments: ["/usr/bin/true"], timeoutSeconds: 30)
        guard case .command(let result) = try await fixture.adapter.handle(
            .command(fixture.envelope(payload: command, type: .command))) else {
            return XCTFail("expected command response")
        }
        XCTAssertEqual(result.commandID, command.commandID)
        XCTAssertEqual(result.state, .failed)
        XCTAssertEqual(result.errorCode, "command_limit_reached")
        XCTAssertEqual(try fixture.capacity.snapshot(), before)
        let events = await fixture.runtime.events()
        XCTAssertFalse(events.contains { $0.hasPrefix("stop:") || $0.hasPrefix("delete:") })
    }

    func testCommandCancellationInterruptsRuntimeWork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await fixture.runtime.blockCommands()
        let scope = Fixture.scope(fencingToken: 7)
        let command = SandboxWireCommand(
            commandID: UUID(),
            idempotencyKey: UUID().uuidString.lowercased(),
            scope: scope,
            arguments: ["/usr/bin/printf", "hello"],
            timeoutSeconds: 900
        )
        let running = Task {
            try await fixture.adapter.handle(.command(
                fixture.envelope(payload: command, type: .command)
            ))
        }
        await fixture.runtime.waitUntilCommandStarted()
        let cancellation = SandboxWireCommandControl(
            operationID: UUID(),
            commandID: command.commandID,
            scope: scope
        )

        let cancelledResponse = try await fixture.adapter.handle(.cancelCommand(
            fixture.envelope(payload: cancellation, type: .cancelCommand)
        ))
        guard case .command(let cancelled) = cancelledResponse else {
            return XCTFail("expected cancelled command response")
        }
        XCTAssertEqual(cancelled.state, .cancelled)
        guard case .command(let original) = try await running.value else {
            return XCTFail("expected original command response")
        }
        XCTAssertEqual(original.state, .cancelled)
    }

    func testExpiryCancelsStartedCommandAfterRenewalRotatesItsFence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await fixture.runtime.blockCommands()
        let scope = Fixture.scope(fencingToken: 7)
        let command = SandboxWireCommand(commandID: UUID(), idempotencyKey: UUID().uuidString,
            scope: scope, arguments: ["/usr/bin/true"], timeoutSeconds: 900)
        let running = Task {
            try await fixture.adapter.handle(.command(fixture.envelope(payload: command, type: .command)))
        }
        await fixture.runtime.waitUntilCommandStarted()
        let renewed = Fixture.scope(fencingToken: 8)
        let lease = SandboxCapacityLease(scope: renewed.operationScope,
            virtualMachineName: Fixture.virtualMachineName(for: renewed), cpuCount: 4,
            memoryBytes: 8 << 30, workspaceBytes: 25 << 30, bootDiskBytes: 100 << 30,
            reservedGrowthBytes: 126 << 30, issuedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(60))
        await fixture.adapter.cancelCommandsForExpiredLeases([lease])
        guard case .command(let result) = try await running.value else { return XCTFail("expected command result") }
        XCTAssertEqual(result.state, .cancelled)
    }

    func testRestartedAdapterDoesNotReportUnknownCommandLost() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scope = Fixture.scope(fencingToken: 7)
        let name = Fixture.virtualMachineName(for: scope)
        await fixture.runtime.seedRunningVirtualMachine(name: name)
        let cancellation = SandboxWireCommandControl(
            operationID: UUID(),
            commandID: UUID(),
            scope: scope
        )

        let response = try await fixture.adapter.handle(.cancelCommand(
            fixture.envelope(payload: cancellation, type: .cancelCommand)
        ))

        guard case .command(let status) = response else {
            return XCTFail("expected command cancellation response")
        }
        XCTAssertEqual(
            status.state,
            .cancelled,
            "a fresh adapter must not acknowledge terminal lost until guest execution is stopped"
        )
        let stopped = await fixture.runtime.record(name: name)
        XCTAssertEqual(stopped?.state, .stopped)
        let stopScopes = await fixture.runtime.stopScopes()
        XCTAssertEqual(stopScopes, [scope.operationScope])
    }

    func testRestartedAdapterDoesNotAcknowledgeFailedStopAsCancelled()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scope = Fixture.scope(fencingToken: 7)
        let name = Fixture.virtualMachineName(for: scope)
        await fixture.runtime.seedRunningVirtualMachine(name: name)
        await fixture.runtime.failStops(
            with: .cleanupFailed(
                operation: "stop \(name)",
                primary: "cancel requested",
                cleanup: "VM remained running"
            )
        )
        let cancellation = SandboxWireCommandControl(
            operationID: UUID(),
            commandID: UUID(),
            scope: scope
        )

        let response = try await fixture.adapter.handle(.cancelCommand(
            fixture.envelope(payload: cancellation, type: .cancelCommand)
        ))

        guard case .command(let status) = response else {
            return XCTFail("expected command cancellation response")
        }
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.errorCode, "runtime_cleanup_failed")
        let stillRunning = await fixture.runtime.record(name: name)
        XCTAssertEqual(stillRunning?.state, .running)
    }

    func testActiveCancellationDoesNotSwallowRuntimeCleanupFailure()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await fixture.runtime.blockCommands(
            cancellationError: .cleanupFailed(
                operation: "execute test",
                primary: "cancelled",
                cleanup: "VM stop failed"
            )
        )
        let scope = Fixture.scope(fencingToken: 7)
        let command = SandboxWireCommand(
            commandID: UUID(),
            idempotencyKey: UUID().uuidString.lowercased(),
            scope: scope,
            arguments: ["/usr/bin/printf", "hello"],
            timeoutSeconds: 900
        )
        let running = Task {
            try await fixture.adapter.handle(.command(
                fixture.envelope(payload: command, type: .command)
            ))
        }
        await fixture.runtime.waitUntilCommandStarted()
        let cancellation = SandboxWireCommandControl(
            operationID: UUID(),
            commandID: command.commandID,
            scope: scope
        )

        let cancellationResponse = try await fixture.adapter.handle(
            .cancelCommand(
                fixture.envelope(
                    payload: cancellation,
                    type: .cancelCommand
                )
            )
        )

        guard case .command(let cancelled) = cancellationResponse else {
            return XCTFail("expected command cancellation response")
        }
        XCTAssertEqual(cancelled.state, .failed)
        XCTAssertEqual(cancelled.errorCode, "runtime_cleanup_failed")
        guard case .command(let original) = try await running.value else {
            return XCTFail("expected original command response")
        }
        XCTAssertEqual(original.state, .failed)
        XCTAssertEqual(original.errorCode, "runtime_cleanup_failed")
    }
}

private final class Fixture: @unchecked Sendable {
    let root: URL
    let now: Date
    let capacity: SandboxHostCapacityArbiter
    let runtime = RecordingSandboxRuntime()
    let isolationReadiness: SandboxHostIsolationReadiness
    let adapter: SandboxHostProductionAdapter

    init(
        isolationReadiness: SandboxHostIsolationReadiness = .init(
            signedGuestControl: true,
            networkPolicy: true,
            workspaceQuota: true
        )
    ) throws {
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        now = fixedNow
        self.isolationReadiness = isolationReadiness
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-host-adapter-\(UUID().uuidString)",
            isDirectory: true
        )
        let state = root.appendingPathComponent("state", isDirectory: true)
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        capacity = try SandboxHostCapacityArbiter(
            stateDirectory: state,
            policy: SandboxCapacityPolicy(
                maximumReservedCPUCount: 8,
                maximumReservedMemoryBytes:
                    16 * SandboxResourcePolicy.gibibyte,
                maximumReservedGrowthBytes:
                    300 * SandboxResourcePolicy.gibibyte,
                storageHeadroomBytes:
                    20 * SandboxResourcePolicy.gibibyte
            ),
            currentDate: { fixedNow },
            availableStorageBytes: { UInt64.max }
        )
        _ = try capacity.initialize()
        _ = try capacity.setMode(.sandboxDedicated)
        adapter = SandboxHostProductionAdapter(
            capacity: capacity,
            runtime: runtime,
            isolationReadiness: isolationReadiness
        )
    }

    func restartedAdapter() -> SandboxHostProductionAdapter {
        SandboxHostProductionAdapter(
            capacity: capacity,
            runtime: runtime,
            isolationReadiness: isolationReadiness
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func preparePayload(fencingToken: UInt64) throws -> SandboxWirePrepare {
        SandboxWirePrepare(
            operationID: UUID(),
            scope: Self.scope(fencingToken: fencingToken),
            resources: SandboxWireResources(
                cpuCount: 4,
                memoryBytes: 8 * SandboxResourcePolicy.gibibyte,
                workspaceBytes: 25 * SandboxResourcePolicy.gibibyte,
                commandTimeoutSeconds: 900,
                gpu: false
            ),
            baseImageID: "macos-tahoe-v1",
            leaseExpiresAt: Self.timestamp(now.addingTimeInterval(120))
        )
    }

    func envelope<Payload>(
        payload: Payload,
        type: SandboxControlMessageType
    ) -> SandboxControlEnvelope<Payload>
    where Payload: Codable & Equatable & Sendable {
        SandboxControlEnvelope(
            type: type,
            hostID: UUID(),
            connectionEpoch: UUID(),
            sequence: 1,
            payload: payload
        )
    }

    static func scope(fencingToken: UInt64) -> SandboxWireScope {
        SandboxWireScope(
            sandboxID: SandboxID(
                "11111111-1111-1111-1111-111111111111"
            )!,
            generation: SandboxGeneration(rawValue: 1)!,
            fencingToken: SandboxFencingToken(rawValue: fencingToken)!
        )
    }

    static func virtualMachineName(for scope: SandboxWireScope) -> String {
        "sbx-11111111111111111111111111111111-g\(scope.generation.rawValue)"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }
}

private actor RecordingSandboxRuntime: SandboxHostVirtualMachineControlling {
    private var records: [String: SandboxVirtualMachineRecord] = [:]
    private var recordedEvents: [String] = []
    private var shouldBlockCommands = false
    private var blockedCommand:
        CheckedContinuation<SandboxGuestCommandResult, Error>?
    private var commandCancellationError: SandboxRuntimeError?
    private var commandError: SandboxRuntimeError?
    private var commandStarted = false
    private var commandStartedWaiter: CheckedContinuation<Void, Never>?
    private var stopError: SandboxRuntimeError?
    private var startErrorAfterRunning: SandboxRuntimeError?
    private var recordedStopScopes: [SandboxOperationScope] = []
    private var releasedScopes: [SandboxOperationScope] = []
    private var shouldFenceInspectionsAfterRelease = false

    func inspect(
        scope: SandboxOperationScope,
        name: String
    ) async throws -> SandboxVirtualMachineRecord? {
        if shouldFenceInspectionsAfterRelease,
           releasedScopes.contains(scope)
        {
            throw SandboxCapacityError.leaseNotFound
        }
        return records[name]
    }

    func create(
        scope _: SandboxOperationScope,
        specification: SandboxVirtualMachineSpecification
    ) async throws {
        recordedEvents.append("create:\(specification.name)")
        records[specification.name] = SandboxVirtualMachineRecord(
            name: specification.name,
            state: .stopped,
            cpuCount: specification.resources.cpuCount,
            memoryBytes: specification.resources.memoryBytes,
            diskBytes: specification.diskBytes,
            guestReady: false
        )
    }

    func start(
        scope _: SandboxOperationScope,
        name: String
    ) async throws {
        recordedEvents.append("start:\(name)")
        guard let record = records[name] else {
            throw SandboxRuntimeError.unsupported("missing test VM")
        }
        records[name] = SandboxVirtualMachineRecord(
            name: name,
            state: .running,
            cpuCount: record.cpuCount,
            memoryBytes: record.memoryBytes,
            diskBytes: record.diskBytes,
            guestReady: true
        )
        if let startErrorAfterRunning {
            throw startErrorAfterRunning
        }
    }

    func execute(
        scope _: SandboxOperationScope,
        name _: String,
        request _: SandboxGuestCommandRequest
    ) async throws -> SandboxGuestCommandResult {
        if let commandError { throw commandError }
        if shouldBlockCommands {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    blockedCommand = $0
                    markCommandStarted()
                    if Task.isCancelled {
                        cancelBlockedCommand()
                    }
                }
            } onCancel: {
                Task {
                    await self.cancelBlockedCommand()
                }
            }
        }
        markCommandStarted()
        return SandboxGuestCommandResult(
            exitCode: 0,
            standardOutput: Data("hello".utf8),
            standardError: Data()
        )
    }

    func stop(
        scope: SandboxOperationScope,
        name: String
    ) async throws {
        recordedEvents.append("stop:\(name)")
        recordedStopScopes.append(scope)
        if let stopError {
            throw stopError
        }
        guard let record = records[name] else {
            return
        }
        records[name] = SandboxVirtualMachineRecord(
            name: name,
            state: .stopped,
            cpuCount: record.cpuCount,
            memoryBytes: record.memoryBytes,
            diskBytes: record.diskBytes,
            guestReady: false
        )
    }

    func deleteAndRelease(
        scope: SandboxOperationScope,
        name: String
    ) async throws {
        recordedEvents.append("delete:\(name)")
        if releasedScopes.contains(scope) {
            guard records[name] == nil else {
                throw SandboxCapacityError.leaseNotFound
            }
            return
        }
        if records[name]?.state == .running {
            throw SandboxRuntimeError.unsupported(
                "refusing to delete running test VM"
            )
        }
        records.removeValue(forKey: name)
        releasedScopes.append(scope)
    }

    func events() -> [String] {
        recordedEvents
    }

    func blockCommands(cancellationError: SandboxRuntimeError? = nil) {
        shouldBlockCommands = true
        commandCancellationError = cancellationError
    }

    func waitUntilCommandStarted() async {
        if commandStarted {
            return
        }
        await withCheckedContinuation {
            commandStartedWaiter = $0
        }
    }

    func seedRunningVirtualMachine(name: String) {
        records[name] = SandboxVirtualMachineRecord(
            name: name,
            state: .running,
            cpuCount: 4,
            memoryBytes: 8 * SandboxResourcePolicy.gibibyte,
            diskBytes: 100 * SandboxResourcePolicy.gibibyte,
            guestReady: true
        )
    }

    func failStops(with error: SandboxRuntimeError) {
        stopError = error
    }

    func failCommands(with error: SandboxRuntimeError) {
        commandError = error
    }

    func failStartsAfterRunning(with error: SandboxRuntimeError) {
        startErrorAfterRunning = error
    }

    func fenceInspectionsAfterRelease() {
        shouldFenceInspectionsAfterRelease = true
    }

    func record(name: String) -> SandboxVirtualMachineRecord? {
        records[name]
    }

    func stopScopes() -> [SandboxOperationScope] {
        recordedStopScopes
    }

    private func markCommandStarted() {
        commandStarted = true
        commandStartedWaiter?.resume()
        commandStartedWaiter = nil
    }

    private func cancelBlockedCommand() {
        guard let continuation = blockedCommand else {
            return
        }
        blockedCommand = nil
        if let commandCancellationError {
            continuation.resume(throwing: commandCancellationError)
        } else {
            continuation.resume(throwing: CancellationError())
        }
    }
}
