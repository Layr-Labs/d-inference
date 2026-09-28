import Foundation

/// Replays the existing native generation schedule against the actual selected
/// history. A client stop is clean, but need not match a full-reference run.
struct QwenGenerationDiagnosticCompletion {
    let finalFrame: QwenLayerStageFrame
    let committedTokens: Int
    let selectedTokenCount: Int
    let finalTokenID: Int
    let selectedTokenIDsSHA256: String
    let reason: QwenLayerStageGenerationFinishReason

    init(request: QwenLayerStageGenerationRequest, selectedTokenIDs: [Int],
         completedFrames: Int, committedTokens: Int,
         reason: QwenLayerStageGenerationFinishReason) throws {
        guard !selectedTokenIDs.isEmpty, selectedTokenIDs.count <= request.outputCount,
              selectedTokenIDs.allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }),
              !selectedTokenIDs.dropLast().contains(where: request.stopTokenIDs.contains),
              completedFrames == request.prefillFrameCount + selectedTokenIDs.count - 1 else {
            throw ProbeError("Diagnostic completion differs from selected generation history")
        }
        var schedule = QwenLayerStageGenerationSchedule(request: request)
        for sequence in 0..<completedFrames { try schedule.commit(request.frame(sequence: sequence)) }
        let last = selectedTokenIDs[selectedTokenIDs.count - 1]
        if reason == .clientStop {
            guard selectedTokenIDs.count < request.outputCount, !request.stopTokenIDs.contains(last) else {
                throw ProbeError("Diagnostic client stop masks the generation EOS/output-limit policy")
            }
        }
        try schedule.finish(reason, selectedTokenCount: selectedTokenIDs.count, lastTokenID: last)
        guard schedule.committedTokens == committedTokens else {
            throw ProbeError("Diagnostic completion differs from the committed native frontier")
        }
        finalFrame = try request.frame(sequence: completedFrames - 1)
        self.committedTokens = committedTokens; selectedTokenCount = selectedTokenIDs.count; finalTokenID = last
        selectedTokenIDsSHA256 = qwenGenerationTokenHash(selectedTokenIDs); self.reason = reason
    }

    func requireCapture(rank: Int, frame: QwenLayerStageFrame, frontier: Int,
                        tokenID: Int, hasLogits: Bool) throws {
        guard (0...1).contains(rank), frame == finalFrame, frontier == committedTokens,
              tokenID == finalTokenID, hasLogits == (rank == 1) else {
            throw ProbeError("Diagnostic final capture differs from rank or completion")
        }
    }
}
