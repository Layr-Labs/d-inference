import ArgumentParser
import Foundation
import ProviderCore

/// `darkbloom route this-mac`: your requests stay on this Mac.
struct RouteThisMac: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: LocalSettings.Route.thisMac.rawValue,
        abstract: "Keep your requests on this Mac.",
        discussion: "Saves [local] route = \"this-mac\": a request this Mac can't take gets this Mac's own answer, and "
            + "nothing is passed on. Needs no account key.")

    @OptionGroup var configOptions: ConfigOptions

    func run() async throws { throw ExitCode(RouteChoiceFlow.live(configPath: configOptions.config).choose(.thisMac)) }
}

/// `darkbloom route my-macs`: a request this Mac can't take goes on to your other Macs.
struct RouteMyMacs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: LocalSettings.Route.myMacs.rawValue,
        abstract: "Send a request this Mac can't take to your other Macs (free).",
        discussion: "Saves [local] route = \"my-macs\": your other Macs answer, free; nothing goes to the Darkbloom "
            + "network. Needs your account API key (`\(BuildEnvironment.current.cliName) route key`).")

    @OptionGroup var configOptions: ConfigOptions

    func run() async throws { throw ExitCode(RouteChoiceFlow.live(configPath: configOptions.config).choose(.myMacs)) }
}

/// `darkbloom route my-macs-first`: your other Macs first, then the Darkbloom network.
struct RouteMyMacsFirst: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: LocalSettings.Route.myMacsFirst.rawValue,
        abstract: "Send it to your other Macs (free), then the Darkbloom network (billed).",
        discussion: "Saves [local] route = \"my-macs-first\": your other Macs first, free, then the Darkbloom network, "
            + "billed to your balance. Requests from other machines (your LAN or tailnet) never use the paid network. "
            + "Needs your account API key (`\(BuildEnvironment.current.cliName) route key`).")

    @OptionGroup var configOptions: ConfigOptions

    func run() async throws {
        throw ExitCode(RouteChoiceFlow.live(configPath: configOptions.config).choose(.myMacsFirst))
    }
}

/// The steps of `route <choice>`, apart from the Keychain, the config file and the terminal: it saves `[local] route`
/// and says where your requests go. A route that passes requests on needs a saved account key; it only asks whether
/// one is saved, never reads or prints it. No line names a speed.
struct RouteChoiceFlow {
    /// Whether the local router's account key is saved; asked only for a route that passes requests on.
    let accountKeySaved: () -> Bool
    /// Saves `[local] route`; true when the file changed.
    let save: (LocalSettings.Route) throws -> Bool
    /// The local API running now: it read its route when it started.
    var liveEndpoint: LocalEndpoint.Info?
    /// On a Mac that follows in a two-Mac cluster, the leading Mac: the pair's API passes requests on as its route says.
    var pairLeader: String?
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
        say((changed ? "✓ Saved" : "✓ Already saved") + ": [local] route = \"\(route.rawValue)\".")
        for line in Self.meaning(route) { say(line) }
        if let liveEndpoint {
            if liveEndpoint.apiKey.isEmpty {
                say("The local API running now has no local key (--no-auth): it keeps every request on this Mac, "
                    + "whatever the route.")
            } else {
                say("The local API running now (\(liveEndpoint.baseURL)) keeps the route it started with until it starts "
                    + "again: `\(cli) restart`.")
            }
        }
        if let pairLeader {
            say("In this Mac's two-Mac cluster, the pair's API passes requests on as \(pairLeader) says: run "
                + "`\(cli) route \(route.rawValue)` there.")
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
        let pair = ClusterPairSummary.local()
        return RouteChoiceFlow(
            accountKeySaved: { Start.accountKeySaved() },
            save: { route in try setLocalSettings(configPath: configPath) { $0.route = route }.changed },
            liveEndpoint: LocalEndpoint.readLiveInfo(),
            pairLeader: pair.paired && pair.role == .member ? pair.otherMac : nil,
            say: { print($0) })
    }
}
