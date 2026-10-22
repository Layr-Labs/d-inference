import Foundation

/// The nil branch constructs no observation or clock. Production wrappers in
/// this slice keep it nil; no native observation entry/export is available.
func observeQwenGenerationPhase(_ observer: QwenGenerationPhaseObserver?,
    _ phase: QwenGenerationPhase, frame: QwenLayerStageFrame? = nil,
    localCommittedTokens: Int? = nil, agreedCommittedTokens: Int? = nil,
    check: () throws -> Void) throws {
    guard let observer else { return }
    if let frame, frame.phase != .prefill { return }
    let observedFrame = frame.map { QwenGenerationPhaseFrame(sequence: $0.sequence,
        tokenOffset: $0.tokenOffset, tokenCount: $0.tokenCount, finalPromptChunk: $0.finalPromptChunk) }
    try QwenGenerationPhaseObservation(phase: phase, frame: observedFrame,
        localCommittedTokens: localCommittedTokens, agreedCommittedTokens: agreedCommittedTokens)
        .deliver(to: observer, check: check)
}
