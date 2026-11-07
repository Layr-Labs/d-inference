import ArgumentParser
import Foundation
import ProviderCore

// How a single-Mac `darkbloom start` serves (`[local]`): only its owner, the Darkbloom network, or both with the
// owner first. A flag decides it for one start; otherwise the saved choice; otherwise, in a terminal, one question,
// whose answer is saved. Without a terminal and without a saved choice (the LaunchAgent after an upgrade, the desktop
// app, scripts), a start keeps today's behaviour exactly: the Darkbloom network, with no local API, no Keychain
// look-up, no port probe and nothing written, so an upgraded Mac never opens a local port by itself.
// No line here names a speed (`StartLocalFirstTests.noSpeedAnywhere` reads them all) or prints a key.

/// A flag that names how this Mac serves, for one start. `--me-first` and `--local-endpoint` both name Both.
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

    /// How this start's mode is decided, in order: a mode flag; `--choose`, the question again; the saved choice;
    /// the question, in a terminal. Without a terminal and without a saved choice: `.today`, the Darkbloom network
    /// with no local API; a saved "Only me" without a terminal is refused. The --foreground service never asks: its
    /// flags say how it serves.
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
        if let mode = saved?.mode {
            // "Only me" serves in the terminal that starts it. Without one (the desktop app's Start, a script) it would
            // be a server its caller waits on forever, after stopping the running provider: refuse before anything.
            guard mode != .local || terminal else {
                throw ValidationError("This Mac is set to Only me, which serves in a terminal. Run "
                    + "`\(BuildEnvironment.current.cliName) start` in one, or name how to serve: --local, --network or "
                    + "--me-first.")
            }
            return .decided(mode, .saved)
        }
        return terminal ? .ask(preselected: .both) : .decided(today, .today)
    }
}

/// Where a start's mode came from.
enum ServingModeSource: Equatable, Sendable {
    /// A mode flag, for this start only.
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
    /// Whether the local router's account key is saved; nil when not looked up (no local API, `--local`, `--no-auth`,
    /// or the --foreground service).
    var accountKeySaved: Bool?
    /// The local API's port and address, with `mode` local or both.
    var port: UInt16
    var bind: String
    var noAuth: Bool
    /// What this start saves in `[local]`.
    var change = LocalSettingsChange()
    /// Says which port this start chose for a new local API.
    var portNote: String?

    var hasLocalAPI: Bool { mode != .network }

    /// The address a client on this Mac dials.
    var baseURL: String { "http://\(bind == "0.0.0.0" ? "127.0.0.1" : bind):\(port)/v1" }

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
    /// The port of this install's running local API, which the new start takes over; asked only when a new local
    /// API needs a port.
    var ownLivePort: () -> UInt16?
    /// No other program listens on the port; asked only about ports a new local API may take.
    var isFree: (UInt16) -> Bool

    /// This Mac's terminal, Keychain, `local.json` and ports.
    static var live: ServingEnvironment {
        ServingEnvironment(terminal: ClusterPairCommands.isTerminal(), readInput: { readLine() },
                           emit: { print($0, terminator: ""); fflush(stdout) },
                           accountKeySaved: { Start.accountKeySaved() },
                           ownLivePort: { LocalEndpoint.readLiveInfo()?.port },
                           isFree: { ClusterLocalServing.portIsFree(Int($0)) })
    }
}

