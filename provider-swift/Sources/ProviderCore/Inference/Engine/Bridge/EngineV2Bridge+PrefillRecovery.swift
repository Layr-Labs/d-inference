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
    func canRecoverPrefillEvidence(promptTokens: Int, deadline: FirstContentDeadline?,
        isMultimodal: Bool, at now: ContinuousClock.Instant = .now) -> Bool {
        supportsPrefillRecoveryRetirement && prefillDeadlineMode == .enforce && prefillDeadlineProjectionEnabled &&
            (deadline?.remainingDuration(now: now) ?? .zero) > .zero &&
            deadlineProfile == nil && !isMultimodal && promptTokens > 0 &&
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
                    prefillEvidenceRecovery.beginSubmission(requestID)
                    if let native = ownedEngine as? CBv2NativeBlockEngine {
                        return try native.submitWithRetirement(request)
                    }
                    if let native = ownedEngine as? EngineV2,
                        native.nativeShutdownExecutionContractID != nil {
                        return try native.submitWithNativeRetirement(request)
                    }
                    throw PreContentDeadlineFailure.deadlineUnreachable
                }) else { throw PreContentDeadlineFailure.deadlineUnreachable }
        return submitted
    }
}
