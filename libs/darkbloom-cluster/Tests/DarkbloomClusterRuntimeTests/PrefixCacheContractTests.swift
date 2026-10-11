import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

// Rank-local prompt-prefix reuse: the frame plan, the two-rank agreement
// (both offers, both confirmations), count-based LRU and the sweep. Pure
// contracts: no collective, model or GPU evaluation.

private func prefixProfile() throws -> QwenLayerStageGenerationProfile {
    try QwenLayerStageGenerationProfile(identifier: "qwen35-prefix-fixture", vocabularySize: 64,
        hiddenSize: 32, activationDType: "bfloat16", maximumPromptTokens: 256,
        maximumChunkTokens: 16, maximumOutputTokens: 8, maximumContextTokens: 512)
}

private func state(_ frontier: Int) -> QwenStagePrefixState {
    QwenStagePrefixState(committedTokens: frontier,
        attention: [3: (keys: MLXArray([Float(frontier)]), values: MLXArray([Float(frontier)]))],
        recurrent: [0: (conv: MLXArray([Float(1)]), ssm: MLXArray([Float(2)]))])
}

@Suite("Prompt prefix reuse contracts (two-rank, no execution)")
struct PrefixCacheContractTests {
    @Test func plannedFramesStartAtTheReusedPrefixAndSplitTheLastToken() throws {
        let request = try QwenLayerStageGenerationRequest(profile: prefixProfile(), requestID: UUID(),
            promptTokenIDs: Array(0..<50), chunkSize: 16, outputCount: 3, stopTokenIDs: [])
        // Cold, split: 0-16, 16-32, 32-48, 48-49, 49-50; fingerprint unchanged.
        let cold = try request.planned(reusedPrefix: 0, splitFinalToken: true)
        let coldFrames = try (0..<cold.prefillFrameCount).map { try cold.frame(sequence: $0) }
        #expect(coldFrames.map(\.tokenOffset) == [0, 16, 32, 48, 49])
        #expect(coldFrames.map(\.tokenCount) == [16, 16, 16, 1, 1])
        #expect(coldFrames.map(\.finalPromptChunk) == [false, false, false, false, true])
        #expect(cold.fingerprint == request.fingerprint)
        #expect(try cold.frame(sequence: cold.prefillFrameCount).tokenOffset == 50)
        // A grid-aligned hit runs exactly the cold frames after it.
        let warm = try request.planned(reusedPrefix: 32, splitFinalToken: true)
        let warmFrames = try (0..<warm.prefillFrameCount).map { try warm.frame(sequence: $0) }
        #expect(warmFrames.map(\.tokenOffset) == [32, 48, 49])
        #expect(warmFrames.map(\.tokenCount) == coldFrames.suffix(3).map(\.tokenCount))
        // A repeat of the whole prompt computes one token.
        let repeatPlan = try request.planned(reusedPrefix: 49, splitFinalToken: true)
        #expect(repeatPlan.prefillFrameCount == 1)
        #expect(try repeatPlan.frame(sequence: 0) == .init(sequence: 0, phase: .prefill, tokenOffset: 49,
            tokenCount: 1, finalPromptChunk: true))
        // An off-grid hit realigns to the grid.
        let offGrid = try request.planned(reusedPrefix: 20, splitFinalToken: true)
        #expect(try (0..<offGrid.prefillFrameCount).map { try offGrid.frame(sequence: $0).tokenOffset } == [20, 32, 48, 49])
        // Never the whole prompt.
        #expect(throws: ProbeError.self) { _ = try request.planned(reusedPrefix: 50, splitFinalToken: true) }
        // Capture frontiers: grid multiples of the stride and promptCount - 1.
        #expect(cold.prefixCaptureFrontiers(stride: 32) == [32, 49])
        #expect(warm.prefixCaptureFrontiers(stride: 32) == [49])
        #expect(try request.planned(reusedPrefix: 0, splitFinalToken: false).prefixCaptureFrontiers(stride: 32).isEmpty)
        // The schedule starts at the reused frontier.
        let schedule = QwenLayerStageGenerationSchedule(request: warm)
        #expect(schedule.committedTokens == 32 && schedule.committedPromptTokens == 32)
        // The lookahead window follows the planned frames.
        var window = try QwenGenerationPrefillWindow(request: warm)
        #expect(window.frameCount == 3)
        try window.beginPreparation(sequence: 0, nativeCommittedTokens: 32)
        try window.commitPreparation(sequence: 0, nativeCommittedTokens: 48)
    }

    @Test func bothRanksSettleOnTheSamePlanAndAMismatchIsAColdPrefillOnBoth() throws {
        let prompt = 100
        let a = QwenStagePrefixOffer(enabled: true, frontiers: [99, 64, 32])
        let b = QwenStagePrefixOffer(enabled: true, frontiers: [64, 32])
        #expect(QwenStagePrefixOffer(words: a.words, promptCount: prompt) == a)
        let fromA = QwenStagePrefixChoice.choose(local: a, peer: b, promptCount: prompt)
        let fromB = QwenStagePrefixChoice.choose(local: b, peer: a, promptCount: prompt)
        #expect(fromA == fromB && fromA == .init(reusedPrefix: 64, splitFinalToken: true))
        // Either switch off: no reuse and no split on both.
        let off = QwenStagePrefixOffer(enabled: false, frontiers: [64])
        #expect(QwenStagePrefixChoice.choose(local: a, peer: off, promptCount: prompt) == .init(reusedPrefix: 0, splitFinalToken: false))
        #expect(QwenStagePrefixChoice.choose(local: off, peer: a, promptCount: prompt) == .init(reusedPrefix: 0, splitFinalToken: false))
        // A malformed or out-of-range peer offer counts as off.
        var words = a.words; words[3] = Int32(prompt)
        #expect(QwenStagePrefixOffer(words: words, promptCount: prompt) == .init(enabled: false, frontiers: []))
        // Confirmed by both with the same key and both restored: reuse.
        let key = String(repeating: "ab", count: 32)
        let ok = QwenStagePrefixConfirmation(choice: fromA, restored: true, key: key)
        #expect(QwenStagePrefixConfirmation(words: ok.words) == ok)
        #expect(QwenStagePrefixConfirmation.settle(local: ok, peer: ok) == fromA)
        // One rank failed to restore: both prefill from zero, keeping the split.
        let failed = QwenStagePrefixConfirmation(choice: fromA, restored: false, key: key)
        #expect(QwenStagePrefixConfirmation.settle(local: ok, peer: failed) == .init(reusedPrefix: 0, splitFinalToken: true))
        #expect(QwenStagePrefixConfirmation.settle(local: failed, peer: ok) == .init(reusedPrefix: 0, splitFinalToken: true))
        // Different keys (incoherent caches) or different choices: cold on both.
        let otherKey = QwenStagePrefixConfirmation(choice: fromA, restored: true, key: String(repeating: "cd", count: 32))
        #expect(QwenStagePrefixConfirmation.settle(local: ok, peer: otherKey).reusedPrefix == 0)
        #expect(QwenStagePrefixConfirmation.settle(local: otherKey, peer: ok).reusedPrefix == 0)
        let shallower = QwenStagePrefixConfirmation(choice: .init(reusedPrefix: 32, splitFinalToken: true), restored: true, key: key)
        #expect(QwenStagePrefixConfirmation.settle(local: ok, peer: shallower).reusedPrefix == 0)
        #expect(QwenStagePrefixConfirmation.settle(local: shallower, peer: ok).reusedPrefix == 0)
        // A split disagreement or an unreadable peer: no reuse and no split on both.
        let noSplit = QwenStagePrefixConfirmation(choice: .init(reusedPrefix: 0, splitFinalToken: false), restored: true, key: nil)
        #expect(QwenStagePrefixConfirmation.settle(local: ok, peer: noSplit) == .init(reusedPrefix: 0, splitFinalToken: false))
        #expect(QwenStagePrefixConfirmation.settle(local: noSplit, peer: ok) == .init(reusedPrefix: 0, splitFinalToken: false))
        #expect(QwenStagePrefixConfirmation.settle(local: ok, peer: nil) == .init(reusedPrefix: 0, splitFinalToken: false))
    }

    @Test func entriesAreKeyedByScopeAndPromptAndEvictedByCountNotBytes() {
        let cache = QwenStagePrefixCache(entryLimit: 3)
        let prompt = Array(0..<100), scope = "plan|artifact"
        cache.insert(scope: scope, tokens: prompt, states: [state(32), state(64), state(99)])
        #expect(cache.count == 3)
        #expect(cache.frontiers(scope: scope, tokens: prompt, maximumFrontier: 99) == [99, 64, 32])
        #expect(cache.frontiers(scope: scope, tokens: prompt, maximumFrontier: 70) == [64, 32])
        // Another scope, or a prompt that differs before a frontier, holds nothing there.
        #expect(cache.frontiers(scope: "other", tokens: prompt, maximumFrontier: 99).isEmpty)
        var changed = prompt; changed[40] = 7
        #expect(cache.frontiers(scope: scope, tokens: changed, maximumFrontier: 99) == [32])
        // Use 32, then insert one more: the least recently used (64) goes, whatever its size.
        #expect(cache.state(scope: scope, tokens: prompt, frontier: 32)?.committedTokens == 32)
        let other = Array(200..<300)
        cache.insert(scope: scope, tokens: other, states: [state(50)])
        #expect(cache.count == 3 && cache.evictions == 1)
        #expect(cache.frontiers(scope: scope, tokens: prompt, maximumFrontier: 99) == [99, 32])
        #expect(cache.frontiers(scope: scope, tokens: other, maximumFrontier: 99) == [50])
    }

    @Test func aSweepDropsEverythingAndTheSwitchTurnsTheCacheOff() {
        let cache = QwenStagePrefixCache()
        cache.insert(scope: "s", tokens: Array(0..<10), states: [state(5), state(9)])
        #expect(cache.count == 2)
        cache.sweep()
        #expect(cache.count == 0 && cache.frontiers(scope: "s", tokens: Array(0..<10), maximumFrontier: 9).isEmpty)
        let off = QwenStagePrefixCache.fromEnvironment(["DARKBLOOM_CLUSTER_PREFIX_CACHE": "off"])
        #expect(!off.enabled)
        off.insert(scope: "s", tokens: Array(0..<10), states: [state(5)])
        #expect(off.count == 0)
        #expect(QwenStagePrefixCache.fromEnvironment([:]).enabled)
        // Memory pressure: entries give way one by one until admission passes;
        // with the cache empty the refusal stands.
        let pressured = QwenStagePrefixCache()
        pressured.insert(scope: "s", tokens: Array(0..<10), states: [state(3), state(5), state(9)])
        var refusals = 2
        #expect(throws: Never.self) {
            try pressured.yieldingMemory { if refusals > 0 { refusals -= 1; throw ProbeError("needs memory") } }
        }
        #expect(pressured.count == 1 && pressured.pressureEvictions == 2)
        #expect(throws: ProbeError.self) { try pressured.yieldingMemory { throw ProbeError("needs memory") } }
        #expect(pressured.count == 0)
        #expect(QwenStagePrefixCache().stride(chunkSize: 512) == 512)
        #expect(QwenStagePrefixCache().stride(chunkSize: 384) == 768)
        #expect(QwenStagePrefixCache(strideTokens: 2048).stride(chunkSize: 512) == 2048)
    }
}
