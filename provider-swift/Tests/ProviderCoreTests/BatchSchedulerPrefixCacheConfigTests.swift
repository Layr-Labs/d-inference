// Unit tests for the engine prefix-cache sizing + weight-binding helpers
// (BatchScheduler). Pure functions — no MLX/model load required.

import Foundation
import Testing
@testable import ProviderCore

@Suite("BatchScheduler prefix-cache sizing + weight binding")
struct BatchSchedulerPrefixCacheConfigTests {

    // #1: the cache identity binds to the WEIGHT hash so a re-download under
    // the same model id with different weights invalidates stale KV.
    @Test("prefixCacheBindingId prefers weightHash, falls back to modelId")
    func bindingId() {
        #expect(BatchScheduler.prefixCacheBindingId(modelId: "m", weightHash: "sha256:aaa") == "sha256:aaa")
        // Different weights under the same id ⇒ different cache identity.
        #expect(
            BatchScheduler.prefixCacheBindingId(modelId: "m", weightHash: "sha256:aaa")
                != BatchScheduler.prefixCacheBindingId(modelId: "m", weightHash: "sha256:bbb"))
        // No/empty weight hash ⇒ fall back to the model id (no worse than before).
        #expect(BatchScheduler.prefixCacheBindingId(modelId: "m", weightHash: nil) == "m")
        #expect(BatchScheduler.prefixCacheBindingId(modelId: "m", weightHash: "") == "m")
    }

    // #2: maxBlocks is bounded by a memory budget so the block cache can't
    // retain KV far beyond what fits (OOM guard) — the cache holds up to
    // blocks*blockSize tokens OUTSIDE the scheduler's active kvBudget.
    @Test("prefixCacheMaxBlocks scales by budget and clamps to the ceiling")
    func maxBlocks() {
        let bs = 256
        let kvPerTok = 4096          // ~1 MB per 256-token block
        let oneGB = 1_073_741_824

        let blocks = BatchScheduler.prefixCacheMaxBlocks(
            kvBytesPerToken: kvPerTok, budgetBytes: oneGB, blockSize: bs)
        #expect(blocks == oneGB / (bs * kvPerTok))   // 1024 blocks

        // Halving the budget halves the block count.
        let half = BatchScheduler.prefixCacheMaxBlocks(
            kvBytesPerToken: kvPerTok, budgetBytes: oneGB / 2, blockSize: bs)
        #expect(half == blocks / 2)

        // A model whose single block exceeds the budget ⇒ 0 (caller disables).
        #expect(BatchScheduler.prefixCacheMaxBlocks(
            kvBytesPerToken: 1_000_000_000, budgetBytes: oneGB, blockSize: bs) == 0)

        // Never exceeds the ceiling even with an enormous budget.
        #expect(BatchScheduler.prefixCacheMaxBlocks(
            kvBytesPerToken: 1, budgetBytes: Int.max / 2, blockSize: bs) == 4096)
    }
}
