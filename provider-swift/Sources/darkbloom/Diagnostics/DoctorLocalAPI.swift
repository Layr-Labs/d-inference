import Foundation
import ProviderCore

/// `darkbloom doctor`'s Local API section (UX audit R17): how this Mac serves (Only me, Darkbloom network or Both, me
/// first), its local API's address, whether it answers and on which port, whether its key file is there, and whether
/// OpenCode and Hermes point at it. Every problem names the next command. On a Mac set to Only me the Darkbloom
/// network's checks don't apply (`onlyMe`), and `doctor` skips them.
///
/// No line holds the key: of the running API's key only whether there is one is read, and of the tools' configs only
/// the file each reads its key from (`DoctorToolSetup`), which is compared with this Mac's (`ToolAddress.miss`), never
/// shown.
struct DoctorLocalAPI {
    /// What the section reads: `live` reads this Mac's; tests give their own.
    struct Facts {
        /// `[local]` as saved.
        var saved: LocalSettings?
        /// The running provider's state; nil when none runs.
        var running: DaemonState?
        /// The local API `local.json` names, while its process runs. It holds the key, which no line shows.
        var live: LocalEndpoint.Info?
        /// Whether that API answered `GET /health`; nil when it wasn't asked.
        var answers: Bool?
        /// The file holding the key of the API on this Mac's port (`LocalEndpoint.keyFile`); nil when none does.
        var keyFile: URL?
        /// This Mac's pair, as it knows it by itself (`ClusterPairSummary.local`).
        var pair: ClusterPairSummary = .notPaired
        /// On a paired Mac, the running provider is single-Mac serving (`start --solo`), not the pair's part
        /// (`ServiceDrain.soloProviderState`): this Mac serves alone, and its own way is described, not the pair's.
        var servingAlone = false
        /// The running provider is Only me in a terminal (`start --local --here`, `Restart.terminalOnlyMe`): the
        /// person's own session, which `restart` never stops and which saves no choice.
        var terminalOnlyMe = false
        /// The provider's background service is installed (`LaunchAgent.isInstalled`): `restart` starts it again as
        /// saved, with no questions.
        var serviceInstalled = false
        /// What OpenCode's and Hermes' configs say of Darkbloom.
        var tools: [DoctorToolSetup] = []
        /// The names this Mac's local API answers to, as `start` counts them (`ToolAddress.thisMacsNames`).
        var thisMac: Set<String> = ToolAddress.loopbackNames
        var home: URL = FileManager.default.homeDirectoryForCurrentUser
        /// The port `start --port` would take instead of one in use (`LocalAPIPort.nextFree`).
        var nextFreePort: (UInt16) -> UInt16? = { _ in nil }
    }

    let facts: Facts

    static var cli: String { BuildEnvironment.current.cliName }

    /// The pair this Mac is in, when its record can be read.
    private var pair: ClusterPairSummary? {
        facts.pair.paired && !facts.pair.pairingUnreadable ? facts.pair : nil
    }

    /// The pair whose lines describe this Mac: its pair, unless this Mac serves alone (`servingAlone`).
    private var pairServing: ClusterPairSummary? { facts.servingAlone ? nil : pair }

    /// How that pair serves, as its leader saved it: Only me when it serves locally only, Both, me first when its local
    /// API runs beside Darkbloom, else the Darkbloom network. Nil before the pair has chosen (no role yet).
    private var pairMode: LocalSettings.Mode? {
        guard let pair = pairServing, pair.role != nil else { return nil }
        return pair.localOnly ? .local : pair.localAPI != nil ? .both : .network
    }

    /// How the running provider serves, read as `status` reads it (`Status.servingLines`): Only me from its first load,
    /// before its local API listens; with its own local API, Both; without one, Both when its local API failed to open,
    /// else the Darkbloom network. Nil when none runs.
    var runningMode: LocalSettings.Mode? {
        guard let state = facts.running else { return nil }
        if state.servesOnlyItsOwner { return .local }
        if facts.live?.pid == state.pid { return .both }
        return state.localAPIFailure != nil ? .both : .network
    }

    /// How this Mac serves on its own: the running provider's way, else the saved choice; nil when neither says.
    var mode: LocalSettings.Mode? { runningMode ?? facts.saved?.mode }

    /// How this Mac serves: its pair's way, else its own (also while it serves alone).
    private var servingMode: LocalSettings.Mode? { pairServing == nil ? mode : pairMode }

    /// This Mac serves only its owner (a single Mac's Only me, a pair serving locally only, or Only me served alone on
    /// a paired Mac): Darkbloom never contacts it, so the account, trust, App Attest and coordinator checks don't
    /// apply. Never while its pairing record can't be read: it may be in a pair that serves Darkbloom.
    var onlyMe: Bool { !facts.pair.pairingUnreadable && servingMode == .local }

