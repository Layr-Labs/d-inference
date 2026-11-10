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
            let lease = await coordinator.beginForeground()
            admitted.set()
            return lease
        }
        let until = ContinuousClock.now + .seconds(5)
        while !admitted.isSet && ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(1))
        }
        let admittedWhileSuccessorBlocked = admitted.isSet
        successor.release()
        let lease = await foreground.value
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
        let lease = await coordinator.beginForeground()
        await first.value
        #expect(coordinator.cancellationSource == "device work" && !coordinator.hasSession)
        lease.finish()

        let second = try #require(coordinator.startIfIdle(isIdle: { true }, operation: probe))
        #expect(coordinator.cancellationSource == nil)
        let foreground = await coordinator.beginForeground()
        await second.value
        #expect(coordinator.cancellationSource == "request")
        foreground.finish()
    }

    @Test("a prefix-store transfer ends a session unless the session tolerates it")
    func prefixStoreTransfersEndOnlySessionsThatDoNotTolerateThem() async throws {
        let budget = WholeMacServiceBudget()
        let coordinator = budget.idleCalibration
        let probe: @Sendable () async -> Void = {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
        }
        // A turn continuation: its own restore and checkpoint write do not end it.
        let tolerant = try #require(coordinator.startIfIdle(
            isIdle: { budget.isIdle }, toleratesPrefixStoreTransfers: true, operation: probe))
        let transfer = budget.beginUnboundedActivity(prefixStoreTransfer: true)
        #expect(!tolerant.isCancelled && coordinator.hasSession && coordinator.cancellationSource == nil)
        // The transfer is still device work to everything else on the Mac.
        #expect(!budget.isIdle)
        transfer.finish()
        #expect(budget.isIdle)
        // Any other device work ends it, and so would an arrival.
        let loading = budget.beginUnboundedActivity()
        await tolerant.value
        #expect(coordinator.cancellationSource == "device work" && !coordinator.hasSession)
        loading.finish()

        let arrival = try #require(coordinator.startIfIdle(
            isIdle: { budget.isIdle }, toleratesPrefixStoreTransfers: true, operation: probe))
        let lease = await coordinator.beginForeground()
        #expect(arrival.isCancelled && coordinator.cancellationSource == "request")
        lease.finish()

        // Calibration and shape warmup measure rates: a transfer ends them.
        let measuring = try #require(coordinator.startIfIdle(isIdle: { budget.isIdle }, operation: probe))
        let later = budget.beginUnboundedActivity(prefixStoreTransfer: true)
        await measuring.value
        #expect(coordinator.cancellationSource == "device work" && !coordinator.hasSession)
        later.finish()
    }
}
