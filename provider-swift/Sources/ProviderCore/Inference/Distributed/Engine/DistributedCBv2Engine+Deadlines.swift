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
}
