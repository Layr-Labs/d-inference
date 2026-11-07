import Foundation

// The pair's leader takes the owner's local requests beside Darkbloom.
//
// The leader member's unified local endpoint (`ProviderLoop+LocalEndpoint`)
// serves the published pair slot: local and Darkbloom requests share its one
// bridge and its lanes. No process, copy or buffer is added. What holds:
//
// - Only the member that hosts the slot runs a local API, and only with a key
//   (`admitsClusterPairLocalAPI`). Every other member refuses one before
//   `run()` binds anything.
// - A local request that finds every lane busy waits in arrival order,
//   bounded as `cluster local`'s queue is (`DistributedRequestQueue`): 429 when
//   the queue is full, 503 past its ceiling. Nobody overtakes a waiter.
// - A waiter costs nothing: it is parked until something that can free a lane
//   or refuse it wakes it (a local request released one, the capacity refresh
//   that follows every Darkbloom request's end, admission opening after the
//   warmup canary, a drain, the slot retiring), its client goes away or its
//   ceiling passes. Nothing polls.
// - Darkbloom requests never enter this queue, and their path through the slot
//   is unchanged. Their side only calls `wakeClusterPairLocalWaiters`, which
//   does nothing while nobody waits.

/// The owner's use of the pair through this Mac's local API began or ended.
enum ClusterPairLocalUse { case began, ended }

/// The leader's local requests on its pair's lanes: those waiting, oldest
/// first, and the lanes the others hold, per published slot. Owned by the
/// loop actor; every method is synchronous. The queue is bounded
/// (`enqueue`) and first in, first out: only the request `isNext` may take a
/// free lane.
struct ClusterPairLocalLanes {
    /// Fixed when the loop is made (`DARKBLOOM_CLUSTER_QUEUE_WAITING`).
    let limits: DistributedRequestQueue.Limits
    private var waiting: [UUID] = []
    private var parked: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Woken while checking rather than parked: it checks again first.
    private var woken: Set<UUID> = []
    /// Refused while checking rather than parked: it throws instead of parking.
    private var refusals: [UUID: any Error] = [:]
    /// Each lane a local request holds, and the slot it was taken on.
    private var grants: [UUID: UUID] = [:]
    /// Local requests waiting for a lane or holding one: the owner's use.
    private(set) var inUse = 0

    init(limits: DistributedRequestQueue.Limits) { self.limits = limits }

    var waitingCount: Int { waiting.count }
    private func isFirst(_ ticket: UUID) -> Bool { waiting.first == ticket }
    func lanesHeld(on slot: UUID) -> Int { grants.values.reduce(0) { $1 == slot ? $0 + 1 : $0 } }

    /// Whether a request may take a free lane now: the first waiter, or one
    /// not queued (nil) while nobody waits, so it never overtakes a waiter.
    func isNext(_ ticket: UUID?) -> Bool {
        guard let ticket else { return waiting.isEmpty }
        return isFirst(ticket)
    }

    /// A place at the back of the queue, or 429 when it is full.
    mutating func enqueue() throws -> UUID {
        guard waiting.count < limits.maximumWaiting else {
            throw MultiModelBatchSchedulerEngineError.queueFull(DistributedRequestQueue.fullMessage)
        }
        let ticket = UUID()
        waiting.append(ticket)
        return ticket
    }

    /// Parks a waiter until it is woken or refused; one that was either
    /// since its last check resumes at once.
    mutating func park(_ ticket: UUID, _ continuation: CheckedContinuation<Void, Error>) {
        if let refusal = refusals.removeValue(forKey: ticket) {
            continuation.resume(throwing: refusal)
        } else if woken.remove(ticket) != nil {
            continuation.resume()
        } else {
            parked[ticket] = continuation
        }
    }

    /// A lane may be free: the first waiter checks.
    mutating func wakeFirst() {
        if let first = waiting.first { wake(first) }
    }

    /// Waiters may be refused (the slot retires, the provider drains): each checks.
    mutating func wakeAll() {
        for ticket in waiting { wake(ticket) }
    }

    private mutating func wake(_ ticket: UUID) {
        if let continuation = parked.removeValue(forKey: ticket) { continuation.resume() } else { woken.insert(ticket) }
    }

    /// Refuses one waiter: its ceiling passed, or its client went away.
    mutating func refuse(_ ticket: UUID, _ error: any Error) {
        guard waiting.contains(ticket) else { return }
        if let continuation = parked.removeValue(forKey: ticket) {
            continuation.resume(throwing: error)
        } else {
            refusals[ticket] = error
        }
    }