enum StartServingResolver {
    /// How this start serves, and what it saves; nil when the person cancelled at the question. Only the question
    /// saves a mode. The settings flags (`--no-me-first`, `--me-first-idle`, `--route`) are saved as `--idle-timeout`
    /// is; a port this start chose for a new local API is saved so that tools keep finding it. The --foreground
    /// service saves nothing, probes no port and never asks the Keychain: launchd's arguments say how it serves.
    static func resolve(_ options: LocalFirstOptions, saved section: LocalSettings?,
                        environment env: ServingEnvironment) throws -> StartServing? {
        let saved = section ?? LocalSettings()
        var change = LocalSettingsChange()
        var accountKeySaved: Bool?
        let mode: LocalSettings.Mode, source: ServingModeSource
        switch try options.modeStep(saved: section, terminal: env.terminal) {
        case .decided(let decided, let from):
            (mode, source) = (decided, from)
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

        var port = options.port ?? saved.resolvedPort
        var portNote: String?
        if mode != .network, !options.foreground {
            if options.port == nil, picksPort(source: source, savedPort: saved.port) {
                let start = saved.resolvedPort
                guard let chosen = LocalAPIPort.pick(from: start, ownLivePort: env.ownLivePort(), isFree: env.isFree) else {
                    throw ValidationError(LocalAPIPort.noneFree(from: start))
                }
                port = chosen
                if chosen != saved.port {
                    change.port = chosen
                    portNote = LocalAPIPort.note(chosen: chosen, start: start)
                }
            } else if source == .question, port != saved.port {
                change.port = port
            }
            // `--local` keeps its banner, which shows the key and no route, and a local API without a key
            // (`--no-auth`) passes nothing on, so neither asks the Keychain.
            if accountKeySaved == nil, source != .flag(.local), !options.noAuth { accountKeySaved = env.accountKeySaved() }
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

    /// A new local API gets a free port, never 8000 or 47420–47423: the question's, a saved choice without a saved
    /// port, and `--me-first`. `--local` and `--local-endpoint` keep the saved or the build's default port, as before.
    static func picksPort(source: ServingModeSource, savedPort: UInt16?) -> Bool {
        switch source {
        case .question: return true
        case .saved, .flag(.meFirst): return savedPort == nil
        default: return false
        }
    }
}

/// The port of a local API a start creates.
enum LocalAPIPort {
    /// Never chosen for a new local API: 8000, where other local AI apps listen (oMLX on the owner's Mac), and
    /// 47420–47423, which two-Mac pairs use. A pair's local API keeps to the same (`ClusterLocalServing.localAPIPort`).
    static let neverChosen = LocalSettings.neverChosenPorts
    /// How far past the first port the search goes.
    static let span: UInt16 = 20

    /// The first of `start`…`start + span` that isn't one of `neverChosen` and that no other program listens on, or
    /// that this install's own running local API holds (the new start replaces it). `isFree` is never asked about
    /// `neverChosen`, so a start never even test-binds them.
    static func pick(from start: UInt16, ownLivePort: UInt16?, isFree: (UInt16) -> Bool) -> UInt16? {
        (start...last(from: start)).first { !neverChosen.contains($0) && ($0 == ownLivePort || isFree($0)) }
    }

    static func last(from start: UInt16) -> UInt16 { start > UInt16.max - span ? UInt16.max : start + span }

    /// Says which port was chosen, and why not the first one.
    static func note(chosen: UInt16, start: UInt16) -> String {
        guard chosen != start else { return "Local API port: \(chosen) (saved)." }
        let why = neverChosen.contains(start) ? "is left for other apps" : "is in use"
        return "Local API port: \(chosen) (saved; \(start) \(why))."
    }

    static func noneFree(from start: UInt16) -> String {
        "No free port for this Mac's API from \(start) to \(last(from: start)) (8000 and \(ClusterLocalServing.pairPortsWords) are never chosen). "
            + "Free one, or name one with --port <n>."
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
    static func minutes(_ count: UInt64) -> String { count == 1 ? "1 minute" : "\(count) minutes" }

    /// A running provider's idle time (`MeFirstSnapshot.idleMs`) in whole minutes, at least one.
    static func idleMinutes(milliseconds: Int64) -> UInt64 { UInt64(max(1, (milliseconds + 59_999) / 60_000)) }

    /// Where the owner's requests go when this Mac can't take them, in the iPhone app's words.
    /// Where requests to a pair member's own port go (`ClusterLocalRelay`).
    static let relayedRequests = ""

    static func requests(route: LocalSettings.Route?, accountKeySaved: Bool) -> String {
        guard accountKeySaved else { return "this Mac only" }
        switch LocalSettings(route: route).resolvedRoute(accountKeySaved: true) {
        case .thisMac: return "this Mac only"
        case .myMacs: return "this Mac first, then your other Macs (free)"
        case .myMacsFirst: return "this Mac first, then your other Macs (free), then the Darkbloom network (billed)"
        }
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
