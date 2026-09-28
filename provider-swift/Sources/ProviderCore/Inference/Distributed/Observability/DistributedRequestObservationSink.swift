import Foundation

/// Best-effort value-only instrumentation. The queued work never captures a
/// request state, lease or model. A blocked callback cannot block its producer.
final class DistributedRequestObservationSink: @unchecked Sendable {
    static let maximumPending = 64
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "darkbloom.distributed.observations")
    private let callback: @Sendable (DistributedRequestObservation) -> Void
    private var pending: [DistributedRequestObservation] = []
    private var draining = false
    private var dropped: UInt64 = 0

    init(_ callback: @escaping @Sendable (DistributedRequestObservation) -> Void) {
        self.callback = callback
        pending.reserveCapacity(Self.maximumPending)
    }

    func enqueue(_ observation: DistributedRequestObservation) {
        let start = lock.withLock { () -> Bool in
            guard pending.count < Self.maximumPending else {
                if dropped != UInt64.max { dropped += 1 }
                return false
            }
            pending.append(observation)
            guard !draining else { return false }
            draining = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            let next = lock.withLock { () -> DistributedRequestObservation? in
                guard !pending.isEmpty else { draining = false; return nil }
                return pending.removeFirst().delivered(droppedObservations: dropped)
            }
            guard let next else { return }
            // Exactly one callback is in flight, outside the lock. Producer
            // contention is bounded by one <=64-element value-array operation.
            callback(next)
        }
    }

    /// Internal fixture observation; no wait or callback is needed to inspect
    /// a blocked sink's bounded backlog and cumulative loss.
    var pendingCount: Int { lock.withLock { pending.count } }
    var droppedCount: UInt64 { lock.withLock { dropped } }
}
