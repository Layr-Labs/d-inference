import Foundation
import MLX

/// Request-local CPU captures. No model, session, MLXArray or file is retained.
/// Both captures are private until the driver returns after bilateral retirement.
final class QwenGenerationDiagnosticCapture {
    /// Replaced once by the planned request after the prefix agreement.
    var request: QwenLayerStageGenerationRequest
    let rank: Int
    let resources: QwenGenerationDiagnosticResources
    private var finalFrame: QwenLayerStageFrame?
    private var finalTokenID: Int?
    private var finalLogits: QwenRecordedLogits?
    private var state: QwenLayerStageRankStateCapture?
    private var completion: QwenGenerationDiagnosticCompletion?
    private var consumed = false
    /// Rank 1 of a speculative pipeline (`pipeline_mtp_v1`): one step per
    /// selected token, in order, from the row that token was taken from (the
    /// prompt's last frame, then each kept column of a verify window). The
    /// record then carries the accepted timeline row by row, so the near-tie
    /// rule reads every accepted token (`QwenRecordedStep`).
    var recordsSteps = false
    private(set) var steps: [QwenRecordedStep] = []

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
            guard String(describing: row.dtype) == request.profile.selectedRowDType else {
                throw ProbeError("Diagnostic final row dtype differs from the generation profile")
            }
            let captured = try QwenRecordedLogits(row,
                vocabularySize: request.profile.vocabularySize, check: check)
            // A sampled token is a draw, not the argmax of its row.
            guard let maximum = captured.record.values.max(),
                  request.sampler != nil || captured.record.values.firstIndex(of: maximum) == tokenID else {
                throw ProbeError("Diagnostic final row differs from the agreed target token")
            }
            finalLogits = captured
        }
        try check()
        try resources.requireLive(force: true)
        finalFrame = frame; finalTokenID = tokenID
    }

    /// One selected token's row on rank 1 of a recorded speculative pipeline:
    /// its digest over the native bytes and its highest candidates. `frame` is
    /// the decode frame the token takes through the generation control.
    func captureStep(_ row: MLXArray, frame: QwenLayerStageFrame, tokenID: Int, check: () throws -> Void) throws {
        guard recordsSteps, rank == 1, !consumed, finalFrame == nil, completion == nil, state == nil else {
            throw ProbeError("Diagnostic step capture outside a recorded speculative pipeline's rank 1")
        }
        try check()
        let step = try QwenRecordedStep(row, ordinal: steps.count, frame: frame, tokenID: tokenID,
            vocabularySize: request.profile.vocabularySize, rowDType: request.profile.selectedRowDType,
            sampled: request.sampler != nil)
        try check()
        steps.append(step)
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
        // A speculative pipeline's rank 1 records one step per selected token, in order.
        if recordsSteps {
            guard steps.map(\.ordinal) == Array(execution.selectedTokenIDs.indices),
                  steps.map(\.tokenID) == execution.selectedTokenIDs else {
                throw ProbeError("Diagnostic steps differ from the selected token history")
            }
        } else if !steps.isEmpty {
            throw ProbeError("Diagnostic steps recorded outside a recorded speculative pipeline")
        }
        consumed = true
        return .init(execution: execution, agreement: agreement.descriptor, requestFingerprint: request.fingerprint,
            profileFingerprint: request.profile.fingerprint, rank: rank,
            sourceLayerStart: stage.sourceRange.lowerBound, sourceLayerEnd: stage.sourceRange.upperBound,
            finalFrame: finalFrame, stateEntries: state.entries, logicalStateBytes: state.logicalBytes,
            stageStateSHA256: state.fingerprint, finalLogits: finalLogits, captureBudget: resources.budget,
            resourceObservationCount: resources.observationCount,
            minimumObservedActualFreeBytes: resources.minimumActualFreeBytes,
            minimumObservedAllocatorLimitBytes: resources.minimumAllocatorLimitBytes,
            steps: recordsSteps ? steps : nil)
    }

    func discard() {
        consumed = true; finalFrame = nil; finalTokenID = nil; finalLogits = nil; state = nil; completion = nil
        steps = []
    }
}
