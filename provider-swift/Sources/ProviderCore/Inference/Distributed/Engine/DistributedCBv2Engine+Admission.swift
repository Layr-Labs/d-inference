import Foundation
import MLXLMCommon

extension DistributedCBv2Engine {
    struct Admission {
        let stream: AsyncStream<CBv2Event>
        let state: DistributedRequestState
        let admittedAt: ContinuousClock.Instant
        let deadlineRefused: Bool
    }

    enum AdmissionOutcome {
        case refused(CBv2FirstTokenProjectedWork)
        case admitted(Admission, CBv2FirstTokenProjectedWork)
    }

    func admit(
        _ submitted: CBv2Request, deadlineContext: DistributedRequestDeadlineContext,
        projected: CBv2FirstTokenProjectedWork? = nil,
        cancellation: DistributedAdmissionCancellation? = nil
    ) throws -> Admission {
        try validate(submitted)
        let request = resolvingSeed(submitted)
        try deadlineContext.checkAdmission(at: clock.now())
        let deadline = deadlineContext.firstTokenDeadline
        guard let capacity = readyCapacity(), capacity > 0 else {
            throw DistributedEngineError.unavailable
        }
        let admissionStartedAt = clock.now()
        let lease: any DistributedResidentRequestLease
        if let boundedOwner = owner as? any DistributedDeadlineExecutionOwner {
            lease = try boundedOwner.reserve(request, identity: identity, profileID: profile.id,
                                             capacityLimit: capacity, deadlineContext: deadlineContext)
        } else {
            // Existing injected owners retain their contract. Only the opt-in
            // capability above can interrupt a synchronous reserve wait itself.
            lease = try owner.reserve(request, identity: identity, profileID: profile.id, capacityLimit: capacity)
        }
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        let state = DistributedRequestState(
            request: request, lease: lease, continuation: continuation,
            detokenizer: detokenizers.makeDetokenizer(stopStrings: request.stopStrings),
            absoluteDeadline: deadlineContext.generationDeadline, firstTokenDeadline: deadline,
            admissionStartedAt: admissionStartedAt, reservedAt: clock.now())
        actives[state.generation] = state
        observe(state, phase: .reserved)
        cancellation?.arm { [weak self, weak state] in
            guard let self, let state else { return }
            self.onQueue { self.stop(state, reason: .cancelled) }
        }
        continuation.onTermination = { [weak self, generation = state.generation] _ in
            self?.onQueue {
                guard self?.actives[generation] != nil else { return }
                self?.stop(state, reason: .cancelled)
            }
        }
        // Always retain the engine and lease until acknowledgement, even if the
        // consumer drops the stream or the owner throws after partially starting.
        Task { [self, state] in
            await state.lease.waitUntilRetired()
            onQueue { retire(state) }
        }
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
        } else if let deadline, let projected,
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
        guard actives.count < max(1, owner.concurrentRequests) else {
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
