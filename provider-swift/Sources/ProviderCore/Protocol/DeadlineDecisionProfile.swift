// Optional, closed diagnostic fields for one provider engine submission.
// Mirror: coordinator/protocol/profile_deadline.go.

import Foundation

public enum DeadlineVerdict: String, ProfilerFoldingEnum {
    case accepted
    case deadlineUnreachable = "deadline_unreachable"
    case expiredBeforeSubmit = "expired_before_submit"
    /// The call was cancelled without returning an engine verdict. This does
    /// not assert whether the engine briefly accepted the request.
    case cancelled
    case other
}

public enum DeadlineContinuation: String, ProfilerFoldingEnum {
    case expired
    case cancelled
    case other
}

public enum DeadlineProjection: String, ProfilerFoldingEnum {
    case bounded
    case unbounded
    case notAttempted = "not_attempted"
    case other
}

/// Why the provider used ordinary submit. An engine `.unbounded` verdict
/// exposes no cause, so it must never be assigned one of these reasons.
public enum DeadlineProjectionReason: String, ProfilerFoldingEnum {
    case noDeadline = "no_deadline"
    case modeOff = "mode_off"
    case unsupportedScheduler = "unsupported_scheduler"
    case multimodal
    case unmeasuredPrefill = "unmeasured_prefill"
    case other
}

public struct DeadlineDecisionProfile: Codable, Sendable, Equatable {
    public var verdict: DeadlineVerdict?
    /// Set only when cancellation/expiry stops continuation after a verdict.
    public var continuation: DeadlineContinuation?
    public var projection: DeadlineProjection?
    public var projectionReason: DeadlineProjectionReason?
    /// Microseconds from the provider profile anchor when the bridge receives
    /// the verdict (or observes pre-submit expiry), NOT the engine's decision
    /// instant. The engine API does not expose its refusal instant.
    public var observedUs: Int64?
    /// Remaining deadline at the same provider observation, clamped at zero.
    public var remainingUs: Int64?
    /// Remaining deadline immediately before calling engine.submit.
    public var submitRemainingUs: Int64?
    public var projectedServiceUs: Int64?
    public var projectedPrefillTokens: Int64?
    public var projectedDecodeTokens: Int64?
    /// Exact conservative rates passed to the engine, after the existing
    /// policy adjustment. Absent means unavailable, never a measured zero.
    public var prefillTps: Double?
    public var decodeTps: Double?

    enum CodingKeys: String, CodingKey {
        case verdict, continuation, projection
        case projectionReason = "projection_reason"
        case observedUs = "observed_us"
        case remainingUs = "remaining_us"
        case submitRemainingUs = "submit_remaining_us"
        case projectedServiceUs = "projected_service_us"
        case projectedPrefillTokens = "projected_prefill_tokens"
        case projectedDecodeTokens = "projected_decode_tokens"
        case prefillTps = "prefill_tps"
        case decodeTps = "decode_tps"
    }

    public init() {}

    public func saturatedToWireRanges() -> Self {
        func us(_ v: Int64?) -> Int64? {
            v.map { min(max(0, $0), InferenceProfile.maxWireMicros) }
        }
        func n(_ v: Int64?) -> Int64? {
            v.map { min(max(0, $0), InferenceProfile.maxWireCount) }
        }
        func rate(_ v: Double?) -> Double? {
            guard let v, v.isFinite, v > 0 else { return nil }
            return min(v, Double(InferenceProfile.maxWireCount))
        }
        var d = self
        d.observedUs = us(d.observedUs)
        d.remainingUs = us(d.remainingUs)
        d.submitRemainingUs = us(d.submitRemainingUs)
        d.projectedServiceUs = us(d.projectedServiceUs)
        d.projectedPrefillTokens = n(d.projectedPrefillTokens)
        d.projectedDecodeTokens = n(d.projectedDecodeTokens)
        d.prefillTps = rate(d.prefillTps)
        d.decodeTps = rate(d.decodeTps)
        return d
    }
}
