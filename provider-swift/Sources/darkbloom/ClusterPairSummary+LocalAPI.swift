import Foundation
import ProviderCore

/// The pair's local API beside Darkbloom (Both, me first), as one Mac sees it: whether its own part runs the pair's
/// slot, where that part's local API listens, and that part's me first.
struct ClusterPairLocalAPI: Sendable, Equatable {
    /// Where a local API listens: its address and port, never its key.
    struct Address: Sendable, Equatable {
        var host: String
        var port: UInt16
    }

    /// This Mac's part runs rank 0, the part that hosts the pair's slot and runs its local API.
    var runsRankZero: Bool
    /// Where this Mac's running part listens (its discovery record, written once the API is bound); nil while none.
    var listening: Address?
    /// The running part's me first (`DaemonState.meFirst`); nil when it is off or not known.
    var meFirst: MeFirstSnapshot?
}

extension ClusterPairSummary {
    /// `status` and `cluster status` on a pair that serves Both, me first: whether Darkbloom is paused for you, where the
    /// pair's local API listens, and what the other Macs do. The Mac whose part runs rank 0 says it from its own part,
    /// and that the other Macs pass requests to it only while its API listens on every address. With the API on every
    /// address, every other Mac names its own relay's address, which passes your requests to it, or why it can't answer
    /// now (`memberAPIUnavailable`). Otherwise it says where to look. Nothing while the pair is stopped, or for the
    /// Darkbloom network alone. With Only me it names no address (`darkbloom local` does), only why this Mac's own port
    /// for the pair can't answer now. No key and no speed.
    ///
    /// The pause comes only from the part that runs rank 0, never worked out here. The leading Mac's status carries it
    /// when that part is its own (`OnboardingLive.pauseLines`), and every Mac shows those lines under the pair's line: it
    /// is said once, there. A status that doesn't carry it (that part runs on the Mac that follows, the leading Mac's
    /// build is older, or its answer didn't come) leaves it to the Mac whose part runs rank 0, from its own part; the
    /// other Mac says where to look.
    func localAPILines(now: Date = Date()) -> [String] {
        guard let localAPI else { return memberAPIUnavailable.map { ["Local API: " + $0] } ?? [] }
        guard started, paired, !pairingUnreadable else { return [] }
        let statusSaysPause = lines.contains { $0.hasPrefix(MeFirstWords.pairPrefix) }
        guard localAPI.runsRankZero else {
            guard answersOnEveryMac else {
                return ["Local API: on \(otherMac), which runs the pair's API; `\(Self.cli) local` there shows its address and key"
                            + (statusSaysPause ? "" : ", and `\(Self.cli) status` there whether Darkbloom is paused for you"),
                        "Members: this Mac is part of the pair; it runs no local API"]
            }
            let passes = "Members: \(otherMac) runs the pair's API; this Mac passes your requests to it, and Darkbloom pauses for them too"
            if let down = memberAPIUnavailable {
                return ["Local API: " + down, "Members: \(otherMac) runs the pair's API; this Mac is part of the pair"]
            }
            guard let relaying else { return ["Local API: " + relayStartingWords, passes] }
            return [Self.addressLine(relaying), passes]
        }
        // From where this Mac's API listens once it does: on this Mac only while Darkbloom doesn't have the pair.
        let everyMac = localAPI.listening.map { ClusterServingScope.answersOnEveryMac(bind: $0.host) } ?? answersOnEveryMac
        let members = "Members: \(otherMac) is part of the pair; "
            + (everyMac ? "its own port passes your requests to this API" : "it runs no local API")
        guard let address = localAPI.listening else {
            return ["Local API: not listening yet; it starts with this Mac's part of the pair", members]
        }
        return (statusSaysPause ? [] : MeFirstWords.pairLines(localAPI.meFirst, now: now)) + [Self.addressLine(address), members]
    }


    /// Why this Mac's own port for the pair's API can't pass a request on now, after "Local API: ", as `status`,
    /// `darkbloom local` and `doctor` say it: `memberAPIDown`, else `memberAPIRestarting`. Nil otherwise.
    var memberAPIUnavailable: String? { memberAPIDown ?? memberAPIRestarting }

    /// Why this Mac, which relays the pair's API on every address (Both, me first or Only me), has no working address for
    /// it now, after "Local API: ", as `status`, `darkbloom local`, `--opencode` and the app's Start all say it: rank 0
    /// answers on its own Mac only while Darkbloom doesn't have the pair, another program holds this Mac's port, or rank
    /// 0's Mac can't be reached (the relay answers 503, in these words). Nil while it has one, while it starts, and on any
    /// other Mac or pair (`mayRelayPairAPI`).
    var memberAPIDown: String? {
        guard mayRelayPairAPI else { return nil }
        if let relaying {
            guard relayRankZeroAway else { return nil }
            return Self.answers503(at: relaying, relayWords.unreachable)
        }
        if relayWaitsForOffer {
            return "none on this Mac while Darkbloom doesn't have the pair; meanwhile the pair answers only on \(otherMac) "
                + "(`\(Self.cli) local` there shows its address and key)"
        }
        if let held = relayPortHeld {
            return "port \(held) on this Mac is held by another program, so this Mac doesn't answer for the pair; free it, or "
                + "set another `[local] port` in provider.toml, then `\(Self.cli) restart`"
        }
        return nil
    }

