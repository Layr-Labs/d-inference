import Foundation

enum QwenLayerStageGenerationFinishReason: String, Encodable { case eos, length, clientStop }

/// Local native frontier. Token publication/peer agreement is owned separately
/// by GenerationControl; this never infers a commit from an attempted forward.
struct QwenLayerStageGenerationSchedule {
    let request: QwenLayerStageGenerationRequest
    private(set) var committedTokens = 0
    private(set) var committedPromptTokens = 0
    private(set) var decodeForwardCount = 0
    private(set) var nextSequence = 0
    private(set) var finishReason: QwenLayerStageGenerationFinishReason?
    var complete: Bool { finishReason != nil }

    init(request: QwenLayerStageGenerationRequest) { self.request = request }

    func admitPrefill(count: Int, offset: Int, final: Bool) throws -> QwenLayerStageFrame {
        let expected = try nextFrame()
        guard expected.phase == .prefill, count == expected.tokenCount,
              offset == expected.tokenOffset, final == expected.finalPromptChunk else {
            throw ProbeError("Generation prefill differs from the local frame")
        }
        return expected
    }

    func admitDecode(offset: Int) throws -> QwenLayerStageFrame {
        let expected = try nextFrame()
        guard expected.phase == .decode, offset == expected.tokenOffset else {
            throw ProbeError("Generation decode differs from the local committed frontier")
        }
        return expected
    }

    mutating func commit(_ frame: QwenLayerStageFrame) throws {
        guard frame == (try nextFrame()) else { throw ProbeError("Generation committed frame changed") }
        committedTokens += frame.tokenCount; nextSequence += 1
        if frame.phase == .prefill { committedPromptTokens += frame.tokenCount }
        else { decodeForwardCount += 1 }
    }

    mutating func finish(_ reason: QwenLayerStageGenerationFinishReason,
                         selectedTokenCount: Int, lastTokenID: Int) throws {
        guard !complete, committedPromptTokens == request.promptCount,
              selectedTokenCount == decodeForwardCount + 1,
              (1...request.outputCount).contains(selectedTokenCount),
              (0..<request.profile.vocabularySize).contains(lastTokenID) else {
            throw ProbeError("Generation finish differs from committed/selected frontier")
        }
        switch reason {
        case .eos:
            guard request.stopTokenIDs.contains(lastTokenID) else { throw ProbeError("Generation EOS is not admitted") }
        case .length:
            guard selectedTokenCount == request.outputCount, !request.stopTokenIDs.contains(lastTokenID) else {
                throw ProbeError("Generation length finish precedes the output limit or masks EOS")
            }
        case .clientStop: break
        }
        finishReason = reason
    }

    private func nextFrame() throws -> QwenLayerStageFrame {
        guard !complete else { throw ProbeError("Generation schedule already finished") }
        let expected = try request.frame(sequence: nextSequence)
        guard expected.tokenOffset == committedTokens else { throw ProbeError("Generation local frontier differs") }
        return expected
    }
}
