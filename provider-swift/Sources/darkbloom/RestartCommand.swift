import ArgumentParser
import ProviderCore

struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart the provider with its current model selection.",
        discussion: """
        Restarts the running launchd service in place, re-using the existing
        coordinator URL and model selection — it does NOT show the model
        picker or change what you serve. Use this to pick up a new binary or
        recover a wedged provider.

        If the service is installed but not running, it is started.
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    mutating func run() async throws {
        let wasLoaded = LaunchAgent.isLoaded()
        do {
            try LaunchAgent.restart()
        } catch LaunchAgentError.notInstalled {
            printError("Provider is not running. Start it with `darkbloom start`.")
            throw ExitCode.failure
        }
        if wasLoaded {
            print("Provider restarted.")
        } else {
            print("Provider started.")
        }

        // Re-arm the watchdog (re-enables it after a prior `stop`, or installs it
        // on a provider upgraded from a pre-watchdog build). The rewrite must
        // not drop a custom config: an explicit --config wins, otherwise the
        // installed plist's recorded config path is preserved. An opted-out
        // config (`auto_restart = false`) DISARMS a still-loaded watchdog
        // instead of leaving the stale job running.
        let watchdogConfig = WatchdogAgent.rearmConfigPath(
            explicit: configOptions.config,
            installed: WatchdogAgent.installedConfigPath()
        )
        switch WatchdogAgent.rearmAction(
            autoRestartEnabled: Watchdog.autoRestartEnabled(configPath: watchdogConfig?.path),
            isLoaded: WatchdogAgent.isLoaded()
        ) {
        case .arm:
            try? WatchdogAgent.installAndStart(configPath: watchdogConfig)
        case .disarm:
            try? WatchdogAgent.stop()
        case nil:
            break
        }

        print("  darkbloom status  Check status")
    }
}
