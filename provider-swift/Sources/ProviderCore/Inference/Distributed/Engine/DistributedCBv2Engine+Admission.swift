import Foundation
import MLXLMCommon

extension DistributedCBv2Engine {
    struct Admission {
        let stream: AsyncStream<CBv2Event>
        let state: DistributedRequestState
        let admittedAt: ContinuousClock.Instant
        let deadlineRefused: Bool
    }

    /// A submission with a first-token deadline: refused for its projection,
    /// or holding a lane.
    enum ProjectedSubmission {
        case refused(CBv2FirstTokenProjectedWork)
        case held(Admitting, CBv2FirstTokenProjectedWork)
    }

    /// A request holding a lane from its submission until it is in `actives`.
    struct Admitting {
        let request: CBv2Request
        let deadlineContext: DistributedRequestDeadlineContext
        let projected: CBv2FirstTokenProjectedWork?
        let cancellation: DistributedAdmissionCancellation?
    }

    /// On queue, at submission: the request's checks, and a lane held for it
    /// (`admitting`), so that the lane check and the capacity read count it
    /// while it waits for its reservation.
    func holdLane(
        _ submitted: CBv2Request, deadlineContext: DistributedRequestDeadlineContext,
        projected: CBv2FirstTokenProjectedWork? = nil,
        cancellation: DistributedAdmissionCancellation? = nil
    ) throws -> Admitting {
        try validate(submitted)
        let request = resolvingSeed(submitted)
        admitting[request.id, default: 0] += 1
        publishCapacity()
        return .init(request: request, deadlineContext: deadlineContext, projected: projected, cancellation: cancellation)
    }

    /// The reservation, then the admission, of a request holding a lane. Never
    /// on `queue`: the ranks answer a reservation at their next step boundary,
    /// and a running lane's step waits for its token's answer, which is given
    /// on `queue`. Reservations run one after another, on `admissionQueue`.
    func admit(_ held: Admitting) throws -> Admission {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return try admissionQueue.sync { try admitInTurn(held) }
    }

    /// `admit` from an async caller: resumed from `admissionQueue`.
    func admitInTurn(_ held: Admitting, continuation: CheckedContinuation<Admission, Error>) {
        admissionQueue.async { [self] in continuation.resume(with: Result { try admitInTurn(held) }) }
    }

    func admitInTurn(_ held: Admitting) throws -> Admission {
        dispatchPrecondition(condition: .onQueue(admissionQueue))
        let capacity: Int
        do {
            capacity = try onQueue { try prepareReservation(held) }
        } catch {
            onQueue {
                releaseLane(held.request.id)
                publishCapacity()
            }
            throw error
        }
        let admissionStartedAt = clock.now()
        let lease = Result { try reserve(held, capacityLimit: capacity) }
        return try onQueue {
            try complete(held, lease: lease, capacity: capacity, admissionStartedAt: admissionStartedAt)
        }
    }

    /// On queue, just before the reservation: what may have changed since
    /// submission. Returns the capacity the reservation is limited to.
    private func prepareReservation(_ held: Admitting) throws -> Int {
        guard !stopping else { throw DistributedEngineError.shuttingDown }
        try held.deadlineContext.checkAdmission(at: clock.now())
        guard let capacity = readyCapacity(), capacity > 0 else {
            throw DistributedEngineError.unavailable
        }
        // A caller that went away while this submission waited (behind another
        // reservation) costs no reservation.
        if held.cancellation?.isCancelled == true { throw CancellationError() }
        return capacity
    }

    /// Off queue: the ranks' reservation.
    private func reserve(_ held: Admitting, capacityLimit capacity: Int) throws -> any DistributedResidentRequestLease {
        if let boundedOwner = owner as? any DistributedDeadlineExecutionOwner {
            return try boundedOwner.reserve(held.request, identity: identity, profileID: profile.id,
                                            capacityLimit: capacity, deadlineContext: held.deadlineContext)
        }
        // Existing injected owners retain their contract. Only the opt-in
        // capability above can interrupt a synchronous reserve wait itself.
        return try owner.reserve(held.request, identity: identity, profileID: profile.id, capacityLimit: capacity)
    }

    /// On queue: the lane is no longer held for an admission. True when a
    /// cancel named the request meanwhile. The caller publishes the capacity
    /// once the request is in `actives` or refused, so that no snapshot shows
    /// its lane free in between.
    @discardableResult
    private func releaseLane(_ id: CBv2RequestID) -> Bool {
        let cancelled = cancelledWhileAdmitting.contains(id)
        let count = admitting[id] ?? 0
        admitting[id] = count > 1 ? count - 1 : nil
        if admitting[id] == nil { cancelledWhileAdmitting.remove(id) }
        return cancelled
    }

