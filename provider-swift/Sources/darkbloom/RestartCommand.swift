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

        If the service is installed but not running, it is started (on a Mac in a two-Mac
        cluster, only with --solo).

        On a Mac in a two-Mac cluster it restarts the pair on both Macs with its current model, then
        waits until it serves. While the pair doesn't run on this Mac (stopped, or the other Mac gone),
        it restarts single-Mac serving that runs here and never starts the pair. With --solo it
        restarts single-Mac serving on this Mac only.
        """
    )

    @OptionGroup var drain: DrainOptions
    @Option(help: "Seconds to confirm a new, freshly authorized connection after restart.")
    var startupTimeout: Int = 180

    @Flag(help: "On a Mac in a two-Mac cluster: restart single-Mac serving on this Mac only; the pair keeps running.")
    var solo = false

    mutating func validate() throws {
        guard (1...3600).contains(startupTimeout) else { throw ValidationError("--startup-timeout must be between 1 and 3600 seconds") }
    }

    @OptionGroup var configOptions: ConfigOptions

    /// What `darkbloom restart` does on a Mac in a two-Mac cluster.
    enum PairRestart: Equatable {
        /// Restart the pair on both Macs (`ClusterPairCommands.restart`).
        case restartPair
        /// Nothing restarts, and why: the pairing record can't be read, `--solo` without single-Mac serving, or neither
        /// the pair nor single-Mac serving runs here.
        case refuse([String])
        /// Single-Mac serving as on any Mac: `--solo`, not in a cluster, or it runs here and the pair doesn't.
        case restartSingleMac
    }

    /// A plain `restart` on a Mac in a cluster acts only on what runs: the pair (`restartRestartsPair`), otherwise
    /// single-Mac serving whose job is loaded (`singleMacRunning`). It never brings back single-Mac serving that `stop`
    /// stopped: `stop` unloads the job but keeps its plist (`singleMacInstalled`). Only `--solo`, which names single-Mac
    /// serving, starts an installed job that isn't loaded, as `restart` does on a Mac that isn't in a cluster.
    static func pairRestart(_ pair: ClusterPairSummary, singleMacInstalled: Bool, singleMacRunning: Bool,
                            solo: Bool) -> PairRestart {
        guard pair.paired else { return .restartSingleMac }
        if solo { return singleMacInstalled ? .restartSingleMac : .refuse(pair.restartRefusal) }
        if pair.pairingUnreadable { return .refuse(pair.unsureRefusal("restart", "restarted")) }
        if pair.restartRestartsPair { return .restartPair }
        return singleMacRunning ? .restartSingleMac : .refuse(pair.idleRestartRefusal)
    }

    mutating func run() async throws {
        let pair = ClusterPairSummary.local()
        let wasLoaded = LaunchAgent.isLoaded()
        let installed = LaunchAgent.isInstalled() || wasLoaded
        let restart = Self.pairRestart(pair, singleMacInstalled: installed, singleMacRunning: wasLoaded, solo: solo)
        if case .refuse(let lines) = restart {
            for line in lines { print(line) }
            throw ExitCode.failure
        }
        guard restart == .restartPair || installed else {
            throw ValidationError("No launchd configuration is installed. Use \(BuildEnvironment.current.cliName) start to select the replacement configuration; the foreground provider was left running.")
        }
        // Decided first: only a restart that goes ahead opens with the mark.
        let look = DarkbloomCommandLook.forCommand()
        look.open("Darkbloom restart")
        if restart == .restartPair {
            let config = configOptions.config
            let code = await look.working("Restarting both Macs") {
                await ClusterPairCommands.restart(pair, actions: ClusterPairActions.live(config: config), config: config,
                                                  say: look.saying(ClusterPairCommands.printLine))
            }
            if code != 0 { throw ExitCode(code) }
            return
        }
        // A pair that doesn't run here may still have a leftover part holding this Mac's serving lock.
        if !solo, pair.pairIdle, pair.started, pair.serviceRunning {
            print(pair.servingAloneLine)
            try await Start.releaseLeftoverPart(pair)
        }
        let soloState = ServiceDrain.soloProviderState()
        let previous = soloState?.processIdentity ?? LaunchAgent.launchSnapshot()?.process
        let session = try await look.working("Draining accepted requests") {
            try await ServiceDrain.prepare(options: drain, state: soloState)
        }
        defer { session.release() }
        do {
            try await look.working("Restarting the provider") {
                try await ServiceDrain.stopDrainedProvider(unloadService: false, daemonState: ServiceDrain.soloProviderState())
                try LaunchAgent.restartAfterDrain()
            }
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
        try await look.working("Waiting for the restarted provider's fresh authorization") {
            try await ServiceDrain.waitForRestart(previous: previous, timeout: startupTimeout)
        }
        print("  \(BuildEnvironment.current.cliName) status  Check status")
        if pair.paired { print(pair.restartAddendum) }
    }
}
