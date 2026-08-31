// Copyright © 2026 Eigen Labs.
//
// Production prefix-cache policy. The provider has one local kill switch
// and one production tier: encrypted SSD. In-memory prefix caching remains
// an upstream engine capability, but it is never selected or funded here.

import Foundation
import MLXLMCommon

enum PrefixCachePolicy {

    /// Local cache kill switch. Unset defaults to enabled. Any explicitly
    /// non-affirmative value disables the encrypted SSD cache.
    static let environmentFlag = "DARKBLOOM_PREFIX_CACHE"

    /// Stats-logger cadence override (seconds). Shared semantics with the
    /// legacy checkpoint-tier logger: unset/malformed ⇒ default 120s;
    /// `0` ⇒ disabled; positive ⇒ the cadence.
    static let statsIntervalEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS"

    /// Hash-block granularity for the v2 cache. Matches the engine's
    /// `CBv2BlockHasher.defaultBlockSize` (and the legacy block tier's 256).
    static let blockSize = CBv2BlockHasher.defaultBlockSize

    // MARK: - Gate

    /// Encrypted SSD is on by default. Explicit affirmative values keep it
    /// enabled; any other non-empty value disables it.
    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[environmentFlag]?
            .trimmingCharacters(in: .whitespaces).lowercased(),
            !raw.isEmpty
        else {
            return true
        }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }

    /// Is prefix ADOPTION bit-exact on the backend a slot actually built?
    ///
    /// NO for contiguous, and that is a measured property of the shipping
    /// checkpoints, not a theory. v0.8.0's six-arm gate ran cold vs adopted
    /// output for the same prompt on the real slot path: on
    /// `gemma-4-26B-A4B-it-qat-4bit` (diverges at byte 4) and
    /// `gpt-oss-20b-MXFP4-Q8` (diverges) — the entire production catalog —
    /// a contiguous slot that adopts a cached prefix answers DIFFERENTLY
    /// from its own cold run, which in production means a silently
    /// truncated completion rather than an error. The split followed the
    /// RESOLVED backend on 6/6 arms, including an arm that requested paged,
    /// degraded to contiguous under the kill switch, and diverged with the
    /// contiguous rows. So this must be asked of the CONSTRUCTED backend,
    /// never the requested one. (`gemma-4-e2b-it-4bit` inverts — exact on
    /// contiguous, inexact on paged — but it is an e2e fixture and appears
    /// zero times in the catalog; it is why the e2b exact-cache lane is
    /// expected red on paged.)
    ///
    /// CONSTRUCTION is what this gates, not lookup, and that is the narrow
    /// choice rather than the broad one:
    ///
    ///   * There is no `adopt` entry point to disable. Adoption IS a
    ///     non-nil `CBv2PrefixCache.lookup`, which has three overloads plus
    ///     a bridge-side `stage` that rehydrates blocks from disk so the
    ///     engine's synchronous lookup can find them. Suppressing "only
    ///     adoption" means a flag threaded through all four, where one
    ///     missed path leaves the wrong-answer class alive. A slot with no
    ///     cache OBJECT has no such path: `EngineV2SlotFactory` feeds the
    ///     same nil to the engine and the bridge.
    ///   * Donation without adoption has no consumer. Donated blocks are
    ///     keyed to this box, and nothing in the product writes
    ///     `engine_v2_kv_backend`, so a contiguous slot cannot become a
    ///     paged one that would read them. They would be written to be
    ///     evicted.
    ///   * Donation is not free. It reserves staging bytes in the shared
    ///     `GlobalKVCacheBudget` — RAM taken from the KV pool this release
    ///     exists to enlarge — plus disk against the 20 GiB box-wide LRU,
    ///     SSD write budget, and engine-thread snapshot work.
    ///
    /// So a contiguous slot gets no cache at all, reported as
    /// `.disabled` / `.unsupportedBackend` — the same shape as the
    /// `DARKBLOOM_PREFIX_CACHE=0` path, not a new one. Paged is untouched
    /// and keeps the full tier.
    static func adoptionIsExact(onResolvedBackend kind: EngineV2KVBackendKind) -> Bool {
        switch kind {
        case .paged: return true
        case .contiguous: return false
        }
    }

    /// The capability a slot reports once `adoptionIsExact` has ruled reuse
    /// out for its resolved backend: explicitly UNSUPPORTED, so the
    /// heartbeat's `replay_strategy` reads `none` ("no replay happens on
    /// this slot") rather than `unknown` ("nobody resolved it") or a
    /// strategy name the slot will never execute. The slot's KV backend is
    /// still reported truthfully in `PrefixCacheModelStatus.backend`.
    static func adoptionDisabledCapability(
        layerKinds: [CBv2LayerKind]
    ) -> CBv2PrefixReuseCapability {
        CBv2PrefixReuseCapability.derive(layerKinds: layerKinds, backend: .unknown)
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

    // MARK: - Exact prefix-reuse capability

    /// Construct the engine-owned typed capability for the backend selected
    /// before cache construction. Callers pass a RESOLVED selection derived
    /// from the backend actually built (`EngineV2SlotFactory` maps
    /// `preparedBackend.kind` to `.paged`/`.contiguous`), so `.auto` never
    /// reaches here — it is grouped with `.contiguous` only as a safe
    /// default. Treat that grouping as defensive rather than as a claim
    /// about config-level `.auto`: it happens to agree with the v0.8.1
    /// default and disagreed with v0.8.0's, and a caller passing a raw,
    /// unresolved selection would have declared a contiguous capability
    /// for a paged slot for the whole of that release. Resolve first,
    /// always.
    /// Explicit paged selection remains eligible only for layouts
    /// whose ordinary single-cursor replay is exact; interleaved hybrids fail
    /// cold until a separately-proven paged dual-cursor row exists.
    static func prefixReuseCapability(
        layerKinds: [CBv2LayerKind],
        backendSelection: EngineV2KVBackendSelection,
        pagedKilled: Bool = false
    ) -> CBv2PrefixReuseCapability {
        let backend: CBv2PrefixReuseBackend
        switch backendSelection {
        case .auto, .contiguous:
            backend = .contiguousUnquantized
        case .paged:
            backend = pagedKilled ? .contiguousUnquantized : .pagedFP16
        }
        return CBv2PrefixReuseCapability.derive(
            layerKinds: layerKinds,
            backend: backend)
    }

    /// Conservative finite-window replay length for the SSD donation/stage
    /// benefit gates; the engine plan remains authoritative per matched
    /// boundary.
    ///
    /// Resolves the backend through `prefixReuseCapability` rather than
    /// hardcoding `.contiguousUnquantized`, so this and the capability can no
    /// longer describe two different backends for the same slot.
    ///
    /// WS-4.2 once made this residency-dependent — a boundary whose window
    /// was restored from sidecars had nothing to replay, so the bound
    /// collapsed to zero. No row in this repo can install a restored window
    /// (paged would need `PagedSequenceKV.restoreWindow(_:at:)`, contiguous
    /// a `CBv2WindowedSequenceKV` ring adoption; neither exists), so the
    /// collapsed bound was unreachable and the plumbing carrying it has been
    /// removed. Restoring it means reintroducing a residency input HERE, not
    /// merely landing a consumer: advertising a matched prefix as free while
    /// the engine still performs its full `windowCount × maxWindow` replay is
    /// the failure this conservatism exists to prevent.
    static func adoptionBoundTokens(
        layerKinds: [CBv2LayerKind],
        backendSelection: EngineV2KVBackendSelection = .auto,
        pagedKilled: Bool = false
    ) -> Int {
        prefixReuseCapability(
            layerKinds: layerKinds,
            backendSelection: backendSelection,
            pagedKilled: pagedKilled
        ).conservativeReplayBoundTokens
    }

    /// Real Gemma QAT evidence is noisy/negative at only 1,024 saved tokens
    /// and positive from 1,536 onward; GPT's shorter 1,536-token replay span
    /// remains beneficial at the generic 1,024 floor. The environment may
    /// raise either floor but cannot lower the proved long-hybrid minimum.
    ///
    /// The override keys off the RESOLVED bound, not the capability's raw
    /// one. That evidence was measured against a 25,600-token replay, where
    /// saving 1,024 tokens was within the noise; with the window restored
    /// there is no replay to be noisy about, so the generic floor applies.
    static func minEffectiveTokens(
        capability: CBv2PrefixReuseCapability,
        adoptionBoundTokens: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        let configured = SSDPrefixCachePolicy.minEffectiveTokens(environment: environment)
        let bound = adoptionBoundTokens ?? capability.conservativeReplayBoundTokens
        let longHybridFloor =
            capability.strategy == .frozenFullReplay && bound >= 25_600 ? 1_536 : 0
        return max(configured, longHybridFloor)
    }

}
