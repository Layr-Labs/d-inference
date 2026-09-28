import Foundation

/// One normalized service allowance shared by every resident model. A profile
/// of width N consumes 1/N per request; three models never get three budgets.
/// Leases have no timeout: cancellation releases only after engine retirement.
final class WholeMacServiceBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var charges: [String: Double] = [:]
    private var observerID: UUID?
    private var observer: AsyncStream<Void>.Continuation?

    func acquire(ownerID: String, concurrency: Int) -> Bool {
        let (acquired, notification) = lock.withLock { () -> (Bool, AsyncStream<Void>.Continuation?) in
            guard charges[ownerID] == nil, concurrency > 0 else { return (false, nil) }
            let charge = 1 / Double(concurrency)
            guard charges.values.reduce(0, +) + charge <= 1 + 1e-12 else { return (false, nil) }
            charges[ownerID] = charge
            return (true, observer)
        }
        notification?.yield()
        return acquired
    }

    func release(ownerID: String) {
        let notification = lock.withLock { () -> AsyncStream<Void>.Continuation? in
            guard charges.removeValue(forKey: ownerID) != nil else { return nil }
            return observer
        }
        notification?.yield()
    }

    /// One provider-loop observer sees changes from all shared model bridges.
    /// Coalesce bursts before the actor hop; the consumer reads current usage,
    /// never a possibly reordered fraction captured by the notifying thread.
    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.removeObserver(id) }
        let previous = lock.withLock {
            let previous = observer
            observerID = id
            observer = continuation
            return previous
        }
        previous?.finish()
        continuation.yield() // include ownership acquired before registration
        return stream
    }

    private func removeObserver(_ id: UUID) {
        lock.withLock {
            guard observerID == id else { return }
            observerID = nil
            observer = nil
        }
    }

    var usedFraction: Double { lock.withLock { charges.values.reduce(0, +) } }
    var count: Int { lock.withLock { charges.count } }
}
