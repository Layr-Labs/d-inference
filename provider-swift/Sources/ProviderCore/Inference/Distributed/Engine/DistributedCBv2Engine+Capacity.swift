import Foundation
import MLXLMCommon

// A reservation asks both ranks to admit a request and waits on the engine
// queue until each answers at its next step boundary: up to the lane admission
// wait (30 s) per reservation, one reservation after another. A capacity read
// that waited for the queue parked its caller for that long, and the caller is
// the bridge actor (heartbeat capacity, cancellation, submission), behind which
// the provider's coordinator traffic queued. So the queue publishes the
// capacity it computes, and a read off the queue answers from that.

/// The capacity the engine queue last computed, with the state that decides
/// whether the engine can admit at all. Read from any thread without waiting.
final class DistributedCapacityPublication: @unchecked Sendable {
    struct Value {
        var snapshot = CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
        /// Stopping or invalidated: the engine admits nothing again.
        var closed = false
        var capacityLimit = 0
    }

    private let lock = NSLock()
    private var value = Value()
    private var refreshQueued = false

    var current: Value { lock.withLock { value } }

    func publish(_ next: Value) { lock.withLock { value = next } }

    /// True for the one caller that should queue a refresh; later callers
    /// read the published value until that refresh starts.
    func claimRefresh() -> Bool {
        lock.withLock {
            guard !refreshQueued else { return false }
            refreshQueued = true
            return true
        }
    }

    func refreshStarted() { lock.withLock { refreshQueued = false } }
}

extension DistributedCBv2Engine {
    /// On the queue: computed, with its readiness and accounting checks, and
    /// published. Elsewhere: the published value at once, never waiting for the
    /// queue, with the owner's readiness read now (a lost peer reads as no
    /// capacity before the queue has seen it); a refresh is queued so the
    /// checks run as soon as the queue is free.
    public func capacity() -> CBv2CapacitySnapshot {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return publishCapacity() }
        if capacityPublication.claimRefresh() {
            queue.async { [weak self] in
                guard let self else { return }
                self.capacityPublication.refreshStarted()
                self.publishCapacity()
            }
        }
        let published = capacityPublication.current
        var snapshot = published.snapshot
        let capacity = published.closed ? 0 : liveReadyCapacity(limit: published.capacityLimit)
        snapshot.kvBytesCapacity = capacity
        snapshot.kvBytesBackendCapacity = capacity
        return snapshot
    }

    /// Called on queue after every change to what `capacity()` reports.
    @discardableResult
    func publishCapacity() -> CBv2CapacitySnapshot {
        let capacity = readyCapacity() ?? 0
        let states = Array(actives.values)
        let reserved = states.reduce(0) { $0 + max(0, $1.lease.reservedBytes) }
        let inUse = states.reduce(0) { $0 + $1.lease.bytesInUse }
        if inUse < 0 || inUse > reserved { invalidate() }
        let snapshot = CBv2CapacitySnapshot(
            activeRequests: states.count, waitingRequests: 0,
            kvBytesInUse: max(0, inUse), kvBytesCapacity: invalidated ? 0 : capacity,
            kvBytesBackendCapacity: invalidated ? 0 : capacity,
            kvBytesReserved: reserved,
            activeTokens: states.reduce(0) { $0 + $1.request.promptTokens.count + $1.completionTokens })
        capacityPublication.publish(
            .init(snapshot: snapshot, closed: stopping || invalidated, capacityLimit: capacityLimit))
        return snapshot
    }

    /// `readyCapacity` without its side effects, for a reader off the queue.
    private func liveReadyCapacity(limit: Int) -> Int {
        guard let ready = owner.readiness(), ready.identity == identity,
            ready.profileID == profile.id, ready.requestCapacityBytes > 0
        else { return 0 }
        return min(limit, ready.requestCapacityBytes)
    }
}
