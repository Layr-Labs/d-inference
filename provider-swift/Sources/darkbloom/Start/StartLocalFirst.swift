import ArgumentParser
import Foundation
import ProviderCore

// How a single-Mac `darkbloom start` serves (`[local]`): only its owner, the Darkbloom network, or both with the
// owner first. A mode flag decides it, and is saved; otherwise the saved choice; otherwise, in a terminal, one
// question, whose answer is saved. So the background service always serves the saved choice, and `restart` and
// `update` bring that back (`SavedChoiceService`). Only `--local --here`, one terminal session, a service's own
// child, and a flag beside `--solo` (on a Mac in a pair `[local] mode` holds the pair's answer) save nothing.
// Without a terminal and without a saved choice or a mode flag (the LaunchAgent after an upgrade, the desktop app,
// scripts), a start keeps today's behaviour exactly: the Darkbloom network, with no local API, no Keychain look-up,
// no port probe and nothing written, so an upgraded Mac never opens a local port by itself.
// Every local API this Mac serves takes its one port (`LocalAPIPort`), so the address tools were given never moves.
// No line here names a speed (`StartLocalFirstTests.noSpeedAnywhere` reads them all) or prints a key.

/// A flag that names how this Mac serves. `--me-first` and `--local-endpoint` both name Both.
enum ServingModeFlag: String, CaseIterable, Sendable {
    case local = "--local"
    case network = "--network"
    case meFirst = "--me-first"
    case localEndpoint = "--local-endpoint"

    var mode: LocalSettings.Mode {
        switch self {
        case .local: .local
        case .network: .network
        case .meFirst, .localEndpoint: .both
        }
    }
}

/// The `start` options that decide how this Mac serves.
struct LocalFirstOptions: Equatable, Sendable {
    var local = false
    var localEndpoint = false
    var network = false
    /// `--me-first` (true) or `--no-me-first` (false).
    var meFirst: Bool?
    var meFirstIdleMinutes: UInt64?
    var route: LocalSettings.Route?
    var choose = false
    var port: UInt16?
    var bind: String?
    var noAuth = false
    /// launchd's child: its flags say how it serves; it never asks and never saves.
    var foreground = false
    /// `--local --here`: Only me in this terminal, for this session only; nothing is saved but this Mac's port.
    var here = false
    /// `--solo`: this Mac alone instead of its pair. There `[local] mode` holds the pair's answer (`darkbloom cluster`
    /// saves it), so a mode flag serves this start only.
    var solo = false

    /// The mode flags given, in `ServingModeFlag` order.
    var modeFlags: [ServingModeFlag] {
        ServingModeFlag.allCases.filter { flag in
            switch flag {
            case .local: local
            case .network: network
            case .meFirst: meFirst == true
            case .localEndpoint: localEndpoint
            }
        }
    }

    /// The mode flag this start serves by, if any: the first one given.
    var modeFlag: ServingModeFlag? { modeFlags.first }

