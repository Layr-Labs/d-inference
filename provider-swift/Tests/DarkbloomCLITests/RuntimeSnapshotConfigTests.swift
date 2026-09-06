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

    @Test("model browsing and doctor preserve an explicit dev config without migration")
    func readOnlyCommandOptionsPreserveDevConfig() throws {
        let url = tempConfigURL()
        let original = """
            # An explicit development endpoint must never be migrated by exploration.
            config_version = 1

            [provider]
            name = "read-only-command-dev"

            [coordinator]
            url = "ws://localhost:8080/ws/provider"

            [backend]
            engine_v2_max_concurrent = 8
            """
        let originalBytes = Data(original.utf8)
        try originalBytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let commandOptions: [(String, ConfigOptions)] = [
            ("models list", try Models.List.parse([
                "--json", "--all", "--config", url.path,
            ]).configOptions),
            ("models catalog runtime eligibility", try Models.Catalog.parse([
                "--json", "--include-runtime-eligibility", "--config", url.path,
            ]).configOptions),
            ("models catalog", try Models.Catalog.parse([
                "--json", "--include-download-plans", "--config", url.path,
            ]).configOptions),
            ("models download-plan", try Models.DownloadPlan.parse([
                "org/model", "--json", "--config", url.path,
            ]).configOptions),
            ("doctor", try Doctor.parse([
                "--json", "--config", url.path,
            ]).configOptions),
        ]
        for (command, options) in commandOptions {
            // Exercise the logging-preserving snapshot boundary with real parsed
            // options, before catalog HTTP requests, model plans, or doctor probes.
            let snapshot = try loadRuntimeSnapshot(configOptions: options, migrateOnDisk: false)
            #expect(snapshot.configPath == url, "wrong config for \(command)")
            #expect(snapshot.config.coordinator.url == "ws://localhost:8080/ws/provider",
                    "changed in-memory endpoint for \(command)")
            #expect(try Data(contentsOf: url) == originalBytes, "rewrote config for \(command)")
        }
    }

    @Test("update propagates existing-path read failures")
    func updateRejectsUnreadableExistingPath() throws {
        let url = tempConfigURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try loadUpdateConfig(configPath: url.path)
            Issue.record("an existing path that cannot be read as TOML must not default")
        } catch ConfigError.readFailed(let path, _) {
            #expect(path == url.path)
        }
    }
}