    /// The waiter left, with a lane or without: if it was first, the next checks.
    mutating func leave(_ ticket: UUID) {
        let wasFirst = isFirst(ticket)
        waiting.removeAll { $0 == ticket }
        woken.remove(ticket)
        refusals.removeValue(forKey: ticket)
        if wasFirst { wakeFirst() }
    }

    mutating func grant(on slot: UUID) -> UUID {
        let grant = UUID()
        grants[grant] = slot
        return grant
    }

    mutating func release(_ grant: UUID) { grants.removeValue(forKey: grant) }

    mutating func note(_ use: ClusterPairLocalUse) {
        inUse = use == .began ? inUse + 1 : max(0, inUse - 1)
    }
}

extension ProviderLoop {
    /// Whether this member hosts its pair's slot: the serving host role only
    /// a rank-0 installation gives (`installClusterPairServing`, before
    /// `run()`), whatever the number of ranks.
    var hostsClusterPairSlot: Bool { clusterPairServing != nil }

    /// A member runs a local API only where its pair's slot is, and always
    /// with a key, as `cluster local` does. `prepareClusterMemberControl` asks
    /// first thing in `run()`, before the endpoint binds: any other member
    /// refuses to start with one.
    func admitsClusterPairLocalAPI(_ endpoint: LocalInferenceHTTPConfig) -> Bool {
        hostsClusterPairSlot && !(endpoint.authToken ?? "").isEmpty
    }

    /// The owner-pause hook (me first): the owner's use of the pair begins
    /// when a local request starts waiting for a lane, or takes one at once,
    /// before it can wait behind Darkbloom work, and ends exactly once: when
    /// it leaves without a lane, or when its lane is released. With me first
    /// on, it pauses the pair's Darkbloom work (`ProviderLoop+ClusterPairMeFirst`).
    func noteClusterPairLocalUse(_ use: ClusterPairLocalUse) {
        clusterPairLocalLanes.note(use)
        noteLocalUse(use == .began ? .start : .end)
    }

    /// The pair's refusal while it does not serve (forming, re-forming,
    /// retired): 503, as `cluster local` answers, so a client retries later
    /// or goes elsewhere.
    static var clusterPairNotServing: MultiModelBatchSchedulerEngineError {
        .requestRejected(DistributedRequestQueue.unavailableMessage)
    }

