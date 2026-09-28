import Foundation
import MLXLMCommon

/// Experimental one-request engine. The injected owner, not this adapter,
/// implements transport, native execution, per-peer resource admission and fencing.
/// Default/local production factories do not instantiate this type.
public final class DistributedCBv2Engine: CBv2Engine, @unchecked Sendable {
    let queue = DispatchQueue(label: "darkbloom.experimental.distributed-engine")
    let queueKey = DispatchSpecificKey<UInt8>()
    let owner: any DistributedResidentExecutionOwner
    let identity: DistributedResidentIdentity
    let profile: DistributedResidentExecutionProfile
    let detokenizers: any CBv2DetokenizerFactory
    let clock: CBv2Clock
    let observationSink: DistributedRequestObservationSink?
    var capacityLimit: Int
    var active: DistributedRequestState?
    var invalidated = false
    var stopping = false
    var shutdownTask: Task<Void, Never>?

    /// On failure, the caller still owns (and must close) owner. On success this
    /// engine owns it exclusively until shutdown() acknowledges model retirement.
    public init(
        owner: any DistributedResidentExecutionOwner,
        expectedIdentity: DistributedResidentIdentity,
        profile: DistributedResidentExecutionProfile,
        detokenizers: any CBv2DetokenizerFactory,
        clock: CBv2Clock = .continuous,
        requestObserver: (@Sendable (DistributedRequestObservation) -> Void)? = nil
    ) throws {
        try expectedIdentity.validate()
        guard let ready = owner.readiness(), ready.identity == expectedIdentity,
            ready.profileID == profile.id, ready.requestCapacityBytes > 0
        else { throw DistributedEngineError.unavailable }
        self.owner = owner
        self.identity = expectedIdentity
        self.profile = profile
        self.detokenizers = detokenizers
        self.clock = clock
        self.observationSink = requestObserver.map(DistributedRequestObservationSink.init)
        self.capacityLimit = ready.requestCapacityBytes
        queue.setSpecific(key: queueKey, value: 1)
        owner.setReadinessInvalidationHandler { [weak self] in
            guard let self else { return }
            self.onQueue { self.invalidate() }
        }
        guard onQueue({ readyCapacity() != nil }) else {
            throw DistributedEngineError.unavailable
        }
    }

    func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }

    public func cancel(_ id: CBv2RequestID) {
        onQueue {
            guard let state = active, state.request.id == id else { return }
            stop(state, reason: .cancelled)
        }
    }

    public func capacity() -> CBv2CapacitySnapshot {
        onQueue {
            let capacity = readyCapacity() ?? 0
            let reserved = max(0, active?.lease.reservedBytes ?? 0)
            let inUse = active?.lease.bytesInUse ?? 0
            if inUse < 0 || inUse > reserved { invalidate() }
            return CBv2CapacitySnapshot(
                activeRequests: active == nil ? 0 : 1, waitingRequests: 0,
                kvBytesInUse: max(0, inUse), kvBytesCapacity: invalidated ? 0 : capacity,
                kvBytesBackendCapacity: invalidated ? 0 : capacity,
                kvBytesReserved: reserved,
                activeTokens: active.map { $0.request.promptTokens.count + $0.completionTokens } ?? 0)
        }
    }

    public func updateKVBytesCapacity(_ bytes: Int) {
        onQueue { capacityLimit = max(0, bytes) }
    }

    public func shutdown() async {
        let task = onQueue { beginShutdown() }
        await task.value
    }

    /// Called on queue; publishes refusal before waiting for any peer work.
    func beginShutdown() -> Task<Void, Never> {
        if let shutdownTask { return shutdownTask }
        stopping = true
        let pending = active
        if let pending { stop(pending, reason: .cancelled) }
        let task = Task { [owner] in
            if let pending { await pending.retired.wait() }
            await owner.shutdown()
        }
        shutdownTask = task
        return task
    }

    func readyCapacity() -> Int? {
        guard !stopping, !invalidated else { return nil }
        guard let ready = owner.readiness(), ready.identity == identity,
            ready.profileID == profile.id, ready.requestCapacityBytes > 0
        else { invalidate(); return nil }
        return min(capacityLimit, ready.requestCapacityBytes)
    }

    func invalidate() {
        invalidated = true
        if let active { stop(active, reason: .error("distributed peer readiness lost")) }
    }
}
