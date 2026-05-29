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

    // Memory budget: valid override wins; malformed/huge values must NOT
    // crash (Int(Double) traps on inf/NaN/overflow) — fall back to RAM/8.
    @Test("resolveMemoryBudget: valid override wins, malformed/huge falls back to RAM/8")
    func memoryBudget() {
        let gib = 1_073_741_824
        let ram = 16 * gib
        #expect(BatchScheduler.resolveMemoryBudget(envGB: 8, physicalMemory: ram) == 8 * gib)
        #expect(BatchScheduler.resolveMemoryBudget(envGB: nil, physicalMemory: ram) == ram / 8)
        // 0 / negative ⇒ default (memory has no "unlimited" mode).
        #expect(BatchScheduler.resolveMemoryBudget(envGB: 0, physicalMemory: ram) == ram / 8)
        #expect(BatchScheduler.resolveMemoryBudget(envGB: -5, physicalMemory: ram) == ram / 8)
        // Non-finite / overflow must degrade, not trap.
        #expect(BatchScheduler.resolveMemoryBudget(envGB: .infinity, physicalMemory: ram) == ram / 8)
        #expect(BatchScheduler.resolveMemoryBudget(envGB: .nan, physicalMemory: ram) == ram / 8)
        #expect(BatchScheduler.resolveMemoryBudget(envGB: 1e30, physicalMemory: ram) == ram / 8)
    }

    // #3 follow-up: the on-disk budget defaults to 50% of free volume space.
    @Test("resolveDiskBudget: 50% of free, env override wins, never 'unlimited' from free")
    func diskBudget() {
        let gib = 1_073_741_824
        // Default: half of the measured free bytes.
        #expect(BatchScheduler.resolveDiskBudget(envGB: nil, freeBytes: 100 * gib) == 50 * gib)
        // Explicit env override wins over free-space measurement.
        #expect(BatchScheduler.resolveDiskBudget(envGB: 5, freeBytes: 100 * gib) == 5 * gib)
        // Env 0 = unlimited (honored only via the env path).
        #expect(BatchScheduler.resolveDiskBudget(envGB: 0, freeBytes: 100 * gib) == 0)
        // A (near-)full disk yields a tiny POSITIVE budget — not 0/unlimited.
        #expect(BatchScheduler.resolveDiskBudget(envGB: nil, freeBytes: 0) == 1)
        #expect(BatchScheduler.resolveDiskBudget(envGB: nil, freeBytes: 1) == 1)
        // Free space unknown ⇒ conservative 10 GB fallback.
        #expect(BatchScheduler.resolveDiskBudget(envGB: nil, freeBytes: nil) == 10 * gib)
        // Non-finite / overflow env must degrade to 50%-of-free, not trap.
        #expect(BatchScheduler.resolveDiskBudget(envGB: .infinity, freeBytes: 100 * gib) == 50 * gib)
        #expect(BatchScheduler.resolveDiskBudget(envGB: .nan, freeBytes: 100 * gib) == 50 * gib)
        #expect(BatchScheduler.resolveDiskBudget(envGB: 1e30, freeBytes: 100 * gib) == 50 * gib)
    }

    @Test("volumeFreeBytes reads a positive capacity for a real directory")
    func freeBytes() {
        let free = BatchScheduler.volumeFreeBytes(at: FileManager.default.temporaryDirectory)
        #expect(free != nil && free! > 0, "should read the temp volume's free capacity")
    }
}
