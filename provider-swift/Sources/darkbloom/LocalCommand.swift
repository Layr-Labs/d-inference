import ArgumentParser
import Foundation
import ProviderCore
import SystemConfiguration

/// `darkbloom local` — serve only you on this Mac, and print the local OpenAI-compatible endpoint (URL + API key) with
/// ready-to-paste client examples. Where nothing serves, it starts Only me first, as `darkbloom start --local` does.
/// Where Darkbloom serves, it never stops it by surprise: it prints what runs and, only in a terminal, asks before
/// switching to local only. A paired Mac is pointed to `darkbloom cluster local`; the pair is never touched. `--json`
/// only reads: it emits the raw discovery record for tooling.
struct Local: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "local",
        abstract: "Serve only you on this Mac, and show the local OpenAI endpoint and API key.",
        discussion: """
        Where nothing serves, starts Only me in the background (as `\(BuildEnvironment.current.cliName) start --local`),
        then shows the address and key from ~/\(BuildEnvironment.current.installDirectoryName)/local.json. Where this Mac
        serves Darkbloom, shows what runs and, in a terminal, asks before switching to local only (Darkbloom stops);
        without a terminal it never switches. On a Mac in a two-Mac cluster, `\(BuildEnvironment.current.cliName) cluster
        local` serves the pair locally. --json only reads.
        Point any OpenAI client at the base URL with the API key to run
        inference on this Mac directly — free, and without the coordinator.
        """
    )

    @Flag(help: "Emit the raw discovery record as JSON (only reads: starts and switches nothing).")
    var json = false

    @Option(help: "Model ID to serve when this starts Only me (repeatable). Default: in a terminal the picker, without one the last selection; switching from Darkbloom keeps its models.")
    var model: [String] = []

    mutating func run() async throws {
        Darkbloom.ensureLogging()
        let pair = ClusterPairSummary.local()
        switch Self.plan(json: json, paired: pair.paired, pairServesLocalOnly: pair.localOnly,
                         serving: Self.servingNow()) {
        case .show:
            guard show(pair: pair) else { throw ExitCode.failure }
        case .pointToClusterLocal:
            let shown = show(pair: pair)
            print(Self.pairedLine)
            guard shown else { throw ExitCode.failure }
        case .startOnlyMe:
            try await startOnlyMe(models: model, pair: pair)
        case .offerSwitch:
            let shown = show(pair: pair, darkbloomServes: true)
            guard Self.asksToSwitch(terminal: ClusterPairCommands.isTerminal(), readInput: { readLine() },
                                    emit: { print($0, terminator: ""); fflush(stdout) })
            else {
                guard shown else { throw ExitCode.failure }
                return
            }
            let models = Self.switchModels(named: model, installed: LaunchAgent.installedServingJob()?.models)
            try await startOnlyMe(models: models, pair: pair)
        }
    }

    /// Starts Only me in the background as `start --local` does (its terms notice, picker, drain and summary), waits for
    /// its API as `start --local --opencode` does (it listens once its models are loaded), then shows it.
    private func startOnlyMe(models: [String], pair: ClusterPairSummary) async throws {
        var start = try Start.parse(Self.onlyMeStartArguments(models: models))
        try await start.run()
        let preload = (try? loadRuntimeConfiguration(configPath: nil).config.backend.startupPreloadTimeoutSecs) ?? 0
        let seconds = Start.toolWaitSeconds + Int(clamping: preload)
        _ = await DarkbloomCommandLook.forCommand().working("Waiting for the local API") {
            await Start.waitForLocalAPI(port: nil, seconds: seconds)
        }
        guard show(pair: pair) else { throw ExitCode.failure }
    }

    /// Prints the running local API's address and key as `local` always has; false, after saying why on standard
    /// error, when none answers. `darkbloomServes`: this Mac serves Darkbloom, so a missing API is said as that.
    private func show(pair: ClusterPairSummary, darkbloomServes: Bool = false) -> Bool {
        // readLiveInfo() returns nil when the recorded server process is gone,
        // so a stale local.json from a Ctrl-C/crash is treated as "not running"
        // rather than advertising a dead endpoint.
        // On a Mac that relays a pair's API: why it has no working address now, in `status`'s words.
        guard let info = LocalEndpoint.readLiveInfo() else {
            if json {
                print("{}")
            } else if pair.relaying == nil, let down = pair.memberAPIDown {
                printError("Local API: " + down)
            } else if let starting = pair.memberAPIStarting {
                // This Mac's port for the pair's API starts once that API answers; meanwhile the pair's key, as ever.
                printError("Local API: \(starting).")
                if let key = LocalEndpoint.existingClusterToken() {
                    printError("The pair's API key (the same on both Macs, and taken on this Mac's port once it listens):")
                    printError("  \(key)")
                }
            } else if let notUp = Self.runningProviderLocalAPIFailure() {
                printError(Self.notUpLine(notUp.failure, nextFree: LocalAPIPort.nextFree(besides: notUp.failure.port),
                                          server: notUp.server))
            } else if darkbloomServes {
                for line in Self.networkOnlyLines { printError(line) }
            } else {
                printError("No local server running.")
                if let key = LocalEndpoint.existingClusterToken() {
                    // `darkbloom cluster local` with the API on the other Mac: the key is the same on both.
                    printError("The cluster's API key (the same on both Macs; `\(BuildEnvironment.current.cliName) cluster` shows where the API is):")
                    printError("  \(key)")
                } else {
                    for line in Self.notRunningHint { printError(line) }
                }
            }
            return false
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = (try? encoder.encode(info)) ?? Data("{}".utf8)
            print(String(decoding: data, as: UTF8.self))
            return true
        }

        print("Local (direct-mode) OpenAI endpoint")
        print("  base URL: \(info.baseURL)")
        if let network = Self.networkURL(host: info.host, port: info.port) {
            // Listening on every interface (`darkbloom cluster local`'s default, or `--bind 0.0.0.0`).
            print("  network:  \(network) (or this Mac's LAN or tailnet address, same port; the API key is required)")
        }
        if info.apiKey.isEmpty {
            print("  API key:  (auth disabled)")
            print("  requests: this Mac only (without a local key nothing is passed on to your other Macs or the network)")
        } else {
            print("  API key:  \(info.apiKey)")
            let pairKeyFile = ClusterPairSummary.runningPairProcesses().contains(info.pid) && LocalEndpoint.existingClusterToken() != nil
                ? LocalEndpoint.clusterTokenPath() : nil
            if let line = Self.keyFileLine(keyFile: LocalEndpoint.keyFile(forPort: Int(info.port)), pairKeyFile: pairKeyFile,
                                           home: FileManager.default.homeDirectoryForCurrentUser) {
                print(line)
            }
        }
        print("  pid:      \(info.pid)")
        // This record is this Mac's relay, which answers 503 while the pair's other Mac can't be reached, or while the
        // pair's API there doesn't listen.
        if pair.relaying?.port == info.port, let down = pair.memberAPIUnavailable { print("Local API: " + down) }
        if let state = DaemonStateFile.read(), state.pid == info.pid {
            let route = (try? savedLocalSettings(configPath: nil))?.route
            for line in Self.servingLines(info: info, state: state, route: route,
                                          accountKeySaved: { Start.accountKeySaved() }) {
                print(line)
            }
        }
        if !info.apiKey.isEmpty { print(Self.toolsLine) }
        print()
        print("Use it with any OpenAI client:")
        print("  export OPENAI_BASE_URL=\(info.baseURL)")
        if !info.apiKey.isEmpty {
            print("  export OPENAI_API_KEY=\(info.apiKey)")
        }
        print()
        print("  curl \(info.baseURL)/chat/completions \\")
        if !info.apiKey.isEmpty {
            print("    -H 'Authorization: Bearer \(info.apiKey)' \\")
        }
        print("    -H 'Content-Type: application/json' \\")
        print("    -d '{\"model\":\"<id>\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'")
        return true
    }

    /// How the server behind `info` serves, and where your requests go when it can't take them; empty when the
    /// running provider's state isn't that server's (a cluster's API, or an older provider). A server without a key
    /// gets no requests line here: `run` has said "this Mac only" under its API key. `accountKeySaved` is asked only
    /// for the requests line. Never a key or a speed.
    static func servingLines(info: LocalEndpoint.Info, state: DaemonState?, route: LocalSettings.Route?,
                             accountKeySaved: () -> Bool) -> [String] {
        guard let state, state.pid == info.pid else { return [] }
        let serving: String
        if state.servesOnlyItsOwner {
            serving = LocalFirstWords.serving(mode: .local, meFirst: false, idleMinutes: 0)
        } else if let meFirst = state.meFirst {
            serving = LocalFirstWords.serving(mode: .both, meFirst: true,
                                              idleMinutes: LocalFirstWords.idleMinutes(milliseconds: meFirst.idleMs))
        } else {
            serving = LocalFirstWords.serving(mode: .both, meFirst: false, idleMinutes: 0)
        }
        guard !info.apiKey.isEmpty else { return ["  serving:  \(serving)"] }
        let keySaved = accountKeySaved()
        return ["  serving:  \(serving)",
                "  requests: \(LocalFirstWords.requests(route: route, accountKeySaved: keySaved))"
                    + (keySaved ? "" : " (`\(BuildEnvironment.current.cliName) route key` adds your other Macs)")]
    }

    /// What `local` says when the running provider's local API couldn't listen (`DaemonState.localAPIFailure`).
    static func notUpLine(_ failure: DaemonState.LocalAPIFailure, nextFree: UInt16?,
                          server: LocalFirstWords.LocalAPIServer = .singleMac(paired: false)) -> String {
        "The local API isn't up: " + LocalFirstWords.whyNotUp(failure, nextFree: nextFree, server: server) + "."
    }

    /// The running provider's local API that couldn't listen, and whose it is; nil when none runs or nothing failed.
    static func runningProviderLocalAPIFailure()
        -> (failure: DaemonState.LocalAPIFailure, server: LocalFirstWords.LocalAPIServer)? {
        guard let state = DaemonStateFile.read(), daemonProcessAlive(pid: state.pid),
              let failure = state.localAPIFailure else { return nil }
        return (failure, .of(state, paired: ClusterPairSummary.local().paired))
    }

    /// How this Mac serves now, as `local` reads it.
    enum ServingNow: Equatable, Sendable {
        /// No provider runs and no job will start one: `local` may start Only me.
        case nothing
        /// Only me: its service, or `start --local --here` in a terminal.
        case onlyMe
        /// The Darkbloom network, with or without a local API beside it.
        case darkbloom
    }

    /// The running provider decides; between two runs of its job (a crash, a restart) the loaded job does, since launchd
    /// starts it again; else a local API that answers is Only me in a terminal.
    static func servingNow(running: DaemonState?, alive: (Int32) -> Bool, loadedJob: LocalSettings.Mode?,
                           liveLocalAPI: Bool) -> ServingNow {
        if let running, alive(running.pid) { return running.servesOnlyItsOwner ? .onlyMe : .darkbloom }
        if let loadedJob { return loadedJob == .local ? .onlyMe : .darkbloom }
        return liveLocalAPI ? .onlyMe : .nothing
    }

    /// `servingNow` on this Mac: its provider's state, its loaded LaunchAgent and `local.json`.
    static func servingNow() -> ServingNow {
        servingNow(running: DaemonStateFile.read(), alive: { daemonProcessAlive(pid: $0) },
                   loadedJob: LaunchAgent.isLoaded() ? LaunchAgent.installedServingJob()?.mode : nil,
                   liveLocalAPI: LocalEndpoint.readLiveInfo() != nil)
    }

    /// What `local` does.
    enum Plan: Equatable, Sendable {
        /// Print the address and key, as `local` always has.
        case show
        /// Nothing serves: start Only me in the background, then show it.
        case startOnlyMe
        /// Darkbloom serves: show what runs, then, only in a terminal, ask before switching to local only.
        case offerSwitch
        /// A paired Mac: show what runs, and name `cluster local`; the pair is never touched.
        case pointToClusterLocal
    }

    /// `--json` only reads. A paired Mac is the pair's (already local only: shown as it is). On a Mac alone: start Only
    /// me where nothing serves, offer the switch where Darkbloom serves, and show Only me as it runs. `serving` is read
    /// only on a Mac alone without `--json`.
    static func plan(json: Bool, paired: Bool, pairServesLocalOnly: Bool,
                     serving: @autoclosure () -> ServingNow) -> Plan {
        if json { return .show }
        if paired { return pairServesLocalOnly ? .show : .pointToClusterLocal }
        switch serving() {
        case .nothing: return .startOnlyMe
        case .onlyMe: return .show
        case .darkbloom: return .offerSwitch
        }
    }

    static let switchQuestion = "Switch this Mac to local only (stops serving Darkbloom)? [y/N] "

    /// Asks `switchQuestion` in a terminal: only y or yes switches. Without a terminal nothing is asked, and Enter, any
    /// other answer or the end of input keeps Darkbloom serving.
    static func asksToSwitch(terminal: Bool, readInput: () -> String?, emit: (String) -> Void) -> Bool {
        guard terminal else { return false }
        emit(switchQuestion)
        guard let answer = readInput() else {
            emit("\n")
            return false
        }
        return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static var pairedLine: String {
        "This Mac is in a two-Mac cluster: `\(BuildEnvironment.current.cliName) cluster local` serves the pair on its "
            + "local API only."
    }

    /// Where Darkbloom serves with no local API beside it.
    static var networkOnlyLines: [String] {
        ["This Mac serves the Darkbloom network, with no local API.",
         "  `\(BuildEnvironment.current.cliName) start --local-endpoint --no-me-first` adds one beside Darkbloom."]
    }

    /// `start`'s arguments for Only me in the background, with `models` when given.
    static func onlyMeStartArguments(models: [String]) -> [String] {
        ["--local"] + models.flatMap { ["--model", $0] }
    }

    /// The models a switch to local only serves: those named, else the ones the Darkbloom job served (none: `start`
    /// picks them as it does for `--local`).
    static func switchModels(named: [String], installed: [String]?) -> [String] {
        named.isEmpty ? installed ?? [] : named
    }

    /// What `local` says to start a local API when none runs.
    static var notRunningHint: [String] {
        let cli = BuildEnvironment.current.cliName
        return ["Start one with:  \(cli) local                                 (only you, on this Mac)",
                "             or: \(cli) start --local-endpoint --no-me-first  (Darkbloom and you)"]
    }

    /// The file the shown key is in (`LocalEndpoint.keyFile(forPort:)`), from `~`; on the pair's API (rank 0's, or this
    /// Mac's relay to it), also the pair's key file, whose key works there too. Journey 2a (J2-a): a Mac keeps two key
    /// files, `local_token` and `cluster_local_token`, and `local` named neither. Nil when no file holds the key.
    static func keyFileLine(keyFile: URL?, pairKeyFile: URL?, home: URL) -> String? {
        guard let keyFile else { return nil }
        let shown = ToolIntegration.displayPath(keyFile, home: home)
        guard let pairKeyFile, pairKeyFile != keyFile else { return "  key file: \(shown)" }
        return "  key file: \(shown) (the pair's key, in \(ToolIntegration.displayPath(pairKeyFile, home: home)), works here too)"
    }

    /// The line under a keyed server's address: the commands that set the tools up for it.
    static var toolsLine: String { "  tools:    \(BuildEnvironment.current.cliName) --opencode · --hermes" }

    /// For a server listening on every interface: this Mac's Bonjour (`.local`) URL, which other computers on the
    /// same network can dial; nil for a loopback or specific-address server, or when the Mac has no local host name.
    static func networkURL(host: String, port: UInt16) -> String? {
        guard host == "0.0.0.0" || host == "::", let name = localHostName() else { return nil }
        return "http://\(name).local:\(port)/v1"
    }

    /// This Mac's Bonjour host name, without `.local`; nil when it has none.
    static func localHostName() -> String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).flatMap { $0.isEmpty ? nil : $0 }
    }
}
