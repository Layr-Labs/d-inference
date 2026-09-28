import Foundation

func checkQwenLayerStageProfiledPrefillSchedules(
    _ counts: inout QwenLayerStageProfiledPrefillCheckCounts
) throws {
    typealias Fixture = QwenLayerStageProfiledPrefillCheckFixture
    for (prompt, chunk, frameCount, lastCount) in [(8192, 512, 16, 512),
        (1025, 512, 3, 1), (8192, 64, 128, 64), (1, 512, 1, 1)] {
        let recorded = try Fixture.recorded(prompt, chunk)
        var schedule = QwenLayerStageAdmittedSchedule(request: .profiled(recorded.request))
        guard recorded.steps.count == frameCount, recorded.steps.last?.frame.tokenCount == lastCount,
              recorded.steps.flatMap(\.tokenIDs) == recorded.promptTokenIDs else {
            throw ProbeError("Profiled recorded timeline missed exact prompt coverage")
        }
        for (index, step) in recorded.steps.enumerated() {
            let expectedOffset = index * chunk // index<=127 and chunk<=512 are admitted
            guard step.frame.sequence == index, step.frame.phase == .prefill,
                  step.frame.tokenOffset == expectedOffset,
                  step.frame.tokenCount == min(chunk, prompt - expectedOffset),
                  step.frame.finalPromptChunk == (index == frameCount - 1),
                  step.expectsLogits == step.frame.finalPromptChunk,
                  step.tokenIDs == Array(recorded.promptTokenIDs[expectedOffset..<step.committedTokens]) else {
                throw ProbeError("Profiled timeline differs from independent contiguous frame geometry")
            }
            let actual = try schedule.admitPrefill(count: step.tokenIDs.count,
                offset: expectedOffset, final: step.expectsLogits)
            guard actual == step.frame else { throw ProbeError("Profiled replay admission changed its frame") }
            try schedule.commit(actual)
            guard schedule.committedTokens == step.committedTokens else { throw ProbeError("Profiled commit changed its frontier") }
        }
        guard schedule.complete, schedule.nextSequence == frameCount,
              schedule.committedPromptTokens == prompt, schedule.decodeForwardCount == 0 else {
            throw ProbeError("Profiled schedule did not finish its exact admitted prompt")
        }
        try counts.reject("duplicate final commit") { try schedule.commit(recorded.steps.last!.frame) }
        try counts.reject("post-prompt decode") { _ = try schedule.admitDecode(offset: prompt) }
        counts.accepted += 1
    }
    let request = try Fixture.request(1025, 512)
    var schedule = QwenLayerStageAdmittedSchedule(request: .profiled(request))
    let invalid: [QwenLayerStageFrame] = [
        .init(sequence: 1, phase: .prefill, tokenOffset: 0, tokenCount: 512, finalPromptChunk: false),
        .init(sequence: 0, phase: .prefill, tokenOffset: 512, tokenCount: 512, finalPromptChunk: false),
        .init(sequence: 0, phase: .prefill, tokenOffset: 0, tokenCount: 511, finalPromptChunk: false),
        .init(sequence: 0, phase: .prefill, tokenOffset: 0, tokenCount: 512, finalPromptChunk: true),
        .init(sequence: 0, phase: .decode, tokenOffset: 0, tokenCount: 1, finalPromptChunk: false),
        .init(sequence: Int.max, phase: .prefill, tokenOffset: 0, tokenCount: 512, finalPromptChunk: false),
        .init(sequence: 0, phase: .prefill, tokenOffset: Int.max, tokenCount: Int.max, finalPromptChunk: true),
        .init(sequence: 0, phase: .prefill, tokenOffset: 0, tokenCount: Int.min, finalPromptChunk: false),
    ]
    for frame in invalid {
        try counts.reject("altered frame geometry") { try schedule.commit(frame) }
        guard schedule.committedTokens == 0, schedule.nextSequence == 0, !schedule.complete else {
            throw ProbeError("Rejected profiled frame advanced state")
        }
    }
    try counts.reject("decode before prompt") { _ = try schedule.admitDecode(offset: 0) }
    let first = try schedule.admitPrefill(count: 512, offset: 0, final: false)
    try schedule.commit(first)
    try counts.reject("duplicate first frame") { try schedule.commit(first) }
    guard schedule.committedTokens == 512, schedule.nextSequence == 1 else {
        throw ProbeError("Rejected duplicate changed the committed frontier")
    }

    let legacy = try QwenLayerStageRequestSpec(requestID: Fixture.id, promptCount: 65, chunkSize: 32, outputCount: 4)
    let timeline = try QwenLayerStageRecordedRequest(request: legacy, vocabularySize: 32,
        prompt: (0..<65).map { $0 % 32 }, teacher: [7, 8, 9])
    var original = QwenLayerStageSchedule(request: legacy)
    var delegated = QwenLayerStageAdmittedSchedule(request: .legacy(legacy))
    for step in timeline.steps {
        let frame = step.frame
        let a = try frame.phase == .prefill
            ? original.admitPrefill(count: frame.tokenCount, offset: frame.tokenOffset, final: frame.finalPromptChunk)
            : original.admitDecode(offset: frame.tokenOffset)
        let b = try frame.phase == .prefill
            ? delegated.admitPrefill(count: frame.tokenCount, offset: frame.tokenOffset, final: frame.finalPromptChunk)
            : delegated.admitDecode(offset: frame.tokenOffset)
        guard a == b, a == frame else { throw ProbeError("Legacy delegate changed frame admission") }
        try original.commit(a); try delegated.commit(b)
        guard original.committedTokens == delegated.committedTokens,
              original.committedPromptTokens == delegated.committedPromptTokens,
              original.decodeForwardCount == delegated.decodeForwardCount,
              original.nextSequence == delegated.nextSequence, original.complete == delegated.complete else {
            throw ProbeError("Legacy delegate changed its original state transition")
        }
    }
    guard delegated.complete, delegated.nextSequence == 6, delegated.committedTokens == 68,
          delegated.request.fingerprint == "89bf1ee2b5c8d441156d1d320ced328b06a989b848e40de172ef96b54e9c559d" else {
        throw ProbeError("Legacy delegate lost its exact six-frame identity")
    }
    counts.accepted += 1
}