    /// Why these options can't be used together, in plain words; nil when they can. `Start.validate` refuses them at
    /// parse, before anything runs or is saved. `--local` with `--local-endpoint` alone is left to `Start.run`, which
    /// has always refused it after the terms notice.
    var conflict: String? {
        let range = LocalSettings.meFirstIdleMinutesRange
        if let minutes = meFirstIdleMinutes, !range.contains(minutes) {
            return "--me-first-idle must be a whole number of minutes from \(range.lowerBound) to \(range.upperBound), "
                + "not \(minutes)."
        }
        let flags = modeFlags
        if let first = flags.first, let other = flags.first(where: { $0.mode != first.mode }),
           !(first == .local && other == .localEndpoint) {
            return "`\(first.rawValue)` and `\(other.rawValue)` choose different ways to serve. Use one: --local (only "
                + "you, on this Mac), --network (the Darkbloom network) or --me-first (both, you first)."
        }
        if choose, let first = flags.first {
            return "`--choose` asks how this Mac serves, so it can't be used with `\(first.rawValue)`. Use one."
        }
        if choose, foreground {
            return "`--choose` asks in a terminal; the --foreground service never asks."
        }
        if here, !local {
            return "`--here` serves Only me in this terminal: use it with --local (`\(BuildEnvironment.current.cliName) "
                + "start --local --here`)."
        }
        if here, foreground {
            return "`--here` serves in a terminal; the --foreground service is launchd's."
        }
        if meFirst == false, meFirstIdleMinutes != nil {
            return "`--me-first-idle` sets when Darkbloom comes back after you; `--no-me-first` turns that pause off. "
                + "Use one."
        }
        let tuning = meFirst == false ? "--no-me-first" : meFirstIdleMinutes != nil ? "--me-first-idle" : nil
        if let tuning, local || network {
            return "`\(tuning)` applies when this Mac serves Darkbloom and you (--me-first); it doesn't apply with "
                + "`\(local ? "--local" : "--network")`."
        }
        if network, let localOnly = [route != nil ? "--route" : nil, port != nil ? "--port" : nil,
                                     bind != nil ? "--bind" : nil, noAuth ? "--no-auth" : nil].compactMap({ $0 }).first {
            return "`--network` serves no local API, so `\(localOnly)` doesn't apply. Drop it, or choose --me-first "
                + "or --local."
        }
        if foreground, let saved = tuning ?? (route != nil ? "--route" : nil) {
            return "`\(saved)` is saved by `\(BuildEnvironment.current.cliName) start`; the --foreground service reads "
                + "it from [local]."
        }
        return nil
    }

    /// How this start's mode is decided, in order: a mode flag; `--choose`, the question again; the saved choice,
    /// with or without a terminal (every choice serves in the background); the question, in a terminal. Without a
    /// terminal and without a saved choice: `.today`, the Darkbloom network with no local API. The --foreground
    /// service never asks: its flags say how it serves.
    func modeStep(saved: LocalSettings?, terminal: Bool) throws -> ServingStep {
        if let flag = modeFlag { return .decided(flag.mode, .flag(flag)) }
        // Today's plain start, as `LocalSettings.launchMode` reads it without --local or --local-endpoint.
        let today = LocalSettings.launchMode(local: false, localEndpoint: false)
        if foreground { return .decided(today, .today) }
        if choose {
            guard terminal else {
                throw ValidationError("`--choose` asks in a terminal. Without one, name how this Mac serves: --local, "
                    + "--network or --me-first.")
            }
            return .ask(preselected: saved?.mode ?? .both)
        }
        if let mode = saved?.mode { return .decided(mode, .saved) }
        return terminal ? .ask(preselected: .both) : .decided(today, .today)
    }

    /// Whether this start's mode flag is saved: always, so the background service, `restart` and `update` serve it
    /// from now on; never for `--local --here` (one terminal session), a service's child, or `--solo`, whose flag is
    /// for that start only (journey 3: `start --solo --local` replaced the pair's saved Both).
    var savesModeFlag: Bool { modeFlag != nil && !foreground && !here && !solo }
}

/// Where a start's mode came from.
enum ServingModeSource: Equatable, Sendable {
    /// A mode flag: saved (`LocalFirstOptions.savesModeFlag`).
    case flag(ServingModeFlag)
    /// `[local] mode`.
    case saved
    /// Answered now, in a terminal, and saved.
    case question
    /// Nothing chose it (no terminal and no saved choice, or the --foreground service without a mode flag): today's
    /// behaviour, the Darkbloom network.
    case today
}

/// A start's first step: a mode, or the question.
enum ServingStep: Equatable, Sendable {
    case decided(LocalSettings.Mode, ServingModeSource)
    case ask(preselected: LocalSettings.Mode)
}

/// The `[local]` keys a start saves; empty when it saves nothing.
struct LocalSettingsChange: Equatable, Sendable {
    var mode: LocalSettings.Mode?
    var route: LocalSettings.Route?
    var port: UInt16?
    var meFirst: Bool?
    var meFirstIdleMinutes: UInt64?

