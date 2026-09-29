import Foundation

/// Runtime-wide numeric measurement notifications. Each subscription owns its
/// stream, so stopping a monitor cannot permanently close future subscriptions.
/// Bursts coalesce before the loop actor hop; consumers read current capacity.
final class EnginePerformanceUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var observerID: UUID?
    private var observer: AsyncStream<Void>.Continuation?

    func notify() {
        let continuation = lock.withLock { observer }
        continuation?.yield()
    }

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
        continuation.yield() // Include observations made before monitor startup.
        return stream
    }

    private func removeObserver(_ id: UUID) {
        lock.withLock {
            guard observerID == id else { return }
            observerID = nil
            observer = nil
        }
    }
}
