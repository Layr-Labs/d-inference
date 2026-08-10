import Foundation
import TOMLKit

/// One `provider.toml` schema upgrade: a `config_version` bump plus, for
/// exactly ONE cap value, a rewrite of `engine_v2_max_concurrent`.
///
/// A step is a historical fact, so `fromCap`/`toCap`/`id` are literals rather
/// than references to the current default constant. The link to today's policy
/// is asserted instead — the newest step must land on
/// ``BackendSettings/defaultEngineV2MaxConcurrent`` — so that changing the
/// default without adding a step fails a test instead of silently shipping a
/// fleet-wide no-op.
public struct ConcurrencyMigrationStep: Sendable, Equatable {
    /// The `config_version` on disk that this step upgrades FROM.
    public let fromVersion: Int
    /// The stamp the file carries once the step has run.
    public let toVersion: Int
    /// The EXACT cap this step rewrites. Any other value is an operator
    /// choice and is left alone — the `migrate_exact_value` discipline.
    public let fromCap: UInt64
    /// The cap `fromCap` becomes.
    public let toCap: UInt64
    /// Stable id, surfaced through ``ProviderConfig/appliedMigrations`` and
    /// keyed on by `RetiredKnobWarnings` to explain the change to operators.
    public let id: String
}

/// The `engine_v2_max_concurrent` default-migration ladder, owned in ONE place
/// because it has two halves that execute from two different representations
/// and drifted apart exactly once:
///
///   * the decode-time value change (`ProviderConfig.init(from:)`) keys on the
///     DECODED cap — the TOML parser has already thrown comments away;
///   * the on-disk rewrite (`migrateConfigSchema` in the CLI) is text surgery
///     on the raw assignment line, and its old regex required line-end
///     immediately after the value.
///
/// So `engine_v2_max_concurrent = 4 # upgraded from old default` was migrated
/// in memory on boot 1 but never rewritten on disk; the stamp still landed, and
/// from boot 2 the literal was honored again — a silent one-boot flip-flop.
/// Both halves now resolve "does a step apply to this file?" through this type,
/// so a change to one cannot silently miss the other.
///
/// # Why a literal on disk needs a migration at all
///
/// `TOMLEncoder` emits every non-optional `CodingKeys` member, so every
/// `provider.toml` `ConfigManager.save` ever wrote carries an EXPLICIT
/// `engine_v2_max_concurrent = <n>`. Unlike `engine_v2_kv_backend`, which is
/// stored as `"auto"` and therefore tracks the binary, a literal does NOT move
/// when the default constant moves. Changing
/// ``BackendSettings/defaultEngineV2MaxConcurrent`` without a step here reaches
/// only fresh installs and is a no-op on the entire existing fleet.
public enum ConcurrencyDefaultMigration {

    /// v0.8.1: the box-wide default returns to 4.
    ///
    /// v0.8.0 raised it 4 -> 8 because PagedAttention made the batch curve keep
    /// climbing — paged gains 1.27x from B=4 to B=8, where contiguous gains
    /// 1.069x, which the gate report calls "within noise of not paying at all"
    /// (`docs/reports/2026-07-25-paged-gate-results.md`, G0b). v0.8.1 reverts
    /// the paged default, so the raise loses the measurement that justified it.
    ///
    /// 4 is the knee of the measured CONTIGUOUS curve, not a round number:
    /// aggregate is flat from B=4 to B=8 (197.5 / 194.3 / 186.1 / 199.7 /
    /// 211.1 tok/s) and collapses below it (B=3 is -7.5%, B=2 is -41%), while
    /// per-request decode is aggregate/B and therefore improves ~linearly as B
    /// falls through that flat region. B=4 measures better than B=5, 6 and 7 on
    /// BOTH axes, which is why the default is 4 and not the 5 originally
    /// proposed.
    ///
    /// UNLIKE the 4 -> 8 step this replaces, the discriminator here is NOT
    /// clean, and that is a deliberate, accepted cost rather than an oversight.
    /// The old step keyed on the ABSENCE of a stamp, and no release before
    /// v0.8.0 ever generated any value but 4, so an operator's choice was
    /// structurally out of reach. Here a `config_version = 1` file holding
    /// `engine_v2_max_concurrent = 8` is byte-identical whether v0.8.0
    /// GENERATED that 8 or an operator read the v0.8.0 notes and typed it
    /// deliberately — v0.8.0's own migration wrote a durable 8. This step
    /// therefore resets a deliberate 8 unless the box also explicitly selects
    /// paged, the one distinguishable posture where B=8 remains the measured
    /// optimum. The exact-value match protects every other cap, the startup
    /// warning announces a migrated 8, and the version-2 stamp spends the
    /// evidence once — from it on, 8 means 8.
    public static let v081ConcurrencyRevert = ConcurrencyMigrationStep(
        fromVersion: 1,
        toVersion: 2,
        fromCap: 8,
        toCap: 4,
        id: "engine_v2_max_concurrent:8->4")

