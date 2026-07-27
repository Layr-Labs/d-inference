import Foundation

/// The one-time pre-v0.8.0 `engine_v2_max_concurrent` 4 → 8 migration,
/// owned in ONE place because it has two halves that executed from two
/// different representations and drifted apart exactly once:
///
///   * the decode-time raise (`ProviderConfig.init(from:)`) keys on the
///     DECODED value — the TOML parser has already thrown comments away;
///   * the on-disk rewrite (`stampConfigVersion` in the CLI) is text
///     surgery on the raw assignment line, and its old regex required
///     line-end immediately after the `4`.
///
/// So `engine_v2_max_concurrent = 4 # upgraded from old default` was raised
/// in memory on boot 1 (serving B=8) but never rewritten on disk; the stamp
/// still landed, and from boot 2 the literal 4 was honored — a silent
/// one-boot flip-flop that under-delivered the release's throughput on that
/// box. Both halves now resolve "is this the legacy generated assignment?"
/// through this type, so a change to one cannot silently miss the other.
public enum LegacyConcurrencyMigration {

    /// The shared predicate: an UNSTAMPED config (`config_version` absent
    /// on disk) whose cap equals the value old releases generated is
    /// migrated. A stamped file is never touched — post-stamp, 4 means 4 —
    /// and no release ever generated any other value, so operator-chosen
    /// caps are structurally out of reach.
    public static func shouldRaise(onDiskVersion: Int?, cap: UInt64) -> Bool {
        onDiskVersion == nil && cap == BackendSettings.legacyGeneratedMaxConcurrent
    }

    /// Matches ONLY a whole legacy assignment line — anchored to the full
    /// line so it cannot touch `[backend.engine_v2_max_concurrent_by_model]`
    /// or a `4` inside it. Captures:
    ///   1. the line's leading indentation, and
    ///   2. an optional trailing inline comment with its leading whitespace
    ///      (`#` per TOML; `;` accepted too since a file carrying one never
    ///      parses anyway and rewriting it loses nothing),
    /// so the rewrite preserves both. The value is interpolated from the
    /// same constant the decode-time predicate compares against.
    static var legacyAssignmentPattern: String {
        #"(?m)^([ \t]*)engine_v2_max_concurrent[ \t]*=[ \t]*"#
            + "\(BackendSettings.legacyGeneratedMaxConcurrent)"
            + #"((?:[ \t]*[#;].*)?)[ \t]*$"#
    }

    /// Rewrite the legacy assignment in `content` to the current default,
    /// preserving indentation and any trailing inline comment. Returns nil
    /// when no legacy assignment is present (different value, already
    /// rewritten, or the key is absent) — the caller's signal that the
    /// stamp alone is needed.
    ///
    /// The caller owns the "is the file unstamped?" half of the predicate
    /// (`stampConfigVersion` checks `config_version` before calling); this
    /// half is the value match, same as `shouldRaise`'s `cap` comparison.
    public static func rewriteAssignment(in content: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: legacyAssignmentPattern) else {
            return nil
        }
        let full = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: full),
            let lineRange = Range(match.range(at: 0), in: content)
        else { return nil }

        let group: (Int) -> Substring = { index in
            Range(match.range(at: index), in: content).map { content[$0] } ?? ""
        }
        let replacement = group(1)
            + "engine_v2_max_concurrent = \(BackendSettings.defaultEngineV2MaxConcurrent)"
            + group(2)
        var rewritten = content
        rewritten.replaceSubrange(lineRange, with: replacement)
        return rewritten
    }
}
