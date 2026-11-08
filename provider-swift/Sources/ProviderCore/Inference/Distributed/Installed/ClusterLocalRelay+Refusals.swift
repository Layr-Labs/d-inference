import Foundation

// What a relay answers when it can't pass a connection on to rank 0: never a connection that just closes, but a typed
// 503 its client can read, in words that name the pair's other Mac. While the cluster service finds rank 0's Mac away
// (`setAway`), at once; otherwise when a connection to rank 0 fails.
extension ClusterLocalRelay {
    /// The words of the relay's 503s, one per reason.
    public struct Refusals: Equatable, Sendable {
        /// Rank 0's Mac can't be reached (unplugged, asleep, gone): `unreachableCode`.
        public var unreachable: String
        /// Rank 0's Mac answers, but its API doesn't listen (it starts again): `notAnsweringCode`.
        public var notAnswering: String

        public init(unreachable: String, notAnswering: String) {
            self.unreachable = unreachable
            self.notAnswering = notAnswering
        }

        /// The words for a pair whose other Mac is `otherMac` (its name, when known), naming the commands of `cli`. While
        /// that Mac is away this Mac's part keeps its serving lock, for up to `ClusterPairWatch.giveUpSeconds`, so
        /// serving this Mac alone takes `stop` first.
        public static func pair(otherMac: String?, cli: String) -> Refusals {
            let other = "Your pair's other Mac" + (otherMac.map { " (\($0))" } ?? "")
            return Refusals(
                unreachable: "\(other) isn't reachable; this Mac relays to it. Requests resume when it's back, or run "
                    + "`\(cli) stop`, then `\(cli) start --solo`, to serve this Mac alone.",
                notAnswering: "The pair's API on \(other.prefix(1).lowercased() + other.dropFirst()) isn't answering yet; "
                    + "this Mac relays to it. Requests resume when it answers.")
        }

        /// Before the cluster service gives the pair's words (and in the checks).
        public static let generic = pair(otherMac: nil, cli: "darkbloom")
    }

    /// The `code` of a 503 while rank 0's Mac can't be reached.
    public static let unreachableCode = "pair_mac_unreachable"
    /// The `code` of a 503 while rank 0's API doesn't listen.
    public static let notAnsweringCode = "pair_api_unavailable"
}
