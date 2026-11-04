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
        return try onQueue { try admit(request, deadlineContext: bounded).stream }
    }

    /// The submission without a timing projection, for a caller that must not
    /// wait for the queue itself: the bridge's actor, which cancels and
    /// capacity reads need while another reservation holds the queue. The
    /// admission still runs on the queue, in order. A caller that goes away
    /// while this waits for the queue never reserves; one that goes away during
    /// its reservation is stopped before its prompt starts. Opaque media
    /// buffers need the returned generation acknowledgement.
    func submitAwaitingQueue(_ request: CBv2Request,
        deadlineContext context: DistributedRequestDeadlineContext
    ) async throws -> (events: AsyncStream<CBv2Event>, retirement: CBv2RequestRetirement) {
        let bounded = context.restricted(to: deadlineContext(receivedAt: clock.now()))
        let cancellation = DistributedAdmissionCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    continuation.resume(with: Result {
                        let value = try admit(request, deadlineContext: bounded, cancellation: cancellation)
                        return (value.stream, value.state.retirement)
                    })
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
}
