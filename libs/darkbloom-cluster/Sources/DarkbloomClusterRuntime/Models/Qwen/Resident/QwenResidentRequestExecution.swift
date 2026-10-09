import DarkbloomClusterProtocol
import Foundation

/// Executes one already-reserved request inside the runtime's autorelease and
/// publication scopes. Returns CPU values; the runtime retains model ownership.
enum QwenResidentRequestExecution {
    /// The reservation's own live check plus the hand-off's named storage.
    static func requireLive(_ reserved: QwenResidentReservation, phaseSplit: QwenPhaseSplitAllowance?) throws {
        guard let phaseSplit else { try reserved.requireLive(); return }
        try reserved.allowance.requireLive(additionalNativeBytes: QwenLongPrefillCheckedBytes.sum([
            reserved.prefillAllowance?.extraNativeBytes ?? 0, reserved.recordingCharge?.capture.extraNativeBytes ?? 0,
            phaseSplit.extraNativeBytes,
        ]), additionalHostBytes: QwenLongPrefillCheckedBytes.sum([
            reserved.prefillAllowance?.extraHostBytes ?? 0, reserved.recordingCharge?.capture.extraHostBytes ?? 0,
            phaseSplit.extraHostBytes,
        ]))
    }

    static func run(stage: any LayerStageResidentStage, producerStage: (any LayerStageResidentStage)? = nil,
                    generationMode: QwenResidentGenerationMode = .pipeline,
                    phaseSplitAllowance: QwenPhaseSplitAllowance? = nil,
                    qualificationFault: QwenPhaseSplitFault? = nil,
                    admission: any LayerStageResidentAdmission,
                    collective: Collective, control: QwenResidentControl,
                    reserved: QwenResidentReservation,
                    onCommittedToken: (Int, Int, Int) throws -> Bool
    ) throws -> (QwenResidentGenerationCompletion, QwenGenerationDiagnosticEvidence?) {
        guard (generationMode == .phaseSplit) == (phaseSplitAllowance != nil),
              (generationMode == .phaseSplit && collective.rank == 1) == (producerStage != nil) else {
            throw ProbeError("Resident generation mode differs from its loaded stages or reservation")
        }
        let receipt = stage.loaded.receipt
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: receipt.sourceConfigurationSHA256,
            artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: receipt.storageCommitmentSHA256,
            planFingerprint: admission.plan.fingerprint,
            producerStageFingerprint: admission.plan.stages[0].fingerprint)
        // Both ranks derive the hand-off terms from their own Plan, registered
        // geometry and this request; the agreement fingerprint carries them.
        var split: QwenPhaseSplitPlan?
        if generationMode == .phaseSplit {
            guard let geometry = stage.handoffGeometry else {
                throw ProbeError("This registered model's request state does not change owner")
            }
            split = try QwenPhaseSplitPlan(plan: admission.plan, geometry: geometry, request: reserved.request)
        }
        let agreement = try QwenLayerStageGenerationAgreement(request: reserved.request,
            membershipEpoch: admission.configuration.identity.membershipEpoch,
            source: source, consumerStageFingerprint: admission.plan.stages[1].fingerprint,
            rankBuildSHA256: admission.configuration.identity.peers.map(\.buildSHA256),
            numericalPolicySHA256: admission.arithmeticSHA256, prefillPolicy: reserved.prefillPolicy,
            phaseSplit: split, compactDecode: generationMode == .pipelineCompactDecode)
        var lastResourceCheck: UInt64 = 0, ordinal = 0
        func check() throws {
            try control.check(deadline: reserved.deadline)
            let now = DispatchTime.now().uptimeNanoseconds
            if lastResourceCheck == 0 || now - lastResourceCheck >= 250_000_000 {
                try requireLive(reserved, phaseSplit: phaseSplitAllowance)
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
                activationDType: reserved.request.profile.selectedRowDType,
                bound: QwenResidentResourceEnvironment.allocationBound)
            try charge.requireCapture(actual.capture)
            // A fault is a qualification input: it exists only in a process
            // started with the explicit test flag, and only a recording request,
            // which the installed owner never makes, can be asked to commit one.
            let fault = split == nil ? nil : qualificationFault
            let recorded = try recordQwenLayerStageGenerationRequest(loaded: stage.loaded,
                producerStage: producerStage?.loaded,
                plan: admission.plan, agreement: agreement, collective: collective,
                resources: {
                    try stage.diagnosticResources(plan: admission.plan, request: reserved.request,
                        rank: collective.rank, requestAllowance: reserved.allowance)
                }, phaseSplitFault: fault,
                onCommittedToken: committedToken, check: check)
            try charge.requireCapture(recorded.captureBudget)
            evidence = recorded; result = recorded.execution
        } else {
            result = try runQwenLayerStageGenerationRequest(loaded: stage.loaded,
                producerStage: producerStage?.loaded,
                plan: admission.plan, agreement: agreement, collective: collective,
                onCommittedToken: committedToken, check: check)
            evidence = nil
        }
        guard result.bothRequestStatesRetired,
              let reason = ClusterWorkerFinishReason(rawValue: result.finishReason.rawValue) else {
            throw ProbeError("Resident generation returned without clean bilateral retirement")
        }
        // Sizes and durations of the hand-off, for whoever launched this worker.
        if let summary = result.phaseSplit { log(summary.diagnosticLine(requestID: reserved.request.requestID)) }
        let completion = QwenResidentGenerationCompletion(requestID: reserved.request.requestID, finishReason: reason,
            selectedTokenIDs: result.selectedTokenIDs, completedFrames: result.completedFrames,
            committedTokens: result.committedTokens, tokenChainSHA256: result.tokenChainSHA256,
            bothRequestStatesRetired: true)
        return (completion, evidence)
    }
}
