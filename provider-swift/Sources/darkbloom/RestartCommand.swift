import ArgumentParser
import ProviderCore

struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart the provider with its current model selection.",
        discussion: """
        Drains accepted requests, then restarts the launchd service, re-using the existing
        coordinator URL and model selection, serving your saved choice ([local] mode): a
        service an earlier start left serving another way restarts as saved. It does NOT
        show the model picker or change your choice. Use this to pick up a new binary or
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
    @Option(help: "Seconds to wait for the restarted service: fresh authorization, or Only me's local API.")
    var startupTimeout: Int = 180

    @Flag(help: "On a Mac in a two-Mac cluster: restart single-Mac serving on this Mac only; the pair keeps running.")
    var solo = false

    mutating func validate() throws {
        guard (1...3600).contains(startupTimeout) else { throw ValidationError("--startup-timeout must be between 1 and 3600 seconds") }
    }

    @OptionGroup var configOptions: ConfigOptions

    /// Whether Only me serves in a terminal now (`start --local --here`): the coordinator-less server, not launchd's job.
    static func terminalOnlyMe(_ state: DaemonState?, launchJob: ProcessIdentity? = LaunchAgent.launchSnapshot()?.process,
                               alive: (Int32) -> Bool = { daemonProcessAlive(pid: $0) }) -> Bool {
        guard let state, state.servesOnlyItsOwner, alive(state.pid) else { return false }
        return state.processIdentity.map { $0 != launchJob } ?? (launchJob?.pid != state.pid)
    }

    /// What `restart` says, and does nothing else, beside Only me in a terminal.
    static var terminalOnlyMeLines: [String] {
        let cli = BuildEnvironment.current.cliName
        return ["Only me serves in a terminal now (`\(cli) start --local --here`), and restart never stops it.",
                "Press Ctrl-C there, then `\(cli) restart` starts the background service again."]
    }

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
        if !solo, pair.leftoverPartHere {
            try await Start.releaseLeftoverPartToServeAlone(pair)
        }
        let soloState = ServiceDrain.soloProviderState()
        // Only me in a terminal is the person's own session: restart never stops it.
        if Self.terminalOnlyMe(soloState) {
            for line in Self.terminalOnlyMeLines { print(line) }
            throw ExitCode.failure
        }
        let previous = soloState?.processIdentity ?? LaunchAgent.launchSnapshot()?.process
        let session = try await look.working("Draining accepted requests") {
            try await ServiceDrain.prepare(options: drain, state: soloState)
        }
        defer { session.release() }
        let restarted: SavedChoiceService.Alignment
        do {
            restarted = try await look.working("Restarting the provider") {
                try await ServiceDrain.stopDrainedProvider(unloadService: false, daemonState: ServiceDrain.soloProviderState())
                return try SavedChoiceService.restartAsSaved(configPath: configOptions.config)
            }
        } catch LaunchAgentError.notInstalled {
            printError("Provider is not running. Start it with `\(BuildEnvironment.current.cliName) start`.")
            throw ExitCode.failure
        }
        if let line = restarted.line { print(line) }
        if wasLoaded {
            print(restarted.mode == .local ? "Drained Only me relaunched; waiting for its local API..."
                : "Drained provider relaunched; waiting for fresh authorization...")
        } else {
            print("Provider started.")
        }

        ServiceDrain.rearmWatchdog(explicitConfig: configOptions.config)

        // Let startup/update confirmation acquire its own process lease.
        session.release()
        try await ServiceDrain.waitForRestartedService(serving: restarted.mode, previous: previous,
                                                       timeout: startupTimeout, look: look)
        print("  \(BuildEnvironment.current.cliName) status  Check status")
        if pair.paired { print(pair.restartAddendum) }
    }
}
