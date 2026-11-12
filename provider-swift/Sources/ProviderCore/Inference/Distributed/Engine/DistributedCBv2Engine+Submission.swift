import Foundation
import MLXLMCommon

extension DistributedCBv2Engine {
    public func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        try submit(request, deadlineContext: deadlineContext(receivedAt: clock.now()))
    }

    public func submit(_ request: CBv2Request,
                       deadlineContext context: DistributedRequestDeadlineContext) throws -> AsyncStream<CBv2Event> {
        // Capture before queue.sync: waiting for the engine queue consumes time.
        let bounded = context.restricted(to: deadlineContext(receivedAt: clock.now()))
        let held = try onQueue { try holdLane(request, deadlineContext: bounded) }
        return try admit(held).stream
    }

    /// The submission without a timing projection, for a caller that must not
    /// wait for the queue itself: the bridge's actor, which cancels and
    /// capacity reads need while another request's reservation waits. The lane
    /// is held at once; the reservations run in order. A caller that goes away
    /// while this waits for its reservation never reserves; one that goes away
    /// during its reservation is stopped before its prompt starts. Opaque media
    /// buffers need the returned generation acknowledgement.
    func submitAwaitingQueue(_ request: CBv2Request,
        deadlineContext context: DistributedRequestDeadlineContext
    ) async throws -> (events: AsyncStream<CBv2Event>, retirement: CBv2RequestRetirement) {
        let bounded = context.restricted(to: deadlineContext(receivedAt: clock.now()))
        let cancellation = DistributedAdmissionCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    let held: Admitting
                    do { held = try holdLane(request, deadlineContext: bounded, cancellation: cancellation) } catch {
                        return continuation.resume(throwing: error)
                    }
                    admissionQueue.async { [self] in
                        continuation.resume(with: Result {
                            let value = try admitInTurn(held)
                            return (value.stream, value.state.retirement)
                        })
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
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
        let checked = try onQueue { () -> ProjectedSubmission in
            try validate(request)
            let projected = projectionRespectingCallerRates(
                behindPendingPrefill(owner.projectFirstToken(request, admission: admission)), admission: admission)
            guard projectionFits(projected, deadline: min(effectiveFirst, bounded.generationDeadline),
                                 promptTokens: request.promptTokens.count) else {
                return .refused(projected)
            }
            return .held(try holdLane(request, deadlineContext: bounded, projected: projected, cancellation: cancellation),
                         projected)
        }
        let held: Admitting, projected: CBv2FirstTokenProjectedWork
        switch checked {
        case .refused(let work): return .deadlineUnreachable(projectedWork: work)
        case .held(let value, let work): (held, projected) = (value, work)
        }
        // Off the cooperative pool: the reservation blocks its thread.
        let admitted = try await withCheckedThrowingContinuation { admitInTurn(held, continuation: $0) }
        if admitted.deadlineRefused {
            await admitted.state.retired.wait()
            try Task.checkCancellation()
            return .deadlineUnreachable(projectedWork: projected)
        }
        if cancellation.isCancelled || Task.isCancelled {
            let state = admitted.state
            onQueueWithoutWaiting { [self] in stop(state, reason: .cancelled) }
            throw CBv2FirstTokenAdmissionCancellation(
                stream: admitted.stream, retirement: admitted.state.retirement)
        }
        return .admitted(
            stream: admitted.stream, projectedWork: projected,
            admittedAt: admitted.admittedAt, retirement: admitted.state.retirement)
    }
}
