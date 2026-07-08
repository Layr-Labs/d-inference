// Copyright © 2026 Eigen Labs.
//
// Env gates, budgets, and thresholds for the encrypted SSD KV-offload
// prefix cache (the v0.7.5 tier that replaces resident-RAM caching:
// donated KV is written to disk encrypted, RAM stays with live serving,
// matching prefixes are loaded back instead of recomputed).
//
// Everything here is PURE and unit-testable: environment, capacity, and
// clock are parameters with production defaults. Mode selection (which
// tier a slot runs) lives in `PrefixCachePolicy.mode` next to the master
// gate; this file owns the SSD-tier-specific knobs.
//
// Threat model: T-041 (the SSD tier reintroduces an at-rest artifact —
// leak #2 is closed by HMAC-keyed names, `SSDLookupKeys`; the 15-minute
// sliding TTL below bounds the at-rest window and the cross-restart
// TTFT-oracle window). SEC-035 stays the accepted residual.

import Foundation

enum SSDPrefixCachePolicy {

    // MARK: - TTL

    /// Sliding TTL override (seconds). Ship decision (Gaj, 2026-07-07):
    /// **15 minutes MAXIMUM**, sliding on hit — pairs with the
    /// coordinator's 10-minute cache-affinity routing window and bounds
    /// both the at-rest window and the cross-restart TTFT-oracle window
    /// (T-041). The env var can only SHORTEN the TTL; values ≤ 0, above
    /// the maximum, or malformed fall back to the 15-minute default.
    static let ttlEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS"
    static let maxTTLSeconds: Int64 = 900
    static let defaultTTLSeconds: Int64 = 900

    static func ttlSeconds(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int64 {
        guard let raw = environment[ttlEnvironmentFlag],
            let n = Int64(raw.trimmingCharacters(in: .whitespaces)), n > 0, n <= maxTTLSeconds
        else { return defaultTTLSeconds }
        return n
    }

    // MARK: - Endurance (daily write cap)

    /// Token-bucket cap on encrypted bytes written per day (endurance
    /// guard — the uncapped hot-box worst case is <6 months to rated wear
    /// on a 512 GB disk; at expected volumes this never binds). `0` ⇒
    /// unlimited; malformed/negative ⇒ default 150 GB/day.
    static let writeCapEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY"
    static let defaultMaxWriteBytesPerDay = 150 * 1_000_000_000

    static func maxWriteBytesPerDay(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment[writeCapEnvironmentFlag],
            let gb = Double(raw.trimmingCharacters(in: .whitespaces)),
            gb >= 0, gb.isFinite, gb < Double(Int.max) / 1_000_000_000
        else { return defaultMaxWriteBytesPerDay }
        return Int(gb * 1_000_000_000)  // 0 ⇒ unlimited
    }

    // MARK: - Adoption benefit gate

    /// Minimum effective tokens (matched − recompute bound) for staging to
    /// pay off — below this the stage I/O costs more than the recompute it
    /// saves on a fast box (spec §7: 1,024 is the first
    /// net-positive-everywhere size).
    static let minEffectiveTokensFlag = "DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS"
    static let defaultMinEffectiveTokens = 1024

    static func minEffectiveTokens(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment[minEffectiveTokensFlag],
            let n = Int(raw.trimmingCharacters(in: .whitespaces)), n > 0
        else { return defaultMinEffectiveTokens }
        return n
    }

    /// Per-adoption staged-bytes cap (bounds the transient staging RAM and
    /// the pre-submit read).
    static let maxStageMBFlag = "DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB"
    static let defaultMaxStageBytes = 1024 * 1_048_576  // 1 GiB

    static func maxStageBytes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment[maxStageMBFlag],
            let mb = Int(raw.trimmingCharacters(in: .whitespaces)), mb > 0,
            mb < Int.max / 1_048_576
        else { return defaultMaxStageBytes }
        return mb * 1_048_576
    }

    /// Skip adoption when the ESTIMATED stage time (at the conservative
    /// pipeline rate below) exceeds this — TTFT-deadline interplay
    /// (spec §6/§7): staging happens before `engine.submit`, so it must
    /// never eat a meaningful slice of the coordinator dispatch deadline.
    static let maxStageMillisFlag = "DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MS"
    static let defaultMaxStageMillis = 1000

    static func maxStageMillis(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment[maxStageMillisFlag],
            let ms = Int(raw.trimmingCharacters(in: .whitespaces)), ms > 0
        else { return defaultMaxStageMillis }
        return ms
    }

    /// Conservative end-to-end read+decrypt planning rate (read and decrypt
    /// serialized on one core; typical overlapped rate is ~2×).
    static let conservativeStageBytesPerSecond: Double = 1_500_000_000

    /// Estimated stage time for `bytes` at the conservative rate.
    static func estimatedStageMillis(bytes: Int) -> Int {
        guard bytes > 0 else { return 0 }
        return Int((Double(bytes) / conservativeStageBytesPerSecond) * 1000.0)
    }

    // MARK: - Low-disk guard

    /// Writes stop when volume free space drops under
    /// `max(20 GiB, 5% of capacity)`. Reads are unaffected.
    static let lowDiskAbsoluteFloorBytes = 20 * 1_073_741_824
    static let lowDiskCapacityFraction = 0.05

    static func lowDiskFloorBytes(volumeCapacityBytes: Int) -> Int {
        let fromFraction = Int(Double(max(0, volumeCapacityBytes)) * lowDiskCapacityFraction)
        return max(lowDiskAbsoluteFloorBytes, fromFraction)
    }

    /// Cooldown after an ENOSPC mid-write before writes are retried.
    static let enospcCooldownSeconds: Int64 = 600

    // MARK: - Durability

    /// Per-file F_FULLFSYNC is OFF by default for the SSD tier (deviation
    /// from the legacy store, spec §4.5): a best-effort cache doesn't need
    /// power-loss durability — GCM auth catches torn/lost writes and the
    /// reader deletes bad files — and skipping the flush saves ~2–15 ms
    /// per block write plus real flash wear.
    static let strictFsyncFlag = "DARKBLOOM_PREFIX_CACHE_SSD_STRICT_FSYNC"

    static func strictFsync(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let v = environment[strictFsyncFlag]?
            .trimmingCharacters(in: .whitespaces).lowercased()
        return v == "1" || v == "true" || v == "yes" || v == "on"
    }

    // MARK: - Write-behind bounds

    /// Max donation jobs buffered behind the serial write-behind consumer
    /// (the CheckpointCapturePipeline in-flight cap pattern). Overflow
    /// DROPS the donation — the engine is never back-pressured.
    static let writeQueueMaxJobs = 2
    /// Max host bytes queued across buffered donation jobs.
    static let writeQueueMaxBytes = 512 * 1_048_576
}
