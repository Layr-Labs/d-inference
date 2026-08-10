import Darwin
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

@Suite("Beta command config mutation")
struct BetaCommandTests {

    /// Write `toml` (when non-nil) into a unique temp `provider.toml` and
    /// return its URL. `~/.config/darkbloom/provider.toml` is guarded around
    /// every toggle call: a non-canonical config path triggers
    /// loadRuntimeSnapshot's legacy→canonical copy when the canonical file is
    /// ABSENT, which would otherwise plant test fixtures in the operator's
    /// real config on a fresh machine.
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

    private func withGuardedCanonicalConfig(
        _ body: () throws -> Void
    ) rethrows {
        let canonical = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/darkbloom/provider.toml")
        let existedBefore = FileManager.default.fileExists(atPath: canonical.path)
        defer {
            if !existedBefore,
               FileManager.default.fileExists(atPath: canonical.path) {
                try? FileManager.default.removeItem(at: canonical)
            }
        }
        try body()
    }

    @Test("enable with an absent section writes the key despite the matching default")
    func enableMaterializesAbsentKey() throws {
        let url = try makeTempConfig("""
            config_version = 2

            [provider]
            name = "beta-test"
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // weightedR1 already decodes to true via the default; the old code
        // no-oped ("already enabled") without pinning anything.
        try withGuardedCanonicalConfig {
            try setBetaFeature("gemma-weighted-r1", enabled: true, configPath: url.path)
        }

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

        try withGuardedCanonicalConfig {
            try setBetaFeature("gemma-weighted-r1", enabled: true, configPath: url.path)
            let pinned = try String(contentsOf: url, encoding: .utf8)

            try setBetaFeature("gemma-weighted-r1", enabled: true, configPath: url.path)
            let after = try String(contentsOf: url, encoding: .utf8)

            #expect(after == pinned)
        }
    }

    @Test("a key pinned at the target value is a no-op without a rewrite")
    func pinnedKeyIsNoOp() throws {
        let url = try makeTempConfig("""
            config_version = 2

            [provider]
            name = "beta-test"

            [gemma_optimizations]
            weighted_r1 = true
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try String(contentsOf: url, encoding: .utf8)

        try withGuardedCanonicalConfig {
            try setBetaFeature("gemma-weighted-r1", enabled: true, configPath: url.path)
        }

        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after == before)
    }

    @Test("disable with an absent key still writes a default-off feature")
    func disableMaterializesAbsentKey() throws {
        // MTP defaults off: disabling an absent key used to no-op without
        // persisting the operator's intent.
        let url = try makeTempConfig("""
            [provider]
            name = "beta-test"
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try withGuardedCanonicalConfig {
            try setBetaFeature("mtp", enabled: false, configPath: url.path)
        }

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("mtp = false"))
        #expect(tomlKeyPresent(written, section: "backend", key: "mtp"))
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

        try withGuardedCanonicalConfig {
            try setBetaFeature("gemma-weighted-r1", enabled: false, configPath: url.path)
        }

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
            try setBetaFeature("gemma-expert-packing", enabled: true, configPath: url.path)
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

        try withGuardedCanonicalConfig {
            try setBetaFeature("gemma-prefill-layer18", enabled: false, configPath: url.path)
        }

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("prefill_layer18 = false"))
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
