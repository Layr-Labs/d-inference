import Foundation
import Testing
@testable import ProviderCore

/// v0.8.2 config-loading hardening: the lenient `ConfigManager.parse` stays
/// for tests only. The production FILE path (`load(from:)` →
/// `parseValidating`) must fail loudly — a malformed `[gemma_optimizations]`
/// entry previously decoded to whole-config defaults and silently re-enabled
/// the default-on stack (and silently applied any other default) with no log.
@Suite("Config strict loading")
struct ConfigValidationTests {

    private func writeTempConfig(_ toml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-validation-\(UUID().uuidString).toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - parseValidating

    @Test("parseValidating decodes a well-formed config")
    func parseValidatingDecodesValid() throws {
        let config = try ConfigManager.parseValidating("""
            [provider]
            name = "strict-provider"

            [gemma_optimizations]
            prefill_layer18 = false
            weighted_r1 = false
            """)

        #expect(config.provider.name == "strict-provider")
        #expect(!config.gemmaOptimizations.prefillLayer18)
        #expect(!config.gemmaOptimizations.weightedR1)
    }

    @Test("parseValidating still defaults a missing optimisation section on")
    func parseValidatingDefaultsMissingSectionOn() throws {
        let config = try ConfigManager.parseValidating("""
            [provider]
            name = "strict-provider"
            """)

        #expect(config.gemmaOptimizations == GemmaOptimizationSettings())
        #expect(config.gemmaOptimizations.prefillLayer18)
        #expect(config.gemmaOptimizations.weightedR1)
    }

    @Test("parseValidating keys off per-key defaults for a partial section")
    func parseValidatingDefaultsMissingKeysOn() throws {
        let config = try ConfigManager.parseValidating("""
            [gemma_optimizations]
            weighted_r1 = false
            """)

        #expect(config.gemmaOptimizations.prefillLayer18)
        #expect(!config.gemmaOptimizations.weightedR1)
    }

    @Test("parseValidating rejects a mis-typed rollback key")
    func parseValidatingRejectsIntegerBool() throws {
        do {
            _ = try ConfigManager.parseValidating("""
                [gemma_optimizations]
                weighted_r1 = 0
                """)
            Issue.record("weighted_r1 = 0 is not a Bool and must not decode")
        } catch ConfigError.parseFailed(let detail) {
            #expect(!detail.isEmpty)
        }
    }

    @Test("parseValidating rejects a quoted rollback key")
    func parseValidatingRejectsQuotedBool() throws {
        do {
            _ = try ConfigManager.parseValidating("""
                [gemma_optimizations]
                prefill_layer18 = "false"
                """)
            Issue.record("prefill_layer18 = \"false\" is not a Bool and must not decode")
        } catch ConfigError.parseFailed(let detail) {
            #expect(!detail.isEmpty)
        }
    }

    @Test("parseValidating rejects syntactically broken TOML")
    func parseValidatingRejectsBrokenSyntax() throws {
        do {
            _ = try ConfigManager.parseValidating("[gemma_optimizations\nbroken")
            Issue.record("syntactically broken TOML must not decode")
        } catch ConfigError.parseFailed(let detail) {
            #expect(!detail.isEmpty)
        }
    }

    // MARK: - file-loading boundary

    @Test("a malformed existing config file fails loading loudly")
    func malformedFileThrowsOnLoad() throws {
        let url = try writeTempConfig("""
            [provider]
            name = "strict-provider"

            [gemma_optimizations]
            weighted_r1 = 0
            """)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try ConfigManager.load(from: url)
            Issue.record("loading a malformed config file must throw, not default")
        } catch ConfigError.parseFailed(let detail) {
            #expect(!detail.isEmpty)
        }
    }

    @Test("a well-formed existing config file still loads")
    func wellFormedFileLoads() throws {
        let url = try writeTempConfig("""
            [provider]
            name = "strict-provider"

            [gemma_optimizations]
            prefill_layer18 = false
            """)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = try ConfigManager.load(from: url)
        #expect(config.provider.name == "strict-provider")
        #expect(!config.gemmaOptimizations.prefillLayer18)
        #expect(config.gemmaOptimizations.weightedR1)
    }

    @Test("a missing config file reports a read failure, not a parse failure")
    func missingFileIsReadFailure() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-validation-missing-\(UUID().uuidString).toml")

        do {
            _ = try ConfigManager.load(from: missing)
            Issue.record("loading a missing file must throw")
        } catch ConfigError.readFailed {
            // Expected: missing-file LENIENCY lives one layer up
            // (loadDefault / loadRuntimeSnapshot substitute defaults there),
            // never a silent whole-config default from this boundary.
        }
    }

    @Test("the lenient test-facing parse keeps its historical contract")
    func lenientParseStillDefaultsOnMalformed() {
        let config = ConfigManager.parse("""
            [gemma_optimizations]
            weighted_r1 = 0
            """)

        #expect(config.gemmaOptimizations == GemmaOptimizationSettings())
    }
}
