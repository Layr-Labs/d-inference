import Foundation
import Testing

/// One-shot test rendezvous. A failed preparation must fail its observer,
/// rather than leaving the whole CI process waiting for an entry that cannot happen.
actor UpgradeBarrier {
    var entered = false
    var released = false
    private var observationExpired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var observationTimer: Task<Void, Never>?

    func wait() async {
        entered = true
        observationTimer?.cancel()
        observationTimer = nil
        let observing = observers; observers.removeAll()
        for observer in observing { observer.resume() }
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }

    func observeEntry() async {
        guard !entered, !observationExpired else { return }
        if observationTimer == nil {
            observationTimer = Task {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { return }
                expireObservation()
            }
        }
        await withCheckedContinuation { observers.append($0) }
    }

    private func expireObservation() {
        guard !entered, !observers.isEmpty else { return }
        observationExpired = true
        observationTimer = nil
        Issue.record("Upgrade barrier was not entered within 30 seconds; preparation or admission may have failed before reaching it")
        let observing = observers; observers.removeAll()
        // Late arrivals also pass through, so failure cleanup cannot strand them.
        release()
        for observer in observing { observer.resume() }
    }

    func release() {
        released = true
        let current = waiters; waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}
