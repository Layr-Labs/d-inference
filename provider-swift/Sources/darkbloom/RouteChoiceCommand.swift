import ArgumentParser
import Foundation
import ProviderCore

// Each command's `route` is both its name and what it saves, so `route my-macs` can't save another route.

/// `darkbloom route this-mac`: your requests stay on this Mac.
struct RouteThisMac: AsyncParsableCommand {
    static let route = LocalSettings.Route.thisMac
    static let configuration = CommandConfiguration(
        commandName: route.rawValue,
        abstract: "Keep your requests on this Mac.",
        discussion: "Saves [local] route = \"this-mac\": a request this Mac can't take gets this Mac's own answer, and "
            + "nothing is passed on. Needs no account key.")

    @OptionGroup var configOptions: ConfigOptions

    func run() async throws {
        throw ExitCode(RouteChoiceFlow.live(configPath: configOptions.config).choose(Self.route))
    }
}

/// `darkbloom route my-macs`: a request this Mac can't take goes on to your other Macs.
struct RouteMyMacs: AsyncParsableCommand {
    static let route = LocalSettings.Route.myMacs
    static let configuration = CommandConfiguration(
        commandName: route.rawValue,
        abstract: "Send a request this Mac can't take to your other Macs (free).",
        discussion: "Saves [local] route = \"my-macs\": your other Macs answer, free; nothing goes to the Darkbloom "
            + "network. Needs your account API key (`\(BuildEnvironment.current.cliName) route key`).")

    @OptionGroup var configOptions: ConfigOptions

    func run() async throws {
        throw ExitCode(RouteChoiceFlow.live(configPath: configOptions.config).choose(Self.route))
    }
}

/// `darkbloom route my-macs-first`: your other Macs first, then the Darkbloom network.
struct RouteMyMacsFirst: AsyncParsableCommand {
    static let route = LocalSettings.Route.myMacsFirst
    static let configuration = CommandConfiguration(
        commandName: route.rawValue,
        abstract: "Send it to your other Macs (free), then the Darkbloom network (billed).",
        discussion: "Saves [local] route = \"my-macs-first\": your other Macs first, free, then the Darkbloom network, "
            + "billed to your balance. Requests from other machines (your LAN or tailnet) never use the paid network. "
            + "Needs your account API key (`\(BuildEnvironment.current.cliName) route key`).")

    @OptionGroup var configOptions: ConfigOptions

    func run() async throws {
        throw ExitCode(RouteChoiceFlow.live(configPath: configOptions.config).choose(Self.route))
    }
}

/// The steps of `route <choice>`, apart from the Keychain, the config file and the terminal: it saves `[local] route`
/// and says where your requests go. A route that passes requests on needs a saved account key: the flow gets only
/// whether one is saved, and no line names a key. No line names a speed.
struct RouteChoiceFlow {
    /// Whether the local router's account key is saved; asked only for a route that passes requests on.
    let accountKeySaved: () -> Bool
    /// Saves `[local] route`; true when the file changed.
    let save: (LocalSettings.Route) throws -> Bool
    /// The local API running now: its router uses the saved route from its next request that needs it. Only whether it
    /// runs and whether it has a local key are read; its key is never said.
    var liveEndpoint: LocalEndpoint.Info?
    /// This Mac's part in a two-Mac cluster: the pair's local API uses the leading Mac's route.
    var pair: RouteSaved.PairPart?
    let say: (String) -> Void

    func choose(_ route: LocalSettings.Route) -> Int32 {
        let cli = BuildEnvironment.current.cliName
        if route != .thisMac, !accountKeySaved() {
            say("✗ Not saved: `\(cli) route \(route.rawValue)` passes your requests on with your account API key, and "
                + "this Mac has none saved.")
            say("Save one from the Darkbloom console with `\(cli) route key` (a self-route-only key is safest), then run "
                + "`\(cli) route \(route.rawValue)` again.")
            return 1
        }
        let changed: Bool
        do {
            changed = try save(route)
        } catch {
            say("✗ Not saved: \(error)")
            return 1
        }
        // A local API without a local key (`--no-auth`) passes nothing on, whatever the route, the pair's on the leading
        // Mac included. On the Mac that follows, the pair's API is the leading Mac's, whatever this Mac runs.
        let keyless = pair?.follows != true && liveEndpoint?.apiKey.isEmpty == true
        let head = changed ? "✓ Saved." : "✓ Already saved."
        say(keyless ? head : head + " " + RouteSaved.when(running: liveEndpoint != nil, pair: pair))
        for line in Self.meaning(route) { say(line) }
        if keyless {
            say("The local API running now has no local key (--no-auth): it keeps every request on this Mac, "
                + "whatever the route.")
        } else if let pair {
            say(RouteSaved.pairRouteLine(pair, route: route))
        }
        return 0
    }

