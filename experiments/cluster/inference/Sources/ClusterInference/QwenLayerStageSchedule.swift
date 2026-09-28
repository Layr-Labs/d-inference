import Foundation

/// Same immutable request object is supplied to both stages. No teacher-token
/// policy, sampling, request coalescing or changed microchunk schedule is hidden here.
struct QwenLayerStageRequestSpec: Codable, Equatable {
    let requestID: UUID
    let promptCount: Int
    let chunkSize: Int
    let outputCount: Int

    init(requestID: UUID, promptCount: Int, chunkSize: Int, outputCount: Int) throws {
        guard (1...128).contains(promptCount), (1...32).contains(chunkSize),
            (1...4).contains(outputCount) else {
            throw ProbeError("Initial layer stages require prompt<=128, chunk<=32, output<=4 and batch one")
        }
        self.requestID = requestID; self.promptCount = promptCount
        self.chunkSize = chunkSize; self.outputCount = outputCount
    }

    private enum CodingKeys: String, CodingKey { case requestID, promptCount, chunkSize, outputCount }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(requestID: values.decode(UUID.self, forKey: .requestID),
            promptCount: values.decode(Int.self, forKey: .promptCount),
            chunkSize: values.decode(Int.self, forKey: .chunkSize),
            outputCount: values.decode(Int.self, forKey: .outputCount))
    }

    var fingerprint: String {
        // UUID and integers have a stable explicit representation independent of JSONEncoder options.
        sha256(Data("qwen-stage-request-v1|\(requestID.uuidString.lowercased())|\(promptCount)|\(chunkSize)|\(outputCount)".utf8))
    }
}

struct QwenLayerStageFrame: Codable, Equatable {
    enum Phase: String, Codable { case prefill, decode }
    let sequence: Int
    let phase: Phase
    let tokenOffset: Int
    let tokenCount: Int
    let finalPromptChunk: Bool
}

/// Pure admission and frontier bookkeeping; advance only after all native
/// outputs/state roots have completed and the recurrent generation committed.
struct QwenLayerStageSchedule {
    let request: QwenLayerStageRequestSpec
    private(set) var committedTokens = 0
    private(set) var committedPromptTokens = 0
    private(set) var decodeForwardCount = 0
    private(set) var nextSequence = 0

    init(request: QwenLayerStageRequestSpec) { self.request = request }

    var complete: Bool {
        committedPromptTokens == request.promptCount && decodeForwardCount == request.outputCount - 1
    }

    func admitPrefill(count: Int, offset: Int, final: Bool) throws -> QwenLayerStageFrame {
        guard committedPromptTokens < request.promptCount, offset == committedTokens,
            count == min(request.chunkSize, request.promptCount - committedPromptTokens),
            final == (committedPromptTokens + count == request.promptCount) else {
            throw ProbeError("Layer-stage prefill differs from the agreed microchunk schedule or token frontier")
        }
        return .init(sequence: nextSequence, phase: .prefill, tokenOffset: offset,
            tokenCount: count, finalPromptChunk: final)
    }

    func admitDecode(offset: Int) throws -> QwenLayerStageFrame {
        guard committedPromptTokens == request.promptCount, offset == committedTokens,
            decodeForwardCount < request.outputCount - 1 else {
            throw ProbeError("Layer-stage decode is outside the agreed token frontier")
        }
        return .init(sequence: nextSequence, phase: .decode, tokenOffset: offset,
            tokenCount: 1, finalPromptChunk: false)
    }

    mutating func commit(_ frame: QwenLayerStageFrame) throws {
        let expected = try frame.phase == .prefill
            ? admitPrefill(count: frame.tokenCount, offset: frame.tokenOffset, final: frame.finalPromptChunk)
            : admitDecode(offset: frame.tokenOffset)
        guard frame == expected else { throw ProbeError("Layer-stage committed frame changed after admission") }
        committedTokens += frame.tokenCount; nextSequence += 1
        if frame.phase == .prefill { committedPromptTokens += frame.tokenCount }
        else { decodeForwardCount += 1 }
    }
}
