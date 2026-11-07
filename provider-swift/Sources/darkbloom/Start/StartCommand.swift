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
        answer is saved; --choose asks again. Without a terminal and without a saved
        answer, it serves the Darkbloom network as before.

        On a Mac in a two-Mac cluster whose pair runs, it starts the pair instead: in a
        terminal the `darkbloom cluster` screen; without one the pair's saved model,
        waiting until it serves (exit 0 serving, 3 not serving yet, 5 the other Mac isn't
        answering). Single-Mac options there need --solo, refused while the pair runs.
        While the pair doesn't run on this Mac (stopped, or the other Mac gone), it serves
        this Mac alone; in a terminal it asks first.
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

    @Flag(help: "Run a local OpenAI-compatible HTTP server only; do not connect to the coordinator.")
    var local = false

    @Flag(help: "Serve a local OpenAI endpoint ALONGSIDE the coordinator (unified mode): same loaded models serve both the public fleet and local clients. Darkbloom pauses while you use it unless --no-me-first.")
    var localEndpoint = false

    @Flag(help: "Serve the Darkbloom network only, with no local API, for this start.")
    var network = false

    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "--me-first: Darkbloom and you, you first. Darkbloom pauses while you use this Mac's local API and comes back once you're idle. --no-me-first: Darkbloom keeps serving while you use it (saved).")
    var meFirst: Bool?

    @Option(name: .customLong("me-first-idle"),
            help: ArgumentHelp("Minutes with none of your requests before Darkbloom comes back (1–120, default 2; saved). Not the model memory setting (--idle-timeout).", valueName: "minutes"))
    var meFirstIdle: UInt64?

    @Option(help: ArgumentHelp("Where your requests go when this Mac can't take them: this-mac, my-macs (your other Macs, free) or my-macs-first (then the Darkbloom network, billed). Saved; needs an account key (`\(BuildEnvironment.current.cliName) route key`).", valueName: "route"),
            transform: Start.parseRoute)
    var route: LocalSettings.Route?

    @Flag(help: "Ask how this Mac serves again, although a choice is saved (in a terminal).")
    var choose = false

    @Option(name: .customLong("port"), help: ArgumentHelp("Local server port (default: [local] port, else \(BuildEnvironment.current.defaultLocalPort); a new local API from the start question or --me-first gets the first free port from there, never 8000).", valueName: "port"))
    var portOption: UInt16?

    @Option(name: .customLong("bind"), help: ArgumentHelp("Bind address for the local API (default [local] bind, else 127.0.0.1; a tailnet IP exposes it to same-account devices, still API-key gated).", valueName: "bind"))
    var bindOption: String?

    @Flag(help: "Disable local API-key auth for --local / --local-endpoint (NOT recommended; trusted/airgapped use only).")
    var noAuth = false

    /// `--port`, else the build's default: what `--local` and `--local-endpoint` take without `[local] port`.
    var port: UInt16 { portOption ?? BuildEnvironment.current.defaultLocalPort }

    /// `--bind`, else loopback.
    var bind: String { bindOption ?? LocalSettings.defaultBind }

    /// The options that decide how this Mac serves (`[local]`).
    var localFirstOptions: LocalFirstOptions {
        LocalFirstOptions(local: local, localEndpoint: localEndpoint, network: network, meFirst: meFirst,
                          meFirstIdleMinutes: meFirstIdle, route: route, choose: choose, port: portOption,
                          bind: bindOption, noAuth: noAuth, foreground: foreground)
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
        let soloOverrides = !model.isEmpty || all || idleTimeout != nil || schedule || autopilot != nil
            || network || meFirst != nil || meFirstIdle != nil || route != nil || choose
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

    /// What `darkbloom start` does on a Mac in a two-Mac cluster: it starts the pair, as `darkbloom cluster` does (the
    /// same screen in a terminal; the saved model for a script), unless `--solo` asks for single-Mac serving. `run`
    /// never asks the cluster's own starts (`--cluster-member`, `--distributed`, the cluster service's solo part) or
    /// launchd's (`--foreground`).
    enum PairStart: Equatable {
        /// Single-Mac serving as on any Mac, after the one line (nil: not in a cluster).
        case single(note: String?)
        /// The pair doesn't run here: this Mac's leftover part is stopped and its saved start cleared
        /// (`ClusterService.releaseForSingleMac`), then single-Mac serving starts, after the one line.
        case serveAlone(note: String)
        /// A terminal, and the pair doesn't run here: "Serve on this Mac alone" or "Start the pair"; alone is the
        /// default when the other Mac isn't answering.
        case choose(aloneByDefault: Bool)
        /// This Mac's pairing record can't be read: refused without `--solo`, and why.
        case refuse([String])
        /// A terminal: the screen `darkbloom cluster` shows on this Mac.
        case openScreen
        /// No terminal: the pair starts with its saved model.
        case startPair
        /// Single-Mac options without `--solo`: nothing starts, and why (never ignored).
        case refuseOptions([String])
    }

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

    static func pairStart(_ pair: ClusterPairSummary, solo: Bool, terminal: Bool,
                          singleMacOptions: [String] = [], soloBlocked: Bool = false) -> PairStart {
        guard pair.paired else { return .single(note: nil) }
        if pair.pairingUnreadable { return solo ? .single(note: pair.startNote) : .refuse(pair.startRefusal) }
        // Single-Mac serving blocks a started pair whose other Mac answers: `start` (the ✗'s "Then run `darkbloom start`")
        // starts the pair, whose screen offers to stop it; never "Serve on this Mac alone", which would recreate the block.
        if soloBlocked, !solo, singleMacOptions.isEmpty, pair.started, pair.otherMacReachable { return terminal ? .openScreen : .startPair }
        // The pair doesn't run here (stopped, or left from a pair whose other Mac stopped taking part): the way back to
        // single-Mac serving is never refused. A person at a terminal chooses; everything else serves this Mac alone,
        // unless the other Mac answers: a pair that hasn't served yet may still be loading, so only --solo stops it then.
        if pair.pairIdle {
            if solo { return .serveAlone(note: pair.servingAloneLine) }
            if terminal, singleMacOptions.isEmpty { return .choose(aloneByDefault: !pair.otherMacReachable) }
            if !pair.started || !pair.otherMacReachable { return .serveAlone(note: pair.servingAloneLine) }
        }
        if solo { return .refuse(pair.soloBesideServingRefusal) }
        if !singleMacOptions.isEmpty { return .refuseOptions(pair.singleMacOptionsRefusal(singleMacOptions)) }
        return terminal ? .openScreen : .startPair
    }

    var startsSingleMacServing: Bool { !foreground && !clusterMember && !distributed }

    /// Tests stand in for stopping this Mac's leftover part (`ClusterService.releaseForSingleMac`).
    @TaskLocal static var releaseForTesting: (@Sendable () -> Bool)?

    /// How long the leftover part gets to release its model and the serving lock.
    static let releaseSeconds: Double = 300

    /// Single-Mac serving blocks the pair: on this Mac (its serving lock), or as the pair's status says.
    static func soloBlocksPair(_ pair: ClusterPairSummary) -> Bool {
        guard pair.paired, ClusterPairSummary.readsThisMacsCluster else { return false }
        return ProviderInstanceHolder.singleMacServing() != nil || pair.reason.map(ClusterOnboardingSoloServing.isBlock) == true
    }

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

    static func releaseLeftoverPart() async -> Bool {
        if let release = releaseForTesting { return release() }
        guard ClusterPairSummary.readsThisMacsCluster else { return true }
        return await Task.detached { ClusterService.releaseForSingleMac(seconds: releaseSeconds) }.value
    }

    /// Tests answer the terminal's question (nil: the default).
    @TaskLocal static var answerForTesting: String??

    /// `darkbloom start` in a terminal on a Mac whose pair doesn't run: serve alone, or open the pair's screen.
    static func chooseInTerminal(_ pair: ClusterPairSummary, aloneByDefault: Bool) -> PairStart {
        let alone = "Serve on this Mac alone", both = "Start the pair (`\(ClusterPairSummary.cli) cluster`)"
        print(pair.pairNotRunning ?? pair.pairSentence)
        print("  1. \(alone)\(aloneByDefault ? " (default)" : "")")
        print("  2. \(both)\(aloneByDefault ? "" : " (default)")")
        print("Choose 1 or 2 [\(aloneByDefault ? 1 : 2)]: ", terminator: "")
        fflush(stdout)
        let answer = (answerForTesting ?? readLine())?.trimmingCharacters(in: .whitespaces) ?? ""
        return choice(answer, pair: pair, aloneByDefault: aloneByDefault)
    }

    static func choice(_ answer: String, pair: ClusterPairSummary, aloneByDefault: Bool) -> PairStart {
        let alone: Bool
        switch answer.lowercased() {
        case "1": alone = true
        case "2": alone = false
        default: alone = aloneByDefault
        }
        return alone ? .serveAlone(note: pair.servingAloneLine) : .openScreen
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
        let look = DarkbloomCommandLook.forCommand()
        // Decided first: only a start that goes ahead opens with the mark, never one its flags refuse.
        let opensLook = !flagsRefuseStart
        if startsSingleMacServing, !ClusterPairSummary.startedByClusterService() {
            let pair = ClusterPairSummary.local()
            let pairStart = Self.pairStart(pair, solo: solo, terminal: ClusterPairCommands.isTerminal(),
                                           singleMacOptions: singleMacOptions, soloBlocked: Self.soloBlocksPair(pair))
            // Only single-Mac serving opens with the mark here: a refusal starts nothing, and the cluster's screen
            // draws the mark itself.
            var choice = pairStart
            if case .choose(let aloneByDefault) = pairStart {
                choice = Self.chooseInTerminal(pair, aloneByDefault: aloneByDefault)
            }
            switch choice {
            case .single, .serveAlone: if opensLook { look.open(Self.lookTitle) }
            default: break
            }
            switch choice {
            case .single(let note):
                if let note { print(note) }
                if pair.paired { Self.recordSoloChoice() }
            case .serveAlone(let note):
                print(note)
                Self.recordSoloChoice()
                let released = !pair.started || !pair.serviceRunning ? true : await Self.releaseLeftoverPart()
                guard released else {
                    for line in pair.releaseFailedLines { print(line) }
                    throw ExitCode.failure
                }
            case .choose:
                return
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
                return
            case .startPair:
                Self.clearSoloChoice()
                let code = await ClusterPairCommands.start(pair, actions: ClusterPairActions.live(config: configOptions.config),
                                                           config: configOptions.config)
                if code != 0 { throw ExitCode(code) }
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

        if localOnly {
            try await runLocalStandalone(
                snapshot: snapshot,
                config: effectiveConfig,
                runtimeCapabilities: runtimeCapabilities,
                serving: serving
            )
        } else if foreground {
            try await runForeground(
                snapshot: snapshot,
                hardware: hardware,
                config: serving.servedConfig(effectiveConfig),
                coordinatorURL: effectiveCoordinator,
                runtimeCapabilities: runtimeCapabilities,
                serving: serving
            )
        } else {
            try await launchDaemon(
                snapshot: snapshot,
                config: effectiveConfig,
                coordinatorURL: effectiveCoordinator,
                configPath: configOptions.config == nil ? nil : snapshot.configPath,
                runtimeCapabilities: runtimeCapabilities,
                scheduleEdit: scheduleEdit,
                serving: serving
            )
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
        return serving
    }

    /// Saves what this start chose in `[local]` (only the question saves a mode) and says which port a new local API
    /// got. Called once the start goes ahead: a cancelled picker or a refused start saves nothing.
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
