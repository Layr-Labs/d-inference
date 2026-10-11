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

    @Test func entriesAreKeyedByScopeAndPromptAndEvictedByCount() {
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
        // Use 32, then insert one more: the least recently used (64) goes (budget not reached).
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

    /// A state whose recurrent arrays hold `own` bytes (Float32 elements).
    private func sized(_ frontier: Int, own: Int) -> QwenStagePrefixState {
        QwenStagePrefixState(committedTokens: frontier,
            attention: [3: (keys: MLXArray([Float(frontier)]), values: MLXArray([Float(frontier)]))],
            recurrent: [0: (conv: MLXArray.zeros([own / 8], dtype: .float32), ssm: MLXArray.zeros([own / 8], dtype: .float32))])
    }

    @Test func bytesCountEachPromptsSharedCopyOnceAndTheBudgetEvictsLeastRecentlyUsed() {
        let cache = QwenStagePrefixCache(entryLimit: 32, budgetBytes: 10_000)
        let a = Array(0..<100), b = Array(100..<200)
        // Three frontiers of one prompt: 3 x 1,000 own + 2,000 shared once.
        cache.insert(scope: "s", tokens: a, states: [sized(32, own: 1_000), sized(64, own: 1_000), sized(99, own: 1_000)],
            sharedBytes: 2_000)
        #expect(cache.bytesInUse == 5_000)
        // The shared copy goes only with the prompt's last entry.
        #expect(cache.evictLeastRecentlyUsed())
        #expect(cache.bytesInUse == 4_000)
        #expect(cache.evictLeastRecentlyUsed() && cache.evictLeastRecentlyUsed())
        #expect(cache.bytesInUse == 0 && cache.count == 0)
        // Within the budget: a second prompt pushes out the least recently used of the first.
        cache.insert(scope: "s", tokens: a, states: [sized(32, own: 1_000), sized(64, own: 1_000), sized(99, own: 1_000)],
            sharedBytes: 2_000)
        _ = cache.state(scope: "s", tokens: a, frontier: 99)
        cache.insert(scope: "s", tokens: b, states: [sized(50, own: 1_000), sized(99, own: 1_000)], sharedBytes: 5_000)
        #expect(cache.bytesInUse <= 10_000)
        #expect(cache.frontiers(scope: "s", tokens: a, maximumFrontier: 99) == [99])
        #expect(cache.frontiers(scope: "s", tokens: b, maximumFrontier: 99) == [99, 50])
        #expect(cache.bytesInUse == 1_000 + 2_000 + 2_000 + 5_000)
        // Re-inserting a key replaces its entry without counting it twice.
        cache.insert(scope: "s", tokens: b, states: [sized(99, own: 1_000)], sharedBytes: 0)
        #expect(cache.bytesInUse == 1_000 + 2_000 + 1_000 + 5_000 + 1_000)
        // A lower budget evicts at once; room for a capture evicts beforehand.
        cache.setBudget(6_000)
        #expect(cache.bytesInUse <= 6_000 && cache.budgetBytes == 6_000)
        cache.makeRoom(forCapture: 5_500)
        #expect(cache.bytesInUse <= 500)
        cache.sweep()
        #expect(cache.bytesInUse == 0)
        // Count still bounds: three tiny entries with a limit of two.
        let counted = QwenStagePrefixCache(entryLimit: 2)
        counted.insert(scope: "s", tokens: a, states: [state(10), state(20), state(30)])
        #expect(counted.count == 2 && counted.heldFrontiers == [20, 30])
    }

    @Test func theBudgetComesFromTheRoomAndTheCaptureLimitFromTheMeasuredCost() {
        let gib = 1 << 30
        #expect(QwenStagePrefixCache.budget(roomBytes: 26 * gib) == QwenStagePrefixCache.maximumBudgetBytes)
        #expect(QwenStagePrefixCache.budget(roomBytes: 6 * gib) == 3 * gib)
        #expect(QwenStagePrefixCache.budget(roomBytes: -1) == 0)
        #expect(QwenStagePrefixCache.budget(roomBytes: 6 * gib + 300 << 20) == 3 * gib)
        let cache = QwenStagePrefixCache(entryLimit: 32, budgetBytes: 8 * gib)
        // Unmeasured: the budget is charged.
        #expect(cache.captureLimit(promptCount: 20_480, chunkSize: 512) == 8 * gib)
        #expect(cache.captureLimit(promptCount: 1, chunkSize: 512) == 0)
        // 27B rank 1 sizes: 48 KiB a token of attention, 113 MB a frontier, 10 KiB a token of history.
        let cost = QwenStagePrefixCaptureCost(attentionBytesPerToken: 49_152, recurrentBytesPerFrontier: 113_000_000,
            historyBytesPerToken: 10_244)
        cache.record(cost)
        // 5,120 tokens: 9 grid frontiers + the split one.
        #expect(cache.captureLimit(promptCount: 5_120, chunkSize: 512) == cost.bytes(deepest: 5_119, frontiers: 10))
        // 30,720 tokens: 59 grid frontiers, capped at 32 by the entry limit.
        #expect(cache.captureLimit(promptCount: 30_720, chunkSize: 512) == cost.bytes(deepest: 30_719, frontiers: 32))
        cache.setBudget(2 * gib)
        #expect(cache.captureLimit(promptCount: 30_720, chunkSize: 512) == 2 * gib)
        #expect(QwenStagePrefixCache(enabled: false).captureLimit(promptCount: 5_120, chunkSize: 512) == 0)
        // The first measurement stands.
        cache.record(.init(attentionBytesPerToken: 1, recurrentBytesPerFrontier: 1, historyBytesPerToken: 0))
        #expect(cache.captureCost == cost)
        // The admitted capture is handed over once.
        cache.admitCapture(123)
        #expect(cache.takeAdmittedCapture() == 123 && cache.takeAdmittedCapture() == nil)
    }

    @Test func theRunningCheckWithdrawsTheCaptureBeforeItWouldFailTheRequest() throws {
        // Withdrawn before the session took it: handed over as zero, and a
        // later registration lets go at once.
        let cache = QwenStagePrefixCache()
        cache.admitCapture(4_000)
        cache.withdrawCapture()
        #expect(cache.takeAdmittedCapture() == 0 && cache.captureWasWithdrawn)
        var released = 0
        cache.beginCapture { released += 1 }
        #expect(released == 1)
        cache.endCapture()
        // The next reservation starts with its capture in place; a withdrawal
        // while the session captures runs its hook once.
        cache.admitCapture(4_000)
        #expect(!cache.captureWasWithdrawn && cache.takeAdmittedCapture() == 4_000)
        cache.beginCapture { released += 1 }
        #expect(released == 1)
        cache.withdrawCapture(); cache.withdrawCapture()
        #expect(released == 2 && cache.captureWasWithdrawn && cache.captureWithdrawals == 3)
        cache.endCapture()

        // The running check: kept entries give way first; with them gone the
        // capture is withdrawn and the request is checked again without it.
        let pressured = QwenStagePrefixCache()
        pressured.insert(scope: "s", tokens: Array(0..<10), states: [state(3), state(5)])
        pressured.admitCapture(1_000)
        _ = pressured.takeAdmittedCapture()
        var withdrawn = false
        pressured.beginCapture { withdrawn = true }
        var asked: [Int] = []
        let charge = try QwenResidentRequestExecution.checkRunning(captureBytes: 1_000, prefixCache: pressured,
            rank: 1, live: { capture in
                asked.append(capture)
                if capture > 0 { throw ProbeError("needs memory") }
            })
        #expect(charge == 0 && withdrawn && pressured.count == 0)
        #expect(asked == [1_000, 1_000, 1_000, 0])
        // From then on it is checked without the capture.
        let next = try QwenResidentRequestExecution.checkRunning(captureBytes: charge, prefixCache: pressured,
            rank: 1, live: { capture in asked.append(capture) })
        #expect(next == 0 && asked.last == 0)
        // A refusal with neither entries nor a capture left fails the request.
        #expect(throws: ProbeError.self) {
            _ = try QwenResidentRequestExecution.checkRunning(captureBytes: 0, prefixCache: pressured, rank: 1,
                live: { _ in throw ProbeError("needs memory") })
        }
        // A request that fits keeps its capture, and the entries stay.
        let roomy = QwenStagePrefixCache()
        roomy.insert(scope: "s", tokens: Array(0..<10), states: [state(3)])
        roomy.admitCapture(1_000)
        let kept = try QwenResidentRequestExecution.checkRunning(captureBytes: 1_000, prefixCache: roomy, rank: 1,
            live: { _ in })
        #expect(kept == 1_000 && roomy.count == 1 && !roomy.captureWasWithdrawn)
    }

    @Test func aCaptureKeepsTheSplitFrontierFirstThenTheDeepestGridFrontiersThatFit() {
        let cost = QwenStagePrefixCaptureCost(attentionBytesPerToken: 10, recurrentBytesPerFrontier: 100,
            historyBytesPerToken: 0)
        let planned = [512, 1024, 1536, 2048, 2559]
        let base = cost.bytes(deepest: 2559, frontiers: 1)
        #expect(base == 25_590 + 100)
        #expect(cost.kept(planned, limit: .max, maximum: 32) == Set(planned))
        #expect(cost.kept(planned, limit: base, maximum: 32) == [2559])
        #expect(cost.kept(planned, limit: base + 250, maximum: 32) == [2048, 1536, 2559])
        #expect(cost.kept(planned, limit: .max, maximum: 3) == [2048, 1536, 2559])
        #expect(cost.kept(planned, limit: base - 1, maximum: 32).isEmpty)
        #expect(cost.kept([], limit: .max, maximum: 32).isEmpty)
        #expect(cost.bytes(deepest: Int.max / 2, frontiers: 1) == Int.max)
    }
}
