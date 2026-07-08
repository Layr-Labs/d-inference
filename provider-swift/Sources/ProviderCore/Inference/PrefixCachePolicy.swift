// Copyright © 2026 Eigen Labs.
//
// Prefix-cache policy for the ContinuousBatchingV2 engine — the gate, the
// budget, and the KV carve. (The legacy scheduler that once delegated its
// env/budget checks here was deleted in the v0.7.5 one-engine release.)
//
// The v2 cache (`PrefixCacheV2`, mlx-swift-lm ContinuousBatchingV2) is
// RAM-ONLY: donated KV lives in process memory under an LRU byte budget,
// with no persistence tier — see threat model T-041/TB-007 (the on-disk
// metadata leak of the legacy encrypted tier does not exist on this path;
// the in-process cross-tenant TTFT oracle remains the SEC-035 accepted
// risk, narrowed by per-request `cacheSalt` scoping).
//
// DORMANT BY DEFAULT (v0.7.5 ship decision): resident RAM belongs to LIVE
// serving — every byte a resident cache retains is a byte of KV
// concurrency the box cannot serve — so the cache stays OFF unless a box
// is explicitly opted in with `DARKBLOOM_PREFIX_CACHE=1` (plus an optional
// `DARKBLOOM_PREFIX_CACHE_MAX_GB`) for experiments. The gate, budget,
// funding-gate, and carve machinery below stay fully wired for opted-in
// boxes and as the foundation for the successor design: an ENCRYPTED SSD
// offload tier (write-behind donation on completion, read-through
// adoption, HMAC-keyed prefix hashes) that caches without occupying
// serving RAM. That tier is reviewed under T-041 before it ships. This
// shared gate means v0.7.5 ships with NO resident prefix cache anywhere
// by default.
//
// PER-MODEL FUNDING GATE (the adoption bound): the engine only ADOPTS a
// cached prefix past `windowCount × maxWindow` matched tokens — every
// stacked sliding-window layer compounds the recompute span
// (`cbv2RequiredRecompute`; `EngineV2.makeAdoption` declines anything
// smaller). For hybrid models whose bound dwarfs real prompt lengths
// (gemma-4-26B: 25 sliding layers × 1024 window = 25,600 tokens, vs a
// production p90 prompt of ~4k) the cache can never produce a hit, yet
// its byte budget would still be carved OUT of the engine's live-KV
// ceiling — on a 36 GB gemma box that is ~4.5 GB of KV (and therefore
// live concurrency) spent on zero benefit. The cache is therefore funded
// only when the model's adoption bound is at most
// `defaultMaxAdoptionBoundTokens` (4,096: gpt-oss-20b's 12 × 128 = 1,536
// funds; gemma-4's 25,600 does not — its full grant stays with live
// serving). Pure full-attention models have bound 0 and always fund; an
// UNKNOWN bound is treated as 0 (fund) for the same reason — only
// CBv2-adapted families reach engine construction, and the conservative
// failure mode of a mis-derived bound is a funded-but-useless cache,
// never lost live KV beyond the configured budget. Operator override:
// DARKBLOOM_PREFIX_CACHE_MAX_ADOPTION_BOUND_TOKENS (0 ⇒ never fund any
// model; absent/malformed ⇒ the 4,096 default).
//
// Everything here is pure and unit-testable: environment and physical
// memory are parameters with production defaults.

import Foundation
import MLXLMCommon

enum PrefixCachePolicy {

    /// Master gate, shared with the legacy engine: the prefix cache is
    /// DORMANT BY DEFAULT as of v0.7.5 — a box opts IN with
    /// `DARKBLOOM_PREFIX_CACHE=1` (also `true`/`yes`/`on`); absent, `0`,
    /// or anything unrecognized keeps it off. See T-041 and the header.
    static let environmentFlag = "DARKBLOOM_PREFIX_CACHE"

    /// In-memory budget override (GB). Unset/invalid ⇒ the default policy
    /// (physical memory / 8) — identical numbers to the legacy sizing
    /// policy (`BatchScheduler+PrefixCacheSizing`).
    static let budgetEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_MAX_GB"