    /// Whether `doctor` runs the Darkbloom network's checks: on every Mac but one set to Only me, and there too when
    /// `--coordinator` names a coordinator to check.
    func runsNetworkChecks(coordinatorOverride: String?) -> Bool { !onlyMe || coordinatorOverride != nil }

    /// Whether this Mac has, or is set to have, a local API: one runs, or it serves Only me or Both, me first.
    private var hasLocalAPI: Bool { facts.live != nil || (servingMode.map { $0 != .network } ?? false) }

    /// The address this Mac's local API is reached at: the running one's, else the saved port's when this Mac serves on
    /// its own (the pair's API takes a port of its own).
    var address: String? {
        if let live = facts.live { return live.baseURL }
        guard pairServing == nil, let saved = facts.saved, let port = saved.port else { return nil }
        return LocalEndpoint.baseURL(host: saved.resolvedBind, port: port)
    }

    /// On a pair serving Both, me first, the Mac that doesn't lead: the pair's API, with its address and key, is on the
    /// other Mac.
    private var pairAPIOnTheOtherMac: Bool { pairServing?.role == .member && pairServing?.localAPI != nil }

    /// The section's lines; `networkChecks` false (`runsNetworkChecks`) adds the line that says the Darkbloom network's
    /// checks are skipped.
    func lines(networkChecks: Bool) -> [Diagnostic] {
        var out = [modeLine]
        if !networkChecks { out.append(networkLine) }
        if hasLocalAPI {
            out.append(addressLine)
            if let key = keyLine { out.append(key) }
        }
        out += facts.tools.compactMap(toolLine)
        return out
    }

    private func line(_ name: String, _ level: DiagnosticLevel, _ message: String, fix: String? = nil) -> Diagnostic {
        Diagnostic(section: .localAPI, name: name, level: level, message: message, fix: fix)
    }

    // MARK: - The next commands

    /// `start`, or `start --solo` where this Mac serves alone beside its pair.
    private var start: String { "\(Self.cli) start\(facts.servingAlone ? " --solo" : "")" }

    /// The command that starts the running local API again as it serves now, never another way.
    /// - Only me in a terminal (`start --local --here`) is the person's own session: `restart` never stops it, and it
    ///   saved no choice, so `restart` could serve another one. It starts again in its terminal.
    /// - `restart` serves the saved choice: the fix while that is what runs (or nothing is saved, and the service
    ///   restarts as installed). Else `start` with the flag of the way it runs. `--solo` where this Mac serves alone;
    ///   the pair's own API restarts with the pair.
    private var restartFix: String {
        let cli = Self.cli
        let solo = facts.servingAlone ? " --solo" : ""
        if facts.terminalOnlyMe { return "press Ctrl-C in its window, then `\(start) --local --here`" }
        if pairServing == nil, let running = runningMode, let saved = facts.saved?.mode, saved != running {
            return "`\(start) \(Self.startFlags(running, meFirst: facts.running?.meFirst != nil))`"
        }
        return "`\(cli) restart\(solo)`"
    }

    /// The `start` flags that serve `mode`, with me first as it runs.
    private static func startFlags(_ mode: LocalSettings.Mode, meFirst: Bool) -> String {
        switch mode {
        case .local: "--local"
        case .network: "--network"
        case .both: meFirst ? "--me-first" : "--local-endpoint --no-me-first"
        }
    }

    // MARK: - The lines

    private var modeLine: Diagnostic {
        let cli = Self.cli
        if facts.pair.pairingUnreadable {
            return line("mode", .info, "this Mac's pairing record couldn't be read, so how it serves is unknown",
                        fix: "`\(cli) cluster` on this Mac checks it")
        }
        if let pair = pairServing {
            guard let pairMode else {
                return line("mode", .info, "this Mac is paired, but how the pair serves isn't chosen yet",
                            fix: "`\(cli) cluster` sets it up")
            }
            let name = LocalFirstWords.choice(pairMode) + " (this pair)"
            let words = switch pairMode {
            case .local: "\(name) — Darkbloom never contacts these Macs; the pair's API runs on \(pair.leadingMac)"
            case .both: "\(name) — the pair's API runs on \(pair.leadingMac)"
            case .network: "\(name) — no local API"
            }
            return line("mode", .info, words)
        }
        if let mode = runningMode, let state = facts.running {
            let idle = state.meFirst.map { LocalFirstWords.idleMinutes(milliseconds: $0.idleMs) } ?? 0
            let words = LocalFirstWords.serving(mode: mode, meFirst: state.meFirst != nil, idleMinutes: idle)
            // Only me's server reports itself from its first load: its local API opens once its models are loaded.
            let starting = mode == .local && facts.live?.pid != state.pid
            if facts.servingAlone {
                return line("mode", .info, words + " (\(starting ? "starting; " : "")this Mac serves alone, not the pair)")
            }
            let now = starting ? "starting" : "serving now"
            guard let saved = facts.saved?.mode, saved != mode else { return line("mode", .info, words + " (\(now))") }
            return line("mode", .info, words + " (\(now); your saved choice, \(LocalFirstWords.choice(saved)), serves at "
                + "the next `\(cli) start`)")
        }
        guard let saved = facts.saved, let mode = saved.mode else {
            return line("mode", .info, "not chosen yet: `\(cli) start` asks how this Mac serves (Only me, Darkbloom "
                + "network or Both, me first)")
        }
        return line("mode", .info, LocalFirstWords.serving(mode: mode, meFirst: saved.meFirstEnabled(in: mode),
                                                           idleMinutes: saved.resolvedMeFirstIdleMinutes) + " (saved)")
    }

