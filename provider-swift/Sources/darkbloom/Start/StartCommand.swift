import Foundation
import ArgumentParser
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the provider as a background service.",
        discussion: """
        Scans local MLX models, lets you pick which to serve, then launches
        a launchd background service. Use --model to skip the interactive picker.

        In a terminal, the first start asks how this Mac serves: only you (--local),
        the Darkbloom network (--network), or both with you first (--me-first). The
        answer is saved, and so is a flag; --choose asks again. Every choice serves in
        the background; --local --here serves only you in this terminal instead. Without
        a terminal and without a saved answer, it serves the Darkbloom network as before.

        On a Mac in a two-Mac cluster it starts the pair instead, also after `stop`: in a
        terminal the `darkbloom cluster` screen; without one the pair's saved model,
        waiting until it serves (exit 0 serving, 3 not serving yet, 5 the other Mac isn't
        answering). --solo serves this Mac alone instead, while the pair doesn't run here;
        single-Mac options there need it, except the app's Start (--model, --local-endpoint,
        no terminal), which starts the pair with its own model and says so.
        """
    )

    @OptionGroup var configOptions: ConfigOptions
    @OptionGroup var drain: DrainOptions

    @Option(help: "Override coordinator WebSocket URL.")
    var coordinatorURL: String?

    @Option(help: "Model ID to serve (repeatable, skips interactive picker).")
    var model: [String] = []

    @Flag(inversion: .prefixedNo, help: "Report downloaded network models to experimental Autopilot; keep the normal startup model and memory selector.")
    var autopilot: Bool?

    @Flag(help: "Serve all local models (skips interactive picker).")
    var all = false

    @Option(help: "Minutes without requests before a model is unloaded (0 = keep loaded). Saved to your config; the interactive picker asks this too. See `\(BuildEnvironment.current.cliName) idle`.")
    var idleTimeout: UInt64?

    @Flag(help: "Interactively configure weekly availability and preloading before starting.")
    var schedule = false

    @Flag(inversion: .prefixedNo, help: .hidden)
    var foreground = false

    @Flag(help: "Only me: this Mac's local OpenAI-compatible API only, in the background; Darkbloom never contacts this Mac. Saved.")
    var local = false

    @Flag(help: "With --local: serve Only me in this terminal for this session (closing it, or Ctrl-C, stops it), instead of the background service.")
    var here = false

    @Flag(help: "Serve a local OpenAI endpoint ALONGSIDE the coordinator (unified mode): same loaded models serve both the public fleet and local clients. Darkbloom pauses while you use it unless --no-me-first. Saved.")
    var localEndpoint = false

    @Flag(help: "Serve the Darkbloom network only, with no local API. Saved.")
    var network = false

    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "--me-first: Darkbloom and you, you first. Darkbloom pauses while you use this Mac's local API and comes back once you're idle (saved). --no-me-first: Darkbloom keeps serving while you use it (saved).")
    var meFirst: Bool?

    @Option(name: .customLong("me-first-idle"),
            help: ArgumentHelp("Minutes with none of your requests before Darkbloom comes back (1–120, default 2; saved). Not the model memory setting (--idle-timeout).", valueName: "minutes"))
    var meFirstIdle: UInt64?

    @Option(help: ArgumentHelp("Where your requests go when this Mac can't take them: this-mac, my-macs (your other Macs, free) or my-macs-first (then the Darkbloom network, billed). Saved; needs an account key (`\(BuildEnvironment.current.cliName) route key`).", valueName: "route"),
            transform: Start.parseRoute)
    var route: LocalSettings.Route?

    @Flag(help: "Ask how this Mac serves again, although a choice is saved (in a terminal).")
    var choose = false

    @Flag(help: "Set up OpenCode to use Darkbloom: adds a provider to ~/.config/opencode (with a backup) pointing at this Mac's local API. Starts Darkbloom only if no local API runs.")
    var opencode = false

    @Flag(help: "Set up Hermes Agent to use Darkbloom: adds a provider to ~/.hermes/config.yaml (with a backup) and makes it the main model. Starts Darkbloom only if no local API runs.")
    var hermes = false

    /// The tools `--opencode` / `--hermes` set up, in a fixed order.
    var requestedTools: [IntegrationTool] {
        IntegrationTool.allCases.filter { tool in
            switch tool {
            case .opencode: opencode
            case .hermes: hermes
            }
        }
    }

    @Option(name: .customLong("port"), help: ArgumentHelp("This Mac's local API port, used and saved. Default: [local] port, else the port this Mac's local API already uses, else the first free port from \(LocalAPIPort.firstCandidate) (never 8000 or \(ClusterLocalServing.pairPortsWords)); saved the first time.", valueName: "port"))
    var portOption: UInt16?

    @Option(name: .customLong("bind"), help: ArgumentHelp("Bind address for the local API (default [local] bind, else 127.0.0.1; a tailnet IP exposes it to same-account devices, still API-key gated).", valueName: "bind"))
    var bindOption: String?

    @Flag(help: "Disable local API-key auth for --local / --local-endpoint (NOT recommended; trusted/airgapped use only).")
    var noAuth = false

    /// `--port`, else the build's default: for callers that resolved nothing (`servingFromFlags`). A start resolves
    /// this Mac's one port instead (`StartServingResolver`).
    var port: UInt16 { portOption ?? BuildEnvironment.current.defaultLocalPort }

    /// `--bind`, else loopback.
    var bind: String { bindOption ?? LocalSettings.defaultBind }

    /// The options that decide how this Mac serves (`[local]`).
    var localFirstOptions: LocalFirstOptions {
        LocalFirstOptions(local: local, localEndpoint: localEndpoint, network: network, meFirst: meFirst,
                          meFirstIdleMinutes: meFirstIdle, route: route, choose: choose, port: portOption,
                          bind: bindOption, noAuth: noAuth, foreground: foreground, here: here)
    }

    /// How this start serves from its flags alone, as before `[local]`: for callers that resolved nothing (tests that
    /// call a serving mode directly).
    var servingFromFlags: StartServing {
        let flag = localFirstOptions.modeFlag
        let mode = flag?.mode ?? LocalSettings.launchMode(local: local, localEndpoint: localEndpoint)
        return StartServing(mode: mode, source: flag.map { .flag($0) } ?? .today,
                            meFirst: mode == .both && meFirst != false,
                            meFirstIdleMinutes: meFirstIdle ?? LocalSettings.defaultMeFirstIdleMinutes, route: route,
                            accountKeySaved: nil, port: port, bind: bind, noAuth: noAuth)
    }

    @Sendable static func parseRoute(_ text: String) throws -> LocalSettings.Route {
        guard let route = LocalSettings.Route(rawValue: text) else {
            throw ValidationError("--route must be this-mac (only this Mac), my-macs (your other Macs, free) or "
                + "my-macs-first (then the Darkbloom network, billed), not \"\(text)\".")
        }
        return route
    }

    @Flag(help: "Register a foreground control-only cluster member; requires a saved cluster and never serves solo inference.")
    var clusterMember = false

    @Flag(help: "Use the saved distributed cluster for local serving and register its leader as a control-only member (requires --local).")
    var distributed = false

    @Flag(name: .customLong("no-coordinator"),
          help: "With --distributed: serve the saved cluster on the local API only and never contact the coordinator (`\(ClusterPairSummary.cli) cluster local` starts it this way).")
    var noCoordinator = false

    @Flag(help: "With --cluster-member: install the member as an always-on background service (starts at login, waits for the cluster link, restarts with backoff, coordinated updates).")
    var alwaysOn = false

    /// launchd's entry point for `--always-on` (and usable in a terminal):
    /// run the member under the cluster-member supervisor in this process.
    @Flag(help: .hidden)
    var supervise = false

    @Flag(help: "On a Mac in a two-Mac cluster: start single-Mac serving on this Mac instead of the pair (refused while the pair runs here: both take this Mac's one serving lock).")
    var solo = false

    /// Both cluster modes are control-only: they take the saved cluster's
    /// model and lifecycle, so every solo serving option is refused at parse.
    mutating func validate() throws {
        if let conflict = localFirstOptions.conflict { throw ValidationError(conflict) }
        if let refusal = toolFlagsRefusal { throw ValidationError(refusal) }
        let soloOverrides = !model.isEmpty || all || idleTimeout != nil || schedule || autopilot != nil
            || network || meFirst != nil || meFirstIdle != nil || route != nil || choose || here
        if clusterMember {
            guard !distributed, !local, !soloOverrides else {
                throw ValidationError("--cluster-member cannot be combined with solo serving or local distributed mode.")
            }
            guard !(alwaysOn && supervise) else {
                throw ValidationError("--always-on installs the service that runs --supervise; use one of them.")
            }
            // The pair's local API beside Darkbloom (Both, me first): the cluster service passes --local-endpoint, its
            // port and its address to the part it runs; the API always needs the pair's key.
            if localEndpoint {
                guard !noAuth else {
                    throw ValidationError("The pair's local API always needs its key: --cluster-member --local-endpoint doesn't take --no-auth.")
                }
                guard !alwaysOn, !supervise else {
                    throw ValidationError("--local-endpoint is for the part the cluster service runs (--cluster-member --foreground), not --always-on or --supervise.")
                }
            }
        } else if alwaysOn || supervise {
            throw ValidationError("--always-on and --supervise apply to --cluster-member only.")
        }
        if noCoordinator {
            guard distributed else {
                throw ValidationError("--no-coordinator applies to --distributed only (plain --local never contacts the coordinator).")
            }
            guard coordinatorURL == nil else { throw ValidationError("--no-coordinator never contacts a coordinator: drop --coordinator-url.") }
        }
        guard distributed else { return }
        guard local, !foreground, !localEndpoint else {
            throw ValidationError("Distributed startup requires --local; its coordinator connection is control-only.")
        }
        guard !soloOverrides else {
            throw ValidationError("Distributed startup uses the saved cluster model and lifecycle; solo model and idle overrides are unavailable.")
        }
    }

    /// Only the process actually owned by launchd ignores stale baked argv.
    /// A manually launched foreground command retains explicit --model priority.
    static func usesPinnedModelSelection(configPath: URL, launchManaged: Bool) -> Bool {
        guard launchManaged, let content = try? String(contentsOf: configPath, encoding: .utf8) else { return false }
        return tomlKeyPresent(content, section: "backend", key: "enabled_models")
    }

    /// Public URL of the Darkbloom Terms of Service.
    static let termsURL = "https://darkbloom.dev/terms.html"

    /// Prints a one-line terms-of-service notice. Starting the provider is the
    /// act of acceptance — there is no separate yes/no prompt — so this is an
    /// informational notice, not a gate. Shown only for the user-facing
    /// invocation; the launchd-relaunched `--foreground` child skips it since
    /// the user already saw it when they ran `darkbloom start`.
    private func printTermsNotice() {
        print("By starting the provider, you agree to the Darkbloom Terms of Service:")
        print("  \(Start.termsURL)")
        print()
    }

    /// What `darkbloom start` does on a Mac in a two-Mac cluster: it starts the pair, whatever its state, as `darkbloom
    /// cluster` does (the same screen in a terminal; the saved model for a script), unless `--solo` asks for single-Mac
    /// serving. `run` never asks the cluster's own starts (`--cluster-member`, `--distributed`, the cluster service's solo
    /// part) or launchd's (`--foreground`).
    enum PairStart: Equatable {
        /// Single-Mac serving as on any Mac, after the one line (nil: not in a cluster).
        case single(note: String?)
        /// `--solo` where the pair doesn't run here: single-Mac serving starts after `note`. Where a leftover part runs
        /// here (`ClusterPairSummary.leftoverPartHere`), that part is stopped and its saved start cleared first, and
        /// `Start.releaseLeftoverPartToServeAlone`'s lines say so instead of `note`.
        case serveAlone(note: String)
        /// This Mac's pairing record can't be read: refused without `--solo`, and why.
        case refuse([String])
        /// A terminal: the screen `darkbloom cluster` shows on this Mac.
        case openScreen
        /// No terminal: the pair starts with its saved model. The desktop app's Start too (`appStartOptions`): a model it
        /// named other than the pair's, or a local API the pair doesn't give this Mac, is said after the start
        /// (`ClusterPairSummary.appStartLines`).
        case startPair
        /// Single-Mac options without `--solo`: nothing starts, and why (never ignored).
        case refuseOptions([String])
    }

    /// The single-Mac options the desktop app's Start passes (`DesktopBackend.arguments`). The app has no `--solo` and no
    /// terminal, so on a paired Mac they start the pair, as a plain start does; never this Mac alone.
    static let appStartOptions: Set<String> = ["--model", "--local-endpoint"]

    /// The single-Mac options given, by name. On a Mac in a cluster each needs `--solo`; `--config` applies to the pair.
    var singleMacOptions: [String] {
        var given: [String] = []
        if coordinatorURL != nil { given.append("--coordinator-url") }
        if !model.isEmpty { given.append("--model") }
        if let autopilot { given.append(autopilot ? "--autopilot" : "--no-autopilot") }
        if all { given.append("--all") }
        if idleTimeout != nil { given.append("--idle-timeout") }
        if schedule { given.append("--schedule") }
        if local { given.append("--local") }
        if here { given.append("--here") }
        if localEndpoint { given.append("--local-endpoint") }
        if network { given.append("--network") }
        if let meFirst { given.append(meFirst ? "--me-first" : "--no-me-first") }
        if meFirstIdle != nil { given.append("--me-first-idle") }
        if route != nil { given.append("--route") }
        if choose { given.append("--choose") }
        if portOption != nil { given.append("--port") }
        if bindOption != nil { given.append("--bind") }
        if noAuth { given.append("--no-auth") }
        if drain.timeout != DrainOptions.defaultTimeout { given.append("--timeout") }
        if drain.force { given.append("--force") }
        return given
    }

    /// A plain `start` starts the pair whatever its state (stopped, given up here, loading or running), as `stop` and
    /// `cluster status` say; `--solo` is the one way to serve this Mac alone, never refused while the pair doesn't run
    /// here. Single-Mac options without it start nothing and say why (never ignored).
    static func pairStart(_ pair: ClusterPairSummary, solo: Bool, terminal: Bool, singleMacOptions: [String] = []) -> PairStart {
        guard pair.paired else { return .single(note: nil) }
        if pair.pairingUnreadable { return solo ? .single(note: pair.startNote) : .refuse(pair.startRefusal) }
        if solo { return pair.pairIdle ? .serveAlone(note: pair.servingAloneLine) : .refuse(pair.soloBesideServingRefusal) }
        if !singleMacOptions.isEmpty, terminal || !appStartOptions.isSuperset(of: singleMacOptions) {
            return .refuseOptions(pair.singleMacOptionsRefusal(singleMacOptions))
        }
        return terminal ? .openScreen : .startPair
    }

    var startsSingleMacServing: Bool { !foreground && !clusterMember && !distributed }

    /// Whether this start is a service's child, which serves exactly as its arguments say: launchd's `--foreground`
    /// child, or `start --local` that a service runs (the app's local-mode job an older version wrote without
    /// `--foreground`, or the cluster service's solo part). It never asks, and never chooses, probes or saves a port,
    /// so an updated Mac's services keep theirs; its banner, which goes to a log, shows no key.
    static func isServiceChild(local: Bool, foreground: Bool, distributed: Bool, startedByAService: () -> Bool) -> Bool {
        foreground || (local && !distributed && startedByAService())
    }

    /// Whether a service started this process: launchd's provider job, or the cluster service's solo part.
    static func startedByAService() -> Bool {
        LaunchAgent.isCurrentProcessJob() || ClusterPairSummary.startedByClusterService()
    }

    /// Tests stand in for stopping this Mac's leftover part (`ClusterService.releaseForSingleMac`).
    @TaskLocal static var releaseForTesting: (@Sendable () -> Bool)?
    /// As `releaseForTesting`, with how it ended, given what it calls before it waits for a running cluster command.
    @TaskLocal static var releaseOutcomeForTesting: (@Sendable (_ waiting: () -> Void) -> ClusterService.SingleMacRelease)?

    /// How long the leftover part gets to release its model and the serving lock.
    static let releaseSeconds: Double = 300

    /// The person chose single-Mac serving on this paired Mac (`ClusterSoloChoice`): it doesn't step aside for the pair.
    static func recordSoloChoice() {
        guard ClusterPairSummary.readsThisMacsCluster, let directory = ClusterService.soloChoiceDirectory() else { return }
        ClusterSoloChoice.record(in: directory)
    }

    /// The person starts the pair here: an earlier choice of single-Mac serving no longer stands.
    static func clearSoloChoice() {
        guard ClusterPairSummary.readsThisMacsCluster, let directory = ClusterService.soloChoiceDirectory() else { return }
        ClusterSoloChoice.clear(in: directory)
    }

    /// Stops this Mac's leftover part of `pair` and clears its saved start (`ClusterService.releaseForSingleMac`), or
    /// says why it couldn't and fails (exit 1).
    static func releaseLeftoverPart(_ pair: ClusterPairSummary) async throws {
        // Flushed: the desktop app reads this output through a pipe while the command waits.
        let waiting: @Sendable () -> Void = { print(ClusterPairSummary.releaseWaitLine); fflush(stdout) }
        let released: ClusterService.SingleMacRelease
        if let release = releaseOutcomeForTesting {
            released = release(waiting)
        } else if let release = releaseForTesting {
            released = release() ? .released : .partNotStopped
        } else if !ClusterPairSummary.readsThisMacsCluster {
            released = .released
        } else {
            released = await Task.detached { ClusterService.releaseForSingleMac(seconds: releaseSeconds, waiting: waiting) }.value
        }
        guard released != .released else { return }
        for line in released == .commandStillRunning ? ClusterPairSummary.releaseBusyLines : pair.releaseFailedLines { print(line) }
        throw ExitCode.failure
    }

    /// `releaseLeftoverPart` before single-Mac serving (`start --solo`, `restart`, `update`): what it does first, then
    /// that the saved start is cleared, only once it is. A running cluster command can make it wait and end with nothing
    /// changed (`releaseBusyLines`).
    static func releaseLeftoverPartToServeAlone(_ pair: ClusterPairSummary) async throws {
        print(pair.leftoverStopLine)
        fflush(stdout)
        try await releaseLeftoverPart(pair)
        print(pair.leftoverReleasedLine)
    }

    /// The title beside the mark as `darkbloom start` opens in a terminal (`DarkbloomCommandLook`).
    static let lookTitle = "Darkbloom start"

    /// Flags `run` refuses before any work: `--local` with `--local-endpoint` or `--autopilot`, `--schedule` with
    /// `--local` or `--foreground`, and an `--idle-timeout` out of range (unless `--schedule`, whose wizard runs first).
    var flagsRefuseStart: Bool {
        (local && (localEndpoint || autopilot == true)) || (schedule && (local || foreground))
            || (!schedule && idleTimeout.map { IdleUnloadPolicy.validate(minutes: $0) != nil } == true)
    }

    mutating func run() async throws {
        Darkbloom.ensureLogging()
        // Line-buffer stdout: in a log or a pipe (`start … > log`, nohup) it is block-buffered, and a start that serves
        // never exits, so its banner, "Listening on" and the tool lines would wait in the buffer.
        setvbuf(stdout, nil, _IOLBF, 0)
        // From here on, a service's child is the --foreground service (`isServiceChild`).
        foreground = Self.isServiceChild(local: local, foreground: foreground, distributed: distributed,
                                         startedByAService: Self.startedByAService)
        // `--opencode` / `--hermes` beside a running local API: set the tools up for it, and start nothing.
        if try await setUpToolsForRunningLocalAPI() { return }
        let look = DarkbloomCommandLook.forCommand()
        // Decided first: only a start that goes ahead opens with the mark, never one its flags refuse.
        let opensLook = !flagsRefuseStart
        if startsSingleMacServing, !ClusterPairSummary.startedByClusterService() {
            let pair = ClusterPairSummary.local()
            let choice = Self.pairStart(pair, solo: solo, terminal: ClusterPairCommands.isTerminal(),
                                        singleMacOptions: singleMacOptions)
            // Only single-Mac serving opens with the mark here: a refusal starts nothing, and the cluster's screen
            // draws the mark itself.
            switch choice {
            case .single, .serveAlone:
                // Before the pair is touched (the solo choice recorded, this Mac's part stopped and its saved start
                // cleared): the refusals of how this Mac would serve alone, such as `--choose` without a terminal.
                // `resolveServing` makes the same ones again below.
                if pair.paired {
                    let step = try localFirstOptions.modeStep(saved: try savedLocalSettings(configPath: configOptions.config),
                                                              terminal: ClusterPairCommands.isTerminal())
                    // Likewise a start that would ask for its models (checked again after `resolveServing`, where a Mac
                    // that isn't paired meets it).
                    if case .decided(let mode, _) = step { try requireModelsNamedWithoutTerminal(mode: mode) }
                }
                if opensLook { look.open(Self.lookTitle) }
            default: break
            }
            switch choice {
            case .single(let note):
                if let note { print(note) }
                if pair.paired { Self.recordSoloChoice() }
            case .serveAlone(let note):
                if pair.leftoverPartHere {
                    try await Self.releaseLeftoverPartToServeAlone(pair)
                } else {
                    print(note)
                }
                Self.recordSoloChoice()
            case .refuse(let lines):
                for line in lines { print(line) }
                throw ExitCode.failure
            case .refuseOptions(let lines):
                for line in lines { print(line) }
                throw ExitCode.validationFailure
            case .openScreen:
                Self.clearSoloChoice()
                print(pair.actingLine("starting the pair"))
                try await ClusterPairCommands.openScreen(config: configOptions.config)
                try await setUpToolsBesidePair()
                return
            case .startPair:
                Self.clearSoloChoice()
                let code = await ClusterPairCommands.start(pair, actions: ClusterPairActions.live(config: configOptions.config),
                                                           config: configOptions.config)
                // What the app's Start asked for and the pair doesn't take: another model, a local API here.
                for line in pair.appStartLines(named: model, localEndpoint: localEndpoint, code: code) { print(line) }
                if code != 0 { throw ExitCode(code) }
                try await setUpToolsBesidePair()
                return
            }
        }
        if !foreground {
            if opensLook { look.open(Self.lookTitle) }
            printTermsNotice()
        }

        // --local (coordinator-less) and --local-endpoint (alongside the
        // coordinator) are mutually exclusive serve modes; reject the ambiguous
        // combination rather than silently picking one.
        if local && localEndpoint {
            printError("--local and --local-endpoint are mutually exclusive: use --local for a coordinator-less local server, or --local-endpoint to serve a local endpoint alongside the coordinator.")
            throw ExitCode.failure
        }
        // Control-only cluster modes leave before the solo runtime is
        // prepared: no model scan, Metal probe or serving-mode selection.
        // The native owner child, not this process, holds the device.
        if clusterMember {
            if alwaysOn {
                try await installClusterMemberService()
            } else if supervise {
                try await runClusterMemberSupervisor()
            } else {
                try await runClusterMember()
            }
            return
        }
        if distributed {
            try await runLocalDistributed()
            return
        }

        // How this Mac serves: a flag, the saved choice, or the question in a terminal.
        guard let serving = try resolveServing() else {
            print(ServingQuestion.cancelled)
            return
        }
        let localOnly = serving.mode == .local
        // No start asks without a terminal, the models' picker included.
        try requireModelsNamedWithoutTerminal(mode: serving.mode)

        var scheduleEdit: (current: ScheduleSettings, draft: ScheduleSettings)?
        if schedule {
            guard !localOnly, !foreground else {
                throw ValidationError("--schedule configures a background provider. Use `\(BuildEnvironment.current.cliName) schedule` before --foreground; standalone --local does not use availability windows.")
            }
            try AvailabilitySchedule.requireInteractiveTerminal()
            let loaded = try loadRuntimeConfiguration(configPath: configOptions.config)
            let current = ScheduleSettings(config: loaded.config)
            guard let draft = ScheduleWizard().run(current: current,
                idleMinutes: idleTimeout ?? loaded.config.backend.idleTimeoutMins,
                preloadModels: loaded.config.backend.preloadModels, starting: true) else {
                print("Cancelled. Configuration unchanged; provider not started or stopped.")
                return
            }
            scheduleEdit = (current, draft)
        }

        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        try CacheStorage.configure(snapshot.config.cache)
        let effectiveCoordinator = coordinatorURL ?? snapshot.config.coordinator.url
        var effectiveConfig = snapshot.config
        scheduleEdit?.draft.apply(to: &effectiveConfig)
        if !localOnly { try effectiveConfig.schedule?.validate() }
        if localOnly {
            if autopilot == true { throw ValidationError("Autopilot requires a network provider.") }
            // A standalone local invocation does not inherit network residency
            // restrictions or change the saved network enrollment.
            effectiveConfig.backend.modelAutopilot.enabled = false
        }
        if let idleTimeout {
            if let problem = IdleUnloadPolicy.validate(minutes: idleTimeout) {
                printError("--idle-timeout: \(problem)")
                throw ExitCode.failure
            }
            if foreground {
                // Plists written before the idle policy moved to TOML baked
                // `--idle-timeout` into the daemon argv. The TOML key is the
                // authority now — `darkbloom idle` must win over a stale plist
                // after `restart` — so the flag only fills in when the config
                // does not set the key.
                if !idleTimeoutPinned(at: snapshot.configPath) {
                    effectiveConfig.backend.idleTimeoutMins = idleTimeout
                }
            } else {
                // Operator-facing: `--idle-timeout` is a writer of the one
                // authority, so `restart` and later `start`s keep the choice.
                let result = try setIdleUnloadMinutes(idleTimeout, configPath: configOptions.config)
                if result.changed {
                    print("Memory when idle: \(IdleUnloadPolicy.describe(minutes: idleTimeout)) (saved to \(result.path.path))")
                }
                effectiveConfig.backend.idleTimeoutMins = idleTimeout
            }
        }

        // These controls are process-start latches in MLX/MLXLM. Project the
        // authoritative TOML, bind the immutable default runtime metallib, and
        // only then let requireMetal() perform the first MLX touch.
        let boundMetallibHash: String?
        do {
            boundMetallibHash = try Self.prepareServeRuntime(
                settings: snapshot.config.gemmaOptimizations)
        } catch {
            printError("Cannot start: \(error)")
            throw ExitCode.failure
        }

        guard let hardware = snapshot.hardware else {
            printError("Cannot start: hardware detection failed (\(snapshot.hardwareError?.localizedDescription ?? "unknown"))")
            throw ExitCode.failure
        }
        // Diagnose once from the already-bound immutable snapshot and carry
        // this exact set through every serving mode and registration path.
        let runtimeCapabilities = GLM5NextLocalServing.gatingCapabilities(
            ProviderRuntimeCapabilityDetector.detectPrepared(
                hardware: hardware,
                boundMetallibHash: boundMetallibHash),
            mode: effectiveConfig.backend.mtpMode)
        // One WARN per retired knob still set, BEFORE the serving-mode split:
        // `--local` builds no ProviderLoop, so emitting these from the serve
        // loop left standalone operators with no notice at all.
        for message in RetiredKnobWarnings.emit(config: effectiveConfig) {
            printError("warning: \(message)")
        }
        let servedModels = advertisedModels(
            from: snapshot.models, config: effectiveConfig, modelOverrides: model, includeDisabled: all,
            runtimeCapabilities: runtimeCapabilities)
        if let notice = GLMWiredLimitAdvice.startNotice(
            hardware: hardware, servedModels: servedModels, limits: .live()) {
            printError("warning: \(notice)")
        }

        switch Self.singleMacServing(mode: serving.mode, here: here, foreground: foreground) {
        case .onlyMeHere:
            try await runLocalStandalone(
                snapshot: snapshot,
                config: effectiveConfig,
                runtimeCapabilities: runtimeCapabilities,
                serving: serving
            )
        case .onlyMeService:
            try await launchOnlyMeService(
                snapshot: snapshot,
                config: effectiveConfig,
                coordinatorURL: effectiveCoordinator,
                configPath: configOptions.config == nil ? nil : snapshot.configPath,
                runtimeCapabilities: runtimeCapabilities,
                serving: serving
            )
            // Only me's server listens once its models are loaded (`[backend] startup_preload`): the tools wait as long.
            try await setUpToolsBesideDaemon(serving: serving, coordinatorURL: effectiveCoordinator,
                                             waitSeconds: Self.toolWaitSeconds
                                                + Int(clamping: effectiveConfig.backend.startupPreloadTimeoutSecs))
        case .foreground:
            try await runForeground(
                snapshot: snapshot,
                hardware: hardware,
                config: serving.servedConfig(effectiveConfig),
                coordinatorURL: effectiveCoordinator,
                runtimeCapabilities: runtimeCapabilities,
                serving: serving
            )
        case .service:
            try await launchDaemon(
                snapshot: snapshot,
                config: effectiveConfig,
                coordinatorURL: effectiveCoordinator,
                configPath: configOptions.config == nil ? nil : snapshot.configPath,
                runtimeCapabilities: runtimeCapabilities,
                scheduleEdit: scheduleEdit,
                serving: serving
            )
            try await setUpToolsBesideDaemon(serving: serving, coordinatorURL: effectiveCoordinator)
        }
    }

    /// How this start serves (`StartServingResolver`), with the question asked in a terminal; nil when the person
    /// cancelled at the question. Nothing is saved yet: `saveServingChoice` saves once the start goes ahead.
    func resolveServing(environment: ServingEnvironment = .live) throws -> StartServing? {
        guard let serving = try StartServingResolver.resolve(
            localFirstOptions, saved: try savedLocalSettings(configPath: configOptions.config), environment: environment)
        else { return nil }
        if serving.mode == .local, !local {
            // `--local` is refused with these before anything is asked; an answer is refused before it's saved.
            if schedule {
                throw ValidationError("--schedule configures a background provider; \"Only me, on this Mac\" does not "
                    + "use availability windows. Nothing was saved.")
            }
            if autopilot == true { throw ValidationError("Autopilot requires a network provider. Nothing was saved.") }
        }
        // The tools need a local API. Whether an account key is saved, which the tool block says too, the resolver
        // has read already: a tool flag goes with neither --no-auth nor --foreground (`toolFlagsRefusal`).
        if !requestedTools.isEmpty, !serving.hasLocalAPI {
            throw ValidationError(ToolIntegrationStep.noLocalAPI(requestedTools) + " Nothing was started or saved.")
        }
        return serving
    }

    /// Saves what this start chose in `[local]` (a mode only from the question or a mode flag,
    /// `LocalFirstOptions.savesModeFlag`) and says which port a new local API got. Called once the start goes ahead: a
    /// cancelled picker or a refused start saves nothing.
    func saveServingChoice(_ serving: StartServing) throws {
        guard !serving.change.isEmpty else { return }
        try setLocalSettings(configPath: configOptions.config) { serving.change.apply(to: &$0) }
        if let note = serving.portNote { print(note) }
    }

    /// Whether the local router's account key is in this Mac's Keychain. Never prints it.
    static func accountKeySaved(_ store: any LocalRouterAccountKeyStore = KeychainLocalRouterAccountKeyStore()) -> Bool {
        (try? store.load())?.isEmpty == false
    }

    /// Backward-compatible forwarding shim for the process-start environment
    /// projection and metallib binding. The real seam (and its ordering
    /// contract: config projection, then binding, then the first MLX touch)
    /// lives in `ServeRuntimePreparer.prepareRuntime` so `benchmark` mirrors the
    /// serve path without referencing `Start`. Tests target both seams.
    @discardableResult
    internal static func prepareServeRuntime(
        settings: GemmaOptimizationSettings,
        apply: (GemmaOptimizationSettings) throws -> Void = {
            try GemmaOptimizationEnvironment.apply($0)
        },
        bindMetallib: () -> String? = {
            bindRuntimeMetallibForMLX(from: nil)
        },
        requireMetal: () throws -> Void = {
            _ = try GPUEnforcement.requireMetal()
        }
    ) throws -> String? {
        try ServeRuntimePreparer.prepareRuntime(
            settings: settings,
            apply: apply,
            bindMetallib: bindMetallib,
            requireMetal: requireMetal
        )
    }

}
