import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

struct QwenTensorParallelAcceptedSelectionsTests {
    @Test func acceptedSuffixDrainsOncePerCreditWithoutRepeatingTargetWork() throws {
        var values = QwenTensorParallelAcceptedSelections()
        try values.append(input: 7, tokens: [8, 9, 10, 11, 12], logprobs: [], depth: 4, vocabulary: 64)
        #expect(values.count == 5)
        #expect(try values.take(input: 7).token == 8)
        #expect(values.count == 4)
        // Unrelated requests can run while this request awaits another credit.
        // Its suffix remains intact; a different history cannot consume it.
        #expect(throws: ProbeError.self) { try values.take(input: 9) }
        #expect(values.count == 4)
        for token in 9...12 { #expect(try values.take(input: token - 1).token == token) }
        #expect(values.isEmpty)
        #expect(throws: ProbeError.self) { try values.take(input: 12) }
        try values.append(input: 12, tokens: [13], logprobs: [], depth: 1, vocabulary: 64)
        #expect(try values.take(input: 12).token == 13)
    }

    @Test func badRoundsCannotOverwriteAcceptedHistory() throws {
        var values = QwenTensorParallelAcceptedSelections()
        for tokens in [[], [64], [-1], [1, 2, 3]] {
            #expect(throws: ProbeError.self) {
                try values.append(input: 0, tokens: tokens, logprobs: [], depth: 1, vocabulary: 64)
            }
            #expect(values.isEmpty)
        }
        try values.append(input: 0, tokens: [1, 2], logprobs: [], depth: 1, vocabulary: 64)
        #expect(throws: ProbeError.self) {
            try values.append(input: 1, tokens: [3], logprobs: [], depth: 1, vocabulary: 64)
        }
        #expect(try values.take(input: 0).token == 1)
        values.removeAll()
        #expect(values.isEmpty)
        #expect(throws: ProbeError.self) { try values.take(input: 1) }
    }

    /// Cohort synchronization: a row whose queue still holds at most `depth`
    /// selections may run its next round from its own last queued token. The
    /// new round's tokens follow the queue in order; the queue is bounded by
    /// two settled rounds and a round may never continue any other token.
    @Test func aheadRoundsExtendOnlyTheirOwnBoundedSuffix() throws {
        var values = QwenTensorParallelAcceptedSelections()
        try values.append(input: 7, tokens: [8, 9, 10, 11, 12], logprobs: [], depth: 4, vocabulary: 64)
        #expect(try values.take(input: 7).token == 8)
        // Four queued (= depth): only a round on the queue's last token joins.
        #expect(throws: ProbeError.self) {
            try values.append(input: 11, tokens: [13], logprobs: [], depth: 4, vocabulary: 64)
        }
        try values.append(input: 12, tokens: [13, 14, 15, 16, 17], logprobs: [], depth: 4, vocabulary: 64)
        #expect(values.count == 9 && values.count == QwenTensorParallelAcceptedSelections.capacity(depth: 4))
        // More than depth queued: no further round until credits drain it.
        #expect(throws: ProbeError.self) {
            try values.append(input: 17, tokens: [18], logprobs: [], depth: 4, vocabulary: 64)
        }
        for token in 9...17 { #expect(try values.take(input: token - 1).token == token) }
        #expect(values.isEmpty)
        // Logprobs stay attached to their own tokens across both rounds.
        let record = { (token: Int) in ClusterWorkerTokenLogprobs(logprob: -Float(token), top: [.init(tokenID: token, logprob: -1)]) }
        try values.append(input: 1, tokens: [2, 3], logprobs: [record(2), record(3)], depth: 1, vocabulary: 64)
        #expect(try values.take(input: 1).token == 2)
        try values.append(input: 3, tokens: [4, 5], logprobs: [record(4), record(5)], depth: 1, vocabulary: 64)
        #expect(values.count == 3)
        for token in 3...5 {
            let taken = try values.take(input: token - 1)
            #expect(taken.token == token && taken.logprobs == record(token))
        }
    }

    @Test func finishedTargetCanStillHaveUnpublishedAcceptedSelections() throws {
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-accepted-credit",
            vocabularySize: 64, hiddenSize: 64, activationDType: "bfloat16",
            maximumPromptTokens: 16, maximumChunkTokens: 4, maximumOutputTokens: 16, maximumContextTokens: 32)
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: [1, 2], chunkSize: 4, outputCount: 6, stopTokenIDs: [])
        var schedule = QwenLayerStageGenerationSchedule(request: request)
        try schedule.commit(schedule.admitPrefill(count: 2, offset: 0, final: true))
        for offset in 2..<7 { try schedule.commit(schedule.admitDecode(offset: offset)) }
        #expect(throws: ProbeError.self) { try request.frame(sequence: schedule.nextSequence) }
        var values = QwenTensorParallelAcceptedSelections()
        try values.append(input: 7, tokens: [8, 9, 10, 11, 12], logprobs: [], depth: 4, vocabulary: 64)
        #expect(try values.take(input: 7).token == 8)
        // The first prompt selection and one credited round selection are
        // visible. Four already-settled selections remain unpublished.
        var stopped = schedule
        try stopped.finish(.clientStop, selectedTokenCount: 2, lastTokenID: 8,
            discardedDecodeForwards: values.count)
        #expect(stopped.complete)
        #expect(throws: ProbeError.self) {
            var wrong = schedule
            try wrong.finish(.clientStop, selectedTokenCount: 2, lastTokenID: 8)
        }
        #expect(throws: ProbeError.self) {
            var wrong = schedule
            try wrong.finish(.length, selectedTokenCount: 2, lastTokenID: 8,
                discardedDecodeForwards: values.count)
        }
        for input in 8...11 { _ = try values.take(input: input) }
        try schedule.finish(.length, selectedTokenCount: 6, lastTokenID: 12)
        #expect(schedule.complete && values.isEmpty)
    }
}
