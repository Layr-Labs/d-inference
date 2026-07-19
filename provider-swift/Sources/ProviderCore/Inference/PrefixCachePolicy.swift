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
    /// before cache construction. `.auto` is the shipped contiguous,
    /// unquantized native-float backend. Explicit paged selection remains eligible only for layouts
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

    /// Conservative finite-window replay length. Kept as a policy convenience
    /// for SSD donation/stage benefit gates; the engine plan remains
    /// authoritative per matched boundary.
    static func adoptionBoundTokens(layerKinds: [CBv2LayerKind]) -> Int {
        CBv2PrefixReuseCapability.derive(
            layerKinds: layerKinds,
            backend: .contiguousUnquantized
        ).conservativeReplayBoundTokens
    }

    /// Real Gemma QAT evidence is noisy/negative at only 1,024 saved tokens
    /// and positive from 1,536 onward; GPT's shorter 1,536-token replay span
    /// remains beneficial at the generic 1,024 floor. The environment may
    /// raise either floor but cannot lower the proved long-hybrid minimum.
    static func minEffectiveTokens(
        capability: CBv2PrefixReuseCapability,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        let configured = SSDPrefixCachePolicy.minEffectiveTokens(environment: environment)
        let longHybridFloor =
            capability.strategy == .frozenFullReplay
                && capability.conservativeReplayBoundTokens >= 25_600
            ? 1_536 : 0
        return max(configured, longHybridFloor)
    }

}
