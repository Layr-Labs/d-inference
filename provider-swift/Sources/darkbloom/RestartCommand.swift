import ArgumentParser
import ProviderCore

struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart the provider with its current model selection.",
        discussion: """
        Drains accepted requests, then restarts the launchd service, re-using the existing
        coordinator URL and model selection — it does NOT show the model
        picker or change what you serve. Use this to pick up a new binary or
        recover a wedged provider.

        If the service is installed but not running, it is started.
        """
    )

    @OptionGroup var drain: DrainOptions
    @Option(help: "Seconds to confirm a new, freshly authorized connection after restart.")
    var startupTimeout: Int = 180

    mutating func validate() throws {
        guard (1...3600).contains(startupTimeout) else { throw ValidationError("--startup-timeout must be between 1 and 3600 seconds") }
    }

    @OptionGroup var configOptions: ConfigOptions

    mutating func run() async throws {
        let wasLoaded = LaunchAgent.isAnySupportedLabelLoaded()
        guard LaunchAgent.isInstalled() || wasLoaded else {
            throw ValidationError("No launchd configuration is installed. Use darkbloom start to select the replacement configuration; the foreground provider was left running.")
        }
        let previous = DaemonStateFile.read()?.processIdentity ?? LaunchAgent.launchSnapshot()?.process
        let session = try await ServiceDrain.prepare(options: drain)
        defer { session.release() }
        do {
            try await ServiceDrain.stopDrainedProvider(unloadService: false)
            try LaunchAgent.restartAfterDrain()
        } catch LaunchAgentError.notInstalled {
            printError("Provider is not running. Start it with `darkbloom start`.")
            throw ExitCode.failure
        }
        if wasLoaded {
            print("Drained provider relaunched; waiting for fresh authorization...")
        } else {
            print("Provider started.")
        }

        ServiceDrain.rearmWatchdog(explicitConfig: configOptions.config)

        // Let startup/update confirmation acquire its own process lease.
        session.release()
        try await ServiceDrain.waitForRestart(previous: previous, timeout: startupTimeout)
        print("  darkbloom status  Check status")
    }
}