    private var networkLine: Diagnostic {
        let change = pairServing != nil ? "`\(Self.cli) cluster` changes how the pair serves"
            : facts.servingAlone ? "`\(start) --choose` changes how this Mac serves alone"
            : "`\(start) --choose` changes how this Mac serves"
        return line("darkbloom network", .info, "not needed (Only me): the account, trust, App Attest and coordinator "
            + "checks are skipped; " + change)
    }

    private var addressLine: Diagnostic {
        let cli = Self.cli
        // A pair's Mac that passes the pair's API on through its own port (#1894) and can't answer for it now: why, and
        // what to do, in `status`'s words. With the other Mac away its relay answers 503, which no restart mends.
        if let down = pairServing?.memberAPIDown { return line("address", .warn, down) }
        if let live = facts.live {
            if facts.answers == false {
                return line("address", .fail, "\(live.baseURL) — its server runs, but port \(live.port) doesn't answer",
                            fix: restartFix)
            }
            return line("address", .pass, "\(live.baseURL) — up on port \(live.port)")
        }
        if let pair = pairServing {
            if !pair.started {
                return line("address", .warn, "the pair is stopped, so its API isn't up", fix: "`\(cli) start` starts the pair")
            }
            if pairAPIOnTheOtherMac {
                return line("address", .info, "on \(pair.otherMac), which runs the pair's API: `\(cli) local` there shows "
                    + "its address and key")
            }
            return line("address", .warn, "not listening yet: it starts with this Mac's part of the pair",
                        fix: "`\(cli) cluster status` says where the pair stands")
        }
        let shown = address ?? "no port yet"
        if let state = facts.running {
            if state.servesOnlyItsOwner {
                return line("address", .info, "\(shown) — starting: it opens once its models are loaded")
            }
            if let failure = state.localAPIFailure {
                return line("address", .fail, "\(LocalEndpoint.baseURL(host: failure.host, port: failure.port)) isn't up",
                            fix: LocalFirstWords.whyNotUp(failure, nextFree: facts.nextFreePort(failure.port),
                                                          server: .singleMac(paired: facts.pair.paired)))
            }
            return line("address", .warn, "\(shown) — not listening yet", fix: "`\(cli) status` shows how this Mac serves")
        }
        guard let address else {
            return line("address", .warn, "not running; the first start chooses its port", fix: "`\(start)`")
        }
        // A stopped background service keeps its job: `restart` starts it again as saved, where `start` asks again.
        return line("address", .warn, "\(address) — not running",
                    fix: facts.serviceInstalled ? "`\(cli) restart` starts it again as saved" : "`\(cli) start`")
    }

    private var keyLine: Diagnostic? {
        let cli = Self.cli
        // Whether the running API takes a key: the one thing read of it.
        if let live = facts.live, live.apiKey.isEmpty {
            return line("key file", .info, "none: this API takes no key (--no-auth), so it keeps every request on this Mac")
        }
        if let keyFile = facts.keyFile {
            return line("key file", .pass, ToolIntegration.displayPath(keyFile, home: facts.home)
                + " (`\(cli) local` shows the key)")
        }
        if facts.live != nil {
            return line("key file", .fail, "no key file holds the running API's key, so tools that read it are refused",
                        fix: restartFix)
        }
        if pairAPIOnTheOtherMac { return nil }
        return line("key file", .info, "none yet: the first start writes it")
    }

