import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Option parsing, defaults, help text and validation for `start` and the
/// small lifecycle commands. Nothing here runs a command.
@Suite("Start and lifecycle command options")
struct StartCommandOptionsTests {
    @Test("start defaults: interactive picker, loopback port 8000, auth on")
    func startDefaults() throws {
        let start = try Start.parse([])
        #expect(start.model == [])
        #expect(!start.all)
        #expect(start.idleTimeout == nil)
        #expect(!start.foreground)
        #expect(!start.local)
        #expect(!start.localEndpoint)
        #expect(start.port == 8000)
        #expect(start.bind == "127.0.0.1")
        #expect(!start.noAuth)
        #expect(start.coordinatorURL == nil)
        #expect(start.configOptions.config == nil)
        #expect(start.drain.timeout == 600)
        #expect(!start.drain.force)
    }

    @Test("start reads every serving option")
    func startParsesAllOptions() throws {
        let start = try Start.parse([
            "--model", "org/a", "--model", "org/b", "--all",
            "--idle-timeout", "45", "--local-endpoint", "--port", "9001",
            "--bind", "0.0.0.0", "--no-auth", "--coordinator-url", "wss://coordinator.invalid/ws/provider",
            "-c", "/tmp/fixture provider.toml", "--timeout", "30", "--force",
        ])
        #expect(start.model == ["org/a", "org/b"])
        #expect(start.all)
        #expect(start.idleTimeout == 45)
        #expect(start.localEndpoint)
        #expect(!start.local)
        #expect(start.port == 9001)
        #expect(start.bind == "0.0.0.0")
        #expect(start.noAuth)
        #expect(start.coordinatorURL == "wss://coordinator.invalid/ws/provider")
        #expect(start.configOptions.config == "/tmp/fixture provider.toml")
        #expect(start.drain.timeout == 30)
        #expect(start.drain.force)
    }

    @Test("the hidden foreground flag accepts both forms")
    func foregroundInversion() throws {
        #expect(try Start.parse(["--foreground"]).foreground)
        #expect(try !Start.parse(["--foreground", "--no-foreground"]).foreground)
        #expect(try Start.parse(["--local"]).local)
    }

    @Test("start rejects malformed values", arguments: [
        ["--port", "70000"],
        ["--port", "http"],
        ["--idle-timeout", "-5"],
        ["--timeout", "3601"],
        ["--model"],
        ["--unknown-flag"],
    ])
    func startRejectsMalformedValues(arguments: [String]) {
        #expect(throws: (any Error).self) { _ = try Start.parse(arguments) }
    }

    @Test("start help lists the public options and hides the launchd flag")
    func startHelp() {
        let help = Start.helpMessage()
        #expect(help.contains("Start the provider as a background service."))
        for option in ["--model", "--all", "--idle-timeout", "--local", "--local-endpoint", "--port", "--bind",
                       "--no-auth", "--coordinator-url", "--config"] {
            #expect(help.contains(option), "missing \(option)")
        }
        #expect(!help.contains("--foreground"))
        #expect(Start.termsURL == "https://darkbloom.dev/terms.html")
    }

    @Test("the root command lists every subcommand and the provider version")
    func rootCommandHelp() {
        #expect(Darkbloom.configuration.commandName == "darkbloom")
        #expect(Darkbloom.configuration.version == ProviderCore.version)
        let help = Darkbloom.helpMessage()
        for name in ["start", "switch", "stop", "restart", "status", "doctor", "models", "local", "login",
                     "logout", "benchmark", "update", "verify", "enroll", "unenroll", "logs", "report",
                     "autoupdate", "beta", "idle", "fan"] {
            #expect(help.contains(name), "missing \(name)")
        }
    }

    @Test("the root parser routes to each lifecycle command with its options")
    func rootRoutesLifecycleCommands() throws {
        let stop = try #require(try Darkbloom.parseAsRoot(["stop", "--uninstall", "--timeout", "0"]) as? Stop)
        #expect(stop.uninstall)
        #expect(stop.drain.timeout == 0)
        let plainStop = try #require(try Darkbloom.parseAsRoot(["stop"]) as? Stop)
        #expect(!plainStop.uninstall)

        let local = try #require(try Darkbloom.parseAsRoot(["local", "--json"]) as? Local)
        #expect(local.json)
        #expect(Local.configuration.commandName == "local")

        let start = try #require(try Darkbloom.parseAsRoot(["start", "--all"]) as? Start)
        #expect(start.all)
    }

    @Test("restart accepts startup timeouts from 1 to 3600 seconds")
    func restartStartupTimeoutBounds() throws {
        let defaults = try #require(try Darkbloom.parseAsRoot(["restart"]) as? Restart)
        #expect(defaults.startupTimeout == 180)
        let shortest = try #require(try Darkbloom.parseAsRoot(["restart", "--startup-timeout", "1"]) as? Restart)
        #expect(shortest.startupTimeout == 1)
        let longest = try #require(try Darkbloom.parseAsRoot(["restart", "--startup-timeout", "3600"]) as? Restart)
        #expect(longest.startupTimeout == 3600)
        #expect(throws: (any Error).self) { _ = try Darkbloom.parseAsRoot(["restart", "--startup-timeout", "0"]) }
        #expect(throws: (any Error).self) { _ = try Darkbloom.parseAsRoot(["restart", "--startup-timeout", "3601"]) }
        #expect(Restart.helpMessage().contains("--startup-timeout"))
    }

    @Test("the config path description says when defaults are in use")
    func configPathDescription() {
        func snapshot(exists: Bool) -> RuntimeSnapshot {
            RuntimeSnapshot(
                configPath: URL(fileURLWithPath: "/tmp/fixture/provider.toml"),
                configFileExists: exists,
                config: ProviderConfig(provider: ProviderSettings(name: "fixture")),
                hardware: nil, hardwareError: nil, models: [])
        }
        #expect(describeConfigPath(snapshot(exists: true)) == "/tmp/fixture/provider.toml")
        #expect(describeConfigPath(snapshot(exists: false))
            == "/tmp/fixture/provider.toml (missing, using defaults)")
    }

    @Test("a model that is not on disk keeps no weight hash")
    func weightHashesSkipModelsNotOnDisk() {
        let id = "fixture/not-on-disk-\(UUID().uuidString)"
        let (models, hashes, fingerprints) = attachWeightHashes(
            to: [ModelInfo(id: id, sizeBytes: 1, estimatedMemoryGb: 1)])
        #expect(models.map(\.id) == [id])
        #expect(models.first?.weightHash == nil)
        #expect(hashes.isEmpty)
        #expect(fingerprints.isEmpty)
    }

    @Test("advertised models without a capability set skip the eligibility filter")
    func advertisedModelsWithoutCapabilities() {
        let gated = ModelRuntimeRequirements.qwen38ConcreteModelID
        let models = ["a", gated].map { ModelInfo(id: $0, sizeBytes: 1, estimatedMemoryGb: 1) }
        let config = ProviderConfig(provider: ProviderSettings(name: "fixture"))
        #expect(advertisedModels(from: models, config: config).map(\.id) == ["a", gated])
        #expect(advertisedModels(from: models, config: config, runtimeCapabilities: []).map(\.id) == ["a"])
    }

    @Test("local preload is skipped when startup preload is off")
    func localPreloadDisabled() async throws {
        let start = try Start.parse(["--local"])
        var config = ProviderConfig(provider: ProviderSettings(name: "fixture"))
        config.backend.startupPreload = false
        #expect(await start.runLocalStartupPreload(server: StandaloneServer(), config: config))
    }
}
