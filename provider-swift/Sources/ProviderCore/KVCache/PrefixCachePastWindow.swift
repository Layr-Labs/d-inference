/// PrefixCachePastWindow — phase P1 helper for the past-window lift
/// (TB-016 sub-feature A). Determines whether a given model
/// architecture's KV restore past the sliding window has been PROVEN
/// bit-exact (via tests like `gemma4RestoreMatchesColdPastWindow` /
/// `gptOssRestoreMatchesColdPastWindow`).
///
/// Only proven families are eligible for the coarse past-window ladder
/// extension (2048, 4096, 8192, 16384, 32768). Unproven families keep the
/// within-window-only ladder (safe default).

import Foundation

public enum PrefixCachePastWindow {

    /// Architecture-string substrings (lowercased) whose past-window KV restore
    /// has been PROVEN bit-exact on real weights:
    ///   - "gemma": gemma4RestoreMatchesColdPastWindow (L=2048,4096 > 1024 window)
    ///   - "gpt-oss"/"gptoss": gptOssRestoreMatchesColdPastWindow (L=256,512 > 128 window)
    /// Both use the same RotatingKVCache mechanism (full-attention layers retain
    /// all tokens; sliding layers keep their wrapped window), so the wrapped-
    /// ring-buffer restore is identical and verified for both.
    private static let provenSubstrings = ["gemma", "gpt-oss", "gptoss"]

    /// Returns true if the model architecture string has been proven to restore
    /// KV state bit-exactly past the sliding window. Case-insensitive substring
    /// match. Default: false (safe; unproven models keep the within-window ladder).
    public static func isProven(arch: String) -> Bool {
        let a = arch.lowercased()
        return provenSubstrings.contains { a.contains($0) }
    }
}
