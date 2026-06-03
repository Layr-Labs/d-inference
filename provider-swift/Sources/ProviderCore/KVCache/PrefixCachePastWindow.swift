/// PrefixCachePastWindow — phase P1 helper for the past-window lift
/// (TB-016 sub-feature A). Determines whether a given model
/// architecture's KV restore past the sliding window has been PROVEN
/// bit-exact (via tests like `gemma4RestoreMatchesColdPastWindow`).
///
/// Only proven families are eligible for the coarse past-window ladder
/// extension (2048, 4096, 8192, 16384, 32768). Unproven families
/// (GPT-OSS's 128 window genuinely discards) keep the existing
/// within-window-only ladder.

import Foundation

public enum PrefixCachePastWindow {

    /// Returns true if the given model architecture string (e.g.,
    /// "gemma", "Gemma", "gemma2", "GEMMA") has been proven to
    /// restore KV state bit-exactly past the sliding window. The check
    /// is case-insensitive and matches any string containing "gemma".
    ///
    /// Default: false (safe; unproven models keep today's ladder).
    public static func isProven(arch: String) -> Bool {
        arch.lowercased().contains("gemma")
    }
}