    /// Every cap-bearing step, ordered oldest first. Selection chains on the
    /// running version, so a file several versions behind is carried all the
    /// way forward in a single pass rather than one step per boot.
    ///
    /// The pre-v0.8.0 `4 -> 8` step is deliberately absent: v0.8.1's default IS
    /// 4, so it became an identity in value, and keeping it would have made the
    /// startup WARN and the on-disk rewrite both claim a change that did not
    /// happen. An unstamped file now keeps its literal cap and is simply dated
    /// (see ``migrate(content:)``), which also means a pre-v0.8.0 operator's
    /// deliberate 4 is finally honored instead of being raised once.
    public static let steps: [ConcurrencyMigrationStep] = [v081ConcurrencyRevert]

    /// Look a step up by the id carried in ``ProviderConfig/appliedMigrations``.
    public static func step(id: String) -> ConcurrencyMigrationStep? {
        steps.first { $0.id == id }
    }

    // MARK: - Decode-time half

    /// The cap a decoded config should serve, given the stamp, cap, and
    /// box-wide KV backend actually on disk, plus the steps that were applied
    /// to get there.
    ///
    /// Chains: each step whose `fromVersion` matches the running version
    /// advances it, and rewrites the cap only when the cap also matches
    /// exactly. A step whose version matches but whose cap does not still
    /// advances the version — the file IS that schema generation, it just holds
    /// an operator value that generation must not touch. Explicit paged keeps
    /// B=8 because that backend's measured batch curve still justifies it.
    public static func resolvedCap(
        onDiskVersion: Int?, cap: UInt64, kvBackend: String
    ) -> (cap: UInt64, applied: [ConcurrencyMigrationStep]) {
        var running = onDiskVersion
        var value = cap
        var applied: [ConcurrencyMigrationStep] = []
        let preservesPagedCap = isExplicitPaged(kvBackend)
        for step in steps where step.fromVersion == running {
            running = step.toVersion
            guard !preservesPagedCap, value == step.fromCap else { continue }
            value = step.toCap
            applied.append(step)
        }
        return (value, applied)
    }

    // MARK: - On-disk half

    /// The outcome of migrating one `provider.toml`'s TEXT.
    public struct Outcome: Sendable, Equatable {
        /// The file's new contents.
        public let text: String
        /// The cap-bearing steps applied. Empty when only the stamp moved.
        public let applied: [ConcurrencyMigrationStep]
    }

    private struct MigrationDocument: Decodable {
        struct Backend: Decodable {
            let kvBackend: String?

            enum CodingKeys: String, CodingKey {
                case kvBackend = "engine_v2_kv_backend"
            }
        }

        let backend: Backend?
    }

    private static func preservesExplicitPagedCap(in content: String) -> Bool {
        guard
            let document = try? TOMLDecoder().decode(
                MigrationDocument.self, from: content)
        else { return false }
        return isExplicitPaged(document.backend?.kvBackend)
    }

    private static func isExplicitPaged(_ value: String?) -> Bool {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "paged"
    }

    /// Detects a `config_version` ASSIGNMENT — line-anchored, so a `#` comment
    /// about the key, a commented-OUT stamp, or the name inside another key's
    /// value is not mistaken for one. Substring-matching the key instead read
    /// such a file as already dated and skipped the migration entirely, while
    /// the decode-time half kept changing the value in memory on every boot.
    ///
    /// Deliberately looser than ``versionAssignmentPattern``: ANY assignment
    /// counts as "already stamped" for the purpose of not prepending a second
    /// one, even if its value does not parse.
    static let versionAssignmentProbe = #"(?m)^[ \t]*config_version[ \t]*="#

    /// The same assignment with its value captured, for reading and rewriting
    /// the stamp in place. Group 1 is everything up to the digits, group 2 the
    /// digits, group 3 any trailing inline comment.
    static let versionAssignmentPattern =
        #"(?m)^([ \t]*config_version[ \t]*=[ \t]*)(\d+)((?:[ \t]*[#;].*)?)[ \t]*$"#

    /// Matches ONLY a whole `engine_v2_max_concurrent` assignment line holding
    /// a TOML integer — anchored to the full line so it cannot touch
    /// `[backend.engine_v2_max_concurrent_by_model]` or a number inside it.
    /// Group 1 is indentation, group 2 is the integer token, and group 3 is an
    /// optional trailing inline comment. The token accepts every TOML integer
    /// spelling that can encode the generated cap (`+8`, `0x8`, `0o10`,
    /// `0b1000`, and underscore-separated digits), so the text rewrite cannot
    /// disagree with the decoder's semantic UInt64 value.
    static let assignmentPattern =
        #"(?m)^([ \t]*)engine_v2_max_concurrent[ \t]*=[ \t]*([+-]?(?:0[xX][0-9A-Fa-f](?:_?[0-9A-Fa-f])*|0[oO][0-7](?:_?[0-7])*|0[bB][01](?:_?[01])*|[0-9](?:_?[0-9])*))((?:[ \t]*[#;].*)?)[ \t]*$"#