    var isEmpty: Bool { self == LocalSettingsChange() }

    func apply(to settings: inout LocalSettings) {
        if let mode { settings.mode = mode }
        if let route { settings.route = route }
        if let port { settings.port = port }
        if let meFirst { settings.meFirst = meFirst }
        if let meFirstIdleMinutes { settings.meFirstIdleMinutes = meFirstIdleMinutes }
    }
}

/// How a start serves, decided before anything starts or is saved.
struct StartServing: Equatable, Sendable {
    var mode: LocalSettings.Mode
    var source: ServingModeSource
    /// With Both: Darkbloom pauses while the owner uses this Mac.
    var meFirst: Bool
    var meFirstIdleMinutes: UInt64
    var route: LocalSettings.Route?
    /// Whether the local router's account key is saved; nil when not looked up (no local API, `--no-auth`, or the
    /// --foreground service).
    var accountKeySaved: Bool?
    /// The local API's port and address, with `mode` local or both.
    var port: UInt16
    var bind: String
    var noAuth: Bool
    /// What this start saves in `[local]`.
    var change = LocalSettingsChange()
    /// Says which port this start gave this Mac's local API, when it chose one or a named one replaced the saved one.
    var portNote: String?

    var hasLocalAPI: Bool { mode != .network }

    /// The address a client on this Mac dials, as `local.json` names it once the API listens.
    var baseURL: String { LocalEndpoint.baseURL(host: bind, port: port) }

    /// The LaunchAgent's local API arguments: the ones `--local-endpoint` has always baked, so an older provider
    /// rolled back to reads the same plist.
    var launchAgentEndpoint: LaunchAgent.LocalEndpointOptions {
        LaunchAgent.LocalEndpointOptions(enabled: mode == .both, port: port, bind: bind, noAuth: noAuth)
    }

    /// The summary block's lines: how this Mac serves and, with a local API, its address and where your requests
    /// go. No key and no speed. A start that nothing chose (`today`) prints today's summary, so nothing.
    var summaryLines: [String] {
        if source == .today, mode == .network { return [] }
        let lines = ["  Serving: " + LocalFirstWords.serving(mode: mode, meFirst: meFirst, idleMinutes: meFirstIdleMinutes)]
        guard hasLocalAPI else { return lines }
        // Without a local key the router passes nothing on, whatever the route (`LocalRouterConfig.localKeyRequired`).
        guard !noAuth else {
            return lines + ["  Local:   \(baseURL) — your requests: this Mac only",
                            "           (no API key: --no-auth, so requests stay on this Mac)"]
        }
        let keySaved = accountKeySaved ?? false
        let cli = BuildEnvironment.current.cliName
        return lines + [
            "  Local:   \(baseURL) — your requests: " + LocalFirstWords.requests(route: route, accountKeySaved: keySaved),
            "           (`\(cli) local` shows the key" + (keySaved ? ")" : "; `\(cli) route key` adds your other Macs)"),
        ]
    }
}

extension StartServing {
    /// The configuration the serving process runs with: its `[local] mode` is the mode it serves, so me first
    /// (`ProviderLoopConfig.meFirstIdle`, which reads the saved mode first) follows what serves, never a saved choice
    /// this start's flags overrode, such as a saved "network" with `--me-first`. Only a saved mode is replaced: the
    /// file then exists, so the model-switch writer edits its table and never encodes this configuration.
    func servedConfig(_ config: ProviderConfig) -> ProviderConfig {
        guard let saved = config.local?.mode, saved != mode else { return config }
        var served = config
        served.local?.mode = mode
        return served
    }
}

/// What resolving a start may touch: tests stand in for the terminal, the Keychain and the ports.
struct ServingEnvironment {
    var terminal: Bool
    var readInput: () -> String?
    var emit: (String) -> Void
    /// Whether the local router's account key is saved; asked only when this start has a local API.
    var accountKeySaved: () -> Bool
    /// The port of this install's running local API, which a start keeps; asked only when no port is saved or named.
    var ownLivePort: () -> UInt16?
    /// The port the installed LaunchAgent's job serves its local API on, which a start on a stopped Mac keeps; asked
    /// only when no port is saved or named and no local API runs.
    var installedPort: () -> UInt16?
    /// No other program listens on the port; asked only about the ports a choice may take.
    var isFree: (UInt16) -> Bool

