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
        _ request: CBv2Request, deadlineContext: DistributedRequestDeadlineContext,
        projected: CBv2FirstTokenProjectedWork? = nil,
        cancellation: DistributedAdmissionCancellation? = nil
    ) throws -> Admission {
        try validate(request)
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
        active = state
        observe(state, phase: .reserved)
        cancellation?.arm { [weak self, weak state] in
            guard let self, let state else { return }
            self.onQueue { self.stop(state, reason: .cancelled) }
        }
        continuation.onTermination = { [weak self, generation = state.generation] _ in
            self?.onQueue {
                guard self?.active?.generation == generation else { return }
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
        if state.terminal != nil {
            // Cancellation during reserve is consumed before native start.
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
            armDeadline(state)
            do {
                try lease.start { [weak self, weak state] event in
                    guard let self, let state else { return false }
                    return self.onQueue { self.receive(event, state: state) }
                }
            } catch {
                stop(state, reason: .error("distributed owner start failed: \(error)"))
            }
        }
        return Admission(stream: stream, state: state, admittedAt: admittedAt, deadlineRefused: refused)
    }

    func validate(_ request: CBv2Request) throws {
        guard !stopping else { throw DistributedEngineError.shuttingDown }
        guard active == nil else { throw CBv2KVError.capacityExhausted(needed: 1, available: 0) }
        guard readyCapacity() != nil else { throw DistributedEngineError.unavailable }
        let total = request.promptTokens.count.addingReportingOverflow(request.maxTokens)
        guard !request.promptTokens.isEmpty, request.promptTokens.count <= profile.maxPromptTokens,
            request.maxTokens > 0, request.maxTokens <= profile.maxOutputTokens,
            !total.overflow, total.partialValue <= profile.maxContextTokens,
            request.promptTokens.allSatisfy({ 0 <= $0 && $0 < profile.vocabularySize }),
            request.stopTokens.allSatisfy({ 0 <= $0 && $0 < profile.vocabularySize })
        else { throw DistributedEngineError.unsupportedRequest("token limits or vocabulary") }
        let p = request.sampling
        guard p.temperature == 0, p.topP == 1, p.topK == 0, p.minP == 0,
            p.repetitionPenalty == 1, p.frequencyPenalty == 0, p.presencePenalty == 0,
            p.seed == nil, p.logitBias.isEmpty, p.topLogprobs == 0,
            request.multimodal == nil, request.positionState == nil,
            request.tokenConstraint == nil, request.priority == 0,
            request.prefixCacheReceiptID == nil,
            request.stopStrings.count <= 16,
            request.stopStrings.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 })
        else { throw DistributedEngineError.unsupportedRequest("only greedy text without MTP, constraints or logprobs") }
        // prefixCacheEnabled permits reuse; this engine always reports disabled.
        // No cache state is reused or donated, including across cacheSalt values.
    }
}