    /// Where your requests go with `route`, in plain words.
    static func meaning(_ route: LocalSettings.Route) -> [String] {
        switch route {
        case .thisMac:
            return ["Your requests stay on this Mac: one it can't take gets this Mac's own answer, and nothing is passed on."]
        case .myMacs:
            return ["A request this Mac can't take goes on to your other Macs, free. It never goes to the Darkbloom network."]
        case .myMacsFirst:
            return ["A request this Mac can't take goes on to your other Macs (free), then to the Darkbloom network, billed "
                        + "to your balance. With a self-route-only key, only your Macs answer.",
                    "Requests from other machines (your LAN or tailnet) never use the paid network: they can use this Mac "
                        + "and your other Macs."]
        }
    }

    /// This Mac's Keychain, provider.toml (`configPath`, else the default), local API and pairing.
    static func live(configPath: String?) -> RouteChoiceFlow {
        RouteChoiceFlow(
            accountKeySaved: { Start.accountKeySaved() },
            save: { route in try setLocalSettings(configPath: configPath) { $0.route = route }.changed },
            liveEndpoint: LocalEndpoint.readLiveInfo(), pair: .of(ClusterPairSummary.local()), say: { print($0) })
    }
}

/// When a saved route or account key counts. A running local API uses both from its next request that needs them:
/// its router reads `[local] route` again once provider.toml changes (`LocalRouterRouteFile`), and the key's change
/// notification makes it read the key again, so nothing restarts and no model reloads. In a two-Mac cluster, the
/// pair's local API runs on the leading Mac and uses that Mac's route and key; the other Mac's own port forwards
/// requests to it.
enum RouteSaved {
    /// This Mac's part in a two-Mac cluster.
    enum PairPart: Equatable, Sendable {
        /// This Mac leads: the pair's local API runs here.
        case leads(other: String)
        /// This Mac follows `leader`, whose local API is the pair's.
        case follows(leader: String)

        /// Whether this Mac follows: the pair doesn't use what it saves.
        var follows: Bool {
            if case .follows = self { return true }
            return false
        }

        /// This Mac's part, when its pairing can be read; nil on a Mac in no pair.
        static func of(_ pair: ClusterPairSummary) -> PairPart? {
            guard pair.paired, !pair.pairingUnreadable, let role = pair.role else { return nil }
            return role == .leader ? .leads(other: pair.otherMac) : .follows(leader: pair.otherMac)
        }
    }

    static let usesItNow = "Your local API uses it now."
    static let appliesAtStart = "It applies when your local API starts."
    static var appliesAlone: String { "It applies when this Mac serves alone (`\(BuildEnvironment.current.cliName) start --solo`)." }

    /// When what was saved counts on this Mac: now, when a local API (or the pair's, on the leading Mac) runs; else at
    /// its start. On the Mac that follows, only when it serves alone: the pair uses the leading Mac's.
    static func when(running: Bool, pair: PairPart?) -> String {
        if pair?.follows == true { return appliesAlone }
        return running ? usesItNow : appliesAtStart
    }

    /// Whose route the pair's local API uses.
    static func pairRouteLine(_ pair: PairPart, route: LocalSettings.Route) -> String {
        switch pair {
        case .leads(let other):
            let passes = route == .thisMac ? "passes nothing on" : "passes on what the pair can't take"
            return "In this pair, this Mac's route applies: the pair's local API runs here and \(passes), including "
                + "requests \(other) forwards to it."
        case .follows(let leader):
            return "In this pair, the leading Mac's route applies (\(leader)): its local API passes on what the pair can't "
                + "take, including requests this Mac forwards to it. Run `\(BuildEnvironment.current.cliName) route "
                + "\(route.rawValue)` there."
        }
    }

    /// Whose account key the pair's local API uses, once `route key` saved this Mac's key or `removed` it.
    /// `routePassesOn`: this Mac's route passes requests on with a key.
    static func pairKeyLine(_ pair: PairPart, removed: Bool, routePassesOn: Bool) -> String {
        let cli = BuildEnvironment.current.cliName
        switch pair {
        case .leads:
            let runsHere = "In this pair, the pair's local API runs on this Mac"
            if !routePassesOn { return runsHere + " and uses this Mac's key once its route passes requests on." }
            return removed ? runsHere + ", so the pair passes nothing on until a key is saved here again."
                : runsHere + " and passes requests on with this key."
        case .follows(let leader):
            return "In this pair, the pair's local API uses the leading Mac's key (\(leader)), not this one: "
                + (removed ? "to stop the pair passing requests on, run `\(cli) route key --remove` there."
                    : "run `\(cli) route key` there.")
        }
    }
}
