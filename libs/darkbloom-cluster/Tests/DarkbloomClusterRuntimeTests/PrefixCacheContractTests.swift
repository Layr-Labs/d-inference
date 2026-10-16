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
        // Room for a capture thins grid frontiers only: both prompts' deepest
        // frontiers stay (finding F3); `insert` keeps the budget afterwards.
        cache.makeRoom(forCapture: 5_500)
        #expect(cache.bytesInUse == 4_000)
        #expect(cache.frontiers(scope: "s", tokens: a, maximumFrontier: 99) == [99])
        #expect(cache.frontiers(scope: "s", tokens: b, maximumFrontier: 99) == [99])
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

    /// The session captures only the frontiers after the prefix it reuses,
    /// and nothing on a repeat of the whole prompt; the reservation charges
    /// that, not the whole prompt as if cold. Otherwise a phantom capture
    /// charge makes kept entries (possibly the one this request reuses) give
    /// way under memory pressure for a capture that never happens.
    @Test func aRequestIsChargedOnlyWhatItCapturesAfterThePrefixThisRankHolds() {
        let gib = 1 << 30
        let cache = QwenStagePrefixCache(entryLimit: 32, budgetBytes: 8 * gib)
        let prompt = Array(0..<5_120), scope = "plan|artifact|chunk=512"
        // Cold and unmeasured: the budget.
        #expect(cache.captureLimit(scope: scope, tokens: prompt, chunkSize: 512) == 8 * gib)
        cache.insert(scope: scope, tokens: prompt, states: [state(4_608), state(5_119)])
        // A repeat of the whole prompt reuses its split frontier and captures nothing, measured or not.
        #expect(cache.captureLimit(scope: scope, tokens: prompt, chunkSize: 512) == 0)
        let cost = QwenStagePrefixCaptureCost(attentionBytesPerToken: 49_152, recurrentBytesPerFrontier: 113_000_000,
            historyBytesPerToken: 10_244)
        cache.record(cost)
        #expect(cache.captureLimit(scope: scope, tokens: prompt, chunkSize: 512) == 0)
        // Another scope holds nothing for it: the whole plan (9 grid frontiers + the split one).
        #expect(cache.captureLimit(scope: "other", tokens: prompt, chunkSize: 512)
            == cost.bytes(deepest: 5_119, frontiers: 10))
        // A longer prompt that extends it reuses 5,119: the grid frontiers 5,120 ... 9,728 after it
        // (10) and its own split frontier; its attention copy is still the whole prompt's.
        let longer = prompt + Array(20_000..<25_120)
        #expect(cache.captureLimit(scope: scope, tokens: longer, chunkSize: 512)
            == cost.bytes(deepest: 10_239, frontiers: 11))
        // A prompt that differs before the held frontiers is cold.
        var changed = longer; changed[100] = 7
        #expect(cache.captureLimit(scope: scope, tokens: changed, chunkSize: 512)
            == cache.captureLimit(promptCount: changed.count, chunkSize: 512))
        // Within the budget and the entry limit as before.
        cache.setBudget(gib)
        #expect(cache.captureLimit(scope: scope, tokens: longer, chunkSize: 512) == gib)
        #expect(cache.captureLimit(scope: scope, tokens: prompt, chunkSize: 512) == 0)
        #expect(QwenStagePrefixCache(enabled: false).captureLimit(scope: scope, tokens: prompt, chunkSize: 512) == 0)
    }

    /// Once a capture of the stage was measured, the reservation charges the
    /// speculative history at the measured cost; the session must keep its
    /// capture by that same figure. With the session's conservative estimate
    /// (twice the bf16 rows) a one-frontier charge (a short prompt, or a hit
    /// in its prompt's last stride) was too small for even the split frontier.
    @Test func aCaptureChargedAtTheMeasuredCostKeepsItsSplitFrontier() {
        // 9B rank 1 (cut 4) at 5,120 tokens as measured on hardware (f2a): 28,672 B a token of attention,
        // 45,072,384 B a frontier, 8,199 B a token of history (bf16 rows and an Int32 token).
        let measured = QwenStagePrefixCaptureCost(attentionBytesPerToken: 28_672, recurrentBytesPerFrontier: 45_072_384,
            historyBytesPerToken: 8_199)
        let estimate = 4_096 * 4 + 4
        let cache = QwenStagePrefixCache(entryLimit: 32, budgetBytes: 8 << 30)
        #expect(cache.historyBytesPerToken(estimate: estimate) == estimate)
        cache.record(measured)
        #expect(cache.historyBytesPerToken(estimate: estimate) == 8_199)
        // The session measures attention and recurrent state itself (the same stage, the same figures)
        // and takes the history figure from the cache.
        let session = QwenStagePrefixCaptureCost(attentionBytesPerToken: 28_672, recurrentBytesPerFrontier: 45_072_384,
            historyBytesPerToken: cache.historyBytesPerToken(estimate: estimate))
        let stride = cache.stride(chunkSize: 512)
        func planned(_ count: Int, after held: Int) -> [Int] {
            Array(Swift.stride(from: (held / stride + 1) * stride, to: count - 1, by: stride)) + [count - 1]
        }
        // A short prompt: one frontier, its split frontier.
        let short = cache.captureLimit(promptCount: 400, chunkSize: 512)
        #expect(session.kept(planned(400, after: 0), limit: short, maximum: 32) == [399])
        // A hit in the prompt's last stride: one frontier after the reused prefix.
        let hit = cache.captureLimit(promptCount: 10_240, chunkSize: 512, heldFrontier: 9_900)
        #expect(session.kept(planned(10_240, after: 9_900), limit: hit, maximum: 32) == [10_239])
        // A cold prompt keeps its whole plan within its charge.
        let cold = cache.captureLimit(promptCount: 5_120, chunkSize: 512)
        #expect(session.kept(planned(5_120, after: 0), limit: cold, maximum: 32) == Set(planned(5_120, after: 0)))
    }

    /// Models stay loaded until unloaded, so the budget follows the room in
    /// both directions: a load during a memory dip does not keep the cache
    /// small (and prefix reuse off on the pair) for as long as it stays loaded.
    @Test func theIdleRefreshFollowsTheRoomInBothDirections() {
        let mib = 1 << 20
        // Loaded during a dip: 256 MiB.
        let cache = QwenStagePrefixCache(entryLimit: 32, budgetBytes: 256 * mib)
        #expect(cache.refreshBudget(roomBytes: 4_096 * mib) && cache.budgetBytes == 2_048 * mib)
        // Drift within one 256 MiB step changes nothing.
        #expect(!cache.refreshBudget(roomBytes: 4_096 * mib + 100 * mib) && cache.budgetBytes == 2_048 * mib)
        #expect(cache.refreshBudget(roomBytes: 64 * 1_024 * mib)
            && cache.budgetBytes == QwenStagePrefixCache.maximumBudgetBytes)
        // Lowered with the room: entries beyond the new budget go at once.
        cache.insert(scope: "s", tokens: Array(0..<100),
            states: [sized(50, own: 300 * mib), sized(99, own: 300 * mib)], sharedBytes: 100 * mib)
        #expect(cache.bytesInUse == 700 * mib)
        #expect(cache.refreshBudget(roomBytes: 1_024 * mib) && cache.budgetBytes == 512 * mib)
        #expect(cache.bytesInUse <= 512 * mib && cache.heldFrontiers == [99])
        #expect(cache.refreshBudget(roomBytes: 0) && cache.budgetBytes == 0 && cache.count == 0 && cache.bytesInUse == 0)
    }

    /// Finding F4: four rotating 8K documents, each captured with its split
    /// frontier and 15 grid frontiers. A frontier-count limit of 32 kept only
    /// the last two; retention by budget keeps all four, and under byte
    /// pressure the older prompts' grid goes before any prompt's deepest.
    @Test func rotatingDocumentsAreAllRetainedByBudgetAndTheGridThinsFirst() {
        func document(_ index: Int) -> [Int] { Array((index * 10_000)..<(index * 10_000 + 8_192)) }
        func states() -> [QwenStagePrefixState] {
            stride(from: 512, through: 8_190, by: 512).map { sized($0, own: 1_000) } + [sized(8_191, own: 1_000)]
        }
        // Roomy: 4 x (16 x 1,000 + 4,000 shared) = 80,000 bytes, all kept.
        let roomy = QwenStagePrefixCache(budgetBytes: 1_000_000)
        for index in 0..<4 { roomy.insert(scope: "s", tokens: document(index), states: states(), sharedBytes: 4_000) }
        #expect(roomy.promptCount == 4 && roomy.count == 64 && roomy.evictions == 0)
        for index in 0..<4 {
            #expect(roomy.frontiers(scope: "s", tokens: document(index), maximumFrontier: 8_191).first == 8_191)
        }
        // Tight: room for three deepest frontiers (3 x 5,000) and the newest whole prompt (20,000).
        let tight = QwenStagePrefixCache(budgetBytes: 35_000)
        for index in 0..<4 { tight.insert(scope: "s", tokens: document(index), states: states(), sharedBytes: 4_000) }
        #expect(tight.promptCount == 4 && tight.bytesInUse <= 35_000)
        for index in 0..<3 {
            #expect(tight.frontiers(scope: "s", tokens: document(index), maximumFrontier: 8_191) == [8_191])
        }
        // The newest document keeps its whole grid (a new question over it reuses the deepest grid frontier).
        #expect(tight.frontiers(scope: "s", tokens: document(3), maximumFrontier: 8_191).count == 16)
        // The prompt count bounds too: a limit of 3 keeps the three most recent documents.
        let counted = QwenStagePrefixCache(budgetBytes: 1_000_000, promptLimit: 3)
        for index in 0..<4 { counted.insert(scope: "s", tokens: document(index), states: states(), sharedBytes: 4_000) }
        #expect(counted.promptCount == 3)
        #expect(counted.frontiers(scope: "s", tokens: document(0), maximumFrontier: 8_191).isEmpty)
        #expect(counted.frontiers(scope: "s", tokens: document(1), maximumFrontier: 8_191).first == 8_191)
        // The oldest prompt went whole; the others kept their grid (count pressure never thins them).
        #expect(counted.frontiers(scope: "s", tokens: document(1), maximumFrontier: 8_191).count == 16)
        #expect(counted.count == 48)
        // One request still captures at most `frontiersPerPrompt` frontiers.
        #expect(QwenStagePrefixCache().frontiersPerPrompt == QwenStagePrefixCache.defaultFrontiersPerPrompt)
        #expect(QwenStagePrefixCache(entryLimit: 4).frontiersPerPrompt == 4)
    }

    /// Finding F3 (27B decoding rank, scaled 1:10,000): each long prompt's
    /// capture plan (up to 32 frontiers of 135 MB recurrent state plus its
    /// attention copy) made room by evicting every other prompt's deepest
    /// frontier, so repeats of U1..U8 and a rotation of three long documents
    /// never hit although their deepest frontiers fit the budget together.
    /// A capture now makes room from grid frontiers only, and the newest
    /// prompt's own grid goes before another prompt's deepest frontier.
    @Test func longPromptCapturesNeverEvictAnotherPromptsDeepestFrontier() {
        let own = 13_472, perToken = 7, budget = 858_993, chunk = 512
        let lengths = [973, 1_932, 3_836, 7_641, 11_455, 15_260, 22_865, 26_642]
        func document(_ index: Int) -> [Int] { Array((index * 100_000)..<(index * 100_000 + lengths[index])) }
        /// One request as the driver runs it: the reservation's capture
        /// limit, a hit when the whole prompt is held, else room for the
        /// capture, the session's kept frontiers, and the insert.
        func serve(_ cache: QwenStagePrefixCache, _ index: Int) -> Bool {
            let tokens = document(index), n = tokens.count
            let limit = cache.captureLimit(scope: "s", tokens: tokens, chunkSize: chunk)
            let held = cache.deepestFrontier(scope: "s", tokens: tokens, maximumFrontier: n - 1)
            if held > 0 { _ = cache.state(scope: "s", tokens: tokens, frontier: held) }
            if held >= n - 1 { return true }
            cache.makeRoom(forCapture: limit)
            let step = cache.stride(chunkSize: chunk)
            let planned = stride(from: step, to: n - 1, by: step).filter { $0 > held } + [n - 1]
            let cost = QwenStagePrefixCaptureCost(attentionBytesPerToken: perToken, recurrentBytesPerFrontier: own,
                historyBytesPerToken: 0)
            let kept = cost.kept(planned, limit: limit, maximum: cache.frontiersPerPrompt)
            cache.insert(scope: "s", tokens: tokens, states: kept.sorted().map { sized($0, own: own) },
                sharedBytes: perToken * (n - 1))
            return false
        }
        func measured() -> QwenStagePrefixCache {
            let cache = QwenStagePrefixCache(budgetBytes: budget)
            cache.record(.init(attentionBytesPerToken: perToken, recurrentBytesPerFrontier: own, historyBytesPerToken: 0))
            return cache
        }
        // The deepest frontiers of all eight documents fit the budget together.
        #expect(lengths.reduce(0) { $0 + perToken * ($1 - 1) + own } < budget)
        let repeats = measured()
        for index in 0..<8 { #expect(!serve(repeats, index)) }
        let hits = (0..<8).filter { serve(repeats, $0) }.count
        #expect(hits == 8)
        #expect(repeats.bytesInUse <= budget)
        let rotation = measured()
        for index in 5..<8 { _ = serve(rotation, index) }
        let rotated = (0..<9).filter { serve(rotation, 5 + $0 % 3) }.count
        #expect(rotated == 9)
        #expect(rotation.bytesInUse <= budget)
    }

    /// Finding F10: a lookup keys every held frontier in one pass over the
    /// prompt (as the SSD tier does), not one whole-prefix hash per frontier.
    @Test func lookupsHashThePromptOncePerCall() {
        let cache = QwenStagePrefixCache(budgetBytes: 1 << 30)
        let tokens = Array(0..<26_642), frontiers = Array(stride(from: 512, to: 26_641, by: 512)) + [26_641]
        cache.insert(scope: "s", tokens: tokens, states: frontiers.map(state))
        let before = cache.lookupHashedTokens
        #expect(cache.frontiers(scope: "s", tokens: tokens, maximumFrontier: 26_641).count == QwenStagePrefixCache.maximumOffered)
        #expect(cache.lookupHashedTokens - before <= tokens.count)
        var changed = tokens; changed[20_000] = -1
        let missed = cache.lookupHashedTokens
        #expect(cache.deepestFrontier(scope: "s", tokens: changed, maximumFrontier: 26_641) == 19_968)
        #expect(cache.lookupHashedTokens - missed <= tokens.count)
        // The one-pass keys are the keys an insert stored, frontier by frontier.
        for frontier in [512, 19_968, 26_641] {
            #expect(cache.frontiers(scope: "s", tokens: tokens, maximumFrontier: frontier).first == frontier)
        }
    }
}
