import ArgumentParser
import Foundation
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
    }
}
