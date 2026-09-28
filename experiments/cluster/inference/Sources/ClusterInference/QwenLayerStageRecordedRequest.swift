import Foundation

/// Immutable teacher-forced timeline shared by the separately resident runs.
/// Construction reuses stage admission; it does not sample or alter token IDs.
struct QwenLayerStageRecordedRequest: Encodable {
    struct Step: Encodable {
        let frame: QwenLayerStageFrame
        let tokenIDs: [Int]

        var committedTokens: Int { frame.tokenOffset + frame.tokenCount }
        var expectsLogits: Bool { frame.phase == .decode || frame.finalPromptChunk }
    }

    let request: QwenLayerStageRequestSpec
    let vocabularySize: Int
    let promptTokenIDs: [Int]
    let teacherTokenIDs: [Int]
    let steps: [Step]
    let fingerprint: String

    init(request: QwenLayerStageRequestSpec, vocabularySize: Int,
         prompt: [Int], teacher: [Int]) throws {
        guard (1...262_144).contains(vocabularySize), prompt.count == request.promptCount,
              teacher.count == request.outputCount - 1,
              (prompt + teacher).allSatisfy({ (0..<vocabularySize).contains($0) }) else {
            throw ProbeError("Recorded request needs the exact bounded prompt and supplied teacher token IDs")
        }
        var schedule = QwenLayerStageSchedule(request: request)
        var steps: [Step] = []
        for offset in stride(from: 0, to: prompt.count, by: request.chunkSize) {
            let end = min(prompt.count, offset + request.chunkSize)
            let frame = try schedule.admitPrefill(count: end - offset, offset: offset,
                                                  final: end == prompt.count)
            steps.append(.init(frame: frame, tokenIDs: Array(prompt[offset..<end])))
            try schedule.commit(frame)
        }
        for token in teacher {
            let frame = try schedule.admitDecode(offset: schedule.committedTokens)
            steps.append(.init(frame: frame, tokenIDs: [token]))
            try schedule.commit(frame)
        }
        guard schedule.complete, !steps.isEmpty, steps.count <= 132,
              steps.filter(\.expectsLogits).count == request.outputCount,
              schedule.committedTokens == prompt.count + teacher.count else {
            throw ProbeError("Recorded timeline did not cover the complete bounded request")
        }
        self.request = request; self.vocabularySize = vocabularySize
        self.promptTokenIDs = prompt; self.teacherTokenIDs = teacher; self.steps = steps
        self.fingerprint = sha256(Data([
            "qwen-layer-stage-recorded-request-v1", request.fingerprint,
            "vocabulary=\(vocabularySize)",
            "prompt=" + prompt.map(String.init).joined(separator: ","),
            "teacher=" + teacher.map(String.init).joined(separator: ","),
        ].joined(separator: "\n").utf8))
    }
}
