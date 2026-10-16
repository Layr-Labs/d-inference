import Foundation
import MLXLMCommon

/// Experimental engine: one request at a time, or as many as the owner's batch
/// lanes (continuous batching on the pair). The injected owner, not this adapter,
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
    /// Every request reserved or running, by state generation: at most the
    /// owner's `concurrentRequests`.
    var actives: [UUID: DistributedRequestState] = [:]
    func isActive(_ state: DistributedRequestState) -> Bool { actives[state.generation] === state }
    /// The request, for an owner that serves one at a time (and its tests).
    var active: DistributedRequestState? { actives.count == 1 ? actives.values.first : nil }
    var invalidated = false
    var stopping = false
    var shutdownTask: Task<Void, Never>?
    /// The seed of every sampled request that names none (see `resolvingSeed`).
    let fallbackSeed = UInt64.random(in: .min ... .max)
    /// Receives a cleanly finished request's receipt and the prompt
    /// frontiers both peers now hold; the bridge turns them into resident
    /// prefix evidence for routing. Set once, before serving.
    var residentPrefixPublication: ((CBv2RequestID, [Int]) -> Void)?

    public func setResidentPrefixPublicationHandler(_ handler: @escaping (CBv2RequestID, [Int]) -> Void) {
        onQueue { residentPrefixPublication = handler }
    }

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
            guard let state = actives.values.first(where: { $0.request.id == id }) else { return }
            stop(state, reason: .cancelled)
        }
    }

    public func capacity() -> CBv2CapacitySnapshot {
        onQueue {
            let capacity = readyCapacity() ?? 0
            let states = Array(actives.values)
            let reserved = states.reduce(0) { $0 + max(0, $1.lease.reservedBytes) }
            let inUse = states.reduce(0) { $0 + $1.lease.bytesInUse }
            if inUse < 0 || inUse > reserved { invalidate() }
            return CBv2CapacitySnapshot(
                activeRequests: states.count, waitingRequests: 0,
                kvBytesInUse: max(0, inUse), kvBytesCapacity: invalidated ? 0 : capacity,
                kvBytesBackendCapacity: invalidated ? 0 : capacity,
                kvBytesReserved: reserved,
                activeTokens: states.reduce(0) { $0 + $1.request.promptTokens.count + $1.completionTokens })
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
        let pending = Array(actives.values)
        for state in pending { stop(state, reason: .cancelled) }
        let task = Task { [owner] in
            for state in pending { await state.retired.wait() }
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
        for state in Array(actives.values) { stop(state, reason: .error("distributed peer readiness lost")) }
    }
}