    /// This Mac's terminal, Keychain, `local.json`, LaunchAgent and ports.
    static var live: ServingEnvironment {
        ServingEnvironment(terminal: ClusterPairCommands.isTerminal(), readInput: { readLine() },
                           emit: { print($0, terminator: ""); fflush(stdout) },
                           accountKeySaved: { Start.accountKeySaved() },
                           ownLivePort: LocalAPIPort.ownLivePort, installedPort: LocalAPIPort.installedJobPort,
                           isFree: LocalAPIPort.isFreeOnThisMac)
    }
}

enum StartServingResolver {
    /// How this start serves, and what it saves; nil when the person cancelled at the question. The question's answer
    /// and a mode flag are saved (`LocalFirstOptions.savesModeFlag`). The settings flags (`--no-me-first`,
    /// `--me-first-idle`, `--route`) are saved as `--idle-timeout` is. Every local API takes this Mac's one port
    /// (`LocalAPIPort.choose`): a named `--port`, else `[local] port`, else one chosen now; a new or named port is saved
    /// so that tools keep finding it. The --foreground service saves nothing, probes no port and never asks the
    /// Keychain: launchd's arguments say how it serves.
    static func resolve(_ options: LocalFirstOptions, saved section: LocalSettings?,
                        environment env: ServingEnvironment) throws -> StartServing? {
        let saved = section ?? LocalSettings()
        var change = LocalSettingsChange()
        var accountKeySaved: Bool?
        let mode: LocalSettings.Mode, source: ServingModeSource
        switch try options.modeStep(saved: section, terminal: env.terminal) {
        case .decided(let decided, let from):
            (mode, source) = (decided, from)
            if options.savesModeFlag, decided != saved.mode { change.mode = decided }
        case .ask(let preselected):
            let idle = options.meFirstIdleMinutes ?? saved.resolvedMeFirstIdleMinutes
            guard let answer = ServingQuestion.askMode(preselected: preselected, idleMinutes: idle,
                                                       readInput: env.readInput, emit: env.emit) else { return nil }
            (mode, source) = (answer, .question)
            change.mode = answer
            if answer != .network, options.route == nil {
                let keySaved = env.accountKeySaved()
                accountKeySaved = keySaved
                if keySaved {
                    guard let route = ServingQuestion.askRoute(preselected: saved.resolvedRoute(accountKeySaved: true),
                                                               readInput: env.readInput, emit: env.emit)
                    else { return nil }
                    change.route = route
                }
            }
        }
        if !options.foreground {
            if let route = options.route { change.route = route }
            if options.meFirst == false {
                change.meFirst = false
            } else if options.meFirst == true, saved.meFirst == false {
                change.meFirst = true
            }
            if let minutes = options.meFirstIdleMinutes { change.meFirstIdleMinutes = minutes }
        }

        // This Mac's one port, for a local API only. Darkbloom network chooses, probes and saves none, so a start
        // without a terminal and without `[local]` (today's Darkbloom network) stays today's, byte for byte. A
        // service's child (`--foreground`) serves on the port its arguments name, else `[local] port`, else the
        // build's default.
        var port = options.port ?? saved.resolvedPort
        var portNote: String?
        if mode != .network, !options.foreground {
            let choice: LocalAPIPort.Choice
            do {
                choice = try LocalAPIPort.choose(named: options.port, saved: saved.port, ownLivePort: env.ownLivePort,
                                                 installedPort: env.installedPort, isFree: env.isFree)
            } catch let none as LocalAPIPortError {
                throw ValidationError(none.description)
            }
            port = choice.port
            if choice.saves { change.port = choice.port }
            portNote = choice.note
            // Where your requests go needs whether an account key is saved (never the key); a local API without a
            // key (`--no-auth`) passes nothing on, so it doesn't ask the Keychain.
            if accountKeySaved == nil, !options.noAuth { accountKeySaved = env.accountKeySaved() }
        }
        // What serves: the saved settings with this start's change.
        var settings = saved
        change.apply(to: &settings)
        return StartServing(
            mode: mode, source: source, meFirst: settings.meFirstEnabled(in: mode),
            meFirstIdleMinutes: settings.resolvedMeFirstIdleMinutes, route: settings.route,
            accountKeySaved: accountKeySaved, port: port, bind: options.bind ?? saved.resolvedBind,
            noAuth: options.noAuth, change: change, portNote: portNote)
    }
}

