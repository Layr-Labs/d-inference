import Foundation

/// CPU-only immutable token history. The request/profile is authoritative;
/// source/model/resource/wire admission remains the caller's separate task.
struct QwenLayerStageProfiledPrefillRecordedRequest: Encodable {
    struct Step: Encodable {
        let frame: QwenLayerStageFrame
        let tokenIDs: [Int]
        let committedTokens: Int
        var expectsLogits: Bool { frame.finalPromptChunk }

        fileprivate init(frame: QwenLayerStageFrame, tokenIDs: [Int], committedTokens: Int) {
            self.frame = frame; self.tokenIDs = tokenIDs; self.committedTokens = committedTokens
        }
    }

    let request: QwenLayerStageProfiledPrefillRequestSpec
    let vocabularySize: Int
    let promptTokenIDs: [Int]
    let teacherTokenIDs: [Int]
    let steps: [Step]
    let fingerprint: String

    init(request: QwenLayerStageProfiledPrefillRequestSpec, vocabularySize: Int,
         prompt: [Int], teacher: [Int]) throws {
        guard (1...request.profile.maximumVocabularySize).contains(vocabularySize),
              prompt.count == request.promptCount, teacher.isEmpty,
              prompt.allSatisfy({ (0..<vocabularySize).contains($0) }) else {
            throw ProbeError("Profiled prefill requires the exact bounded prompt and no teacher tokens")
        }
        var schedule = QwenLayerStageAdmittedSchedule(request: .profiled(request))
        var steps: [Step] = []
        steps.reserveCapacity(request.prefillFrameCount)
        while !schedule.complete {
            let offset = schedule.committedTokens
            let count = min(request.chunkSize, request.promptCount - offset)
            let (end, overflow) = offset.addingReportingOverflow(count)
            guard !overflow, end <= prompt.count, offset < end,
                  steps.count < request.prefillFrameCount else {
                throw ProbeError("Profiled prefill recorded timeline exceeded its admitted geometry")
            }
            let frame = try schedule.admitPrefill(count: count, offset: offset, final: end == prompt.count)
            try schedule.commit(frame)
            steps.append(.init(frame: frame, tokenIDs: Array(prompt[offset..<end]),
                               committedTokens: schedule.committedTokens))
        }
        guard steps.count == request.prefillFrameCount,
              schedule.committedTokens == request.promptCount, schedule.decodeForwardCount == 0,
              steps.filter(\.expectsLogits).count == 1 else {
            throw ProbeError("Profiled prefill did not cover exactly one final-logit frontier")
        }
        self.request = request; self.vocabularySize = vocabularySize
        self.promptTokenIDs = prompt; self.teacherTokenIDs = []; self.steps = steps
        self.fingerprint = sha256(Data([
            "qwen-layer-stage-profiled-prefill-recorded-request-v1", request.profile.rawValue,
            request.profile.fingerprint, request.fingerprint, "vocabulary=\(vocabularySize)",
            "prompt=" + prompt.map(String.init).joined(separator: ","), "teacher=",
        ].joined(separator: "\n").utf8))
    }
}
