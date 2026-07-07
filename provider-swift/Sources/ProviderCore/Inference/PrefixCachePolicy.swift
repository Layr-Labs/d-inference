// Copyright © 2026 Eigen Labs.
//
// Prefix-cache policy for the ContinuousBatchingV2 engine — the gate, the
// budget, and the KV carve, factored SCHEDULER-FREE (no BatchScheduler
// dependency; the legacy scheduler delegates its env/budget checks here
// until its deletion pass).
//
// The v2 cache (`PrefixCacheV2`, mlx-swift-lm ContinuousBatchingV2) is
// RAM-ONLY: donated KV lives in process memory under an LRU byte budget,
// with no persistence tier — see threat model T-041/TB-007 (the on-disk
// metadata leak of the legacy encrypted tier does not exist on this path;
// the in-process cross-tenant TTFT oracle remains the SEC-035 accepted
// risk, narrowed by per-request `cacheSalt` scoping).
//
// Everything here is pure and unit-testable: environment and physical
// memory are parameters with production defaults.

import Foundation
import MLXLMCommon

enum PrefixCachePolicy {

    /// Master gate, shared with the legacy engine: the prefix cache is ON
    /// BY DEFAULT; an operator opts OUT with `DARKBLOOM_PREFIX_CACHE=0`
    /// (also `false`/`off`/`no`). See T-041 — untrusted multi-tenant
    /// deployments must set this.
    static let environmentFlag = "DARKBLOOM_PREFIX_CACHE"

    /// In-memory budget override (GB). Unset/invalid ⇒ the default policy
    /// (physical memory / 8) — identical numbers to the legacy sizing
    /// policy (`BatchScheduler+PrefixCacheSizing`).
    static let budgetEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_MAX_GB"

    /// Stats-logger cadence override (seconds). Shared semantics with the
    /// legacy checkpoint-tier logger: unset/malformed ⇒ default 120s;
    /// `0` ⇒ disabled; positive ⇒ the cadence.
    static let statsIntervalEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS"

    /// Hash-block granularity for the v2 cache. Matches the engine's
    /// `CBv2BlockHasher.defaultBlockSize` (and the legacy block tier's 256).
    static let blockSize = CBv2BlockHasher.defaultBlockSize

    // MARK: - Gate

