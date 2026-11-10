import Foundation
import MLXLMCommon

extension DistributedCBv2Engine {
    /// Establish the profile ceiling at a trusted provider-local origin. The
    /// coordinator's first-content budget remains a separate first-token limit.
    public func deadlineContext(receivedAt: ContinuousClock.Instant,
                                firstTokenDeadline: ContinuousClock.Instant? = nil) -> DistributedRequestDeadlineContext {
        .init(generationDeadline: receivedAt.advanced(by: profile.requestTimeout),
              firstTokenDeadline: firstTokenDeadline)
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

    /// The prompt tokens of every request holding a lane that has not given its first token: running, or waiting for
    /// its reservation.
    var pendingPrefillTokens: Int {
        actives.values.reduce(admittingPromptTokens) { total, state in
            state.firstTokenAt == nil && state.terminal == nil ? total + state.request.promptTokens.count : total
        }
    }

    /// The owner's projection of a request's own first token, behind every prompt already holding a lane. A pair runs
    /// its lanes' prompts one after another, so a request's first token waits for all of them (C1, 2026-11-10: of eight
    /// 8K-token prompts sent at once, the last gave its first token at 63.7 s, against 7.7 s alone). The caller's
    /// prefill rate prices them (`projectionRespectingCallerRates`).
    func behindPendingPrefill(_ projection: CBv2FirstTokenProjectedWork) -> CBv2FirstTokenProjectedWork {
        let pending = pendingPrefillTokens
        guard case .bounded(let work, let duration) = projection, pending > 0 else { return projection }
        return .bounded(work: .init(prefillTokens: work.prefillTokens + pending, decodeTokens: work.decodeTokens,
                                    scheduledSteps: work.scheduledSteps, mixedSteps: work.mixedSteps,
                                    decodeSteps: work.decodeSteps),
                        serviceDuration: duration)
    }

    func projectionRespectingCallerRates(
        _ projection: CBv2FirstTokenProjectedWork, admission: CBv2FirstTokenDeadlineAdmission
    ) -> CBv2FirstTokenProjectedWork {
        guard case .bounded(let work, let ownerDuration) = projection, ownerDuration > .zero else { return .unbounded(reason: nil) }
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
        else { return .unbounded(reason: nil) }
        // The owner adds transfer/control costs; a more conservative caller
        // phase-rate policy can never be replaced by the owner's faster bound.
        return .bounded(work: work, serviceDuration: max(ownerDuration, .seconds(prefill + decode)))
    }
}
