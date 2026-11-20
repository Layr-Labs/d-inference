import Foundation
import MLXLMCommon

/// Experimental engine: one request at a time, or as many as the owner's batch
/// lanes (continuous batching on the pair). The injected owner, not this adapter,
/// implements transport, native execution, per-peer resource admission and fencing.
/// Default/local production factories do not instantiate this type.
public final class DistributedCBv2Engine: CBv2Engine, @unchecked Sendable {
    let queue = DispatchQueue(label: "darkbloom.experimental.distributed-engine")
    let queueKey = DispatchSpecificKey<UInt8>()
    /// Where the ranks' reservations wait, one after another, off `queue`
    /// (`DistributedCBv2Engine+Admission.swift`).
    let admissionQueue = DispatchQueue(label: "darkbloom.experimental.distributed-engine.admission")
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
    /// Lanes held by requests submitted but not yet in `actives` (waiting for
    /// their reservation, or in it), by request ID; and those of them a cancel
    /// named meanwhile.
    var admitting: [CBv2RequestID: Int] = [:]
    var cancelledWhileAdmitting: Set<CBv2RequestID> = []
    var admittingCount: Int { admitting.values.reduce(0, +) }
    /// The prompt tokens of the requests holding those lanes (`pendingPrefillTokens`).
    var admittingPromptTokens = 0
    /// The request, for an owner that serves one at a time (and its tests).
    var active: DistributedRequestState? { actives.count == 1 ? actives.values.first : nil }
    var invalidated = false
    var stopping = false
    var shutdownTask: Task<Void, Never>?
    /// The capacity the queue last computed, which `capacity()` answers from
    /// off the queue (`DistributedCBv2Engine+Capacity.swift`).
    let capacityPublication = DistributedCapacityPublication()
    /// The seed of every sampled request that names none (see `resolvingSeed`).
    let fallbackSeed = UInt64.random(in: .min ... .max)
    /// The pair's MTP counts over every request that reported them
    /// (`DistributedRankTelemetry`, the decoding rank's), for `/metrics`.
    var mtpTotals = DistributedMTPTotals()
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
            self.onQueue { self.invalidate(); self.publishCapacity() }
        }
        guard onQueue({ readyCapacity() != nil }) else {
            throw DistributedEngineError.unavailable
        }
        onQueue { _ = publishCapacity() }
    }

    func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }

    /// `onQueue` for a caller that must never wait for the queue: a task's
    /// cancellation handler, or a stream's termination that cancellation runs.
    /// Those hold the task's status lock, which the queue needs to resume that
    /// task (a `yield` to its stream, its retirement), so waiting can deadlock.
    func onQueueWithoutWaiting(_ body: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { body() } else { queue.async(execute: body) }
    }

    /// Returns at once. A request whose reservation is in flight, or still
    /// waiting, is stopped as soon as it is admitted.
    public func cancel(_ id: CBv2RequestID) {
        onQueueWithoutWaiting { [self] in
            if let state = actives.values.first(where: { $0.request.id == id }) {
                stop(state, reason: .cancelled)
            } else if admitting[id] != nil {
                cancelledWhileAdmitting.insert(id)
            }
        }
    }

    /// The pair's cumulative MTP counts (rank 0's runtime, request by request).
    public func mtpTotalsSnapshot() -> DistributedMTPTotals { onQueue { mtpTotals } }

    public func updateKVBytesCapacity(_ bytes: Int) {
        onQueue { capacityLimit = max(0, bytes); publishCapacity() }
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
        let task = Task { [self, owner] in
            for state in pending { await state.retired.wait() }
            // A reservation in flight returns into a stopping engine, which
            // stops its request at once; wait for those too.
            let late = await withCheckedContinuation { done in
                admissionQueue.async { [self] in queue.async { [self] in done.resume(returning: Array(actives.values)) } }
            }
            for state in late { await state.retired.wait() }
            await owner.shutdown()
        }
        shutdownTask = task
        publishCapacity()
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

/// Cumulative MTP counts a pair reported, summed request by request from the
/// decoding rank's request telemetry. `reported`: at least one request carried
/// MTP counts (its runtime decodes with a NextN head).
public struct DistributedMTPTotals: Sendable, Equatable {
    public var reported = false
    public var rounds = 0
    public var proposed = 0
    public var accepted = 0

    public init() {}

    mutating func add(_ telemetry: DistributedRankTelemetry) {
        guard telemetry.mtpRounds != nil || telemetry.mtpDrafted != nil else { return }
        reported = true
        rounds += max(0, telemetry.mtpRounds ?? 0)
        proposed += max(0, telemetry.mtpDrafted ?? 0)
        accepted += max(0, telemetry.mtpAccepted ?? 0)
    }
}