    /// The exact `DARKBLOOM_PREFIX_CACHE` semantics the legacy engine has
    /// always used (default ON; only an explicit opt-out disables).
    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let env = environment[environmentFlag]?
            .trimmingCharacters(in: .whitespaces).lowercased()
        let disabled = env == "0" || env == "false" || env == "off" || env == "no"
        return !disabled
    }

    // MARK: - Budget

    /// Requested in-memory budget (bytes): `DARKBLOOM_PREFIX_CACHE_MAX_GB`
    /// when valid, else physical/8 — the legacy default policy, verbatim.
    static func budgetBytes(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        physicalMemory: Int = Int(min(
            ProcessInfo.processInfo.physicalMemory, UInt64(Int.max)))
    ) -> Int {
        let envGB = environment[budgetEnvironmentFlag].flatMap(Double.init)
        return resolveMemoryBudget(envGB: envGB, physicalMemory: physicalMemory)
    }

    /// Pure memory-budget policy (moved verbatim from the legacy
    /// `BatchScheduler.resolveMemoryBudget`, which now delegates here). A
    /// valid positive env override wins; a non-finite or out-of-Int-range
    /// value is REJECTED back to the physicalMemory/8 default rather than
    /// crashing (Int(Double) traps on inf/NaN/overflow).
    static func resolveMemoryBudget(envGB: Double?, physicalMemory: Int) -> Int {
        if let gb = envGB, gb > 0, gb.isFinite, gb < gbToBytesCeiling {
            return Int(gb * 1_073_741_824)
        }
        return max(1, physicalMemory / 8)
    }

    /// Largest GB value that won't overflow Int when multiplied by 2^30.
    private static var gbToBytesCeiling: Double { Double(Int.max) / 1_073_741_824 }

    // MARK: - Stats cadence

    static let defaultStatsIntervalSecs = 120

    /// Pure stats-interval policy (legacy `BatchScheduler.resolveStatsInterval`
    /// semantics, now shared). Unset / malformed / negative ⇒ default;
    /// `0` ⇒ disabled; a positive value sets the cadence in seconds.
    static func statsIntervalSecs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let v = environment[statsIntervalEnvironmentFlag] else {
            return defaultStatsIntervalSecs
        }
        guard let n = Int(v), n >= 0 else { return defaultStatsIntervalSecs }
        return n  // 0 ⇒ disabled
    }

    // MARK: - KV carve

    /// How a v2 slot's fleet-sized KV grant is split between the engine's
    /// admission ceiling and the prefix cache's byte budget.
    ///
    /// Invariant: `engineKVBytesCapacity + prefixCacheBudgetBytes ==
    /// slotKVBytesCapacity` whenever the cache is funded (`prefix > 0`),
    /// and `engineKVBytesCapacity == slotKVBytesCapacity` when it is not —
    /// the carve never loses or invents bytes, so cached KV + live-request
    /// KV can never jointly exceed the slot's grant under the
    /// unified-memory cap.
    struct Carve: Equatable {
        /// Admission ceiling handed to `makeProductionEngine` (and reported
        /// in heartbeats — the coordinator is never told about bytes the
        /// prefix cache will consume).
        let engineKVBytesCapacity: Int
        /// `PrefixCacheV2.maxBytes` budget. 0 ⇒ cache stays off.
        let prefixCacheBudgetBytes: Int
    }

    /// Carve the prefix-cache budget out of a slot's KV grant.
    ///
    /// Live serving wins — the cache is best-effort:
    ///   * The engine always keeps at least `minimumEngineKVBytes`
    ///     (default: the same 1 GiB floor the load gate uses to judge a
    ///     model serveable, `UnifiedMemoryCap.minimumLoadKVBytes`). When
    ///     honoring the requested budget would drop the engine below that
    ///     floor, the PREFIX budget shrinks — never live KV.
    ///   * A budget too small to retain even one hash block of KV
    ///     (`blockSize × kvBytesPerToken`) is useless — it would evict
    ///     every donation immediately — so it degrades to 0 (cache off),
    ///     mirroring the legacy `prefixCacheMaxBlocks(...) >= 1` guard.
    ///     Skipped when the per-token rate is unknown (0).
    static func carve(
        slotKVBytesCapacity: Int,
        requestedBudgetBytes: Int,
        kvBytesPerToken: Int,
        minimumEngineKVBytes: UInt64 = UnifiedMemoryCap.minimumLoadKVBytes,
        blockSize: Int = PrefixCachePolicy.blockSize
    ) -> Carve {
        let slot = max(0, slotKVBytesCapacity)
        guard requestedBudgetBytes > 0, slot > 0 else {
            return Carve(engineKVBytesCapacity: slot, prefixCacheBudgetBytes: 0)
        }
        let floor = Int(min(minimumEngineKVBytes, UInt64(Int.max)))
        guard slot > floor else {
            // The grant barely (or not even) clears the serviceable floor:
            // funding a cache would starve live KV. Everything to the engine.
            return Carve(engineKVBytesCapacity: slot, prefixCacheBudgetBytes: 0)
        }
        let prefix = min(requestedBudgetBytes, slot - floor)
        // One-block viability (overflow-safe: both factors are small).
        if kvBytesPerToken > 0 {
            let (perBlock, overflow) = blockSize.multipliedReportingOverflow(
                by: kvBytesPerToken)
            if overflow || prefix < perBlock {
                return Carve(engineKVBytesCapacity: slot, prefixCacheBudgetBytes: 0)
            }
        }
        return Carve(
            engineKVBytesCapacity: slot - prefix, prefixCacheBudgetBytes: prefix)
    }

    // MARK: - Construction

    /// Build the v2 cache for a funded budget. blockSize 256 (engine
    /// default, byte-compatible with the legacy chain scheme), model-id
    /// namespace for cross-model isolation, LRU byte budget. The default
    /// `materializeOnDonate: true` stays — required for any backend whose
    /// donated views reference recyclable storage, and ~free on the
    /// contiguous backend (see `EngineV2.prefixCachePairingViolation`).
    static func makePrefixCache(modelId: String, budgetBytes: Int) -> PrefixCacheV2? {
        guard budgetBytes > 0 else { return nil }
        return PrefixCacheV2(
            config: CBv2PrefixCacheConfig(
                blockSize: blockSize,
                modelName: modelId,
                maxBytes: budgetBytes
            ))
    }
}
