// Copyright © 2026 Eigen Labs.
//
// BatchScheduler prefix-cache sizing/binding helpers (pure, testable): layer
// shape probing, binding id, RAM/disk budgets, persist floor, and TTL policy.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation
import os

extension BatchScheduler {
    // MARK: - Prefix cache sizing/binding helpers (testable)

    /// Per-layer `[kvHeads, headDim]` ground truth for a model, derived by
    /// running a tiny 1-token prefill through a throwaway cache so every
    /// layer materializes its KV (the cache state is empty before any
    /// update). Needed because heterogeneous models (Gemma-4: sliding
    /// `[8,256]` + full `[2,512]` layers) can't be described by a single
    /// (kvHeads, headDim), and the load-time shape guard validates per layer.
    /// Returns nil on any failure (caller falls back to the scalar guard).
    static func probeLayerShapes(model: any LanguageModel) -> [[Int]]? {
        let caches = model.newCache(parameters: nil)
        guard !caches.isEmpty else { return nil }
        let probe = MLXArray([Int32(0)]).reshaped([1, 1])
        _ = model.callAsFunction(probe, cache: caches)
        for c in caches { eval(c.innerState()) }
        var shapes: [[Int]] = []
        shapes.reserveCapacity(caches.count)
        for c in caches {
            guard let k = c.state.first, k.shape.count == 4 else { return nil }
            shapes.append([k.dim(1), k.dim(3)])  // [kvHeads, headDim]
        }
        return shapes
    }

    internal static func checkpointLayerSignatures(
        for caches: [any KVCache],
        layerShapes: [[Int]]?
    ) -> [CheckpointLayerSignature] {
        caches.enumerated().map { idx, cache in
            let shape: [Int]? =
                if let layerShapes, idx < layerShapes.count {
                    layerShapes[idx]
                } else {
                    nil
                }
            return CheckpointLayerSignature.from(cache, layerShape: shape)
        }
    }

    /// Cache identity: bind to the weight hash so a re-download under the
    /// same model id with different weights invalidates old KV. Falls back
    /// to the model id when no weight hash is known.
    static func prefixCacheBindingId(modelId: String, weightHash: String?) -> String {
        if let w = weightHash, !w.isEmpty { return w }
        return modelId
    }

    /// Block count for the engine prefix cache, bounded by a memory budget.
    /// The cache retains up to blocks*blockSize tokens of KV OUTSIDE the
    /// scheduler's active kvBudget, so a fixed 4096 would OOM large models.
    /// Returns 0 when even one block exceeds the budget (caller disables).
    static func prefixCacheMaxBlocks(
        kvBytesPerToken: Int, budgetBytes: Int, blockSize: Int, ceiling: Int = 4096
    ) -> Int {
        let perBlock = max(1, blockSize) * max(1, kvBytesPerToken)
        let fromBudget = max(0, budgetBytes) / perBlock
        return min(ceiling, fromBudget)
    }

    /// In-memory budget for the engine prefix cache. Operator override:
    /// DARKBLOOM_PREFIX_CACHE_MAX_GB; default = 1/8 of physical memory.
    /// NOTE: this is read UNCONDITIONALLY at every model load (to size
    /// maxBlocks) even when the cache is disabled, so a malformed value must
    /// degrade — never crash. See resolveMemoryBudget.
    static func prefixCacheBudgetBytes() -> Int {
        let envGB: Double? = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_MAX_GB"]
            .flatMap(Double.init)
        return resolveMemoryBudget(envGB: envGB, physicalMemory: Int(ProcessInfo.processInfo.physicalMemory))
    }

    /// Pure memory-budget policy (testable). A valid positive env override
    /// wins; a non-finite or out-of-Int-range value is REJECTED back to the
    /// physicalMemory/8 default rather than crashing (Int(Double) traps on
    /// inf/NaN/overflow, and this is read even when the cache is off).
    static func resolveMemoryBudget(envGB: Double?, physicalMemory: Int) -> Int {
        if let gb = envGB, gb > 0, gb.isFinite, gb < gbToBytesCeiling {
            return Int(gb * 1_073_741_824)
        }
        return max(1, physicalMemory / 8)
    }

    /// Largest GB value that won't overflow Int when multiplied by 2^30.
    private static var gbToBytesCeiling: Double { Double(Int.max) / 1_073_741_824 }

    /// Conservative per-model on-disk default (bytes) when the operator sets
    /// no explicit `DARKBLOOM_PREFIX_CACHE_DISK_GB`. Deliberately a small
    /// FIXED cap, NOT a fraction of free space: the budget is PER MODEL (see
    /// docs / issue #266), so a "50% of free" default lets N models
    /// collectively fill the disk. A fixed cap keeps the default-on prefix cache
    /// safe out of the box for a low-churn / few-model rollout (≈ N × 10 GB
    /// aggregate); operators raise it explicitly when they have the headroom.
    static let defaultDiskBudgetBytes = 10 * 1_073_741_824

