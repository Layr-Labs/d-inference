import Foundation

/// Waits for authorization on one already-authenticated connection. The lookup
/// never mints a grant or follows a replacement connection. Closing the scope
/// blocks new local starts before cancelling/joining its original obligation.
final class NativePairLocalStart: @unchecked Sendable {
    private let next: @Sendable () throws -> NativePairRetainedSessionClaim?
    private let closeScope: @Sendable () -> Task<Void, Never>
    private let lock = NSLock(), closed = DispatchGroup()
    private var closing = false
    private var selected: NativePairRetainedSessionClaim?
    private var cleanup: Task<Void, Never>?

    init(next: @escaping @Sendable () throws -> NativePairRetainedSessionClaim?,
         closeScope: @escaping @Sendable () -> Task<Void, Never>) {
        self.next = next; self.closeScope = closeScope; closed.enter()
    }
    func wait(until deadline: UInt64) async throws -> NativePairRetainedSessionClaim {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now, deadline - now <= 90_000_000_000 else { cancel(); throw NativePairMemberError.deadline }
        return try await withTaskCancellationHandler {
            do {
                while DispatchTime.now().uptimeNanoseconds < deadline {
                    try Task.checkCancellation()
                    guard !lock.withLock({ closing }) else { throw CancellationError() }
                    if let value = try next() {
                        let allowed = lock.withLock { () -> Bool in
                            guard !closing, selected == nil else { return false }
                            selected = value; return true
                        }
                        guard allowed else { value.cancel(); throw CancellationError() }
                        try Task.checkCancellation()
                        return value
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                throw NativePairMemberError.deadline
            } catch { cancel(); throw error }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        let state = lock.withLock { () -> (Bool, NativePairRetainedSessionClaim?) in
            guard !closing else { return (false, nil) }
            closing = true; return (true, selected)
        }
        guard state.0 else { return }
        let task = closeScope()
        state.1?.cancel()
        lock.withLock { cleanup = task }
        closed.leave()
    }
    func waitUntilClosed() async {
        cancel()
        await withCheckedContinuation { continuation in
            closed.notify(queue: .global()) { continuation.resume() }
        }
        let task = lock.withLock { cleanup! }
        await task.value
    }
}
