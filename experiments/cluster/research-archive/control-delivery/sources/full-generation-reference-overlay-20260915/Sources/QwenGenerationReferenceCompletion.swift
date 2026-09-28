import Foundation

/// A completed native full-model frontier, validated with the existing typed
/// generation schedule. It permits EOS without pretending all O-1 decodes ran.
struct QwenGenerationReferenceCompletion {
    let request: QwenLayerStageGenerationRequest
    let reason: QwenLayerStageGenerationFinishReason
    let selectedTokenIDs: [Int]
    let completedFrames: Int
    let committedTokens: Int
    var decodeForwardCount: Int { selectedTokenIDs.count - 1 }

    init(request: QwenLayerStageGenerationRequest, reason: QwenLayerStageGenerationFinishReason,
         selectedTokenIDs: [Int], completedFrames: Int) throws {
        guard reason != .clientStop, !selectedTokenIDs.isEmpty,
              selectedTokenIDs.count <= request.outputCount,
              selectedTokenIDs.allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }),
              !selectedTokenIDs.dropLast().contains(where: request.stopTokenIDs.contains),
              completedFrames == request.prefillFrameCount + selectedTokenIDs.count - 1 else {
            throw ProbeError("Generation reference completion has invalid token history or frame count")
        }
        var schedule = QwenLayerStageGenerationSchedule(request: request)
        for sequence in 0..<completedFrames { try schedule.commit(request.frame(sequence: sequence)) }
        try schedule.finish(reason, selectedTokenCount: selectedTokenIDs.count,
                            lastTokenID: selectedTokenIDs[selectedTokenIDs.count - 1])
        self.request = request; self.reason = reason; self.selectedTokenIDs = selectedTokenIDs
        self.completedFrames = completedFrames; committedTokens = schedule.committedTokens
    }

    func requireSession(promptCount: Int, outputCount: Int, committedPromptTokens: Int,
                        decodeForwardCount: Int, committedTokens: Int) throws {
        guard promptCount == request.promptCount, outputCount == request.outputCount,
              committedPromptTokens == request.promptCount,
              decodeForwardCount == self.decodeForwardCount, committedTokens == self.committedTokens else {
            throw ProbeError("Full-model session differs from the completed generation frontier")
        }
    }
}
