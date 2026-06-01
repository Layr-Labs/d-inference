import Foundation
import Testing
@testable import MLXLMCommon
@testable import ProviderCore

// Step 1 (zero-runtime): the capability classifier that routes a model to
// the engine block tier, the checkpoint tier, or no caching — the single
// point that keeps the two tiers mutually exclusive and leaves
// uncacheable models at today's behavior.

@Suite("PrefixCacheStrategy classification")
struct PrefixCacheStrategyTests {

    @Test("all-KVCacheSimple ⇒ .engine (pure-attention; unchanged path)")
    func pureAttentionIsEngine() {
        let caches: [any KVCache] = [KVCacheSimple(), KVCacheSimple(), KVCacheSimple()]
        #expect(PrefixCacheStrategy.classify(caches) == .engine)
    }

    @Test("KVCacheSimple + RotatingKVCache ⇒ .checkpoint (Gemma-4 / GPT-OSS shape)")
    func slidingWindowIsCheckpoint() {
        // Gemma-4 pattern: 4 sliding of every 5, last full.
        let caches: [any KVCache] = [
            RotatingKVCache(maxSize: 512), RotatingKVCache(maxSize: 512),
            RotatingKVCache(maxSize: 512), RotatingKVCache(maxSize: 512),
            KVCacheSimple(),
        ]
        #expect(PrefixCacheStrategy.classify(caches) == .checkpoint)
    }

    @Test("any MambaCache ⇒ .none (Qwen3.5/Next stays uncached, unchanged)")
    func recurrentIsNone() {
        let caches: [any KVCache] = [KVCacheSimple(), MambaCache(), KVCacheSimple()]
        #expect(PrefixCacheStrategy.classify(caches) == .none)
    }

    @Test("ChunkedKVCache (unsupported KVCacheSimple subclass) ⇒ .none")
    func chunkedIsNone() {
        // ChunkedKVCache IS-A KVCacheSimple; must be rejected before the
        // base check, or it would be mis-serialized.
        let caches: [any KVCache] = [KVCacheSimple(), ChunkedKVCache()]
        #expect(PrefixCacheStrategy.classify(caches) == .none)
    }

    @Test("empty cache ⇒ .none")
    func emptyIsNone() {
        #expect(PrefixCacheStrategy.classify([]) == .none)
    }

    @Test("a lone rotating layer still ⇒ .checkpoint")
    func onlyRotatingIsCheckpoint() {
        #expect(PrefixCacheStrategy.classify([RotatingKVCache(maxSize: 128)]) == .checkpoint)
    }

    @Test("minSlidingWindow takes the smallest rotating window, ignores non-rotating layers")
    func minSlidingWindow() {
        // Gemma-4 shape: all sliding layers share window 512.
        let gemma: [any KVCache] = [
            RotatingKVCache(maxSize: 512), KVCacheSimple(), RotatingKVCache(maxSize: 512),
        ]
        #expect(PrefixCacheStrategy.minSlidingWindow(gemma) == 512)

        // Mixed windows ⇒ the minimum (the binding constraint).
        let mixed: [any KVCache] = [
            RotatingKVCache(maxSize: 256), RotatingKVCache(maxSize: 128), KVCacheSimple(),
        ]
        #expect(PrefixCacheStrategy.minSlidingWindow(mixed) == 128)

        // No rotating layers ⇒ nil (pure-attention; window doesn't apply).
        #expect(PrefixCacheStrategy.minSlidingWindow([KVCacheSimple(), KVCacheSimple()]) == nil)
        #expect(PrefixCacheStrategy.minSlidingWindow([]) == nil)
    }

    @Test("classify + minSlidingWindow → checkpoint boundaries (Gemma-4 / GPT-OSS end to end)")
    func strategyToBoundaries() {
        // Gemma-4: checkpoint strategy, window 512 → boundaries ≤ 512.
        let gemma: [any KVCache] = [RotatingKVCache(maxSize: 512), KVCacheSimple()]
        #expect(PrefixCacheStrategy.classify(gemma) == .checkpoint)
        let gemmaBounds = PrefixDigest.checkpoints(
            forSlidingWindow: PrefixCacheStrategy.minSlidingWindow(gemma) ?? 0)
        #expect(gemmaBounds == [256, 512])

        // GPT-OSS: checkpoint strategy, window 128 → a usable sub-window boundary.
        let gptoss: [any KVCache] = [RotatingKVCache(maxSize: 128), KVCacheSimple()]
        #expect(PrefixCacheStrategy.classify(gptoss) == .checkpoint)
        let gptBounds = PrefixDigest.checkpoints(
            forSlidingWindow: PrefixCacheStrategy.minSlidingWindow(gptoss) ?? 0)
        #expect(!gptBounds.isEmpty && gptBounds.allSatisfy { $0 <= 128 })
    }
}

// Step 2 (zero-runtime): checkpoint boundaries derived from the sliding
// window, so a checkpoint snapshot never claims tokens the window has
// already discarded.

@Suite("PrefixDigest.checkpoints(forSlidingWindow:)")
struct PrefixCacheBoundaryTests {

    @Test("no/unknown window ⇒ defaults unchanged")
    func noWindowKeepsDefaults() {
        #expect(PrefixDigest.checkpoints(forSlidingWindow: 0) == PrefixDigest.defaultCheckpoints)
        #expect(PrefixDigest.checkpoints(forSlidingWindow: -1) == PrefixDigest.defaultCheckpoints)
    }

    @Test("Gemma-4 window 512 ⇒ only boundaries ≤ 512")
    func gemmaWindow() {
        let b = PrefixDigest.checkpoints(forSlidingWindow: 512)
        #expect(b == [256, 512])
        #expect(b.allSatisfy { $0 <= 512 }, "no boundary may exceed the window")
    }

    @Test("GPT-OSS window 128 ⇒ a usable sub-window boundary exists")
    func gptOssWindow() {
        let b = PrefixDigest.checkpoints(forSlidingWindow: 128)
        #expect(!b.isEmpty, "tiny window must still yield ≥1 usable checkpoint")
        #expect(b.allSatisfy { $0 <= 128 && $0 > 0 }, "all ≤ window, positive")
        #expect(b.contains(128), "the window itself is the largest usable checkpoint")
    }

    @Test("boundaries are sorted, unique, positive for any window")
    func wellFormed() {
        for w in [1, 2, 64, 100, 128, 256, 512, 4096] {
            let b = PrefixDigest.checkpoints(forSlidingWindow: w)
            #expect(b == b.sorted(), "sorted")
            #expect(Set(b).count == b.count, "unique")
            #expect(b.allSatisfy { $0 > 0 && $0 <= w }, "positive and ≤ window for w=\(w)")
        }
    }
}
