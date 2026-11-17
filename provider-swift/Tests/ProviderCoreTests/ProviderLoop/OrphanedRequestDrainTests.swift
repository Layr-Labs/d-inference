import Foundation
import Testing

@testable import ProviderCore

/// A request's task that ignores cancellation until the test opens it, as one
/// stuck behind an engine that stopped stepping does.
private final class OrphanTaskGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if opened { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let continuation = lock.withLock {
            opened = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }
}

private extension ProviderLoop {
    /// An accepted coordinator request whose task ends only when `gate` opens,
    /// then finishes the way an inference task does.
    func startOrphanTestRequest(_ id: String, model: String, gate: OrphanTaskGate) {
        acceptedLifecycleRequests.insert(id)
        requestToModel[id] = model
        inflightTasks[id] = Task {
            await gate.wait()
            await self.finishInflightRequest(requestId: id)
        }
    }

    func setOrphanedRequestGraceForTesting(_ grace: Duration) { orphanedRequestGrace = grace }
}

/// On 11-10 a stop drained for 600 s and timed out on 20 requests its
/// coordinator had already cancelled: each one's client was gone, and each
/// one's task waited on an engine that had stopped stepping.
@Suite("A drain and the requests the coordinator abandoned", .serialized)
struct OrphanedRequestDrainTests {
    static let model = "test/orphan-model"

    @Test("a request the coordinator cancelled stops holding the drain after the grace, though its task never ends")
    func cancelledRequestStopsHoldingTheDrain() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        await loop.skipCapacityRebuildForTesting()
        await loop.setOrphanedRequestGraceForTesting(.milliseconds(100))
        let gate = OrphanTaskGate()
        defer { gate.open() }
        await loop.startOrphanTestRequest("stuck", model: Self.model, gate: gate)
        #expect(await loop.lifecycleRemaining == 1)

        await loop.handleCancellation(requestId: "stuck")
        #expect(await loop.lifecycleRemaining == 1, "its task gets the grace to end and send its terminal")
        try await Task.sleep(for: .milliseconds(300))
        #expect(await loop.lifecycleRemaining == 0, "the coordinator abandoned it: nobody waits for its answer")
        #expect(await loop.hasInflightWork, "eviction and memory still count it until its task ends")

        gate.open()
        let until = ContinuousClock.now + .seconds(5)
        while await loop.hasInflightWork, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!(await loop.hasInflightWork))
    }

    @Test("a cancel that did not come from the coordinator keeps the drain waiting")
    func localCancelHoldsTheDrain() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        await loop.skipCapacityRebuildForTesting()
        await loop.setOrphanedRequestGraceForTesting(.milliseconds(100))
        let gate = OrphanTaskGate()
        await loop.startOrphanTestRequest("local", model: Self.model, gate: gate)
        // As a disconnect's cancel-all does: the client did not leave.
        await loop.handleCancellation(requestId: "local", receivedFromCoordinator: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await loop.lifecycleRemaining == 1, "only a coordinator cancel says nobody waits for the answer")
        gate.open()
        let until = ContinuousClock.now + .seconds(5)
        while await loop.lifecycleRemaining > 0, ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await loop.lifecycleRemaining == 0)
    }

    @Test("a request nobody cancelled keeps the drain waiting")
    func uncancelledRequestHoldsTheDrain() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        await loop.skipCapacityRebuildForTesting()
        await loop.setOrphanedRequestGraceForTesting(.milliseconds(100))
        let gate = OrphanTaskGate()
        await loop.startOrphanTestRequest("serving", model: Self.model, gate: gate)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await loop.lifecycleRemaining == 1, "graceful drains never truncate accepted work")
        gate.open()
        let until = ContinuousClock.now + .seconds(5)
        while await loop.lifecycleRemaining > 0, ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await loop.lifecycleRemaining == 0)
    }
}