    /// Bring `content` up to ``ProviderConfig/currentConfigVersion``.
    ///
    /// Returns nil — meaning "write nothing" — when the file is already
    /// current, when it is stamped with a version this binary does not
    /// understand (never downgrade a file a NEWER release wrote), or when it
    /// carries a stamp whose value does not parse (prepending a second one
    /// would produce a duplicate key and break the file outright).
    ///
    /// An unstamped file is dated but never value-migrated. It predates
    /// v0.8.0, so any cap it holds is either the 4 that release generated —
    /// which is v0.8.1's default anyway — or a value a human typed. Stamping
    /// straight to the current version is what makes a later hand-edit stick.
    public static func migrate(content: String) -> Outcome? {
        let current = ProviderConfig.currentConfigVersion

        guard content.range(of: versionAssignmentProbe, options: .regularExpression) != nil
        else {
            // A top-level key is legal only ahead of the first table header,
            // and position 0 always satisfies that.
            return Outcome(text: "config_version = \(current)\n" + content, applied: [])
        }

        guard let onDiskVersion = stampedVersion(in: content), onDiskVersion < current
        else { return nil }

        var text = content
        var running = onDiskVersion
        var applied: [ConcurrencyMigrationStep] = []
        let preservesPagedCap = preservesExplicitPagedCap(in: content)
        for step in steps where step.fromVersion == running {
            running = step.toVersion
            guard !preservesPagedCap,
                let rewritten = rewriteAssignment(
                    in: text, from: step.fromCap, to: step.toCap)
            else { continue }
            text = rewritten
            applied.append(step)
        }

        guard let restamped = rewriteStamp(in: text, to: current) else { return nil }
        return Outcome(text: restamped, applied: applied)
    }

    /// The `config_version` value on disk, or nil when absent/unparseable.
    static func stampedVersion(in content: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: versionAssignmentPattern) else {
            return nil
        }
        let full = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: full),
            let digits = Range(match.range(at: 2), in: content)
        else { return nil }
        return Int(content[digits])
    }

    /// Rewrite an existing stamp's value in place, preserving indentation and
    /// any trailing inline comment. Nil when there is no parseable stamp.
    ///
    /// This is the half the v0.8.0 mechanism never had: it only ever PREPENDED
    /// a stamp to an unstamped file and bailed the moment one was present, so
    /// reusing it for a second migration would have been a silent no-op across
    /// the whole already-stamped fleet.
    static func rewriteStamp(in content: String, to version: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: versionAssignmentPattern) else {
            return nil
        }
        let full = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: full),
            let lineRange = Range(match.range(at: 0), in: content)
        else { return nil }
        let group = captureReader(match: match, in: content)
        var rewritten = content
        rewritten.replaceSubrange(lineRange, with: group(1) + "\(version)" + group(3))
        return rewritten
    }

    /// Rewrite a `engine_v2_max_concurrent = from` line to `to`, preserving
    /// indentation and any trailing inline comment. Nil when no such
    /// assignment is present (different value, already rewritten, or the key is
    /// absent) — the caller's signal that only the stamp needs to move.
    static func rewriteAssignment(in content: String, from: UInt64, to: UInt64) -> String? {
        guard let regex = try? NSRegularExpression(pattern: assignmentPattern) else {
            return nil
        }
        let full = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: full),
            let lineRange = Range(match.range(at: 0), in: content)
        else { return nil }
        let group = captureReader(match: match, in: content)
        guard parseTOMLUnsignedInteger(group(2)) == from else { return nil }
        var rewritten = content
        rewritten.replaceSubrange(
            lineRange, with: group(1) + "engine_v2_max_concurrent = \(to)" + group(3))
        return rewritten
    }

    private static func parseTOMLUnsignedInteger(_ token: Substring) -> UInt64? {
        var literal = String(token).replacingOccurrences(of: "_", with: "")
        guard !literal.hasPrefix("-") else { return nil }
        if literal.hasPrefix("+") {
            literal.removeFirst()
        }

        let lower = literal.lowercased()
        let radix: Int
        let digits: Substring
        if lower.hasPrefix("0x") {
            radix = 16
            digits = literal.dropFirst(2)
        } else if lower.hasPrefix("0o") {
            radix = 8
            digits = literal.dropFirst(2)
        } else if lower.hasPrefix("0b") {
            radix = 2
            digits = literal.dropFirst(2)
        } else {
            radix = 10
            digits = literal[...]
            guard digits.count == 1 || digits.first != "0" else { return nil }
        }
        return UInt64(digits, radix: radix)
    }

    /// Capture-group text, empty for groups that did not participate.
    private static func captureReader(
        match: NSTextCheckingResult, in content: String
    ) -> (Int) -> Substring {
        { index in
            Range(match.range(at: index), in: content).map { content[$0] } ?? ""
        }
    }
}
