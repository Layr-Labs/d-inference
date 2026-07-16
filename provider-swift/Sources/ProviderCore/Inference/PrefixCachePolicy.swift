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

    // MARK: - SSD adoption bound

    /// Whether the engine can resume from a partial layer snapshot without
    /// changing model outputs. A storage-owning full-attention layer after any
    /// sliding-window layer permanently caches activations computed from an
    /// incomplete replay window, so `cbv2RequiredRecompute` correctly requires
    /// full replay for that layout. Advertising reusable SSD evidence for such
    /// a model would be false: staging can match bytes but save zero prefill.
    static func supportsReusablePrefixes(layerKinds: [CBv2LayerKind]) -> Bool {
        var sawWindowedLayer = false
        for kind in layerKinds {
            if case .slidingWindow = kind.attention {
                sawWindowedLayer = true
            } else if sawWindowedLayer, kind.sharesKVWithLayer == nil {
                return false
            }
        }
        return true
    }

    /// The model's adoption bound: `windowCount × maxWindow` over its layer
    /// kinds for layouts that pass `supportsReusablePrefixes`. 0 for pure
    /// full-attention models (every whole-block hit is adoptable).
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

}
