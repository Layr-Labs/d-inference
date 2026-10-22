import DarkbloomClusterProtocol
import Foundation
import MLX

/// Executes one already-reserved request inside the runtime's autorelease and
/// publication scopes. Returns CPU values; the runtime retains model ownership.
enum QwenResidentRequestExecution {
    /// The reservation's own live check plus the hand-off's named storage.
    static func requireLive(_ reserved: QwenResidentReservation, phaseSplit: QwenPhaseSplitAllowance?) throws {
        guard let phaseSplit else { try reserved.requireLive(); return }
        try reserved.allowance.requireLive(additionalNativeBytes: QwenLongPrefillCheckedBytes.sum([
            reserved.prefillAllowance?.extraNativeBytes ?? 0, reserved.recordingCharge?.capture.extraNativeBytes ?? 0,
            phaseSplit.extraNativeBytes, reserved.prefixCaptureBytes,
        ]), additionalHostBytes: QwenLongPrefillCheckedBytes.sum([
            reserved.prefillAllowance?.extraHostBytes ?? 0, reserved.recordingCharge?.capture.extraHostBytes ?? 0,
            phaseSplit.extraHostBytes,
        ]), onLoadedStage: true)
    }

    /// While the request runs: what it still needs, given that this process's
    /// allocator grew by `grown` bytes since the request started.
    static func requireContinuing(_ reserved: QwenResidentReservation, phaseSplit: QwenPhaseSplitAllowance?,
                                  grown: Int) throws {
        try reserved.requireContinuing(grown: grown, additionalNativeBytes: phaseSplit?.extraNativeBytes ?? 0,
            additionalHostBytes: phaseSplit?.extraHostBytes ?? 0)
    }

    /// One live check of a running request: the prefix cache never makes it
    /// fail for memory. Kept prefixes give way first (`yieldingMemory`); if
    /// the check still refuses, the request's own capture, which is optional,
    /// is withdrawn (released, nothing stored for this request), its freed
    /// buffers returned to the system, and the request is checked again
    /// without that charge (`live` is given the capture charge to check).
    /// Only a refusal with both gone fails the request. Returns the capture
    /// charge from now on.
    static func checkRunning(captureBytes: Int, prefixCache: QwenStagePrefixCache?, rank: Int,
                             live: (_ captureBytes: Int) throws -> Void) throws -> Int {
        guard let prefixCache else { try live(captureBytes); return captureBytes }
        do {
            try prefixCache.yieldingMemory { try live(captureBytes) }
            return captureBytes
        } catch where captureBytes > 0 {
            prefixCache.withdrawCapture()
            Stream.gpu.synchronize()
            Memory.clearCache()
            log("darkbloom-prefix-v1 rank=\(rank) capture-withdrawn bytes=\(captureBytes) entries=\(prefixCache.count): \(error)")
            try live(0)
            return 0
        }
    }