    /// Stats-logger cadence override (seconds). Shared semantics with the
    /// legacy checkpoint-tier logger: unset/malformed ⇒ default 120s;
    /// `0` ⇒ disabled; positive ⇒ the cadence.
    static let statsIntervalEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS"

    /// Funding-gate threshold override (tokens). The cache is funded only
    /// for models whose adoption bound is at most this. `0` ⇒ never fund;
    /// absent/malformed/negative ⇒ `defaultMaxAdoptionBoundTokens`. See
    /// the header for the rationale.
    static let adoptionBoundEnvironmentFlag =
        "DARKBLOOM_PREFIX_CACHE_MAX_ADOPTION_BOUND_TOKENS"

    /// Hash-block granularity for the v2 cache. Matches the engine's
    /// `CBv2BlockHasher.defaultBlockSize` (and the legacy block tier's 256).
    static let blockSize = CBv2BlockHasher.defaultBlockSize

    // MARK: - Gate

    /// OPT-IN as of v0.7.5 (ship decision: resident RAM is for live
    /// serving; caching returns by default with the encrypted SSD tier).
    /// Only an explicit affirmative enables; absent / `0` / `false` /
    /// `off` / `no` / anything unrecognized keeps the cache dormant.
    /// Fail-safe direction is OFF: a typo'd value can only ever leave a
    /// box uncached, never opt it into the SEC-035 channel by accident.
    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let env = environment[environmentFlag]?
            .trimmingCharacters(in: .whitespaces).lowercased()
        return env == "1" || env == "true" || env == "yes" || env == "on"
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

    // MARK: - Per-model funding gate (adoption bound)

    /// Default funding threshold (tokens): models whose adoption bound
    /// exceeds this never fund a cache. 4,096 sits above gpt-oss-20b's
    /// bound (1,536) and far below gemma-4's (25,600), and roughly tracks
    /// the fleet's real prompt lengths (a bound at/under it is reachable
    /// by production traffic; one above it is not).
    static let defaultMaxAdoptionBoundTokens = 4096

    /// The model's adoption bound: `windowCount × maxWindow` over its layer
    /// kinds — the exact bound term of the engine's `cbv2RequiredRecompute`
    /// (`EngineV2.makeAdoption` declines any hit whose matched prefix does
    /// not exceed it). 0 for pure full-attention models (every whole-block
    /// hit is adoptable).
    static func adoptionBoundTokens(layerKinds: [CBv2LayerKind]) -> Int {
        var maxWindow = 0
        var windowCount = 0
        for kind in layerKinds {
            if case .slidingWindow(let window) = kind.attention {
                maxWindow = max(maxWindow, window)
                windowCount += 1
            }
        }
        // Same overflow posture as the engine's derivation: the product can
        // only overflow at absurd model shapes; saturate rather than trap.
        let (bound, overflow) = windowCount.multipliedReportingOverflow(by: maxWindow)
        return overflow ? Int.max : bound
    }

    /// Resolved funding threshold: env override (`0` ⇒ never fund; positive
    /// value ⇒ the threshold), absent/malformed/negative ⇒ the default.
    static func maxAdoptionBoundTokens(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment[adoptionBoundEnvironmentFlag] else {
            return defaultMaxAdoptionBoundTokens
        }
        guard let n = Int(raw), n >= 0 else { return defaultMaxAdoptionBoundTokens }
        return n  // 0 ⇒ never fund
    }

    /// Whether a model with this adoption bound should have its cache
    /// funded. A threshold of 0 funds NOTHING (including bound-0 models) —
    /// it is the per-box "cache budget off" switch that leaves the
    /// `DARKBLOOM_PREFIX_CACHE` master gate (which also governs the legacy
    /// engine) untouched.
    static func shouldFund(
        adoptionBoundTokens bound: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let cap = maxAdoptionBoundTokens(environment: environment)
        return cap > 0 && bound <= cap
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
