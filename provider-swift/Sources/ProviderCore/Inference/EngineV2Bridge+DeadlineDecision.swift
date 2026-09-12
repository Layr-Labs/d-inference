// Deadline diagnostics observe existing decisions. They never participate in
// policy, engine submission, resource ownership, or external error mapping.

import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    func deadlineProjectionBypassReason(
        deadline: FirstContentDeadline?, isMultimodal: Bool
    ) -> DeadlineProjectionReason {
        if deadline == nil { return .noDeadline }
        if prefillDeadlineMode != .enforce { return .modeOff }
        if !prefillDeadlineProjectionEnabled { return .unsupportedScheduler }
        if isMultimodal { return .multimodal }
        return .unmeasuredPrefill
    }
}

extension RequestProfileBuilder {
    /// Call in the same synchronous stretch immediately before engine.submit.
    func beginDeadlineDecision(
        deadline: FirstContentDeadline?,
        admission: CBv2FirstTokenDeadlineAdmission?,
        bypassReason: DeadlineProjectionReason?
    ) {
        let remaining = deadline.map { Self.budgetRemainingUs($0.remainingDuration()) }
        update { f, _ in
            var d = DeadlineDecisionProfile()
            d.submitRemainingUs = remaining
            d.prefillTps = admission?.conservativePrefillTokensPerSecond
            d.decodeTps = admission?.conservativeDecodeTokensPerSecond
            if admission == nil {
                d.projection = .notAttempted
                d.projectionReason = bypassReason
            }
            f.deadlineDecision = d
        }
    }

    /// Store the returned engine evidence before the bridge checks cancellation
    /// or expiry. The first verdict wins; later cleanup only annotates it.
    func observeDeadlineDecision(
        _ verdict: DeadlineVerdict,
        work: CBv2FirstTokenProjectedWork? = nil,
        deadline: FirstContentDeadline?,
        continuation: DeadlineContinuation? = nil
    ) {
        let observed = SuspendingClock.now
        let remaining = deadline.map { Self.budgetRemainingUs($0.remainingDuration()) }
        let offset = offsetUs(of: observed)
        update { f, _ in
            var d = f.deadlineDecision ?? DeadlineDecisionProfile()
            if d.verdict == nil {
                d.verdict = verdict
                d.observedUs = max(1, offset)
                d.remainingUs = remaining
                if let work {
                    switch work {
                    case .bounded(let work, let duration):
                        d.projection = .bounded
                        d.projectedPrefillTokens = Int64(work.prefillTokens)
                        d.projectedDecodeTokens = Int64(work.decodeTokens)
                        d.projectedServiceUs = Self.microseconds(duration)
                    case .unbounded:
                        d.projection = .unbounded
                    }
                }
            }
            if let continuation { d.continuation = continuation }
            f.deadlineDecision = d
        }
    }

    func stopDeadlineContinuation(_ continuation: DeadlineContinuation) {
        update { f, _ in
            guard var d = f.deadlineDecision else { return }
            d.continuation = continuation
            f.deadlineDecision = d
        }
    }
}
