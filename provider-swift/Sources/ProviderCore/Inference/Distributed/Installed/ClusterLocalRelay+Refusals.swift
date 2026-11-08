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

    /// A 503 as the local API words its own (`{"error":{…}}`, `type` `server_error`), with `code` and `message`, to be
    /// tried again in 10 s, and the connection's last.
    static func refusal(code: String, message: String) -> [UInt8] {
        let error = ["code": code, "message": message, "type": "server_error"]
        let body = (try? JSONSerialization.data(withJSONObject: ["error": error], options: [.sortedKeys]))
            ?? Data(#"{"error":{"message":"the pair's API can't be reached","type":"server_error"}}"#.utf8)
        let head = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\n"
            + "Retry-After: 10\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n"
        return Array(head.utf8) + Array(body)
    }

    /// Answers `client` the 503 instead of closing its connection: its request is read first (`readRequest`, bounded),
    /// so the answer isn't lost to a reset, then the answer, then what the client still sends is read until it closes
    /// (at most a second).
    static func refuse(_ client: Int32, code: String, message: String) {
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        readRequest(client)
        guard writeAll(client, refusal(code: code, message: message)[...]) else { return }
        shutdown(client, SHUT_WR)
        wait = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        while readSome(client, into: &buffer) > 0 {}
    }
}
