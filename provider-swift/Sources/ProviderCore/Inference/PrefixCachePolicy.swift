// Copyright © 2026 Eigen Labs.
//
// Prefix-cache policy for the ContinuousBatchingV2 engine — the gate, the
// budget, and the KV carve. (The legacy scheduler that once delegated its
// env/budget checks here was deleted in the v0.7.5 one-engine release.)
//
// TWO TIERS as of v0.7.5:
//
//   * The ENCRYPTED SSD OFFLOAD TIER (`SSDPrefixCache`, KVCacheSSD/)
//     SHIPS IN v0.7.5 and is the DEFAULT for every CBv2-adapted model:
//     write-behind donation on completion (per-donation gate: persist
//     only prefixes longer than the model's adoption bound + the
//     1,024-token benefit floor), read-through adoption, HMAC-keyed
//     names (T-041 leak #2 closed), 15-minute sliding TTL, 20 GiB
//     box-wide LRU disk budget, and ZERO memory carve — resident RAM
//     belongs entirely to LIVE serving. Reviewed and shipped under
//     T-041. Kill switch: `DARKBLOOM_PREFIX_CACHE_SSD=0` (and the
//     master `DARKBLOOM_PREFIX_CACHE=0` kills every tier).
//
//   * The RAM tier (`PrefixCacheV2`, mlx-swift-lm ContinuousBatchingV2)
//     stays OPT-IN EXPERIMENTAL: donated KV in process memory under an
//     LRU byte budget carved out of the slot's KV grant. Reached only
//     with `DARKBLOOM_PREFIX_CACHE=1` AND the SSD tier killed (when
//     both are active, SSD wins with a WARN — no tier composition).
//     Every byte it retains is a byte of KV concurrency the box cannot
//     serve, hence opt-in (plus optional
//     `DARKBLOOM_PREFIX_CACHE_MAX_GB`). The in-process cross-tenant
//     TTFT oracle remains the SEC-035 accepted risk on both tiers,
//     narrowed by per-request `cacheSalt` scoping.
//
// See `mode(environment:)` for the tier selector.
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

    /// Master gate. As of v0.7.5 it plays
    /// two roles (see `mode`): any set-but-non-affirmative value KILLS
    /// every tier (incl. the default-on SSD tier); an affirmative value
    /// opts the box into the experimental RAM tier (which only engages
    /// when the SSD tier is also killed). See T-041 and the header.
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

    /// RAM-tier opt-in (v2 slots use `mode` instead,
    /// which layers the default-on SSD tier on top): only an explicit
    /// affirmative enables; absent / `0` / `false` / `off` / `no` /
    /// anything unrecognized keeps the RAM cache dormant. Fail-safe
    /// direction is OFF: a typo'd value can only ever leave a box
    /// uncached, never opt it into the SEC-035 channel by accident.
    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let env = environment[environmentFlag]?
            .trimmingCharacters(in: .whitespaces).lowercased()
        return env == "1" || env == "true" || env == "yes" || env == "on"
    }

    // MARK: - Tier selection (v0.7.5 SSD offload)

    /// SSD-tier kill switch. The encrypted SSD offload tier is ON BY DEFAULT
    /// for CBv2-supported models when KEK construction succeeds; it caches
    /// without occupying serving RAM and benefit-gates each donation. An
    /// explicit `DARKBLOOM_PREFIX_CACHE_SSD=0` (or any other
    /// non-affirmative set value — fail-safe: a typo only ever disables)
    /// kills just the SSD tier. `DARKBLOOM_PREFIX_CACHE=0` (the existing
    /// master switch, any non-affirmative set value) kills EVERYTHING.
    static let ssdEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_SSD"

    /// Which prefix-cache tier a v2 slot runs. The per-model funding gate is
    /// applied only to RAM after this selection.
    enum Mode: Equatable {
        /// No prefix cache anywhere.
        case off
        /// RAM `PrefixCacheV2` — the opt-in-experimental tier, exactly the
        /// v0.7.5 dormant-default semantics (`DARKBLOOM_PREFIX_CACHE=1`
        /// with the SSD tier killed).
        case ram
        /// Encrypted SSD offload (default for supported models).
        /// `warnBothTiers`: the box ALSO opted into the RAM tier — SSD
        /// wins for the slot (no tier composition in v1), WARN logged.
        case ssd(warnBothTiers: Bool)
    }

    /// Resolve the tier for this environment:
    ///   * `DARKBLOOM_PREFIX_CACHE` set to anything non-affirmative ⇒
    ///     `.off` (master kill, existing fail-safe semantics: a typo can
    ///     only ever leave a box uncached).
    ///   * SSD tier on (default, or `_SSD` affirmative) ⇒ `.ssd` — with a
    ///     WARN flag when the RAM tier was ALSO opted in.
    ///   * SSD killed + `DARKBLOOM_PREFIX_CACHE=1` ⇒ `.ram` (the opt-in
    ///     experimental tier, unchanged).
    ///   * SSD killed + master unset ⇒ `.off`.
    static func mode(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Mode {
        let master = environment[environmentFlag]?
            .trimmingCharacters(in: .whitespaces).lowercased()
        let masterAffirmative =
            master == "1" || master == "true" || master == "yes" || master == "on"
        // Master set to anything else (incl. "0") ⇒ kill everything.
        if let master, !master.isEmpty, !masterAffirmative { return .off }

        let ssd = environment[ssdEnvironmentFlag]?
            .trimmingCharacters(in: .whitespaces).lowercased()
        let ssdAffirmative = ssd == "1" || ssd == "true" || ssd == "yes" || ssd == "on"
        let ssdKilled = ssd.map { !$0.isEmpty && !ssdAffirmative } ?? false
        if !ssdKilled {
            return .ssd(warnBothTiers: masterAffirmative)
        }
        return masterAffirmative ? .ram : .off
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

    /// Pure memory-budget policy retained from the legacy scheduler. A
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

    // MARK: - SSD disk budget

    /// On-disk budget env override (GB) — the existing operator knob,
    /// now governing the BOX-WIDE SSD-tier budget (adapted from the
    /// retired `BatchScheduler+PrefixCacheSizing` resolver).
    static let diskBudgetEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_DISK_GB"

    /// Box-wide SSD default: 20 GiB across ALL models (Gaj, 2026-07-07),
    /// clamped to half the volume's free space on a tight disk.
    static let defaultSSDDiskBudgetBytes = 20 * 1_073_741_824

    /// Resolved box-wide SSD disk budget (bytes). A valid positive env
    /// override wins verbatim; otherwise `min(20 GiB, free/2)` — like the
    /// legacy default derivation, re-evaluated per enforcement so the
    /// ceiling shrinks as the volume fills. Unknown free space ⇒ the
    /// fixed default.
    static func ssdDiskBudgetBytes(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        freeBytes: Int?
    ) -> Int {
        let envGB = environment[diskBudgetEnvironmentFlag].flatMap(Double.init)
        if let gb = envGB, gb > 0, gb.isFinite, gb < gbToBytesCeiling {
            return Int(gb * 1_073_741_824)
        }
        guard let free = freeBytes else { return defaultSSDDiskBudgetBytes }
        return max(1, min(defaultSSDDiskBudgetBytes, free / 2))
    }

    /// Best-effort free capacity (bytes) of the volume containing `url`
    /// (moved from the legacy sizing helpers). Prefers Apple's
    /// "important usage" figure, falls back to the raw available capacity.
    static func volumeFreeBytes(at url: URL) -> Int? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        guard let v = try? probe.resourceValues(forKeys: keys) else { return nil }
        if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 {
            return Int(important)
        }
        if let plain = v.volumeAvailableCapacity, plain > 0 { return plain }
        return nil
    }

    // MARK: - Stats cadence

    static let defaultStatsIntervalSecs = 120

    /// Pure stats-interval policy with the retired scheduler's wire-compatible
    /// semantics. Unset / malformed / negative ⇒ default;
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
    /// `DARKBLOOM_PREFIX_CACHE` master gate untouched.
    ///
    /// RAM TIER ONLY (v0.7.5 per-donation decision): the SSD tier RETIRED
    /// this per-model gate — it is constructed for every CBv2-adapted
    /// model in `.ssd` mode and gates each DONATION on the model's own
    /// adoption bound + benefit floor instead
    /// (`SSDPrefixCache.donate`), so hybrid models with huge bounds
    /// (gemma-4) cache exactly their adoptable long-context tail rather
    /// than nothing. `DARKBLOOM_PREFIX_CACHE_MAX_ADOPTION_BOUND_TOKENS`
    /// therefore has NO effect on the SSD tier; a model is only "never
    /// cached" there when its bound is unknown/saturated (the donation
    /// gate can then never pass).
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
