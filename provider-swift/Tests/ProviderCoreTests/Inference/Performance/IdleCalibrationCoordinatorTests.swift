import Foundation
import Testing
@testable import ProviderCore

/// Models ProviderLoop/bridge actor hops: waiting here ignores task cancellation.
private final class SuccessorSchedulingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    var hasEntered: Bool { lock.withLock { entered } }

    func enterAndWait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                entered = true
                if released { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock {
            released = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }
}

private final class ObservedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

@Suite("Idle calibration coordinator")
struct IdleCalibrationCoordinatorTests {
    @Test("foreground admission waits for calibration retirement, not successor scheduling")
    func foregroundDoesNotAwaitSuccessorScheduling() async throws {
        let coordinator = IdleCalibrationCoordinator()
        let successor = SuccessorSchedulingGate()
        defer { successor.release() }
        let session = coordinator.startIfIdle(isIdle: { true },
            onRetired: { await successor.enterAndWait() }) {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
        }
        #expect(session != nil)

        let admitted = ObservedFlag()
        let foreground = Task {
            let lease = await coordinator.admittedLease()
            admitted.set()
            return lease
        }
        let until = ContinuousClock.now + .seconds(5)
        while !admitted.isSet && ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(1))
        }
        let admittedWhileSuccessorBlocked = admitted.isSet
        successor.release()
        let lease = try #require(await foreground.value)
        #expect(admittedWhileSuccessorBlocked,
            "a customer's deadline must not wait on cross-actor successor scheduling")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!successor.hasEntered, "a preempted session leaves successors to the next idle opportunity")
        lease.finish()
    }

    @Test("an uncancelled retirement schedules its successor after releasing the global owner")
    func retirementSchedulesSuccessorAfterRelease() async throws {
        let coordinator = IdleCalibrationCoordinator()
        let successorStarted = ObservedFlag()
        let successor = SuccessorSchedulingGate()
        defer { successor.release() }
        let session = coordinator.startIfIdle(isIdle: { true }, onRetired: {
            if coordinator.startIfIdle(isIdle: { true }, operation: {}) != nil { successorStarted.set() }
            await successor.enterAndWait()
        }) {}
        #expect(session != nil)
        let until = ContinuousClock.now + .seconds(5)
        while !successor.hasEntered && ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(successor.hasEntered, "retirement still offers the next resident engine")
        #expect(successorStarted.isSet, "the successor sees the finished session's ownership released")
    }

    @Test("a session records what first cancelled it, and a new session starts clean")
    func sessionRecordsItsFirstCanceller() async throws {
        let coordinator = IdleCalibrationCoordinator()
        let probe: @Sendable () async -> Void = {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
        }
        let first = try #require(coordinator.startIfIdle(isIdle: { true }, operation: probe))
        #expect(coordinator.hasSession && coordinator.cancellationSource == nil)
        coordinator.cancel()
        let lease = try #require(await coordinator.admittedLease())
        await first.value
        #expect(coordinator.cancellationSource == "device work" && !coordinator.hasSession)
        lease.finish()

        let second = try #require(coordinator.startIfIdle(isIdle: { true }, operation: probe))
        #expect(coordinator.cancellationSource == nil)
        let foreground = try #require(await coordinator.admittedLease())
        await second.value
        #expect(coordinator.cancellationSource == "request")
        foreground.finish()
    }

    @Test("a waiting request that is cancelled leaves at once and holds nothing")
    func cancelledWaiterLeaves() async throws {
        let coordinator = IdleCalibrationCoordinator()
        // Ignores cancellation, as a probe whose engine stopped stepping does.
        let engine = SuccessorSchedulingGate()
        defer { engine.release() }
        let stuck = try #require(coordinator.startIfIdle(isIdle: { true }) { await engine.enterAndWait() })
        let waiter = Task { await coordinator.admitForeground() }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        let outcome = await waiter.value
        guard case .cancelled = outcome else {
            Issue.record("a cancelled request must stop waiting for the probe")
            return
        }
        #expect(!coordinator.isOverdue(stuck), "a cancel is not a stall")
        #expect(coordinator.hasSession, "the probe is still running")
    }

    @Test("a probe that outlives the bound refuses the waiter and reads overdue until it retires")
    func overdueProbeRefusesUntilItRetires() async throws {
        let coordinator = IdleCalibrationCoordinator()
        coordinator.retirementBound = .milliseconds(50)
        let engine = SuccessorSchedulingGate()
        defer { engine.release() }
        let probe = try #require(coordinator.startIfIdle(isIdle: { true }) { await engine.enterAndWait() })
        guard case .retirementOverdue = await coordinator.admitForeground() else {
            Issue.record("a request must be refused once the bound passes")
            return
        }
        #expect(coordinator.isOverdue(probe))
        #expect(coordinator.startIfIdle(isIdle: { true }, operation: {}) == nil,
            "no new probe while the overdue one still runs")
        engine.release()
        await probe.value
        #expect(!coordinator.isOverdue(probe) && !coordinator.hasSession)
        let lease = try #require(await coordinator.admittedLease(), "with no probe a request is admitted at once")
        lease.finish()
    }
}

extension IdleCalibrationCoordinator {
    /// The lease of a request that waited for retirement, or nil if it was
    /// refused or cancelled.
    func admittedLease() async -> IdleCalibrationForegroundLease? {
        guard case .admitted(let lease) = await admitForeground() else { return nil }
        return lease
    }
}