    private func toolLine(_ setup: DoctorToolSetup) -> Diagnostic? {
        let name = setup.tool.displayName
        let setUpCommand = "`\(ToolIntegrationStep.command([setup.tool]))`"
        let file = ToolIntegration.displayPath(setup.file, home: facts.home)
        switch setup.found {
        case .notSetUp:
            guard hasLocalAPI else { return nil }
            return line(name, .info, "not set up (\(setUpCommand) sets it up)")
        case .unreadable(let why):
            guard hasLocalAPI else { return nil }
            return line(name, .warn, "can't read \(file): \(why)")
        case .entry(let pointer):
            guard let pointsAt = pointer.baseURL else {
                guard hasLocalAPI else { return nil }
                return line(name, .warn, "Darkbloom's provider in \(file) has no address", fix: setUpCommand)
            }
            guard let here = address else {
                guard !hasLocalAPI else { return line(name, .info, "points at \(pointsAt) (\(file))") }
                return line(name, .warn, "points at \(pointsAt), but this Mac serves no local API (\(file))",
                            fix: pairServing != nil ? "`\(Self.cli) cluster` changes how the pair serves"
                                : "`\(start) --choose` (Only me or Both, me first)")
            }
            // An API without a key takes any key file.
            let ours = facts.live?.apiKey.isEmpty == true ? nil : facts.keyFile
            switch ToolAddress.miss(pointer, baseURL: here, keyFile: ours, thisMac: facts.thisMac) {
            case .address(let url)?:
                return line(name, .warn, "points at \(url), not this Mac's local API (\(here)) (\(file))", fix: setUpCommand)
            case .key(let path)?:
                let theirs = ToolIntegration.displayPath(URL(fileURLWithPath: path), home: facts.home)
                let mine = ours.map { ", not " + ToolIntegration.displayPath($0, home: facts.home) } ?? ""
                return line(name, .warn, "points here, but reads its key from \(theirs)\(mine) (\(file))", fix: setUpCommand)
            case nil:
                return line(name, .pass, "points here (\(file))")
            }
        }
    }
}

extension DoctorLocalAPI {
    /// What `live` reads on this Mac, each a stand-in for tests.
    struct Reads {
        var liveInfo: () -> LocalEndpoint.Info? = { LocalEndpoint.readLiveInfo() }
        var keyFile: (Int) -> URL? = { LocalEndpoint.keyFile(forPort: $0) }
        /// The running provider's state when it is single-Mac serving, not a pair's part.
        var soloState: (DaemonState) -> DaemonState? = { ServiceDrain.soloProviderState($0) }
        var terminalOnlyMe: (DaemonState) -> Bool = { Restart.terminalOnlyMe($0) }
        var serviceInstalled: () -> Bool = { LaunchAgent.isInstalled() }
        var tools: () -> [DoctorToolSetup] = { DoctorToolSetup.read() }
        var localHostName: () -> String? = { Local.localHostName() }
        var nextFreePort: (UInt16) -> UInt16? = { LocalAPIPort.nextFree(besides: $0) }
        var answers: (LocalEndpoint.Info) async -> Bool = { await DoctorLocalAPI.answers($0) }
    }

    /// This Mac's: `[local]` from the config `doctor` loaded, the running provider (`running`: its process matches the
    /// state), `local.json`, the key file, the pair, and the tools' configs. The live API is asked `GET /health`.
    static func live(config: ProviderConfig, daemonState: DaemonState?, daemonRunning: Bool,
                     pair: ClusterPairSummary, reads: Reads = Reads()) async -> DoctorLocalAPI {
        let live = reads.liveInfo()
        let running = daemonRunning ? daemonState : nil
        var facts = Facts(saved: config.local, running: running, live: live)
        // The running API's key file, else the saved port's.
        facts.keyFile = (live?.port ?? config.local?.port).flatMap { reads.keyFile(Int($0)) }
        facts.pair = pair
        let solo = running.flatMap(reads.soloState)
        facts.servingAlone = pair.paired && solo != nil
        facts.terminalOnlyMe = solo.map { $0.servesOnlyItsOwner && reads.terminalOnlyMe($0) } ?? false
        facts.serviceInstalled = reads.serviceInstalled()
        facts.tools = reads.tools()
        let bind = live?.host ?? config.local?.resolvedBind ?? LocalSettings.defaultBind
        facts.thisMac = ToolAddress.thisMacsNames(listeningOn: bind, localHostName: reads.localHostName)
        facts.nextFreePort = reads.nextFreePort
        if let live { facts.answers = await reads.answers(live) }
        return DoctorLocalAPI(facts: facts)
    }

    /// Whether the local API answers `GET /health` (which needs no key) within `timeout` seconds.
    static func answers(_ info: LocalEndpoint.Info, timeout: TimeInterval = 2) async -> Bool {
        let host = ["0.0.0.0", "::", ""].contains(info.host) ? "127.0.0.1" : info.host
        guard let url = URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(info.port)/health") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// The detailed check that stands for the network checks `doctor` skips on a Mac set to Only me.
    static let networkNotNeeded = DoctorCheck(name: "darkbloom network", status: .info,
                                              detail: "not needed (Only me): account, trust and coordinator checks skipped")
}