    /// On queue, once the reservation returned: the request runs in its lane.
    private func complete(
        _ held: Admitting, lease reserved: Result<any DistributedResidentRequestLease, Error>,
        capacity: Int, admissionStartedAt: ContinuousClock.Instant
    ) throws -> Admission {
        defer { publishCapacity() }
        let cancelledMeanwhile = releaseLane(held.request.id)
        let lease = try reserved.get()
        let request = held.request, deadlineContext = held.deadlineContext, cancellation = held.cancellation
        let deadline = deadlineContext.firstTokenDeadline
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        let state = DistributedRequestState(
            request: request, lease: lease, continuation: continuation,
            detokenizer: detokenizers.makeDetokenizer(stopStrings: request.stopStrings, scope: request.stopStringScope),
            absoluteDeadline: deadlineContext.generationDeadline, firstTokenDeadline: deadline,
            admissionStartedAt: admissionStartedAt, reservedAt: clock.now())
        actives[state.generation] = state
        observe(state, phase: .reserved)
        // Both run from task cancellation: they never wait for the queue (a
        // cancellation already consumed here, during reserve, still runs at once).
        cancellation?.arm { [weak self, weak state] in
            guard let self, let state else { return }
            self.onQueueWithoutWaiting { self.stop(state, reason: .cancelled) }
        }
        continuation.onTermination = { [weak self, generation = state.generation] _ in
            guard let self else { return }
            self.onQueueWithoutWaiting {
                guard self.actives[generation] != nil else { return }
                self.stop(state, reason: .cancelled)
            }
        }
        // Always retain the engine and lease until acknowledgement, even if the
        // consumer drops the stream or the owner throws after partially starting.
        // A cooperative thread never waits for the queue.
        Task { [self, state] in
            await state.lease.waitUntilRetired()
            queue.async { [self] in retire(state) }
        }
        // A cancel that named it during its reservation, or a shutdown begun
        // meanwhile, stops it before its prompt starts.
        if cancelledMeanwhile || stopping { stop(state, reason: .cancelled) }
        var refused = false
        let admittedAt = clock.now()
        if state.terminal != nil, !state.cleanStopPending {
            // A cancellation during reserve that the lease could not take as a
            // clean stop is consumed before native start.
        } else if lease.identity != identity || lease.requestID != request.id ||
            lease.reservedBytes <= 0 || lease.reservedBytes > capacity {
            stop(state, reason: .error("distributed owner returned an invalid reservation"))
        } else if readyCapacity() == nil {
            stop(state, reason: .error("distributed readiness changed during admission"))
        } else if let deadline, let projected = held.projected,
            !projectionFits(projected, deadline: min(deadline, state.absoluteDeadline),
                            promptTokens: request.promptTokens.count) {
            refused = true
            stop(state, reason: .terminal(cause: .admissionTimeout, message: "distributed admission deadline"))
        } else if clock.now() >= state.absoluteDeadline {
            stop(state, reason: .terminal(cause: .safetyDeadline, message: "distributed request deadline"))
        } else if let deadline, clock.now() >= deadline {
            stop(state, reason: .terminal(cause: .admissionTimeout, message: "distributed first-token deadline"))
        } else {
            // Also reached by a request whose consumer went away during
            // reserve: the owner has no way to give a reservation back, so the
            // request is started and ends at its first token with the clean
            // stop, which keeps the pair.
            armDeadline(state)
            do {
                try lease.start { [weak self, weak state] event in
                    guard let self, let state else { return false }
                    return self.onQueue { self.receive(event, state: state) }
                }
                state.leaseStarted = true
                publishFailure(state)
            } catch {
                stop(state, reason: .error("distributed owner start failed: \(error)"))
            }
        }
        return Admission(stream: stream, state: state, admittedAt: admittedAt, deadlineRefused: refused)
    }

    func validate(_ request: CBv2Request) throws {
        guard !stopping else { throw DistributedEngineError.shuttingDown }
        // A request the pair can never serve is refused for what it is, even
        // while another request runs.
        if let refusal = profile.refusal(for: request) { throw DistributedEngineError.refused(refusal) }
        // A pair that can no longer serve says so first, also while its last
        // request is still retiring (not "busy", which invites a retry).
        guard readyCapacity() != nil else { throw DistributedEngineError.unavailable }
        guard actives.count + admittingCount < max(1, owner.concurrentRequests) else {
            throw CBv2KVError.capacityExhausted(needed: 1, available: 0)
        }
        // Within the profile but longer than what the owner serves now (a
        // rank's live admissible memory): refused up front, retryably.
        let total = request.promptTokens.count.addingReportingOverflow(request.maxTokens)
        if let serving = owner.readiness()?.servingContextTokens, !total.overflow, total.partialValue > serving {
            throw DistributedEngineError.refusedForCapacity(requestedContextTokens: total.partialValue,
                servingContextTokens: serving, reason: "capacity")
        }
        // Sampling (temperature, top-p/k, min-p, penalties, logit bias, seed)
        // is the decoding rank's, with the product's sampler. A receipt only
        // names this submission for the bridge's evidence; the peers decide
        // reuse themselves (rank-local caches, agreed before the first
        // forward) and the terminal usage reports what they reused.
    }

    /// An omitted seed takes this engine's fallback, as the product's
    /// sampler gives every row without a seed its engine-level seed: fixed
    /// for this engine, random across runs. Paired with the request's own
    /// identity, it gives each unseeded request its own random stream.
    func resolvingSeed(_ request: CBv2Request) -> CBv2Request {
        guard request.sampling.seed == nil else { return request }
        var resolved = request
        resolved.sampling.seed = fallbackSeed
        return resolved
    }
}