    /// This Mac's relay runs while the pair's API on rank 0's Mac doesn't listen for now (its part starts again after a
    /// stop, a restart or an update; `ClusterServiceStatus.relayRankZeroAPIDown`): it answers each request a 503 until
    /// that API listens, in these words, after "Local API: ", as `status`, `darkbloom local` and `doctor` say it. Unlike
    /// `memberAPIDown`, it ends by itself, so the app's Start and `start --opencode` still take the address as this
    /// Mac's. Nil otherwise, and while `memberAPIDown` says why.
    var memberAPIRestarting: String? {
        guard relayRankZeroAPIDown, memberAPIDown == nil, let relaying, mayRelayPairAPI else { return nil }
        return Self.answers503(at: relaying, relayWords.notAnswering)
    }

    /// The pair is started and serves its API on every address, and this Mac's part isn't rank 0, so this Mac may relay
    /// that API. With Only me, `localAPI` (Both's) doesn't say whether this Mac's part runs rank 0, but only a Mac that
    /// relays has the relay's facts from its cluster service (`ClusterService.RelayState.publish`).
    private var mayRelayPairAPI: Bool {
        (localAPI.map { !$0.runsRankZero } ?? localOnly) && answersOnEveryMac && started && paired && !pairingUnreadable
    }

    /// The words of this Mac's relay's 503s, which name the other Mac.
    private var relayWords: ClusterLocalRelay.Refusals { .pair(otherMac: otherMacName, cli: Self.cli) }

    /// This Mac's relay, on `relaying`, answers each request a 503 for now, in `words`.
    private static func answers503(at relaying: ClusterPairLocalAPI.Address, _ words: String) -> String {
        "http://127.0.0.1:\(relaying.port)/v1 on this Mac answers 503 for now. " + words
    }

    /// This Mac relays the pair's API on every address, and its port for it isn't up yet, with nothing against it
    /// (`memberAPIDown`): in `status`'s words, after "Local API: ". Nil otherwise. With Only me, whose `localAPI` (Both's)
    /// doesn't say which Mac runs rank 0, the Mac that follows stands for the one that relays, as in
    /// `givesThisMacALocalAPI`.
    var memberAPIStarting: String? {
        guard relaying == nil, memberAPIDown == nil, answersOnEveryMac, started, paired, !pairingUnreadable,
              localAPI.map({ !$0.runsRankZero }) ?? (localOnly && role == .member) else { return nil }
        return relayStartingWords
    }

    /// This Mac's port for the pair's API before its relay is up, after "Local API: ".
    private var relayStartingWords: String {
        "not listening on this Mac yet; it starts once the pair's API on \(otherMac) answers"
    }

    /// Where the pair's API listens on this Mac, as a tool dials it.
    static func addressLine(_ address: ClusterPairLocalAPI.Address) -> String {
        let key = " (`\(cli) local` shows the key)"
        switch address.host {
        case "0.0.0.0", "::":
            return "Local API: http://127.0.0.1:\(address.port)/v1 on this Mac, and port \(address.port) of its LAN or tailnet address" + key
        case "127.0.0.1", "localhost":
            return "Local API: http://127.0.0.1:\(address.port)/v1 on this Mac" + key
        case "::1":
            return "Local API: http://[::1]:\(address.port)/v1 on this Mac" + key
        default:
            let host = address.host.contains(":") ? "[\(address.host)]" : address.host
            return "Local API: http://\(host):\(address.port)/v1" + key
        }
    }

    /// This Mac's relay, from its own files: the discovery record (`live`) its cluster service wrote (`own`, its status
    /// with its pid), never its part's or another server's; nil when none.
    static func relayAddress(own: ClusterServiceStatus?, live: LocalEndpoint.Info?) -> ClusterPairLocalAPI.Address? {
        guard let service = own?.servicePID, let live, live.pid == service else { return nil }
        return .init(host: live.host, port: live.port)
    }

    /// This Mac's view of the pair's local API, read from its own files: whether its part runs rank 0 (its cluster
    /// service's status), the discovery record that part wrote, and that part's me first (the daemon state it writes).
    static func localAPIFacts(own: ClusterServiceStatus?) -> ClusterPairLocalAPI {
        let part = own?.child.running == true ? own?.child.pid : nil
        let endpoint = LocalEndpoint.readLiveInfo().flatMap { info in info.pid == part ? info : nil }
        let state = DaemonStateFile.read().flatMap { state in state.pid == part ? state : nil }
        return ClusterPairLocalAPI(runsRankZero: own?.sessionLeader == true,
                                   listening: endpoint.map { ClusterPairLocalAPI.Address(host: $0.host, port: $0.port) },
                                   meFirst: endpoint == nil ? nil : state?.meFirst)
    }
}
