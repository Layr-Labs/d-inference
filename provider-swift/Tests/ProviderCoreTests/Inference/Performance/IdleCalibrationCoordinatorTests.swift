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

private final class AdmissionFlag: @unchecked Sendable {
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

        let admitted = AdmissionFlag()
        let foreground = Task {
            let lease = await coordinator.beginForeground()
            admitted.set()
            return lease
        }
        let until = ContinuousClock.now + .seconds(5)
        while !(admitted.isSet && successor.hasEntered) && ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(1))
        }
        let admittedWhileSuccessorBlocked = admitted.isSet
        let successorRan = successor.hasEntered
        successor.release()
        let lease = await foreground.value
        #expect(admittedWhileSuccessorBlocked,
            "a customer's deadline must not wait on cross-actor successor scheduling")
        #expect(successorRan, "retirement still offers the next resident engine")
        lease.finish()
    }
}
