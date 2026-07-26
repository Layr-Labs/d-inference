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
