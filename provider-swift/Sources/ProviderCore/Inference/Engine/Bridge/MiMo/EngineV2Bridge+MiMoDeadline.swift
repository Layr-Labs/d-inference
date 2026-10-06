import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    func captureNativeMediaRateEvidence(requestID: String) -> NativeMediaRateEvidence? {
        serviceBudget?.captureNativeMediaRateEvidence(
            ownerID: serviceOwnerPrefix + ":" + requestID, modelID: modelId)
    }

    /// Missing media measurements do not turn short-text throughput into a
    /// certified media prediction. One isolated request may gather evidence
    /// under the unchanged clock; rejected/failed attempts are rate limited.
    func nativeMediaDeadlinePolicy(requestID: String?, promptTokens: Int,
        evidence: NativeMediaRateEvidence?)
        -> CBv2NativeTargetPrefillPolicy {
        // Submission shares this exact snapshot with its completion receipt.
        // Nil stays nil even if posture becomes eligible a moment later.
        guard let requestID, promptTokens > 0, let evidence
        else { return .init() }
        let now = ContinuousClock.now
        if let observation = nativeMediaPrefillRates.observation(
            tokens: promptTokens, evidence: evidence, now: now) {
            return .init(observation: observation)
        }
        guard nativeMediaBootstrapRequestID == nil,
            nextNativeMediaBootstrapAt.map({ now >= $0 }) ?? true else { return .init() }
        nativeMediaBootstrapRequestID = requestID
        nextNativeMediaBootstrapAt = now + NativeMediaPrefillRates.maximumAge
        // releaseServiceAllowance clears the in-flight owner only after
        // pre-submit rejection or real engine retirement, including the
        // transferred cancellation path. Failed/ineligible attempts keep the
        // cooldown; a valid observation clears it only at real retirement.
        return .init(bootstrap: .init(promptTokens: promptTokens,
            validUntil: evidence.validUntil, evidenceGuard: evidence.guardToken))
    }
}
