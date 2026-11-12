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
    let requestObserver: (@Sendable (DistributedRequestObservation) -> Void)?
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
        self.requestObserver = requestObserver
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

    /// Establish the profile ceiling at a trusted provider-local origin. The
    /// coordinator's first-content budget remains a separate first-token limit.
    public func deadlineContext(receivedAt: ContinuousClock.Instant,
                                firstTokenDeadline: ContinuousClock.Instant? = nil) -> DistributedRequestDeadlineContext {
        .init(generationDeadline: receivedAt.advanced(by: profile.requestTimeout),
              firstTokenDeadline: firstTokenDeadline)
    }

    public func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        try submit(request, deadlineContext: deadlineContext(receivedAt: clock.now()))
    }

    public func submit(_ request: CBv2Request,
                       deadlineContext context: DistributedRequestDeadlineContext) throws -> AsyncStream<CBv2Event> {
        // Capture before queue.sync: waiting for the engine queue consumes time.
        let bounded = context.restricted(to: deadlineContext(receivedAt: clock.now()))
        return try onQueue { try admit(request, deadlineContext: bounded).stream }
    }

    public func submit(
        _ request: CBv2Request, firstTokenDeadline: CBv2FirstTokenDeadlineAdmission
    ) async throws -> CBv2FirstTokenDeadlineResult {
        try await submit(request, firstTokenDeadline: firstTokenDeadline,
                         deadlineContext: deadlineContext(receivedAt: clock.now()))
    }

    public func submit(
        _ request: CBv2Request, firstTokenDeadline: CBv2FirstTokenDeadlineAdmission,
        deadlineContext context: DistributedRequestDeadlineContext
    ) async throws -> CBv2FirstTokenDeadlineResult {
        let bounded = context.restricted(to: deadlineContext(receivedAt: clock.now(),
                                                             firstTokenDeadline: firstTokenDeadline.deadline))
        let cancellation = DistributedAdmissionCancellation()
        return try await withTaskCancellationHandler {
            try await submit(request, deadline: firstTokenDeadline, cancellation: cancellation,
                             deadlineContext: bounded)
        } onCancel: {
            cancellation.cancel()
        }
    }

    func submit(
        _ request: CBv2Request, deadline: CBv2FirstTokenDeadlineAdmission,
        cancellation: DistributedAdmissionCancellation,
        deadlineContext context: DistributedRequestDeadlineContext? = nil
    ) async throws -> CBv2FirstTokenDeadlineResult {
        let local = deadlineContext(receivedAt: clock.now(), firstTokenDeadline: deadline.deadline)
        let bounded = context.map { local.restricted(to: $0) } ?? local
        let effectiveFirst = min(deadline.deadline, bounded.firstTokenDeadline ?? deadline.deadline)
        let admission = CBv2FirstTokenDeadlineAdmission(deadline: effectiveFirst,
            conservativePrefillTokensPerSecond: deadline.conservativePrefillTokensPerSecond,
            conservativeDecodeTokensPerSecond: deadline.conservativeDecodeTokensPerSecond)
        try Task.checkCancellation()
        let outcome = try onQueue { () -> AdmissionOutcome in
            try validate(request)
            let projected = projectionRespectingCallerRates(
                owner.projectFirstToken(request, admission: admission), admission: admission)
            guard projectionFits(projected, deadline: min(effectiveFirst, bounded.generationDeadline),
                                 promptTokens: request.promptTokens.count) else {
                return .refused(projected)
            }
            let admitted = try admit(
                request, deadlineContext: bounded, projected: projected, cancellation: cancellation)
            return .admitted(admitted, projected)
        }
        switch outcome {
        case .refused(let projected):
            return .deadlineUnreachable(projectedWork: projected)
        case .admitted(let admitted, let projected):
            if admitted.deadlineRefused {
                await admitted.state.retired.wait()
                try Task.checkCancellation()
                return .deadlineUnreachable(projectedWork: projected)
            }
            if cancellation.isCancelled || Task.isCancelled {
                onQueue { stop(admitted.state, reason: .cancelled) }
                throw CBv2FirstTokenAdmissionCancellation(
                    stream: admitted.stream, retirement: admitted.state.retirement)
            }
            return .admitted(
                stream: admitted.stream, projectedWork: projected,
                admittedAt: admitted.admittedAt, retirement: admitted.state.retirement)
        }
    }

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

    func projectionFits(
        _ projection: CBv2FirstTokenProjectedWork, deadline: ContinuousClock.Instant, promptTokens: Int
    ) -> Bool {
        guard case .bounded(let work, let duration) = projection,
            work.prefillTokens >= promptTokens, work.decodeTokens >= 0, work.scheduledSteps > 0,
            work.mixedSteps >= 0, work.mixedSteps <= work.scheduledSteps, duration > .zero,
            duration <= profile.requestTimeout
        else { return false }
        return clock.now().duration(to: deadline) >= duration
    }

    func projectionRespectingCallerRates(
        _ projection: CBv2FirstTokenProjectedWork, admission: CBv2FirstTokenDeadlineAdmission
    ) -> CBv2FirstTokenProjectedWork {
        guard case .bounded(let work, let ownerDuration) = projection, ownerDuration > .zero else { return .unbounded }
        func phaseSeconds(_ tokens: Int, _ rate: Double?) -> Double? {
            guard tokens >= 0 else { return nil }
            if tokens == 0 { return 0 }
            guard let rate, rate.isFinite, rate > 0 else { return nil }
            let value = Double(tokens) / rate
            return value.isFinite && value <= 3600 ? value : nil
        }
        guard let prefill = phaseSeconds(work.prefillTokens, admission.conservativePrefillTokensPerSecond),
            let decode = phaseSeconds(work.decodeTokens, admission.conservativeDecodeTokensPerSecond),
            prefill + decode <= 3600
        else { return .unbounded }
        // The owner adds transfer/control costs; a more conservative caller
        // phase-rate policy can never be replaced by the owner's faster bound.
        return .bounded(work: work, serviceDuration: max(ownerDuration, .seconds(prefill + decode)))
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
