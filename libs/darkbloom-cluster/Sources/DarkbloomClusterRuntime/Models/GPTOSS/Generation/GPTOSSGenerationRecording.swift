import Foundation
import MLX

/// One rank's request-local capture for a recording run: the final logits row
/// (rank 1 only) and the digests of this stage's committed state. CPU values
/// only; no model, session or array is retained. The record it produces is the
/// runtime's final-diagnostic record, so the pair tools read it unchanged.
final class GPTOSSGenerationRecording {
    let request: QwenLayerStageGenerationRequest
    let rank: Int
    let budget: QwenGenerationDiagnosticBudget
    private var finalFrame: QwenLayerStageFrame?
    private var finalTokenID: Int?
    private var finalLogits: QwenRecordedLogits?
    private var entries: [QwenRecordedState.Entry]?
    private var completion: QwenGenerationDiagnosticCompletion?
    private var consumed = false
    private var observationCount = 0
    private var minimumActualFreeBytes = Int.max
    private var minimumAllocatorLimitBytes = Int.max

    init(request: QwenLayerStageGenerationRequest, rank: Int, budget: QwenGenerationDiagnosticBudget) throws {
        guard (0...1).contains(rank), budget.rank == rank, budget.vocabularySize == request.profile.vocabularySize,
              budget.activationDType == request.profile.activationDType else {
            throw ProbeError("Recording budget differs from its request or rank")
        }
        self.request = request; self.rank = rank; self.budget = budget
        try observe()
    }

    private func observe() throws {
        let os = try QwenDenseStageLoadResources.observeOS()
        let native = QwenDenseStageLoadResources.observeNative()
        observationCount += 1
        minimumActualFreeBytes = min(minimumActualFreeBytes, os.actualFreeBytes)
        minimumAllocatorLimitBytes = min(minimumAllocatorLimitBytes, native.allocatorLimitBytes)
    }

    func captureFinalRow(_ row: MLXArray?, frame: QwenLayerStageFrame, tokenID: Int,
                         check: () throws -> Void) throws {
        guard !consumed, finalFrame == nil, completion == nil, entries == nil,
              (row != nil) == (rank == 1) else { throw ProbeError("Repeated or wrong-rank recording row capture") }
        try check(); try observe()
        if let row {
            guard String(describing: row.dtype) == request.profile.activationDType else {
                throw ProbeError("Recorded final row dtype differs from the generation profile")
            }
            let captured = try QwenRecordedLogits(row, vocabularySize: request.profile.vocabularySize, check: check)
            guard let maximum = captured.record.values.max(),
                  captured.record.values.firstIndex(of: maximum) == tokenID else {
                throw ProbeError("Recorded final row differs from the agreed target token")
            }
            finalLogits = captured
        }
        try check()
        finalFrame = frame; finalTokenID = tokenID
    }

    func captureState(session: GPTOSSLayerStageSession, selectedTokenIDs: [Int], completedFrames: Int,
                      committedTokens: Int, reason: QwenLayerStageGenerationFinishReason,
                      check: () throws -> Void) throws {
        guard !consumed, completion == nil, entries == nil, let finalFrame, let finalTokenID else {
            throw ProbeError("Recording state precedes final row or repeats")
        }
        let completed = try QwenGenerationDiagnosticCompletion(request: request, selectedTokenIDs: selectedTokenIDs,
            completedFrames: completedFrames, committedTokens: committedTokens, reason: reason)
        try completed.requireCapture(rank: rank, frame: finalFrame, frontier: session.committedTokens,
            tokenID: finalTokenID, hasLogits: finalLogits != nil)
        try check(); try observe()
        entries = try session.stateEntries(check: check)
        try check()
        completion = completed
    }

    func finish(execution: QwenLayerStageGenerationResult, agreement: QwenLayerStageGenerationAgreement,
                stage: GPTOSSLayerStagePlan.Stage) throws -> QwenGenerationDiagnosticEvidence {
        guard !consumed, let entries, let completion, let finalFrame, execution.bothRequestStatesRetired,
              execution.agreementFingerprint == agreement.fingerprint,
              execution.membershipEpoch == agreement.descriptor.membershipEpoch,
              execution.identity.stageIndex == rank, stage.index == rank,
              execution.identity.requestFingerprint == request.fingerprint,
              execution.identity.stageFingerprint == stage.fingerprint,
              execution.committedTokens == completion.committedTokens,
              execution.selectedTokenIDs.count == completion.selectedTokenCount,
              execution.selectedTokenIDs.last == completion.finalTokenID,
              qwenGenerationTokenHash(execution.selectedTokenIDs) == completion.selectedTokenIDsSHA256,
              execution.finishReason == completion.reason,
              execution.completedFrames == finalFrame.sequence + 1,
              // Every layer of this stage, keys and values, and no other layer.
              Set(entries.map(\.key)) == Set(stage.layers.flatMap { layer in
                  ["kv.keys", "kv.values"].map { "\(layer.globalIndex)|\($0)" }
              }), entries.count == stage.layers.count * 2 else {
            throw ProbeError("Recording publication precedes complete retirement or evidence")
        }
        consumed = true
        return .init(execution: execution, agreement: agreement.descriptor, requestFingerprint: request.fingerprint,
            profileFingerprint: request.profile.fingerprint, rank: rank,
            sourceLayerStart: stage.sourceRange.lowerBound, sourceLayerEnd: stage.sourceRange.upperBound,
            finalFrame: finalFrame, stateEntries: entries,
            logicalStateBytes: try QwenLongPrefillCheckedBytes.sum(entries.map(\.byteCount)),
            stageStateSHA256: gptossStateFingerprint(entries, committedTokens: completion.committedTokens),
            finalLogits: finalLogits, captureBudget: budget, resourceObservationCount: observationCount,
            minimumObservedActualFreeBytes: minimumActualFreeBytes,
            minimumObservedAllocatorLimitBytes: minimumAllocatorLimitBytes)
    }

    func discard() {
        consumed = true; finalFrame = nil; finalTokenID = nil; finalLogits = nil; entries = nil; completion = nil
    }
}

/// The runtime's state-identity convention over recorded entries, so a pair's
/// two disjoint stage captures join into the fingerprint one host reports.
func gptossStateFingerprint(_ entries: [QwenRecordedState.Entry], committedTokens: Int) -> String {
    let sorted = entries.sorted { ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component) }
    return sha256(Data((["cbv2-owned-state-v1", "tokens=\(committedTokens)"]
        + sorted.map(\.identity)).joined(separator: "\n").utf8))
}
