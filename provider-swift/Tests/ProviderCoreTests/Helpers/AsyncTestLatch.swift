import Foundation

/// Counting latch for deterministic async test ordering. Signals are retained
/// until consumed, so a producer may run before its waiter without losing an edge.
final class AsyncTestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        let waiter: CheckedContinuation<Void, Never>?
        if waiters.isEmpty {
            permits += 1
            waiter = nil
        } else {
            waiter = waiters.removeFirst()
        }
        lock.unlock()
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            let resumeImmediately: Bool
            if permits > 0 {
                permits -= 1
                resumeImmediately = true
            } else {
                waiters.append(continuation)
                resumeImmediately = false
            }
            lock.unlock()
            if resumeImmediately { continuation.resume() }
        }
    }
}
