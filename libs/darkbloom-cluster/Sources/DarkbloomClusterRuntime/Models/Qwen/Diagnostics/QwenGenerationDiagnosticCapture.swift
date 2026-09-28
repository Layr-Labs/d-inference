import Foundation
import MLX

/// Request-local CPU captures. No model, session, MLXArray or file is retained.
/// Both captures are private until the driver returns after bilateral retirement.
final class QwenGenerationDiagnosticCapture {
    let request: QwenLayerStageGenerationRequest
    let rank: Int
    let resources: QwenGenerationDiagnosticResources
    private var finalFrame: QwenLayerStageFrame?
    private var finalTokenID: Int?
    private var finalLogits: QwenRecordedLogits?
    private var state: QwenLayerStageRankStateCapture?
    private var completion: QwenGenerationDiagnosticCompletion?
    private var consumed = false

    init(request: QwenLayerStageGenerationRequest, rank: Int,
         resources: QwenGenerationDiagnosticResources) {
        self.request = request; self.rank = rank; self.resources = resources
    }

    func captureFinalRow(_ row: MLXArray?, frame: QwenLayerStageFrame, tokenID: Int,
                         check: () throws -> Void) throws {
        guard !consumed, finalFrame == nil, completion == nil, state == nil,
              (row != nil) == (rank == 1) else { throw ProbeError("Repeated or wrong-rank diagnostic row capture") }
        try resources.requireLive(force: true)
        try check()
        if let row {
            guard String(describing: row.dtype) == request.profile.activationDType else {
                throw ProbeError("Diagnostic final row dtype differs from the generation profile")
            }
            let captured = try QwenRecordedLogits(row,
                vocabularySize: request.profile.vocabularySize, check: check)
            guard let maximum = captured.record.values.max(),
                  captured.record.values.firstIndex(of: maximum) == tokenID else {
                throw ProbeError("Diagnostic final row differs from the agreed target token")
            }
            finalLogits = captured
        }
        try check()
        try resources.requireLive(force: true)
        finalFrame = frame; finalTokenID = tokenID
    }

    func captureState(session: QwenLayerStageSession, stage: QwenLayerStagePlan.Stage,
                      selectedTokenIDs: [Int], completedFrames: Int, committedTokens: Int,
                      reason: QwenLayerStageGenerationFinishReason,
                      check: () throws -> Void) throws {
        guard !consumed, completion == nil, state == nil,
              let finalFrame, let finalTokenID else { throw ProbeError("Diagnostic state precedes final row or repeats") }
        let completed = try QwenGenerationDiagnosticCompletion(request: request,
            selectedTokenIDs: selectedTokenIDs, completedFrames: completedFrames,
            committedTokens: committedTokens, reason: reason)
        try completed.requireCapture(rank: rank, frame: finalFrame, frontier: session.committedTokens,
            tokenID: finalTokenID, hasLogits: finalLogits != nil)
        try resources.requireLive(force: true)
        try check()
        let snapshot = try session.snapshot(includeBytes: false, check: check)
        let captured = try QwenLayerStageRankStateCapture(snapshot: snapshot, stage: stage,
            committedTokens: committedTokens)
        try check()
        try resources.requireLive(force: true)
        state = captured; completion = completed
    }

    func finish(execution: QwenLayerStageGenerationResult, agreement: QwenLayerStageGenerationAgreement,
                stage: QwenLayerStagePlan.Stage) throws -> QwenGenerationDiagnosticEvidence {
        guard !consumed, let state, let completion, let finalFrame,
              execution.bothRequestStatesRetired,
              execution.agreementFingerprint == agreement.fingerprint,
              execution.membershipEpoch == agreement.descriptor.membershipEpoch,
              execution.identity.stageIndex == rank,
              execution.identity.requestFingerprint == request.fingerprint,
              execution.identity.stageFingerprint == stage.fingerprint,
              execution.committedTokens == completion.committedTokens,
              execution.selectedTokenIDs.count == completion.selectedTokenCount,
              execution.selectedTokenIDs.last == completion.finalTokenID,
              qwenGenerationTokenHash(execution.selectedTokenIDs) == completion.selectedTokenIDsSHA256,
              execution.finishReason == completion.reason,
              execution.completedFrames == finalFrame.sequence + 1,
              resources.observationCount > 0 else { throw ProbeError("Diagnostic publication precedes complete retirement/evidence") }
        consumed = true
        return .init(execution: execution, agreement: agreement.descriptor, requestFingerprint: request.fingerprint,
            profileFingerprint: request.profile.fingerprint, rank: rank,
            sourceLayerStart: stage.sourceRange.lowerBound, sourceLayerEnd: stage.sourceRange.upperBound,
            finalFrame: finalFrame, stateEntries: state.entries, logicalStateBytes: state.logicalBytes,
            stageStateSHA256: state.fingerprint, finalLogits: finalLogits, captureBudget: resources.budget,
            resourceObservationCount: resources.observationCount,
            minimumObservedActualFreeBytes: resources.minimumActualFreeBytes,
            minimumObservedAllocatorLimitBytes: resources.minimumAllocatorLimitBytes)
    }

    func discard() {
        consumed = true; finalFrame = nil; finalTokenID = nil; finalLogits = nil; state = nil; completion = nil
    }
}