    /// A local request on the leader: 404 for a model this member does not
    /// serve, the drain's refusal as on a single Mac, 503 while the pair does
    /// not serve, otherwise one of the pair's lanes (`takeClusterPairLane`).
    /// The owner's use begins once the request is past those refusals.
    func acquireClusterPairForLocal(_ modelID: String) async throws -> MultiModelBatchSchedulerEngine.AcquiredModel {
        guard advertisedModels[modelID] != nil else { throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelID) }
        try throwIfRefusingNewLocalWork(modelId: modelID)
        guard let handle = clusterPairSlot, handle.modelID == modelID, clusterPairSlotServes(modelID) else {
            throw Self.clusterPairNotServing
        }
        noteClusterPairLocalUse(.began)
        do {
            return try await takeClusterPairLane(handle)
        } catch {
            noteClusterPairLocalUse(.ended)
            throw error
        }
    }

    /// The request's lane: taken at once when one is free and nobody waits,
    /// otherwise in its place in the queue, until its ceiling. Every wake
    /// checks the slot, the drain and the lanes again before parking again.
    private func takeClusterPairLane(_ handle: ClusterPairSlotHandle) async throws
        -> MultiModelBatchSchedulerEngine.AcquiredModel {
        if let acquired = try await grantClusterPairLaneIfFree(handle, ticket: nil) { return acquired }
        let ticket = try clusterPairLocalLanes.enqueue()
        let ceiling = clusterPairLocalLanes.limits.waitCeiling(requestTimeout: handle.requestTimeout, lanes: handle.lanes)
        let expiry = Task { [weak self] in
            do { try await Task.sleep(for: ceiling) } catch { return }
            await self?.refuseClusterPairWaiter(ticket,
                MultiModelBatchSchedulerEngineError.requestRejected(DistributedRequestQueue.waitedTooLongMessage))
        }
        defer {
            expiry.cancel()
            clusterPairLocalLanes.leave(ticket)
        }
        while true {
            try Task.checkCancellation()
            guard clusterPairSlotStillServes(handle) else { throw Self.clusterPairNotServing }
            try throwIfRefusingNewLocalWork(modelId: handle.modelID)
            if let acquired = try await grantClusterPairLaneIfFree(handle, ticket: ticket) { return acquired }
            try await parkClusterPairWaiter(ticket)
        }
    }

    /// Parks a waiter until it is woken (it then checks again) or refused (its
    /// ceiling passed, or its client went away).
    private func parkClusterPairWaiter(_ ticket: UUID) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                clusterPairLocalLanes.park(ticket, continuation)
            }
        } onCancel: {
            Task { await self.refuseClusterPairWaiter(ticket, CancellationError()) }
        }
    }

    /// A lane for this request when it is next and a lane is free, nil
    /// otherwise. Free means both counts are below the pair's lanes: this
    /// Mac's (`clusterPairLaneFreeHere`) and the engine's own. Every check is
    /// made again after the engine's answer, and from there to the reservation
    /// nothing suspends, so a drain or retirement either refuses this request
    /// or counts it (`hasInflightWork`).
    private func grantClusterPairLaneIfFree(_ handle: ClusterPairSlotHandle, ticket: UUID?) async throws
        -> MultiModelBatchSchedulerEngine.AcquiredModel? {
        guard clusterPairLocalLanes.isNext(ticket), clusterPairLaneFreeHere(handle),
              let bridge = modelSlots[handle.modelID]?.engineV2 else { return nil }
        // The engine's own count, read without waiting for its queue: a
        // request that ended here may still be retiring there.
        let engine = await bridge.capacitySnapshot()
        guard engine.activeRequests + engine.waitingRequests < handle.lanes,
              clusterPairLocalLanes.isNext(ticket), clusterPairLaneFreeHere(handle),
              let slot = modelSlots[handle.modelID] else { return nil }
        try throwIfRefusingNewLocalWork(modelId: handle.modelID)
        let grant = clusterPairLocalLanes.grant(on: handle.id)
        localReservations.reserve(handle.modelID)
        modelSlots[handle.modelID]?.lastInferenceAt = .now
        let release: @Sendable (String) async -> Void = { [weak self] model in
            await self?.releaseClusterPairLane(grant, model: model)
        }
        // The pair's tokenizer and bridge, as `cluster local` hands them out: no
        // container and no vision gate (the ranks hold the model).
        return .init(tokenizer: slot.tokenizer,
            releaseToken: OneShotRelease(release: release, modelId: handle.modelID),
            modelType: slot.modelType, container: nil, isVLM: false, engineV2Bridge: slot.engineV2, visionGate: nil,
            queueExitedAt: ticket == nil ? nil : .now)
    }

    /// Whether `handle` is still the published slot and serves now: a request
    /// bound to it on arrival gets 503 once it does not.
    private func clusterPairSlotStillServes(_ handle: ClusterPairSlotHandle) -> Bool {
        clusterPairSlot === handle && clusterPairSlotServes(handle.modelID)
    }

    /// The slot still serves, its admission opened, and fewer requests hold
    /// its lanes than it has: local ones taken here and the Darkbloom ones
    /// this member accepted.
    private func clusterPairLaneFreeHere(_ handle: ClusterPairSlotHandle) -> Bool {
        guard clusterPairAdmissionOpenSlotID == handle.id, clusterPairSlotStillServes(handle) else { return false }
        let darkbloom = requestToModel.reduce(0) { held, entry in
            entry.value == handle.modelID && !entry.key.hasPrefix(Self.engineV2RecoveryPinPrefix) ? held + 1 : held
        }
        return clusterPairLocalLanes.lanesHeld(on: handle.id) + darkbloom < handle.lanes
    }

    /// The pair's own release, kept apart from a single Mac's
    /// (`releaseLocalReservation`): here the owner's use ends, once, and the
    /// first waiter checks the lane just freed.
    private func releaseClusterPairLane(_ grant: UUID, model: String) {
        clusterPairLocalLanes.release(grant)
        localReservations.release(model)
        modelSlots[model]?.lastInferenceAt = .now
        noteClusterPairLocalUse(.ended)
        clusterPairLocalLanes.wakeFirst()
    }

    private func refuseClusterPairWaiter(_ ticket: UUID, _ error: any Error) {
        clusterPairLocalLanes.refuse(ticket, error)
    }

    /// Something that can free a lane or refuse the waiters happened: the
    /// first waiter checks, or every waiter when they are to be refused.
    /// The Darkbloom side calls this too (each request's end through
    /// `refreshClusterPairCapacity`, and `beginServingDrain` on every Mac):
    /// while nobody waits it is one count check, so their path costs nothing
    /// more.
    func wakeClusterPairLocalWaiters() {
        guard clusterPairLocalLanes.waitingCount > 0 else { return }
        let serving = clusterPairSlot.map { clusterPairSlotServes($0.modelID) } ?? false
        if !serving || isDraining || isShuttingDown {
            clusterPairLocalLanes.wakeAll()
        } else {
            clusterPairLocalLanes.wakeFirst()
        }
    }
}
