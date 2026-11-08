import Foundation
import ProviderCore

/// `darkbloom doctor`'s Local API section (UX audit R17): how this Mac serves (Only me, Darkbloom network or Both, me
/// first), its local API's address, whether it answers and on which port, whether its key file is there (never the
/// key), and whether OpenCode and Hermes point at it. Every problem names the next command. On a Mac set to Only me
/// the Darkbloom network's checks don't apply (`onlyMe`), and `doctor` skips them.
struct DoctorLocalAPI {
    /// What the section reads: `live` reads this Mac's; tests give their own.
    struct Facts {
        /// `[local]` as saved.
        var saved: LocalSettings?
        /// The running provider's state; nil when none runs.
        var running: DaemonState?
        /// The local API `local.json` names, while its process runs.
        var live: LocalEndpoint.Info?
        /// Whether that API answered `GET /health`; nil when it wasn't asked.
        var answers: Bool?
        /// The file holding the key of the API on this Mac's port (`LocalEndpoint.keyFile`); nil when none does.
        var keyFile: URL?
        /// This Mac's pair, as it knows it by itself (`ClusterPairSummary.local`).
        var pair: ClusterPairSummary = .notPaired
        /// What OpenCode's and Hermes' configs say of Darkbloom.
        var tools: [DoctorToolSetup] = []
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

    /// How the running provider serves, read as `status` reads it (`Status.servingLines`): with its own local API,
    /// Only me when it serves only its owner, else Both; without one, Both when its local API failed to open, else the
    /// Darkbloom network. Nil when none runs.
    var runningMode: LocalSettings.Mode? {
        guard let state = facts.running else { return nil }
        if facts.live?.pid == state.pid { return state.servesOnlyItsOwner ? .local : .both }
        return state.localAPIFailure != nil ? .both : .network
    }

    /// How this Mac serves: the running provider's way, else the saved choice; nil when neither says.
    var mode: LocalSettings.Mode? { runningMode ?? facts.saved?.mode }

    /// This Mac serves only its owner (a single Mac's Only me, or a pair serving locally only): Darkbloom never
    /// contacts it, so the account, trust, App Attest and coordinator checks don't apply.
    var onlyMe: Bool {
        if let pair { return pair.localOnly }
        return !facts.pair.pairingUnreadable && mode == .local
    }

    /// Whether this Mac has, or is set to have, a local API.
    private var hasLocalAPI: Bool {
        if facts.live != nil { return true }
        if let pair { return pair.localOnly || pair.localAPI != nil }
        return mode == .local || mode == .both
    }

    /// The address this Mac's local API is reached at: the running one's, else the saved port's on a single Mac.
    var address: String? {
        if let live = facts.live { return live.baseURL }
        guard pair == nil, let saved = facts.saved, let port = saved.port else { return nil }
        return LocalEndpoint.baseURL(host: saved.resolvedBind, port: port)
    }

    /// The section's lines, with the line that says the network checks are skipped (`onlyMe`).
    var diagnostics: [Diagnostic] { lines(networkChecks: !onlyMe) }

    /// The section's lines; `networkChecks` false adds the line that says the Darkbloom network's checks are skipped.
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
        if let pair {
            let words = pair.localOnly ? "Only me (this pair) — Darkbloom never contacts these Macs; the pair's API runs on "
                + pair.leadingMac
                : pair.localAPI != nil ? "Both, me first (this pair) — the pair's API runs on \(pair.leadingMac)"
                : "Darkbloom network (this pair) — no local API"
            return line("mode", .info, words)
        }
        guard let mode else {
            return line("mode", .info, "not chosen yet: `\(cli) start` asks how this Mac serves (Only me, Darkbloom "
                + "network or Both, me first)")
        }
        let words: String
        if runningMode != nil, let state = facts.running {
            words = LocalFirstWords.serving(mode: mode, meFirst: state.meFirst != nil,
                                            idleMinutes: state.meFirst.map { LocalFirstWords.idleMinutes(milliseconds: $0.idleMs) } ?? 0)
        } else {
            let saved = facts.saved ?? LocalSettings()
            words = LocalFirstWords.serving(mode: mode, meFirst: saved.meFirstEnabled(in: mode),
                                            idleMinutes: saved.resolvedMeFirstIdleMinutes)
        }
        guard runningMode != nil else { return line("mode", .info, words + " (saved)") }
        guard let saved = facts.saved?.mode, saved != mode else { return line("mode", .info, words + " (serving now)") }
        return line("mode", .info, words + " (serving now; your saved choice, \(Self.name(saved)), serves at the next "
            + "`\(cli) start`)")
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
            if pair.role == .member, pair.localAPI != nil {
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
        if let pair, pair.role == .member, pair.localAPI != nil { return nil }
        return line("key file", .info, "none yet: the first start writes it")
    }

    private func toolLine(_ setup: DoctorToolSetup) -> Diagnostic? {
        let cli = Self.cli
        let flag = setup.tool == .opencode ? "--opencode" : "--hermes"
        let file = ToolIntegration.displayPath(setup.file, home: facts.home)
        switch setup.found {
        case .noFile, .noEntry:
            guard hasLocalAPI else { return nil }
            return line(setup.name, .info, "not set up (`\(cli) \(flag)` sets it up)")
        case .unreadable(let why):
            guard hasLocalAPI else { return nil }
            return line(setup.name, .warn, "can't read \(file): \(why)")
        case .entry(let pointsAt, let keyFile):
            guard let here = address else {
                guard !hasLocalAPI else { return line(setup.name, .info, "points at \(pointsAt) (\(file))") }
                return line(setup.name, .warn, "points at \(pointsAt), but this Mac serves no local API (\(file))",
                            fix: pair == nil ? "`\(cli) start --choose` (Only me or Both, me first)" : nil)
            }
            guard DoctorToolSetup.sameAddress(pointsAt, here) else {
                return line(setup.name, .warn, "points at \(pointsAt), not this Mac's local API (\(here)) (\(file))",
                            fix: "`\(cli) \(flag)`")
            }
            if let keyFile, let ours = facts.keyFile,
               DoctorToolSetup.expanded(keyFile, home: facts.home) != ours.path {
                return line(setup.name, .warn, "points here, but reads its key from \(keyFile), not "
                    + ToolIntegration.displayPath(ours, home: facts.home) + " (\(file))", fix: "`\(cli) \(flag)`")
            }
            return line(setup.name, .pass, "points here (\(file))")
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
    /// This Mac's: `[local]` from the config `doctor` loaded, the running provider (`running`: its process matches the
    /// state), `local.json`, the key file, the pair, and the tools' configs. The live API is asked `GET /health`.
    static func live(config: ProviderConfig, daemonState: DaemonState?, daemonRunning: Bool,
                     pair: ClusterPairSummary) async -> DoctorLocalAPI {
        let live = LocalEndpoint.readLiveInfo()
        var facts = Facts(saved: config.local, running: daemonRunning ? daemonState : nil, live: live)
        facts.keyFile = (live?.port ?? config.local?.port).flatMap { LocalEndpoint.keyFile(forPort: Int($0)) }
        facts.pair = pair
        facts.tools = DoctorToolSetup.read()
        facts.nextFreePort = { LocalAPIPort.nextFree(besides: $0) }
        if let live { facts.answers = await answers(live) }
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
