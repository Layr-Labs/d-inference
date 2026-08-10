import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Operator-facing pin for the v0.8.2 config-loading contract: every
/// snapshot-based command (`start`, `benchmark`, `beta`, ...) loads its config
/// through `loadRuntimeSnapshot`. A MISSING file must keep defaulting
/// leniently; an EXISTING but malformed file must fail loudly instead of
/// silently re-enabling whole-config defaults (e.g. re-arming the default-on
/// Gemma stack after a botched rollback edit).
@Suite("Runtime snapshot config loading")
struct RuntimeSnapshotConfigTests {

    private func tempConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-cfg-\(UUID().uuidString).toml")
    }

    @Test("a missing config file keeps the lenient default path")
    func missingConfigYieldsDefaults() throws {
        let missing = tempConfigURL()

        let snapshot = try loadRuntimeSnapshot(configPath: missing.path)

        #expect(!snapshot.configFileExists)
        // Missing section/keys decode defaulted: the optimisation stack stays
        // on; hardware-derived name when detection succeeds, "darkbloom" else.
        #expect(snapshot.config.gemmaOptimizations == GemmaOptimizationSettings())
        #expect(snapshot.config.gemmaOptimizations.prefillLayer18)
        #expect(snapshot.config.gemmaOptimizations.weightedR1)
    }

    @Test("a malformed config file fails the load loudly")
    func malformedConfigThrows() throws {
        let url = tempConfigURL()
        try """
        [provider]
        name = "snapshot-test"

        [gemma_optimizations]
        weighted_r1 = 0
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try loadRuntimeSnapshot(configPath: url.path)
            Issue.record("a malformed provider.toml must abort, not silently default")
        } catch ConfigError.parseFailed(let detail) {
            #expect(!detail.isEmpty)
        }
    }

    @Test("benchmark-style loading never rewrites its config")
    func readOnlyLoadPreservesFile() throws {
        let url = tempConfigURL()
        let original = """
            config_version = 1

            [provider]
            name = "benchmark-a-b"

            [backend]
            engine_v2_max_concurrent = 8

            [gemma_optimizations]
            prefill_layer18 = false
            weighted_r1 = false
            """
        try original.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try loadRuntimeSnapshot(
            configPath: url.path,
            migrateOnDisk: false)

        #expect(!snapshot.config.gemmaOptimizations.prefillLayer18)
        #expect(!snapshot.config.gemmaOptimizations.weightedR1)
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }
}
