import Darwin
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

@Suite("Beta command config mutation")
struct BetaCommandTests {

    /// Write a unique temporary config; mutation calls disable home-directory migration.
    private func makeTempConfig(_ toml: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beta-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("provider.toml")
        if let toml {
            try toml.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    @Test("beta projections distinguish automatic MTP from on and off")
    func automaticProjection() throws {
        #expect(betaFeatureListMark(.auto) == "auto")
        #expect(betaFeatureListMark(.on) == "on ")
        #expect(betaFeatureListMark(.off) == "off")
        #expect(betaFeatureStatusLabel(.auto) == "AUTOMATIC (model-aware)")

        let report = BetaFeatureReport(
            id: "mtp",
            title: "MTP",
            state: BetaFeatureState.auto.rawValue,
            enabled: BetaFeatureState.auto.enabled,
            requiresRestart: true,
            summary: "automatic")
        let data = try JSONEncoder().encode(report)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""state":"auto""#))
        #expect(!json.contains(#""enabled""#))
    }
    @Test("enable with an absent section writes the key despite the matching default")
    func enableMaterializesAbsentKey() throws {
        let url = try makeTempConfig("""
            config_version = 3

            [provider]
            name = "beta-test"
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // weightedR1 already decodes to true via the default; the old code
        // no-oped ("already enabled") without pinning anything.
        try setBetaFeature("gemma-weighted-r1", enabled: true, configPath: url.path, migrateOnDisk: false)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("[gemma_optimizations]"))
        #expect(written.contains("weighted_r1 = true"))
        let reloaded = try ConfigManager.load(from: url)
        #expect(reloaded.gemmaOptimizations.weightedR1)
    }

    @Test("enable after the materializing write is a true no-op")
    func secondEnableDoesNotRewrite() throws {
        let url = try makeTempConfig("""
            [provider]
            name = "beta-test"
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try setBetaFeature("gemma-weighted-r1", enabled: true, configPath: url.path, migrateOnDisk: false)
        let pinned = try String(contentsOf: url, encoding: .utf8)

        try setBetaFeature("gemma-weighted-r1", enabled: true, configPath: url.path, migrateOnDisk: false)
        let after = try String(contentsOf: url, encoding: .utf8)

        #expect(after == pinned)
    }

    @Test("a key pinned at the target value is a no-op without a rewrite")
    func pinnedKeyIsNoOp() throws {
        let url = try makeTempConfig("""
            config_version = 3

            [provider]
            name = "beta-test"

            [gemma_optimizations]
            weighted_r1 = true
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try String(contentsOf: url, encoding: .utf8)

        try setBetaFeature("gemma-weighted-r1", enabled: true, configPath: url.path, migrateOnDisk: false)

        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after == before)
    }

    @Test("disable with an absent key materializes an explicit off override")
    func disableMaterializesAbsentKey() throws {
        // MTP defaults to automatic model-aware policy. Disabling an absent key
        // must persist the operator's stronger all-target rollback.
        let url = try makeTempConfig("""
            [provider]
            name = "beta-test"
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try setBetaFeature("mtp", enabled: false, configPath: url.path, migrateOnDisk: false)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("mtp_mode = 'off'"))
        #expect(!written.contains("\nmtp = "))
        #expect(tomlKeyPresent(written, section: "backend", key: "mtp_mode"))
    }

    @Test("automatic MTP is not mistaken for an explicit off pin")
    func disableReplacesAutomaticMode() throws {
        let url = try makeTempConfig("""
            [provider]
            name = "beta-test"

            [backend]
            mtp_mode = "auto"
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try setBetaFeature("mtp", enabled: false, configPath: url.path, migrateOnDisk: false)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("mtp_mode = 'off'"))
        #expect(!written.contains("mtp_mode = 'auto'"))
        #expect(!written.contains("\nmtp = "))
    }

    @Test("disable flips a pinned key and keeps its neighbour")
    func disableFlipsPinnedKey() throws {
        let url = try makeTempConfig("""
            [provider]
            name = "beta-test"

            [gemma_optimizations]
            prefill_layer18 = false
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try setBetaFeature("gemma-weighted-r1", enabled: false, configPath: url.path, migrateOnDisk: false)

        let reloaded = try ConfigManager.load(from: url)
        #expect(!reloaded.gemmaOptimizations.weightedR1)
        #expect(!reloaded.gemmaOptimizations.prefillLayer18)
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("weighted_r1 = false"))
        #expect(written.contains("prefill_layer18 = false"))
    }

    @Test("an unknown feature id is rejected before touching the file")
    func unknownFeatureThrows() throws {
        let url = try makeTempConfig("""
            [provider]
            name = "beta-test"
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try String(contentsOf: url, encoding: .utf8)

        do {
            try setBetaFeature("gemma-expert-packing", enabled: true, configPath: url.path, migrateOnDisk: false)
            Issue.record("gemma-expert-packing is not a beta feature in this build")
        } catch {
            // ValidationError naming the known feature ids.
        }

        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after == before)
    }

    @Test("enabling into a missing config file creates it with the key")
    func missingFileIsWritten() throws {
        let url = try makeTempConfig(nil)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try setBetaFeature("gemma-prefill-layer18", enabled: false, configPath: url.path, migrateOnDisk: false)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("prefill_layer18 = false"))
    }

    @Test("fixture mutations retain unrelated legacy settings without migration")
    func isolatedMutationsPreserveOtherSettings() throws {
        let url = try makeTempConfig("""
            config_version = 1

            [provider]
            name = "isolated-mutations"

            [coordinator]
            url = "ws://localhost:8080/ws/provider"

            [backend]
            idle_timeout_mins = 60
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try setBetaFeature("mtp", enabled: false, configPath: url.path, migrateOnDisk: false)
        let idle = try setIdleUnloadMinutes(45, configPath: url.path, migrateOnDisk: false)

        #expect(idle.path == url)
        let reloaded = try ConfigManager.load(from: url)
        #expect(reloaded.coordinator.url == "ws://localhost:8080/ws/provider")
        #expect(reloaded.provider.name == "isolated-mutations")
        #expect(reloaded.backend.idleTimeoutMins == 45)
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("mtp_mode = 'off'"))
        #expect(tomlKeyPresent(written, section: "backend", key: "idle_timeout_mins"))
    }

    // MARK: - tomlKeyPresent

    @Test("tomlKeyPresent matches keys inside their own section only")
    func tomlKeyPresentSectioning() {
        let content = """
            [provider]
            name = "x"

            [gemma_optimizations]
            weighted_r1 = false

            [backend]
            kv_quant = true
            """

        #expect(tomlKeyPresent(content, section: "gemma_optimizations", key: "weighted_r1"))
        #expect(tomlKeyPresent(content, section: "backend", key: "kv_quant"))
        #expect(!tomlKeyPresent(content, section: "backend", key: "weighted_r1"))
        #expect(!tomlKeyPresent(content, section: "gemma_optimizations", key: "kv_quant"))
        #expect(!tomlKeyPresent(content, section: "gemma_optimizations", key: "prefill_layer18"))
    }

    @Test("tomlKeyPresent ignores commented-out keys")
    func tomlKeyPresentIgnoresComments() {
        let content = """
            [gemma_optimizations]
            # weighted_r1 = false
            """
        #expect(!tomlKeyPresent(content, section: "gemma_optimizations", key: "weighted_r1"))
    }

    // MARK: - config flock

    @Test("the config lock excludes a second exclusive flock on the sidecar")
    func configLockMutualExclusion() throws {
        let url = try makeTempConfig(nil)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let lockPath = url.path + ".lock"
        try withExclusiveConfigLock(at: url) {
            let fd = open(lockPath, O_RDWR | O_CREAT, 0o644)
            #expect(fd >= 0)
            defer { close(fd) }
            // flock is per open-file-description: a second descriptor to the
            // same sidecar must fail LOCK_EX|LOCK_NB while the guard holds it.
            #expect(flock(fd, LOCK_EX | LOCK_NB) != 0)
            #expect(errno == EWOULDBLOCK)
        }

        // After the guard released it, an exclusive lock succeeds again.
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o644)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        _ = flock(fd, LOCK_UN)
    }
}
