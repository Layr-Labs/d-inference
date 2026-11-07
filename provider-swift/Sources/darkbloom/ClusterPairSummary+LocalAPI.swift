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
    /// pair's local API listens, and what the other Macs do. The Mac whose part runs rank 0 says it from its own part.
    /// With the API on every address, every other Mac names its own relay's address, which passes your requests to it;
    /// otherwise it says where to look. Nothing while the pair is stopped, and nothing for the other two ways to serve.
    /// No key and no speed.
    func localAPILines(now: Date = Date(), timeZone: TimeZone = .current) -> [String] {
        guard let localAPI, started, paired, !pairingUnreadable else { return [] }
        let everyMac = localAPIBind == ClusterServingScope.localOnlyDefaultBind
        guard localAPI.runsRankZero else {
            guard everyMac else {
                return ["Local API: on \(otherMac), which runs the pair's API; `\(Self.cli) local` there shows its address and key, "
                            + "and `\(Self.cli) status` there whether Darkbloom is paused for you",
                        "Members: this Mac is part of the pair; it runs no local API"]
            }
            let passes = "Members: \(otherMac) runs the pair's API; this Mac passes your requests to it, and Darkbloom pauses for them too"
            guard let relaying else {
                return ["Local API: not listening on this Mac yet; it starts once the pair's API on \(otherMac) answers", passes]
            }
            return [Self.addressLine(relaying), passes]
        }
        let members = "Members: \(otherMac) is part of the pair; "
            + (everyMac ? "its own port passes your requests to this API" : "it runs no local API")
        guard let address = localAPI.listening else {
            return ["Local API: not listening yet; it starts with this Mac's part of the pair", members]
        }
        return Self.pauseLines(localAPI.meFirst, now: now, timeZone: timeZone) + [Self.addressLine(address), members]
    }

    /// Whether Darkbloom is paused for you, in `status`'s single-Mac words for "the pair" (`Status.meFirstLines`).
    static func pauseLines(_ meFirst: MeFirstSnapshot?, now: Date, timeZone: TimeZone) -> [String] {
        guard let meFirst else {
            return ["Pair: Darkbloom and you, shared — Darkbloom keeps serving while you use the pair (me first is off)"]
        }
        let serving = "Serving: ", pair = "Pair: "
        return Status.meFirstLines(meFirst, now: now, timeZone: timeZone).map { line in
            if line.hasPrefix(serving) { return pair + line.dropFirst(serving.count) }
            // The line under it keeps its words under the first one's.
            let indent = String(repeating: " ", count: serving.count)
            return line.hasPrefix(indent) ? String(repeating: " ", count: pair.count) + line.dropFirst(indent.count) : line
        }
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
