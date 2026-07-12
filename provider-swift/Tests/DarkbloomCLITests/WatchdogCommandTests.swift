import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Unit tests for the `darkbloom watchdog` subcommand wiring + its cheap config
/// read. The launchctl side effects are environment-dependent (manual /
/// integration verification); here we pin the deterministic pieces.
@Suite("Watchdog command")
struct WatchdogCommandTests {

    @Test("watchdog is registered and parses to a Watchdog command")
    func watchdogParses() throws {
        let command = try Darkbloom.parseAsRoot(["watchdog"])
        #expect(command is Watchdog)
    }

    @Test("watchdog is hidden from help and named correctly")
    func watchdogConfiguration() {
        #expect(Watchdog.configuration.commandName == "watchdog")
        #expect(Watchdog.configuration.shouldDisplay == false)
    }

    // MARK: - autoRestartEnabled (cheap config read, fail-open)

    private func writeTempConfig(_ toml: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-cfg-\(UUID().uuidString).toml")
        try? toml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("auto_restart = false disables recovery")
    func honoursDisable() {
        let url = writeTempConfig("""
        [provider]
        name = "x"
        auto_restart = false
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Watchdog.autoRestartEnabled(configPath: url.path) == false)
    }

    @Test("absent auto_restart defaults to enabled")
    func defaultsEnabled() {
        let url = writeTempConfig("""
        [provider]
        name = "x"
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Watchdog.autoRestartEnabled(configPath: url.path) == true)
    }

    @Test("a missing config file fails open to enabled")
    func failsOpen() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-missing-\(UUID().uuidString).toml")
        #expect(Watchdog.autoRestartEnabled(configPath: missing.path) == true)
        #expect(Watchdog.settings(configPath: missing.path).autoUpdate == true)
    }

    @Test("auto_update = false disables watchdog-owned update checks")
    func honoursAutoUpdateDisable() {
        let url = writeTempConfig("""
        [provider]
        name = "x"
        auto_update = false
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = Watchdog.settings(configPath: url.path)
        #expect(settings.autoRestart)
        #expect(!settings.autoUpdate)
    }

    @Test("watchdog uses the persisted beta release channel")
    func honoursReleaseChannel() {
        let url = writeTempConfig("""
        [provider]
        name = "x"
        release_channel = "beta"
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Watchdog.settings(configPath: url.path).releaseChannel == .beta)
    }

    @Test("DARKBLOOM_NO_UPDATE_CHECK disables only watchdog updates")
    func environmentUpdateOptOut() {
        let url = writeTempConfig("""
        [provider]
        name = "x"
        auto_update = true
        auto_restart = true
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = Watchdog.settings(
            configPath: url.path,
            environment: ["DARKBLOOM_NO_UPDATE_CHECK": "1"]
        )
        #expect(settings.autoRestart)
        #expect(!settings.autoUpdate)
    }

    @Test("raised startup_preload_timeout_secs raises the candidate timeout")
    func derivesCandidateTimeoutFromPreloadConfig() {
        let url = writeTempConfig("""
        [provider]
        name = "x"

        [backend]
        startup_preload_timeout_secs = 420
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = Watchdog.settings(configPath: url.path)
        #expect(settings.candidateStartupTimeoutSeconds == 600)

        let defaults = writeTempConfig("""
        [provider]
        name = "x"
        """)
        defer { try? FileManager.default.removeItem(at: defaults) }
        #expect(Watchdog.settings(
            configPath: defaults.path
        ).candidateStartupTimeoutSeconds == 300)
    }

    @Test("tick budget exceeds the bounded network whole-transfer timeout")
    func tickBudgetCoversBoundedDownload() {
        #expect(
            Watchdog.tickDeadlineSeconds
                > SelfUpdater.watchdogResourceTimeoutSeconds
        )
    }

    @Test("restart accepts --config for the watchdog re-arm")
    func restartParsesConfig() throws {
        let command = try Darkbloom.parseAsRoot([
            "restart",
            "--config",
            "/tmp/custom.toml",
        ])
        guard let restart = command as? Restart else {
            Issue.record("expected Restart command")
            return
        }
        #expect(restart.configOptions.config == "/tmp/custom.toml")
    }

    @Test("manual quarantine override is explicit and parseable")
    func manualOverrideParses() throws {
        let command = try Darkbloom.parseAsRoot([
            "update",
            "--override-quarantine",
        ])
        guard let update = command as? Update else {
            Issue.record("expected Update command")
            return
        }
        #expect(update.overrideQuarantine)
    }
}
