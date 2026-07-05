import Foundation

/// Rollover jitter for background auto-updates.
///
/// A release used to restart the whole fleet in near-unison: every provider's
/// 30-minute update tick discovered the release within the same window (ticks
/// align after any previous synchronized restart), so every box drained and
/// restarted together and the entire fleet was cold at once — the
/// first_chunk_timeout storm. A uniformly-random delay before the
/// drain+install step decorrelates the restarts.
///
/// Placement matters: the delay sits strictly AFTER the download + signature
/// verification (the bundle is already verified and staged) and BEFORE the
/// drain begins, so the provider keeps serving normally while it waits and no
/// security-critical check is deferred. Forced/manual updates
/// (`darkbloom update`, the startup update check) never call this — they stay
/// immediate.
public enum UpdateJitter {

    /// Sanity ceiling: a misconfigured `update_jitter_seconds` can never delay
    /// an update by more than an hour.
    public static let maxJitterCapSeconds: UInt64 = 3600

    /// Pick a uniformly-random delay in `[0, maxSeconds]` (millisecond
    /// granularity). Returns `.zero` when jitter is disabled (`maxSeconds ==
    /// 0`) or the update is forced (manual/startup paths).
    public static func delay(maxSeconds: UInt64, forced: Bool = false) -> Duration {
        var rng = SystemRandomNumberGenerator()
        return delay(maxSeconds: maxSeconds, forced: forced, using: &rng)
    }

    /// RNG-injectable variant for deterministic tests.
    public static func delay(
        maxSeconds: UInt64,
        forced: Bool = false,
        using rng: inout some RandomNumberGenerator
    ) -> Duration {
        guard !forced, maxSeconds > 0 else { return .zero }
        let capped = min(maxSeconds, maxJitterCapSeconds)
        let millis = Int64.random(in: 0...(Int64(capped) * 1000), using: &rng)
        return .milliseconds(millis)
    }
}
