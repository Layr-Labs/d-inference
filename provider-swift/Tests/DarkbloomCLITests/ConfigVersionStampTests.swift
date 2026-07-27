import Foundation
import ProviderCore
import Testing
@testable import darkbloom

/// The durable half of the v0.8.0 concurrency default.
///
/// `ProviderConfig.init(from:)` raises a pre-v0.8.0 generated
/// `engine_v2_max_concurrent = 4` to 8 in memory on every decode. That alone
/// would re-fire forever, so an operator who genuinely wants 4 could never
/// say so. The stamp written here is what ends the ambiguity: it dates the
/// file exactly once, after which 4 means 4.
@Suite("provider.toml config_version stamp")
struct ConfigVersionStampTests {

    private func withTempConfig(
        _ contents: String, _ body: (URL) throws -> Void
    ) throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-\(UUID().uuidString).toml")
        try contents.write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }
        try body(path)
    }

    private func read(_ path: URL) throws -> String {
        try String(contentsOf: path, encoding: .utf8)
    }

    /// What every pre-v0.8.0 `ConfigManager.save` produced: the concurrency
    /// key present and explicit, because `TOMLEncoder` emits every
    /// non-optional member.
    private let generated = """
        [provider]
        name = "test-provider"

        [backend]
        port = 8100
        engine_v2_max_concurrent = 4
        """

    @Test("a generated 4 is raised to 8 and the file is dated")
    func raisesGeneratedFour() throws {
        try withTempConfig(generated) { path in
            #expect(stampConfigVersion(in: path) == true)

            let text = try read(path)
            #expect(text.contains("engine_v2_max_concurrent = 8"))
            #expect(!text.contains("engine_v2_max_concurrent = 4"))
            #expect(text.hasPrefix("config_version = 1\n"))

            // And the file now decodes to the raised value with nothing left
            // to migrate.
            let config = try ConfigManager.load(from: path)
            #expect(config.backend.engineV2MaxConcurrent == 8)
            #expect(config.appliedMigrations.isEmpty)
        }
    }

    /// The stamp is unconditional on an undated file. If it only landed when
    /// the concurrency line changed, a config holding `= 6` would stay
    /// undated, and an operator later editing it to 4 would be migrated —
    /// silently overriding a choice they had just made.
    @Test("an undated file is dated even when no value needs raising")
    func datesFileWithNothingToRaise() throws {
        try withTempConfig(
            """
            [provider]
            name = "test-provider"

            [backend]
            engine_v2_max_concurrent = 6
            """
        ) { path in
            #expect(stampConfigVersion(in: path) == false)
            #expect(try read(path).hasPrefix("config_version = 1\n"))

            // The later hand-edit back to 4 now sticks.
            var text = try read(path)
            text = text.replacingOccurrences(
                of: "engine_v2_max_concurrent = 6", with: "engine_v2_max_concurrent = 4")
            try text.write(to: path, atomically: true, encoding: .utf8)

            let config = try ConfigManager.load(from: path)
            #expect(config.backend.engineV2MaxConcurrent == 4)
            #expect(config.appliedMigrations.isEmpty)
        }
    }

    @Test("a dated file is left completely alone")
    func secondPassIsANoOp() throws {
        try withTempConfig(generated) { path in
            _ = stampConfigVersion(in: path)
            let afterFirst = try read(path)

            #expect(stampConfigVersion(in: path) == false)
            #expect(try read(path) == afterFirst)
        }
    }

    /// "Already dated" is an ASSIGNMENT of `config_version`, not the three
    /// words appearing anywhere in the file. A pre-v0.8.0 config that merely
    /// MENTIONS the key — a comment about it, a commented-out stamp, or the
    /// name inside another key's value — is undated, and mistaking it for
    /// dated skips BOTH halves of the migration: the durable `4 -> 8`
    /// rewrite and the stamp. `ProviderConfig.init(from:)` still raises the
    /// value in memory, so the provider then runs at 8 while its file says
    /// 4, forever, and no later pass corrects it.
    @Test("a file that only mentions config_version in prose is not treated as dated")
    func mentionWithoutAssignmentIsNotAStamp() throws {
        let mentions = [
            // A comment about the key, which is exactly what an operator
            // reading the upgrade notes would paste above their config.
            """
            # config_version is written by the upgrade, do not hand-edit
            [provider]
            name = "test-provider"

            [backend]
            engine_v2_max_concurrent = 4
            """,
            // A commented-OUT stamp is not a stamp.
            """
            [provider]
            name = "test-provider"

            [backend]
            # config_version = 1
            engine_v2_max_concurrent = 4
            """,
            // The key named inside another key's value.
            """
            [provider]
            name = "config_version"

            [backend]
            engine_v2_max_concurrent = 4
            """,
        ]

        for contents in mentions {
            try withTempConfig(contents) { path in
                #expect(stampConfigVersion(in: path) == true)

                let text = try read(path)
                #expect(text.hasPrefix("config_version = 1\n"))
                #expect(text.contains("engine_v2_max_concurrent = 8"))
                #expect(!text.contains("engine_v2_max_concurrent = 4"))

                let config = try ConfigManager.load(from: path)
                #expect(config.backend.engineV2MaxConcurrent == 8)
                #expect(config.appliedMigrations.isEmpty)
            }
        }
    }

    /// The other direction: a real assignment is a stamp however it is
    /// spaced, so the detector must not be so narrow that an indented or
    /// loosely-spaced stamp gets a second one prepended.
    @Test("an indented or loosely-spaced assignment counts as dated")
    func spacingVariantsCountAsDated() throws {
        for stamp in ["  config_version = 1", "config_version=1", "config_version\t=\t1"] {
            try withTempConfig(
                """
                \(stamp)
                [provider]
                name = "test-provider"

                [backend]
                engine_v2_max_concurrent = 4
                """
            ) { path in
                #expect(stampConfigVersion(in: path) == false)
                let text = try read(path)
                #expect(text.contains("engine_v2_max_concurrent = 4"))
                #expect(!text.hasPrefix("config_version = 1\n\(stamp)"))
            }
        }
    }

    /// Why this is text surgery and not a `ConfigManager.save` round-trip:
    /// the encoder would drop both of these, and startup still needs the
    /// retired key present in order to warn about it.
    @Test("operator comments and retired keys survive the rewrite")
    func preservesCommentsAndRetiredKeys() throws {
        try withTempConfig(
            """
            # hand-tuned for the rack, do not clobber
            [provider]
            name = "test-provider"

            [backend]
            kv_quant = true  # retired, still warned about
            engine_v2_max_concurrent = 4
            """
        ) { path in
            #expect(stampConfigVersion(in: path) == true)

            let text = try read(path)
            #expect(text.contains("# hand-tuned for the rack, do not clobber"))
            #expect(text.contains("kv_quant = true"))
            #expect(text.contains("# retired, still warned about"))
            #expect(text.contains("engine_v2_max_concurrent = 8"))

            let config = try ConfigManager.load(from: path)
            #expect(config.backend.retiredKeysPresent == ["kv_quant"])
        }
    }

    /// The decode-time raise and the on-disk rewrite share one predicate
    /// (`LegacyConcurrencyMigration`), and this pins the case where they
    /// once disagreed: a trailing inline comment. The TOML decoder ignores
    /// comments, so boot 1 raised `4 # comment` to 8 in memory — but the
    /// old full-line regex never matched it, the stamp still landed, and
    /// boot 2+ honored the literal 4. The comment must also SURVIVE the
    /// rewrite: text surgery exists precisely to preserve operator prose.
    @Test(
        "a legacy 4 with a trailing inline comment is rewritten, comment preserved",
        arguments: [
            ("engine_v2_max_concurrent = 4 # upgraded from old default",
             "engine_v2_max_concurrent = 8 # upgraded from old default"),
            // Tab-separated comment, multiple spaces.
            ("engine_v2_max_concurrent = 4\t\t# tuned",
             "engine_v2_max_concurrent = 8\t\t# tuned"),
            ("engine_v2_max_concurrent = 4   ; semicolon prose",
             "engine_v2_max_concurrent = 8   ; semicolon prose"),
            // No comment at all — the original shape keeps working.
            ("engine_v2_max_concurrent = 4",
             "engine_v2_max_concurrent = 8"),
        ])
    func rewritesCommentedLegacyFour(line: String, want: String) throws {
        try withTempConfig(
            """
            [provider]
            name = "test-provider"

            [backend]
            \(line)
            """
        ) { path in
            #expect(stampConfigVersion(in: path) == true)
            let text = try read(path)
            #expect(text.contains(want))
            #expect(!text.contains(line) || line == want)
            #expect(text.hasPrefix("config_version = 1\n"))
        }
    }

    /// Both halves agree end to end on the comment shape: the decode of the
    /// STAMPED rewritten file yields 8 with nothing left to migrate — no
    /// more one-boot flip-flop.
    @Test("after the rewrite, a commented config decodes to 8 with no pending migration")
    func commentedRewriteDecodesCleanly() throws {
        try withTempConfig(
            """
            [provider]
            name = "test-provider"

            [backend]
            engine_v2_max_concurrent = 4  # upgraded from old default
            """
        ) { path in
            #expect(stampConfigVersion(in: path) == true)
            let config = try ConfigManager.load(from: path)
            #expect(config.backend.engineV2MaxConcurrent == 8)
            #expect(config.appliedMigrations.isEmpty)
        }
    }

    /// A post-stamp explicit 4 means 4 — comment or not. The stamp is what
    /// the one-time migration spent; nothing may re-raise after it.
    @Test("an explicit post-stamp 4 (with or without comment) is never raised")
    func postStampFourSticks() throws {
        for line in [
            "engine_v2_max_concurrent = 4",
            "engine_v2_max_concurrent = 4 # I really mean it",
        ] {
            try withTempConfig(
                """
                config_version = 1
                [provider]
                name = "test-provider"

                [backend]
                \(line)
                """
            ) { path in
                #expect(stampConfigVersion(in: path) == false)
                let text = try read(path)
                #expect(text.contains(line))
                let config = try ConfigManager.load(from: path)
                #expect(config.backend.engineV2MaxConcurrent == 4)
                #expect(config.appliedMigrations.isEmpty)
            }
        }
    }

    /// Only the exact legacy value is rewritten: `4` with a comment is, but
    /// `42`, `14`, or an operator's `6 # note` are not — no release ever
    /// generated those, so they are choices.
    @Test("non-4 values are untouched, commented or not")
    func nonFourValuesUntouched() throws {
        for line in [
            "engine_v2_max_concurrent = 42",
            "engine_v2_max_concurrent = 14 # not a legacy 4",
            "engine_v2_max_concurrent = 6 # chosen",
        ] {
            try withTempConfig(
                """
                [provider]
                name = "test-provider"

                [backend]
                \(line)
                """
            ) { path in
                // The stamp still lands (undated file), but nothing is raised.
                #expect(stampConfigVersion(in: path) == false)
                let text = try read(path)
                #expect(text.contains(line))
            }
        }
    }

    /// The rewrite is anchored to a whole assignment line, so neither the
    /// `..._by_model` table header nor a 4 inside it can be caught by it.
    @Test("the per-model override table is never rewritten")
    func leavesPerModelOverridesAlone() throws {
        try withTempConfig(
            """
            [provider]
            name = "test-provider"

            [backend]
            engine_v2_max_concurrent = 4

            [backend.engine_v2_max_concurrent_by_model]
            "gemma-4-26b-qat-4bit" = 4
            """
        ) { path in
            #expect(stampConfigVersion(in: path) == true)

            let config = try ConfigManager.load(from: path)
            #expect(config.backend.engineV2MaxConcurrent == 8)
            // The operator named this model and this cap explicitly. Per-model
            // entries were never generated, so they are never ambiguous.
            #expect(config.backend.engineV2MaxConcurrentByModel == ["gemma-4-26b-qat-4bit": 4])
        }
    }

    @Test("an absent file is not created")
    func missingFileIsNotCreated() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-\(UUID().uuidString).toml")
        #expect(stampConfigVersion(in: path) == false)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
}
