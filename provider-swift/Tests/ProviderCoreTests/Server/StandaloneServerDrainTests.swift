import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ProviderCore

// Lifecycle drain and stop behavior of the standalone (local mode) server.
// These tests use no model weights. Held work is simulated with a slot
// reservation or a response-tracker lease, which are the same counters the
// drain loop reads.

/// Poll `condition` until it is true or the timeout ends.
private func pollDrainState(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await taskSleep(.milliseconds(10))
    }
    return await condition()
}

private func drainRequest(timeoutSeconds: Int, force: Bool = false) throws -> ProviderDrainRequest {
    let identity = try #require(ProcessIdentity.current())
    return ProviderDrainRequest(target: identity, timeoutSeconds: timeoutSeconds, force: force)
}

@Suite("Standalone server drain and stop")
struct StandaloneServerDrainTests {

    @Test func drainWithNoWorkReportsDrainedAndClosesAdmission() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        let request = try drainRequest(timeoutSeconds: 5)

        let status = await server.drainForLifecycle(request)

        #expect(status.requestID == request.id)
        #expect(status.outcome == .drained)
        #expect(status.remaining == 0)
        #expect(status.deadline != nil)
        #expect(await server.lifecycleStatus == status)
        #expect(await server.lifecycleDraining)
        #expect(await server.lifecycleDrainTask == nil)
        // New HTTP work is refused with 503 once a drain starts.
        do {
            let lease = try server.responseTracker.admit()
            lease.release()
            Issue.record("a draining server must refuse new HTTP work")
        } catch let error as HTTPError {
            #expect(error.status == .serviceUnavailable)
        }
    }

    @Test func drainTimesOutWhileASlotReservationIsHeld() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        await server.reserveSlot("held-model")
        let request = try drainRequest(timeoutSeconds: 0)

        let status = await server.drainForLifecycle(request)

        #expect(status.requestID == request.id)
        #expect(status.outcome == .timedOut)
        #expect(status.remaining == 1)
        await server.releaseSlot("held-model")
    }

    @Test func drainCountsActiveHTTPResponses() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        let lease = try server.responseTracker.admit()
        let request = try drainRequest(timeoutSeconds: 0)

        let status = await server.drainForLifecycle(request)

        #expect(status.outcome == .timedOut)
        #expect(status.remaining == 1)
        lease.release()
        #expect(server.responseTracker.activeCount == 0)
    }

    @Test func forcedDrainReturnsAtOnceAndReportsHeldWork() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        await server.reserveSlot("held-model")
        let request = try drainRequest(timeoutSeconds: 30, force: true)

        let status = await server.drainForLifecycle(request)

        #expect(status.requestID == request.id)
        #expect(status.outcome == .forced)
        #expect(status.remaining == 1)
        #expect(await server.lifecycleDraining)
        await server.releaseSlot("held-model")
    }

    @Test func drainAndStopOnAnIdleServerSucceeds() async throws {
        let server = StandaloneServer(config: .init(port: 0))

        let stopped = await server.drainAndStop(timeoutSeconds: 5)

        #expect(stopped)
        #expect(await server.lifecycleState == .stopped)
        #expect(await server.lifecycleStatus.outcome == .drained)
        #expect(await server.lifecycleStatus.requestID != nil)
    }

    @Test func drainAndStopReturnsFalseWhenTheDrainTimesOut() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        await server.reserveSlot("held-model")

        let stopped = await server.drainAndStop(timeoutSeconds: 0)

        #expect(!stopped)
        #expect(await server.lifecycleStatus.outcome == .timedOut)
        #expect(await server.lifecycleStatus.remaining == 1)
        // Admission stays closed after the failed drain.
        await #expect(throws: MultiModelBatchSchedulerEngineError.queueFull("provider draining")) {
            _ = try await server.acquireModel("any-model")
        }
        await server.releaseSlot("held-model")
    }

    @Test func drainAndStopJoinsADrainThatIsAlreadyRunning() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        await server.reserveSlot("held-model")
        let request = try drainRequest(timeoutSeconds: 30)
        let firstDrain = Task { await server.drainForLifecycle(request) }
        let draining = await pollDrainState {
            let status = await server.lifecycleStatus
            return status.requestID == request.id && status.outcome == .draining
        }
        #expect(draining)
        #expect(await server.lifecycleStatus.remaining == 1)

        let stopper = Task { await server.drainAndStop(timeoutSeconds: 30) }
        try? await taskSleep(.milliseconds(200))
        await server.releaseSlot("held-model")

        #expect(await stopper.value)
        let first = await firstDrain.value
        #expect(first.requestID == request.id)
        #expect(first.outcome == .drained)
        #expect(first.remaining == 0)
        #expect(await server.lifecycleState == .stopped)
    }

    @Test func repeatedRequestWithTheSameIDSharesOneDrain() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        await server.reserveSlot("held-model")
        let request = try drainRequest(timeoutSeconds: 30)
        let first = Task { await server.drainForLifecycle(request) }
        let draining = await pollDrainState {
            await server.lifecycleStatus.outcome == .draining
        }
        #expect(draining)

        let second = Task { await server.drainForLifecycle(request) }
        try? await taskSleep(.milliseconds(200))
        await server.releaseSlot("held-model")

        let firstStatus = await first.value
        let secondStatus = await second.value
        #expect(firstStatus.requestID == request.id)
        #expect(secondStatus.requestID == request.id)
        #expect(firstStatus.outcome == .drained)
        #expect(secondStatus.outcome == .drained)
        #expect(await server.lifecycleDrainTask == nil)
    }

    @Test func newDrainRequestCancelsTheOlderDrain() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        await server.reserveSlot("held-model")
        let older = try drainRequest(timeoutSeconds: 30)
        let olderTask = Task { await server.drainForLifecycle(older) }
        let draining = await pollDrainState {
            let status = await server.lifecycleStatus
            return status.requestID == older.id && status.outcome == .draining
        }
        #expect(draining)

        let newer = try drainRequest(timeoutSeconds: 0)
        let newerStatus = await server.drainForLifecycle(newer)

        // The older drain was cancelled long before its 30 s deadline; the
        // held reservation keeps both outcomes at "timed out".
        let olderStatus = await olderTask.value
        #expect(olderStatus.requestID == older.id)
        #expect(olderStatus.outcome == .timedOut)
        #expect(olderStatus.remaining == 1)
        #expect(newerStatus.requestID == newer.id)
        #expect(newerStatus.outcome == .timedOut)
        #expect(newerStatus.remaining == 1)
        #expect(await server.lifecycleCommandID == newer.id)
        #expect(await server.lifecycleDrainTask == nil)
        await server.releaseSlot("held-model")
    }

    @Test func healthStaysAvailableWhileDraining() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        _ = await server.drainForLifecycle(try drainRequest(timeoutSeconds: 0))
        let app = server.makeApplication()

        // Only POST work is admitted through the response tracker, so a
        // liveness probe still answers while the server drains.
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
        _ = server
    }

    @Test func runningServerDrainsAndStopsAndReopensAdmission() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        try await server.start()
        #expect(await server.lifecycleState == .running)
        #expect(await server.nativeServiceOwnershipForTesting().stored)
        // A second start on a running server does nothing.
        try await server.start()
        #expect(await server.lifecycleState == .running)

        let stopped = await server.drainAndStop(timeoutSeconds: 5)

        #expect(stopped)
        #expect(await server.lifecycleState == .stopped)
        #expect(!(await server.lifecycleDraining))
        let ownership = await server.nativeServiceOwnershipForTesting()
        #expect(!ownership.stored)
        #expect(!ownership.stopping)
        // The full shutdown path reopens the tracker for a later start.
        let lease = try server.responseTracker.admit()
        #expect(server.responseTracker.activeCount == 1)
        lease.release()
        // No service task remains, so a bind wait fails at once.
        #expect(!(await server.waitUntilBound(timeoutSeconds: 5)))
    }

    @Test func concurrentStopCallsShareOneShutdown() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        try await server.start()

        let first = Task { await server.stop() }
        let second = Task { await server.stop() }
        await first.value
        await second.value

        #expect(await server.lifecycleState == .stopped)
        #expect(await server.shutdownTask == nil)
    }

    @Test func waitUntilStoppedReturnsAfterStop() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        try await server.start()

        let waiter = Task { await server.waitUntilStopped() }
        try? await taskSleep(.milliseconds(50))
        await server.stop()
        await waiter.value

        #expect(await server.lifecycleState == .stopped)
    }

    @Test func idleServerReportsNoBindAndStopsCleanly() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        #expect(await server.port == 0)
        #expect(await server.lifecycleState == .stopped)
        // Never started: there is no service task to wait for.
        #expect(!(await server.waitUntilBound(timeoutSeconds: 5)))
        await server.waitUntilStopped()
        await server.stopAndWait()
        #expect(await server.lifecycleState == .stopped)
    }

    @Test func nativeServiceHooksNeedTheNativeTestOwner() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        await #expect(throws: MiMoV26NativeTransactionError.invalidLifecycle) {
            try await server.setNativeServiceLifecycleHooksForTesting(
                exitTail: {}, beforeJoin: {})
        }
    }
}