    /// The source identity both ranks' generation agreement carries for a
    /// request on this loaded stage.
    static func sourceIdentity(stage: any LayerStageResidentStage, admission: any LayerStageResidentAdmission) throws
        -> QwenLayerStageWireSourceIdentity {
        let receipt = stage.loaded.receipt
        return try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: receipt.sourceConfigurationSHA256,
            artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: receipt.storageCommitmentSHA256,
            planFingerprint: admission.plan.fingerprint,
            producerStageFingerprint: admission.plan.stages[0].fingerprint)
    }

    /// The prefix cache's scope of a request on this loaded stage, as its
    /// generation agreement will key it (`qwenStagePrefixScope`), before the
    /// agreement exists: at reservation.
    static func prefixScope(stage: any LayerStageResidentStage, admission: any LayerStageResidentAdmission,
                            request: QwenLayerStageGenerationRequest) throws -> String {
        qwenStagePrefixScope(source: try sourceIdentity(stage: stage, admission: admission),
            numericalPolicySHA256: admission.arithmeticSHA256, request: request)
    }

    static func run(stage: any LayerStageResidentStage, producerStage: (any LayerStageResidentStage)? = nil,
                    speculativeHead: QwenMTPHead? = nil, speculativeTerms: QwenMTPTerms? = nil,
                    generationMode: QwenResidentGenerationMode = .pipeline,
                    phaseSplitAllowance: QwenPhaseSplitAllowance? = nil,
                    qualificationFault: QwenPhaseSplitFault? = nil,
                    admission: any LayerStageResidentAdmission,
                    collective: Collective, control: QwenResidentControl,
                    reserved: QwenResidentReservation, prefixCache: QwenStagePrefixCache? = nil,
                    activeAtStart: Int? = nil,
                    onCommittedToken: (Int, Int, Int) throws -> Bool
    ) throws -> (QwenResidentGenerationCompletion, QwenGenerationDiagnosticEvidence?) {
        // A phase split charges its hand-off on both ranks; a speculative
        // pipeline charges its verify windows (and on rank 1 the head's
        // request state) on both ranks.
        guard (generationMode.isPhaseSplit || generationMode == .pipelineMTP) == (phaseSplitAllowance != nil),
              (generationMode.isPhaseSplit && collective.rank == 1) == (producerStage != nil),
              generationMode.usesSpeculativeHead == (speculativeTerms != nil),
              (generationMode.usesSpeculativeHead && collective.rank == 1) == (speculativeHead != nil) else {
            throw ProbeError("Resident generation mode differs from its loaded stages, head or reservation")
        }
        let source = try sourceIdentity(stage: stage, admission: admission)
        // Both ranks derive the hand-off terms from their own Plan, registered
        // geometry and this request; the agreement fingerprint carries them.
        var split: QwenPhaseSplitPlan?
        if generationMode.isPhaseSplit {
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
            phaseSplit: split, compactDecode: generationMode == .pipelineCompactDecode,
            speculativeHead: generationMode.isPhaseSplit ? speculativeTerms : nil,
            speculativeRoundsFraming: generationMode == .pipelineMTP ? speculativeTerms?.pipelineDecodeFraming : nil)
        let speculativeRounds = generationMode == .pipelineMTP ? speculativeTerms : nil
        var lastResourceCheck: UInt64 = 0, ordinal = 0
        // The prompt-prefix capture still charged to this request (zero once withdrawn).
        var captureCharge = reserved.prefixCaptureBytes
        func check() throws {
            try control.check(deadline: reserved.deadline)
            let now = DispatchTime.now().uptimeNanoseconds
            if lastResourceCheck == 0 || now - lastResourceCheck >= 250_000_000 {
                // Admitted at its reservation; from here it asks only for what
                // it still needs (`requireContinuing`). A caller without the
                // allocator's start figure keeps the reservation's own check.
                func live(_ capture: Int) throws {
                    var current = reserved
                    current.prefixCaptureBytes = capture
                    if let activeAtStart {
                        try requireContinuing(current, phaseSplit: phaseSplitAllowance,
                            grown: Memory.activeMemory - activeAtStart)
                    } else {
                        try requireLive(current, phaseSplit: phaseSplitAllowance)
                    }
                }
                captureCharge = try checkRunning(captureBytes: captureCharge, prefixCache: prefixCache, rank: collective.rank,
                    live: live)
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
                producerStage: producerStage?.loaded, speculativeHead: speculativeHead,
                speculativeRounds: speculativeRounds, plan: admission.plan, agreement: agreement, collective: collective,
                resources: {
                    try stage.diagnosticResources(plan: admission.plan, request: reserved.request,
                        rank: collective.rank, requestAllowance: reserved.allowance)
                }, phaseSplitFault: fault, prefixCache: prefixCache,
                onCommittedToken: committedToken, check: check)
            try charge.requireCapture(recorded.captureBudget)
            evidence = recorded; result = recorded.execution
        } else {
            result = try runQwenLayerStageGenerationRequest(loaded: stage.loaded,
                producerStage: producerStage?.loaded, speculativeHead: speculativeHead,
                speculativeRounds: speculativeRounds, plan: admission.plan, agreement: agreement, collective: collective, prefixCache: prefixCache,
                onCommittedToken: committedToken, check: check)
            evidence = nil
        }
        guard result.bothRequestStatesRetired,
              let reason = ClusterWorkerFinishReason(rawValue: result.finishReason.rawValue) else {
            throw ProbeError("Resident generation returned without clean bilateral retirement")
        }
        // Sizes and durations of the hand-off, for whoever launched this worker.
        if let summary = result.phaseSplit { log(summary.diagnosticLine(requestID: reserved.request.requestID)) }
        if let prefix = result.prefixCache {
            log("darkbloom-prefix-v1 rank=\(collective.rank) request=\(reserved.request.requestID.uuidString.lowercased())"
                + " prompt=\(reserved.request.promptCount) reused=\(prefix.reusedPromptTokens)"
                + " stored=\(prefix.storedFrontiers.map(String.init).joined(separator: "_")) entries=\(prefix.cacheEntries)"
                + " tier=\(prefix.restoredTier ?? "none")")
        }
        var completion = QwenResidentGenerationCompletion(requestID: reserved.request.requestID, finishReason: reason,
            selectedTokenIDs: result.selectedTokenIDs, completedFrames: result.completedFrames,
            committedTokens: result.committedTokens, tokenChainSHA256: result.tokenChainSHA256,
            bothRequestStatesRetired: true, reusedPromptTokens: result.prefixCache?.reusedPromptTokens ?? 0,
            storedPromptFrontiers: result.prefixCache?.storedFrontiers ?? [])
        if let summary = result.phaseSplit, summary.handoffPerformed {
            completion.telemetry = .init(handoffNanoseconds: summary.handoffNanoseconds,
                handoffBytes: summary.handoffLogicalBytes, mtpDrafted: summary.mtp?.drafted, mtpAccepted: summary.mtp?.accepted)
        }
        if let rounds = result.speculativeRounds {
            // The last rank's rounds, for whoever launched this worker.
            log((["darkbloom-pipeline-speculative-v1", "rank=\(collective.rank)",
                  "request=\(reserved.request.requestID.uuidString.lowercased())"] + rounds.diagnosticFields)
                .joined(separator: " "))
            completion.telemetry = .init(mtpDrafted: rounds.drafted, mtpAccepted: rounds.accepted)
        }
        return (completion, evidence)
    }
}