/// The config at `configPath` (the default config when nil), read without detecting hardware; nil when the file is
/// absent. A file this build refuses throws its plain refusal.
func savedConfig(configPath rawPath: String?) throws -> ProviderConfig? {
    let path = try rawPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? ConfigManager.defaultConfigPath()
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    return try ConfigManager.load(from: path)
}

/// `[local]` from `savedConfig(configPath:)`; nil when the file or the section is absent.
func savedLocalSettings(configPath: String?) throws -> LocalSettings? {
    try savedConfig(configPath: configPath)?.local
}

/// The start screen's question, and the route follow-up. Plain words; never a speed.
enum ServingQuestion {
    static let modes: [LocalSettings.Mode] = [.local, .network, .both]
    static let routes: [LocalSettings.Route] = [.thisMac, .myMacs, .myMacsFirst]

    static func modeLines(idleMinutes: UInt64) -> [String] {
        [
            "How should this Mac serve?",
            "  1. Only me, on this Mac      Darkbloom never contacts this Mac. Your tools use this Mac's own API.",
            "  2. Darkbloom network         This Mac serves Darkbloom and earns while it runs.",
            "  3. Both, me first            This Mac serves Darkbloom while you aren't using it. When you use it,",
            "                               Darkbloom traffic pauses until you've been idle for "
                + "\(LocalFirstWords.minutes(idleMinutes)).",
        ]
    }

    static let routeLines = [
        "When this Mac can't take one of your requests:",
        "  1. Only this Mac",
        "  2. Only my Macs (free)",
        "  3. My Macs first (the network answers when they can't; billed to your balance)",
    ]

    static func prompt(preselected number: Int) -> String { "Choose 1, 2 or 3 [\(number)]: " }

    static let retry = "Please enter 1, 2 or 3."

    static func askMode(preselected: LocalSettings.Mode, idleMinutes: UInt64, readInput: () -> String?,
                        emit: (String) -> Void) -> LocalSettings.Mode? {
        for line in modeLines(idleMinutes: idleMinutes) { emit(line + "\n") }
        return choose(modes, preselected: preselected, readInput: readInput, emit: emit)
    }

    static func askRoute(preselected: LocalSettings.Route, readInput: () -> String?,
                         emit: (String) -> Void) -> LocalSettings.Route? {
        for line in routeLines { emit(line + "\n") }
        return choose(routes, preselected: preselected, readInput: readInput, emit: emit)
    }

    /// Reads 1, 2 or 3; Enter takes `preselected`. nil when the input ends, or after three answers that aren't 1, 2
    /// or 3: the start is cancelled, with nothing saved.
    static func choose<Choice: Equatable>(_ choices: [Choice], preselected: Choice, readInput: () -> String?,
                                          emit: (String) -> Void) -> Choice? {
        let fallback = (choices.firstIndex(of: preselected) ?? 0) + 1
        for attempt in 0..<3 {
            emit(prompt(preselected: fallback))
            guard let line = readInput() else {
                emit("\n")
                return nil
            }
            let answer = line.trimmingCharacters(in: .whitespaces)
            if answer.isEmpty { return preselected }
            if let number = Int(answer), choices.indices.contains(number - 1) { return choices[number - 1] }
            if attempt < 2 { emit(retry + "\n") }
        }
        return nil
    }

