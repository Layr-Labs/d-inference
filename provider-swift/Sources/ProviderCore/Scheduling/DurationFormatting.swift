import Foundation

/// Single source of truth for human-readable elapsed-time strings.
///
/// The provider historically grew several near-identical `formatDuration`
/// helpers that diverged in subtle, user-visible ways (download progress shows
/// seconds in the minute range; idle/status logs use the compact `2h30m` form;
/// the scheduler uses the spaced `2h 30m` form; some elide a trailing zero
/// minutes, some don't). This consolidates the logic into one function whose
/// flags reproduce each of those styles exactly, so call sites keep their
/// existing output while the formatting lives in one place.
public enum DurationFormatting {

    /// Format a non-negative duration in seconds as `Ns` / `Mm` / `Hh`,
    /// optionally with finer components.
    ///
    /// - Parameters:
    ///   - seconds: elapsed seconds (clamped at 0; fractional part dropped).
    ///   - secondsInMinuteRange: when in `[60, 3600)`, append `Ss` (e.g.
    ///     `30m 15s`) instead of just `Mm`.
    ///   - spaced: separate hour/minute (and minute/second) components with a
    ///     space (`2h 30m`) vs concatenated (`2h30m`).
    ///   - elideZeroMinutesInHourRange: when `>= 3600` and the minute component
    ///     is zero, render `2h` instead of `2h 0m`.
    public static func compact(
        _ seconds: Double,
        secondsInMinuteRange: Bool = false,
        spaced: Bool = true,
        elideZeroMinutesInHourRange: Bool = true
    ) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }

        let separator = spaced ? " " : ""

        if total < 3600 {
            let minutes = total / 60
            if secondsInMinuteRange {
                return "\(minutes)m\(separator)\(total % 60)s"
            }
            return "\(minutes)m"
        }

        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if elideZeroMinutesInHourRange && minutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h\(separator)\(minutes)m"
    }
}
