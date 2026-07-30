import Foundation
import ProviderCore
import Testing
@testable import darkbloom

/// The durable half of the v0.8.1 concurrency default.
///
/// `ProviderConfig.init(from:)` changes a v0.8.0-generated
/// `engine_v2_max_concurrent = 8` to 4 in memory on every decode. That alone
/// would re-fire forever, so an operator who genuinely wants 8 could never say
/// so. The `config_version` bump written here is what ends the ambiguity: it
/// re-dates the file exactly once, after which 8 means 8.
///
/// The v0.8.0 mechanism could not be reused for this. It keyed on the ABSENCE
/// of a stamp and bailed the moment one was present, and every box that booted
/// v0.8.0 is stamped — so copying that pattern would have been a silent no-op
/// across the entire fleet. These tests pin the in-place restamp that replaces
/// it.
@Suite("provider.toml config_version migration")
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

    /// What every v0.8.0 `ConfigManager.save` produced: the stamp and the
    /// concurrency key both present and explicit, because `TOMLEncoder` emits
    /// every non-optional member.
    private let generated = """
        config_version = 1
        [provider]
        name = "test-provider"

        [backend]
        port = 8100
        engine_v2_max_concurrent = 8
        """

    @Test("a generated 8 becomes 4 and the file is re-dated to 2")
    func migratesGeneratedEight() throws {
        try withTempConfig(generated) { path in
            let applied = migrateConfigSchema(in: path)
            #expect(applied == [ConcurrencyDefaultMigration.v081ConcurrencyRevert])

            let text = try read(path)
            #expect(text.contains("engine_v2_max_concurrent = 4"))
            #expect(!text.contains("engine_v2_max_concurrent = 8"))
            #expect(text.hasPrefix("config_version = 2\n"))
            // Re-dated in place, not stacked: a second stamp line would be a
            // duplicate key and would not parse.
            #expect(!text.contains("config_version = 1"))

            // And the file now decodes to the migrated value with nothing left
            // to migrate.
            let config = try ConfigManager.load(from: path)
            #expect(config.backend.engineV2MaxConcurrent == 4)
            #expect(config.appliedMigrations.isEmpty)
        }
    }

    /// The re-stamp is unconditional on an out-of-date file. If it only landed
    /// when the concurrency line changed, a config holding `= 6` would stay at
    /// version 1, and an operator later editing it to 8 would be migrated —
    /// silently overriding a choice they had just made.
    @Test("an out-of-date file is re-dated even when no value needs migrating")
    func redatesFileWithNothingToMigrate() throws {
        try withTempConfig(
            """
            config_version = 1
            [provider]
            name = "test-provider"

            [backend]
            engine_v2_max_concurrent = 6
            """
        ) { path in
            #expect(migrateConfigSchema(in: path).isEmpty)
            #expect(try read(path).hasPrefix("config_version = 2\n"))

            // The later hand-edit to 8 now sticks.
            var text = try read(path)
            text = text.replacingOccurrences(
                of: "engine_v2_max_concurrent = 6", with: "engine_v2_max_concurrent = 8")
            try text.write(to: path, atomically: true, encoding: .utf8)

            let config = try ConfigManager.load(from: path)
            #expect(config.backend.engineV2MaxConcurrent == 8)
            #expect(config.appliedMigrations.isEmpty)
        }
    }

    @Test("a current file is left completely alone")
    func secondPassIsANoOp() throws {
        try withTempConfig(generated) { path in
            _ = migrateConfigSchema(in: path)
            let afterFirst = try read(path)

            #expect(migrateConfigSchema(in: path).isEmpty)
            #expect(try read(path) == afterFirst)
        }
    }

    /// A file written by a NEWER release must never be dragged backwards: the
    /// caps it holds belong to a schema this binary does not know.
    @Test("a file from a future release is never downgraded")
    func futureVersionIsUntouched() throws {
        let future = """
            config_version = 99
            [provider]
            name = "test-provider"

            [backend]
            engine_v2_max_concurrent = 8
            """
        try withTempConfig(future) { path in
            #expect(migrateConfigSchema(in: path).isEmpty)
            let text = try read(path)
            #expect(text == future)
        }
    }

    /// An unparseable stamp is still a stamp. Treating it as absent would
    /// prepend a second `config_version`, producing a duplicate key that does
    /// not parse at all — strictly worse than leaving the file alone.
    @Test("a malformed stamp is left alone rather than duplicated")
    func malformedStampIsNotDuplicated() throws {
        let malformed = """
            config_version = "one"
            [provider]
            name = "test-provider"

            [backend]
            engine_v2_max_concurrent = 8
            """
        try withTempConfig(malformed) { path in
            #expect(migrateConfigSchema(in: path).isEmpty)
            let text = try read(path)
            #expect(text == malformed)
        }
    }

    /// "Already dated" is an ASSIGNMENT of `config_version`, not the three
    /// words appearing anywhere in the file. A config that merely MENTIONS the
    /// key — a comment about it, a commented-out stamp, or the name inside
    /// another key's value — is undated, and mistaking it for dated skips the
    /// migration while `ProviderConfig.init(from:)` keeps changing the value in
    /// memory on every decode.
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
            engine_v2_max_concurrent = 8
            """,
            // A commented-OUT stamp is not a stamp.
            """
            [provider]
            name = "test-provider"

            [backend]
            # config_version = 1
            engine_v2_max_concurrent = 8
            """,
            // The key named inside another key's value.
            """
            [provider]
            name = "config_version"

            [backend]
            engine_v2_max_concurrent = 8
            """,
        ]

        for contents in mentions {
            try withTempConfig(contents) { path in
                // Undated means PRE-v0.8.0, so the 8 was typed by a human and
                // the v0.8.1 step does not apply — the file is only dated.
                #expect(migrateConfigSchema(in: path).isEmpty)

                let text = try read(path)
                #expect(text.hasPrefix("config_version = 2\n"))
                #expect(text.contains("engine_v2_max_concurrent = 8"))

                let config = try ConfigManager.load(from: path)
                #expect(config.backend.engineV2MaxConcurrent == 8)
                #expect(config.appliedMigrations.isEmpty)
            }
        }
    }

    /// The other direction: a real assignment is a stamp however it is spaced,
    /// so the detector must not be so narrow that a loosely-spaced stamp gets a
    /// second one prepended — and the restamp must preserve that spacing.
    @Test("an indented or loosely-spaced assignment counts as dated")
    func spacingVariantsCountAsDated() throws {
        for (stamp, want) in [
            ("  config_version = 1", "  config_version = 2"),
            ("config_version=1", "config_version=2"),
            ("config_version\t=\t1", "config_version\t=\t2"),
            ("config_version = 1 # dated by the upgrade", "config_version = 2 # dated by the upgrade"),
        ] {
            try withTempConfig(
                """
                \(stamp)
                [provider]
                name = "test-provider"

                [backend]
                engine_v2_max_concurrent = 6
                """
            ) { path in
                #expect(migrateConfigSchema(in: path).isEmpty)
                let text = try read(path)
                #expect(text.hasPrefix("\(want)\n"))
                #expect(text.contains("engine_v2_max_concurrent = 6"))
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
            config_version = 1
            # hand-tuned for the rack, do not clobber
            [provider]
            name = "test-provider"

            [backend]
            kv_quant = true  # retired, still warned about
            engine_v2_max_concurrent = 8
            """
        ) { path in
            #expect(migrateConfigSchema(in: path) == [
                ConcurrencyDefaultMigration.v081ConcurrencyRevert
            ])

            let text = try read(path)
            #expect(text.contains("# hand-tuned for the rack, do not clobber"))
            #expect(text.contains("kv_quant = true"))
            #expect(text.contains("# retired, still warned about"))
            #expect(text.contains("engine_v2_max_concurrent = 4"))

            let config = try ConfigManager.load(from: path)
            #expect(config.backend.retiredKeysPresent == ["kv_quant"])
        }
    }

    /// The decode-time change and the on-disk rewrite share one predicate, and
    /// this pins the case where they once disagreed: a trailing inline comment.
    /// The TOML decoder ignores comments, so boot 1 changed `8 # comment` in
    /// memory — but the old full-line regex never matched it, the stamp still
    /// landed, and boot 2+ honored the literal. The comment must also SURVIVE
    /// the rewrite: text surgery exists precisely to preserve operator prose.
    @Test(
        "a generated 8 with a trailing inline comment is rewritten, comment preserved",
        arguments: [
            ("engine_v2_max_concurrent = 8 # raised by the v0.8.0 upgrade",
             "engine_v2_max_concurrent = 4 # raised by the v0.8.0 upgrade"),
            // Tab-separated comment, multiple spaces.
            ("engine_v2_max_concurrent = 8\t\t# tuned",
             "engine_v2_max_concurrent = 4\t\t# tuned"),
            ("engine_v2_max_concurrent = 8   ; semicolon prose",
             "engine_v2_max_concurrent = 4   ; semicolon prose"),
            // Indentation is preserved too.
            ("  engine_v2_max_concurrent = 8",
             "  engine_v2_max_concurrent = 4"),
            // No comment at all — the original shape keeps working.
            ("engine_v2_max_concurrent = 8",
             "engine_v2_max_concurrent = 4"),
        ])
    func rewritesCommentedGeneratedEight(line: String, want: String) throws {
        try withTempConfig(
            """
            config_version = 1
            [provider]
            name = "test-provider"

            [backend]
            \(line)
            """
        ) { path in
            #expect(migrateConfigSchema(in: path) == [
                ConcurrencyDefaultMigration.v081ConcurrencyRevert
            ])
            let text = try read(path)
            #expect(text.contains(want))
            #expect(text.hasPrefix("config_version = 2\n"))
        }
    }

    /// Both halves agree end to end on the comment shape: the decode of the
    /// re-stamped rewritten file yields 4 with nothing left to migrate — no
    /// more one-boot flip-flop.
    @Test("after the rewrite, a commented config decodes to 4 with no pending migration")
    func commentedRewriteDecodesCleanly() throws {
        try withTempConfig(
            """
            config_version = 1
            [provider]
            name = "test-provider"

            [backend]
            engine_v2_max_concurrent = 8  # raised by the v0.8.0 upgrade
            """
        ) { path in
            #expect(migrateConfigSchema(in: path) == [
                ConcurrencyDefaultMigration.v081ConcurrencyRevert
            ])
            let config = try ConfigManager.load(from: path)
            #expect(config.backend.engineV2MaxConcurrent == 4)
            #expect(config.appliedMigrations.isEmpty)
        }
    }

    /// A post-migration explicit 8 means 8 — comment or not. The stamp is what
    /// the one-time migration spent; nothing may re-migrate after it.
    @Test("an explicit post-migration 8 (with or without comment) is never touched")
    func postMigrationEightSticks() throws {
        for line in [
            "engine_v2_max_concurrent = 8",
            "engine_v2_max_concurrent = 8 # I really mean it",
        ] {
            try withTempConfig(
                """
                config_version = 2
                [provider]
                name = "test-provider"

                [backend]
                \(line)
                """
            ) { path in
                #expect(migrateConfigSchema(in: path).isEmpty)
                let text = try read(path)
                #expect(text.contains(line))
                let config = try ConfigManager.load(from: path)
                #expect(config.backend.engineV2MaxConcurrent == 8)
                #expect(config.appliedMigrations.isEmpty)
            }
        }
    }

    /// Only the exact generated value is rewritten: `8` with a comment is, but
    /// `18`, `81`, or an operator's `6 # note` are not — v0.8.0 never generated
    /// those, so they are choices.
    @Test("non-8 values are untouched, commented or not")
    func nonEightValuesUntouched() throws {
        for line in [
            "engine_v2_max_concurrent = 18",
            "engine_v2_max_concurrent = 81 # not a generated 8",
            "engine_v2_max_concurrent = 6 # chosen",
            "engine_v2_max_concurrent = 3",
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
                // The re-stamp still lands, but nothing is migrated.
                #expect(migrateConfigSchema(in: path).isEmpty)
                let text = try read(path)
                #expect(text.contains(line))
                #expect(text.hasPrefix("config_version = 2\n"))
            }
        }
    }

    /// The rewrite is anchored to a whole assignment line, so neither the
    /// `..._by_model` table header nor an 8 inside it can be caught by it.
    @Test("the per-model override table is never rewritten")
    func leavesPerModelOverridesAlone() throws {
        try withTempConfig(
            """
            config_version = 1
            [provider]
            name = "test-provider"

            [backend]
            engine_v2_max_concurrent = 8

            [backend.engine_v2_max_concurrent_by_model]
            "gemma-4-26b-qat-4bit" = 8
            """
        ) { path in
            #expect(migrateConfigSchema(in: path) == [
                ConcurrencyDefaultMigration.v081ConcurrencyRevert
            ])

            let config = try ConfigManager.load(from: path)
            #expect(config.backend.engineV2MaxConcurrent == 4)
            // The operator named this model and this cap explicitly. Per-model
            // entries were never generated, so they are never ambiguous — and
            // 8 stays reachable there, which is why the clamp keeps its top.
            #expect(config.backend.engineV2MaxConcurrentByModel == ["gemma-4-26b-qat-4bit": 8])
        }
    }

    @Test("an absent file is not created")
    func missingFileIsNotCreated() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-\(UUID().uuidString).toml")
        #expect(migrateConfigSchema(in: path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
}