    static let cancelled = "Cancelled: nothing was saved or started."
}

/// Plain words for how this Mac serves, shared by `start`, `status` and `local`. Never a speed.
enum LocalFirstWords {
    /// "1 minute", "2 minutes".
    static func minutes(_ count: UInt64) -> String { MeFirstWords.minutes(count) }

    /// A running provider's idle time (`MeFirstSnapshot.idleMs`) in whole minutes, at least one.
    static func idleMinutes(milliseconds: Int64) -> UInt64 { MeFirstWords.idleMinutes(milliseconds: milliseconds) }

    /// Where requests to a Mac's relay go (`ClusterLocalRelay`): to the pair's API on another Mac, whose route decides
    /// the rest; it sees them come from this Mac, another machine, so never to the paid network.
    static let relayedRequests = "the pair, on its API on the other Mac; never the paid Darkbloom network"

    /// Where the owner's requests go when this Mac can't take them, in the iPhone app's words.
    static func requests(route: LocalSettings.Route?, accountKeySaved: Bool) -> String {
        guard accountKeySaved else { return "this Mac only" }
        switch LocalSettings(route: route).resolvedRoute(accountKeySaved: true) {
        case .thisMac: return "this Mac only"
        case .myMacs: return "this Mac first, then your other Macs (free)"
        case .myMacsFirst: return "this Mac first, then your other Macs (free), then the Darkbloom network (billed)"
        }
    }

    /// A choice's name, as the start question says it; with `article`, "the Darkbloom network".
    static func choice(_ mode: LocalSettings.Mode, article: Bool = false) -> String {
        switch mode {
        case .local: "Only me"
        case .network: article ? "the Darkbloom network" : "Darkbloom network"
        case .both: "Both, me first"
        }
    }

    /// Why the local API a provider was asked to open beside Darkbloom isn't up, and what to do, after "the local API
    /// isn't up: ". `nextFree` is the port `start --port` would take instead; `server` says whose API it is, so the
    /// command named works on this Mac.
    static func whyNotUp(_ failure: DaemonState.LocalAPIFailure, nextFree: UInt16?, server: LocalAPIServer) -> String {
        let cli = BuildEnvironment.current.cliName
        let solo = server == .singleMac(paired: true) ? " --solo" : ""
        guard failure.portInUse else {
            return "it couldn't listen on \(failure.host):\(failure.port)" + (failure.reason.map { " (\($0))" } ?? "")
                + "; `\(cli) restart\(solo)` tries again"
        }
        guard server != .pair else {
            return "port \(failure.port) is in use (free it, or set "
                + (nextFree.map { "`[local] port = \($0)`" } ?? "another `[local] port`") + " in provider.toml, then `\(cli) restart`)"
        }
        return "port \(failure.port) is in use (" + (nextFree.map { "`\(cli) start\(solo) --port \($0)`" }
            ?? "free it, or name another with `\(cli) start\(solo) --port <n>`") + ")"
    }

    /// Whose local API isn't up, for the command its line names: single-Mac serving's (`start --port`, which a Mac in
    /// a two-Mac cluster takes only with `--solo`), or the pair's (its port is this Mac's `[local] port` too, used as it
    /// is: a paired Mac changes it in provider.toml, then `restart`).
    enum LocalAPIServer: Equatable, Sendable {
        case singleMac(paired: Bool)
        case pair
    }

    /// How a start serves, after `Serving: `.
    static func serving(mode: LocalSettings.Mode, meFirst: Bool, idleMinutes: UInt64) -> String {
        switch mode {
        case .local:
            return "Only me, on this Mac — Darkbloom never contacts this Mac"
        case .network:
            return "Darkbloom network — this Mac serves Darkbloom and earns while it runs"
        case .both where meFirst:
            return "Both, me first — Darkbloom pauses while you use this Mac, back after \(idleMinutes) idle "
                + (idleMinutes == 1 ? "minute" : "minutes")
        case .both:
            return "Both — Darkbloom keeps serving while you use this Mac (me first is off)"
        }
    }
}