    /// On-disk budget for persisted prefix files. Operator override:
    /// DARKBLOOM_PREFIX_CACHE_DISK_GB — a positive value sets the cap; unset / 0 /
    /// non-numeric falls back to the default (NOT unlimited). Default = a fixed
    /// 10 GB per model, clamped down to 50% of free space on a tight volume.
    static func prefixCacheDiskBudgetBytes(cacheDir: URL) -> Int {
        let envGB: Double? = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_DISK_GB"]
            .flatMap(Double.init)
        return resolveDiskBudget(envGB: envGB, freeBytes: volumeFreeBytes(at: cacheDir))
    }

    /// Pure disk-budget policy (testable). An explicit env override wins
    /// (including 0 = unlimited; non-finite/overflowing values are rejected
    /// back to the default). Otherwise use a FIXED conservative cap
    /// (`defaultDiskBudgetBytes`, per model) so multiple models can't each
    /// claim a large fraction of free space — but clamp to half of measured
    /// free so a near-full volume yields a smaller (still positive) budget
    /// rather than over-committing. When free space is unknown, use the
    /// fixed default directly.
    static func resolveDiskBudget(envGB: Double?, freeBytes: Int?) -> Int {
        if let gb = envGB, gb >= 0, gb.isFinite, gb < gbToBytesCeiling {
            return Int(gb * 1_073_741_824)
        }
        guard let free = freeBytes else { return defaultDiskBudgetBytes }
        return max(1, min(defaultDiskBudgetBytes, free / 2))
    }

    /// GLOBAL disk ceiling (bytes) for the GlobalDiskAccountant, parsed from
    /// `DARKBLOOM_PREFIX_CACHE_DISK_GB`. Returns the explicit byte cap when the
    /// operator set a positive value, else 0 = "derive from live free disk"
    /// (the accountant uses min(10GiB, free/2) and re-evaluates each tick).
    ///
    /// Previously the env var was parsed only into the per-model
    /// backing's diskBudgetBytes, which is forced to 0 when the accountant is
    /// active — so an operator-set global cap was silently ignored. The
    /// accountant is the sole authority now, so the env cap must reach IT.
    static func prefixCacheGlobalDiskCeiling() -> Int {
        let envGB: Double? = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_DISK_GB"]
            .flatMap(Double.init)
        guard let gb = envGB, gb > 0, gb.isFinite, gb < gbToBytesCeiling else { return 0 }
        return Int(gb * 1_073_741_824)
    }
    // Under the global accountant, DISK_GB semantics differ from
    // the legacy per-model parser: `0` (or unset / non-numeric) means "derive a
    // cap from live free disk" (min(10GiB, free/2)), NOT "unlimited". An
    // unlimited GLOBAL cache would defeat the accountant's purpose (fill the
    // volume), so there is intentionally no unbounded mode here; an operator who
    // wants effectively-unbounded sets a very large explicit value. Documented
    // in docs/ssd-kv-cache.md §11.

    /// Best-effort free capacity (bytes) of the volume containing `url`.
    /// Prefers the "important usage" figure Apple recommends for storage
    /// decisions, falling back to the raw available capacity.
    static func volumeFreeBytes(at url: URL) -> Int? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 {
            return Int(important)
        }
        if let plain = v.volumeAvailableCapacity, plain > 0 { return plain }
        return nil
    }

    /// TB-016 sub-feature B: Minimum token count for SSD persistence.
    /// Default: 16384 for Gemma family (proven past-window restore),
    /// 0 otherwise (all checkpoints persist). Env override:
    /// DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS.
    static func prefixCacheMinPersistTokens(arch: String) -> Int {
        if let env = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS"],
           let val = Int(env), val >= 0 {
            return val
        }
        // Default: 16384 for Gemma, 0 otherwise.
        return PrefixCachePastWindow.isProven(arch: arch) ? 16384 : 0
    }

    /// Sliding TTL (seconds) for persisted SSD prefix checkpoints. Default 300
    /// (5 min, matching Anthropic/OpenAI prompt-cache defaults); `0` disables
    /// (infinite — capacity-driven eviction only). Operator override:
    /// `DARKBLOOM_PREFIX_CACHE_TTL_SECONDS`.
    static let defaultPrefixCacheTTLSeconds: Int64 = 300
    static func prefixCacheTTLSeconds() -> Int64 {
        resolveTTLSeconds(env: ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_TTL_SECONDS"])
    }

    /// Pure TTL policy (testable). Unset / malformed / negative ⇒ default;
    /// `0` ⇒ disabled (infinite); a positive value sets the sliding window.
    static func resolveTTLSeconds(env: String?) -> Int64 {
        guard let v = env else { return defaultPrefixCacheTTLSeconds }
        guard let n = Int64(v), n >= 0 else { return defaultPrefixCacheTTLSeconds }
        return n  // 0 ⇒ disabled
    }

}
