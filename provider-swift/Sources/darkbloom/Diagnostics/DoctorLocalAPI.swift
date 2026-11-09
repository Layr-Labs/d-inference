import Foundation
import ProviderCore

/// `darkbloom doctor`'s Local API section (UX audit R17): how this Mac serves (Only me, Darkbloom network or Both, me
/// first), its local API's address, whether it answers and on which port, whether its key file is there, and whether
/// OpenCode and Hermes point at it. Every problem names the next command. On a Mac set to Only me the Darkbloom
/// network's checks don't apply (`onlyMe`), and `doctor` skips them.
///
/// No line holds the key: of the running API's key only whether there is one is read (`keyLine`), and of the tools'
/// configs only the path of the file each reads its key from (`DoctorToolSetup`).
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
        /// RED SEAM: not read yet. On a paired Mac, the running provider is single-Mac serving (`start --solo`).
        var servingAlone = false
        /// RED SEAM: not read yet. The running provider is Only me in a terminal (`start --local --here`).
        var terminalOnlyMe = false
        /// RED SEAM: not read yet. The provider's background service is installed.
        var serviceInstalled = false
        /// What OpenCode's and Hermes' configs say of Darkbloom.
        var tools: [DoctorToolSetup] = []
        /// RED SEAM: not read yet. The names this Mac's local API answers to.
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

    /// How that pair serves, as its leader saved it: Only me when it serves locally only, Both, me first when its local
    /// API runs beside Darkbloom, else the Darkbloom network.
    private var pairMode: LocalSettings.Mode? {
        guard let pair else { return nil }
        return pair.localOnly ? .local : pair.localAPI != nil ? .both : .network
    }

    /// How the running provider serves, read as `status` reads it (`Status.servingLines`): with its own local API,
    /// Only me when it serves only its owner, else Both; without one, Both when its local API failed to open, else the
    /// Darkbloom network. Nil when none runs.
    var runningMode: LocalSettings.Mode? {
        guard let state = facts.running else { return nil }
        if facts.live?.pid == state.pid { return state.servesOnlyItsOwner ? .local : .both }
        return state.localAPIFailure != nil ? .both : .network
    }

    /// How this Mac serves on its own: the running provider's way, else the saved choice; nil when neither says.
    var mode: LocalSettings.Mode? { runningMode ?? facts.saved?.mode }

    /// How this Mac serves: its pair's way, else its own.
    private var servingMode: LocalSettings.Mode? { pairMode ?? mode }

    /// This Mac serves only its owner (a single Mac's Only me, or a pair serving locally only): Darkbloom never
    /// contacts it, so the account, trust, App Attest and coordinator checks don't apply. Never while its pairing record
    /// can't be read: it may be in a pair that serves Darkbloom.
    var onlyMe: Bool { !facts.pair.pairingUnreadable && servingMode == .local }

    /// Whether `doctor` runs the Darkbloom network's checks: on every Mac but one set to Only me, and there too when
    /// `--coordinator` names a coordinator to check.
    func runsNetworkChecks(coordinatorOverride: String?) -> Bool { !onlyMe || coordinatorOverride != nil }

    /// Whether this Mac has, or is set to have, a local API: one runs, or it serves Only me or Both, me first.
    private var hasLocalAPI: Bool { facts.live != nil || (servingMode.map { $0 != .network } ?? false) }

    /// The address this Mac's local API is reached at: the running one's, else the saved port's on a single Mac.
    var address: String? {
        if let live = facts.live { return live.baseURL }
        guard pair == nil, let saved = facts.saved, let port = saved.port else { return nil }
        return LocalEndpoint.baseURL(host: saved.resolvedBind, port: port)
    }

    /// On a pair serving Both, me first, the Mac that doesn't lead: the pair's API, with its address and key, is on the
    /// other Mac.
    private var pairAPIOnTheOtherMac: Bool { pair?.role == .member && pair?.localAPI != nil }

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

    // MARK: - The lines

    private var modeLine: Diagnostic {
        let cli = Self.cli
        if facts.pair.pairingUnreadable {
            return line("mode", .info, "this Mac's pairing record couldn't be read, so how it serves is unknown",
                        fix: "`\(cli) cluster` on this Mac checks it")
        }
        if let pair, let pairMode {
            let words = switch pairMode {
            case .local: "Only me (this pair) — Darkbloom never contacts these Macs; the pair's API runs on "
                + pair.leadingMac
            case .both: "Both, me first (this pair) — the pair's API runs on \(pair.leadingMac)"
            case .network: "Darkbloom network (this pair) — no local API"
            }
            return line("mode", .info, words)
        }
        if let mode = runningMode, let state = facts.running {
            let idle = state.meFirst.map { LocalFirstWords.idleMinutes(milliseconds: $0.idleMs) } ?? 0
            let words = LocalFirstWords.serving(mode: mode, meFirst: state.meFirst != nil, idleMinutes: idle)
            guard let saved = facts.saved?.mode, saved != mode else { return line("mode", .info, words + " (serving now)") }
            return line("mode", .info, words + " (serving now; your saved choice, \(Self.name(saved)), serves at the next "
                + "`\(cli) start`)")
        }
        guard let saved = facts.saved, let mode = saved.mode else {
            return line("mode", .info, "not chosen yet: `\(cli) start` asks how this Mac serves (Only me, Darkbloom "
                + "network or Both, me first)")
        }
        return line("mode", .info, LocalFirstWords.serving(mode: mode, meFirst: saved.meFirstEnabled(in: mode),
                                                           idleMinutes: saved.resolvedMeFirstIdleMinutes) + " (saved)")
    }

    private var networkLine: Diagnostic {
        let change = pair == nil ? "`\(Self.cli) start --choose` changes how this Mac serves"
            : "`\(Self.cli) cluster` changes how the pair serves"
        return line("darkbloom network", .info, "not needed (Only me): the account, trust, App Attest and coordinator "
            + "checks are skipped; " + change)
    }

    private var addressLine: Diagnostic {
        let cli = Self.cli
        if let live = facts.live {
            if facts.answers == false {
                return line("address", .fail, "\(live.baseURL) — its server runs, but port \(live.port) doesn't answer",
                            fix: "`\(cli) restart`")
            }
            return line("address", .pass, "\(live.baseURL) — up on port \(live.port)")
        }
        if let pair {
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
            if let failure = state.localAPIFailure {
                return line("address", .fail, "\(shown) isn't up",
                            fix: LocalFirstWords.whyNotUp(failure, nextFree: facts.nextFreePort(failure.port),
                                                          server: .singleMac(paired: false)))
            }
            return line("address", .warn, "\(shown) — not listening yet", fix: "`\(cli) status` shows how this Mac serves")
        }
        return line("address", .warn, address.map { "\($0) — not running" } ?? "not running; the first start chooses its port",
                    fix: "`\(cli) start`")
    }

    private var keyLine: Diagnostic? {
        let cli = Self.cli
        // The section's one read of the key: whether the API takes one.
        if let live = facts.live, live.apiKey.isEmpty {
            return line("key file", .info, "none: this API takes no key (--no-auth), so it keeps every request on this Mac")
        }
        if let keyFile = facts.keyFile {
            return line("key file", .pass, ToolIntegration.displayPath(keyFile, home: facts.home)
                + " (`\(cli) local` shows the key)")
        }
        if facts.live != nil {
            return line("key file", .fail, "no key file holds the running API's key, so tools that read it are refused",
                        fix: "`\(cli) restart`")
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
            // RED SEAM: doctor's own comparison, on `ToolAddress`'s shape.
            guard let pointsAt = pointer.baseURL else {
                guard hasLocalAPI else { return nil }
                return line(name, .warn, "can't read \(file): its provider has no address")
            }
            guard let here = address else {
                guard !hasLocalAPI else { return line(name, .info, "points at \(pointsAt) (\(file))") }
                return line(name, .warn, "points at \(pointsAt), but this Mac serves no local API (\(file))",
                            fix: pair == nil ? "`\(Self.cli) start --choose` (Only me or Both, me first)" : nil)
            }
            guard DoctorToolSetup.sameAddress(pointsAt, here) else {
                return line(name, .warn, "points at \(pointsAt), not this Mac's local API (\(here)) (\(file))",
                            fix: setUpCommand)
            }
            if let keyFile = pointer.keyFile, let ours = facts.keyFile, keyFile.path != ours.path {
                return line(name, .warn, "points here, but reads its key from "
                    + ToolIntegration.displayPath(keyFile, home: facts.home) + ", not "
                    + ToolIntegration.displayPath(ours, home: facts.home) + " (\(file))", fix: setUpCommand)
            }
            return line(name, .pass, "points here (\(file))")
        }
    }

    /// A way to serve, as the start question names it.
    static func name(_ mode: LocalSettings.Mode) -> String {
        switch mode {
        case .local: "Only me"
        case .network: "Darkbloom network"
        case .both: "Both, me first"
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
        var facts = Facts(saved: config.local, running: daemonRunning ? daemonState : nil, live: live)
        facts.keyFile = (live?.port ?? config.local?.port).flatMap { reads.keyFile(Int($0)) }
        facts.pair = pair
        facts.tools = reads.tools()
        facts.nextFreePort = reads.nextFreePort
        if let live { facts.answers = await reads.answers(live) }
        // RED SEAM: whether this Mac serves alone, Only me in a terminal, the service, and this Mac's names: not read.
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
