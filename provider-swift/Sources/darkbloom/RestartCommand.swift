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

        On a Mac in a two-Mac cluster it restarts single-Mac serving only, and only with --solo
        while the cluster service runs; the cluster is restarted in `darkbloom cluster`.
        """
    )

    @OptionGroup var drain: DrainOptions
    @Option(help: "Seconds to confirm a new, freshly authorized connection after restart.")
    var startupTimeout: Int = 180

    @Flag(help: "On a Mac in a two-Mac cluster: restart single-Mac serving anyway, beside the cluster.")
    var solo = false

    mutating func validate() throws {
        guard (1...3600).contains(startupTimeout) else { throw ValidationError("--startup-timeout must be between 1 and 3600 seconds") }
    }

    @OptionGroup var configOptions: ConfigOptions

    /// `darkbloom restart` on a Mac in a two-Mac cluster (UX audit P4c): nothing to restart without single-Mac serving;
    /// beside a running cluster service only with `--solo`, as `darkbloom start`. Nil: restart as on any Mac.
    static func pairRefusal(_ pair: ClusterPairSummary, singleMacInstalled: Bool, solo: Bool) -> [String]? {
        nil
    }

    mutating func run() async throws {
        let pair = ClusterPairSummary.local(config: configOptions.config)
        let wasLoaded = LaunchAgent.isLoaded()
        if let refusal = Self.pairRefusal(pair, singleMacInstalled: LaunchAgent.isInstalled() || wasLoaded, solo: solo) {
            for line in refusal { print(line) }
            throw ExitCode.failure
        }
        guard LaunchAgent.isInstalled() || wasLoaded else {
            throw ValidationError("No launchd configuration is installed. Use \(BuildEnvironment.current.cliName) start to select the replacement configuration; the foreground provider was left running.")
        }
        let soloState = ServiceDrain.soloProviderState()
        let previous = soloState?.processIdentity ?? LaunchAgent.launchSnapshot()?.process
        let session = try await ServiceDrain.prepare(options: drain, state: soloState)
        defer { session.release() }
        do {
            try await ServiceDrain.stopDrainedProvider(unloadService: false, daemonState: ServiceDrain.soloProviderState())
            try LaunchAgent.restartAfterDrain()
        } catch LaunchAgentError.notInstalled {
            printError("Provider is not running. Start it with `\(BuildEnvironment.current.cliName) start`.")
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
        print("  \(BuildEnvironment.current.cliName) status  Check status")
        if pair.paired { print(pair.pairSentence + " The cluster was not restarted.") }
    }
}
