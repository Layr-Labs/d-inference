import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    var supportsPrefillRecoveryRetirement: Bool {
        ownedEngine is CBv2NativeBlockEngine || tracksNativeShutdown
    }

    func isolatedPrefillEvidenceExpired(at now: ContinuousClock.Instant = .now) -> Bool {
        guard let expiration = performanceMeasurements.rateExpiration("isolated_prefill") else { return false }
        return now > expiration
    }

    /// Recovery is deliberately smaller than ordinary serving. A busy Mac,
    /// media request or large prompt still requires the normal projection.
    func canRecoverPrefillEvidence(promptTokens: Int, maxOutputTokens: Int, deadline: FirstContentDeadline?,
        isMultimodal: Bool, at now: ContinuousClock.Instant = .now) -> Bool {
        supportsPrefillRecoveryRetirement && prefillDeadlineMode == .enforce && prefillDeadlineProjectionEnabled &&
            (deadline?.remainingDuration(now: now) ?? .zero) > .zero &&
            deadlineProfile == nil && !isMultimodal && promptTokens > 0 && maxOutputTokens > 0 &&
            promptTokens <= PrefillEvidenceRecovery.maximumPromptTokens &&
            isolatedPrefillEvidenceExpired(at: now) && prefillEvidenceRecovery.available(at: now)
    }

    func submitPrefillEvidenceRecovery(_ request: CBv2Request, requestID: String,
        deadline: FirstContentDeadline?) throws
        -> (events: AsyncStream<CBv2Event>, retirement: CBv2RequestRetirement) {
        guard let serviceBudget, let guardValue = prefillEvidenceRecovery.evidenceGuard,
            let submitted = try serviceBudget.withExclusiveEvidence(
                ownerID: serviceOwnerPrefix + ":" + requestID, guardValue: guardValue, submit: {
                    try deadline?.check()
                    let submitted: (events: AsyncStream<CBv2Event>, retirement: CBv2RequestRetirement)
                    if let native = ownedEngine as? CBv2NativeBlockEngine {
                        submitted = try native.submitWithRetirement(request)
                    } else if let native = ownedEngine as? EngineV2,
                        native.nativeShutdownExecutionContractID != nil {
                        submitted = try native.submitWithNativeRetirement(request)
                    } else { throw PreContentDeadlineFailure.deadlineUnreachable }
                    prefillEvidenceRecovery.admit(requestID)
                    return submitted
                }) else { throw PreContentDeadlineFailure.deadlineUnreachable }
        return submitted
    }
}
