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

        // Re-arm crash recovery to match `start`: a manual restart should leave
        // the watchdog watching (and re-enable it if a prior `stop` disarmed it,
        // or install it on a provider upgraded from a pre-watchdog build).
        if Watchdog.autoRestartEnabled(configPath: nil) {
            try? WatchdogAgent.installAndStart()
        }

        print("  darkbloom status  Check status")
    }
}
