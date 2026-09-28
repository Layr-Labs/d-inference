import DarkbloomClusterProtocol
import Foundation

/// Executes one already-reserved request inside the runtime's autorelease and
/// publication scopes. Returns CPU values; the runtime retains model ownership.
enum QwenResidentRequestExecution {
    static func run(stage: QwenResidentLoadedStage, admission: QwenResidentAdmission,
                    collective: Collective, control: QwenResidentControl,
                    reserved: QwenResidentReservation,
                    onCommittedToken: (Int, Int, Int) throws -> Bool
    ) throws -> (QwenResidentGenerationCompletion, QwenGenerationDiagnosticEvidence?) {
        let receipt = stage.loaded.receipt
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: receipt.sourceConfigurationSHA256,
            artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: receipt.storageCommitmentSHA256,
            planFingerprint: admission.plan.fingerprint,
            producerStageFingerprint: admission.plan.stages[0].fingerprint)
        let agreement = try QwenLayerStageGenerationAgreement(request: reserved.request,
            membershipEpoch: admission.configuration.identity.membershipEpoch,
            source: source, consumerStageFingerprint: admission.plan.stages[1].fingerprint,
            rankBuildSHA256: admission.configuration.identity.peers.map(\.buildSHA256),
            numericalPolicySHA256: admission.arithmeticSHA256, prefillPolicy: reserved.prefillPolicy)
        var lastResourceCheck: UInt64 = 0, ordinal = 0
        func check() throws {
            try control.check(deadline: reserved.deadline)
            let now = DispatchTime.now().uptimeNanoseconds
            if lastResourceCheck == 0 || now - lastResourceCheck >= 250_000_000 {
                try reserved.requireLive()
                lastResourceCheck = DispatchTime.now().uptimeNanoseconds
            }
            try control.check(deadline: reserved.deadline)
        }
        try check()
        func committedToken(_ token: Int) throws -> Bool {
            let current = ordinal; ordinal += 1
            return try onCommittedToken(current, token, reserved.request.promptCount + current)
        }
        let result: QwenLayerStageGenerationResult
        let evidence: QwenGenerationDiagnosticEvidence?
        if reserved.mode == .recording {
            guard let charge = reserved.recordingCharge else { throw ProbeError("Recording capture was not reserved") }
            let actual = try QwenResidentRecordingCharge.derive(base: reserved.allowance, rank: collective.rank,
                vocabularySize: reserved.request.profile.vocabularySize,
                activationDType: reserved.request.profile.activationDType,
                bound: QwenResidentResourceEnvironment.allocationBound)
            try charge.requireCapture(actual.capture)
            let recorded = try recordQwenLayerStageGenerationRequest(loaded: stage.loaded,
                profile: stage.profile, plan: admission.plan, agreement: agreement, collective: collective,
                requestAllowance: reserved.allowance, onCommittedToken: committedToken, check: check)
            try charge.requireCapture(recorded.captureBudget)
            evidence = recorded; result = recorded.execution
        } else {
            result = try runQwenLayerStageGenerationRequest(loaded: stage.loaded,
                plan: admission.plan, agreement: agreement, collective: collective,
                onCommittedToken: committedToken, check: check)
            evidence = nil
        }
        guard result.bothRequestStatesRetired,
              let reason = ClusterWorkerFinishReason(rawValue: result.finishReason.rawValue) else {
            throw ProbeError("Resident generation returned without clean bilateral retirement")
        }
        let completion = QwenResidentGenerationCompletion(requestID: reserved.request.requestID, finishReason: reason,
            selectedTokenIDs: result.selectedTokenIDs, completedFrames: result.completedFrames,
            committedTokens: result.committedTokens, tokenChainSHA256: result.tokenChainSHA256,
            bothRequestStatesRetired: true)
        return (completion, evidence)
    }
}
