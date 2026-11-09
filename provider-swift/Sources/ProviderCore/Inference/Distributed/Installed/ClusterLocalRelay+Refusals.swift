import Foundation

// What a relay answers when it can't pass a connection on to rank 0: never a connection that just closes, but what the
// local API would answer that caller. While the cluster service finds rank 0's Mac away (`setAway`), at once; otherwise
// when a connection to rank 0 fails. A caller with this Mac's key or the pair's gets a typed 503 in words that name the
// pair's other Mac and say what to do; one with another key in the local key format, which this Mac can't judge (the
// other Mac's own), the same 503 without names; one with any other key, or none, the local API's own 401; and one the
// API takes without a key (a CORS preflight, a liveness check) the 503 with no names, chip, memory or commands. No
// unauthenticated caller learns the other Mac's hardware.
extension ClusterLocalRelay {
    /// The words of the relay's answers: one 503 per reason, the two again without the other Mac's name, and the local
    /// API's 401.
    public struct Refusals: Equatable, Sendable {
        /// Rank 0's Mac can't be reached (unplugged, asleep, gone): `unreachableCode`.
        public var unreachable: String
        /// Rank 0's Mac answers, but its API doesn't listen (it starts again): `notAnsweringCode`.
        public var notAnswering: String
        /// The two without the other Mac's name, for a key this Mac can't judge (`Caller.otherKey`).
        public var otherKeyUnreachable: String
        public var otherKeyNotAnswering: String
        /// The local API's 401 message (`LocalAuthPolicy.unauthorizedBody`), which names its CLI's `local` command.
        public var unauthorized: String

        public init(unreachable: String, notAnswering: String, otherKeyUnreachable: String, otherKeyNotAnswering: String,
                    unauthorized: String) {
            self.unreachable = unreachable
            self.notAnswering = notAnswering
            self.otherKeyUnreachable = otherKeyUnreachable
            self.otherKeyNotAnswering = otherKeyNotAnswering
            self.unauthorized = unauthorized
        }

        /// The words for a pair whose other Mac is `otherMac` (its name, when known), naming the commands of `cli`: wait,
        /// or serve this Mac alone (`servingAlone`).
        public static func pair(otherMac: String?, cli: String) -> Refusals {
            func words(_ otherMac: String?) -> (unreachable: String, notAnswering: String) {
                let other = "Your pair's other Mac" + (otherMac.map { " (\($0))" } ?? "")
                let alone = ClusterLocalRelay.servingAlone(cli: cli)
                return ("\(other) isn't reachable; this Mac relays to it. Requests resume when it's back" + alone,
                        "The pair's API on \(other.prefix(1).lowercased() + other.dropFirst()) isn't answering yet; this Mac "
                            + "relays to it. Requests resume when it answers" + alone)
            }
            let named = words(otherMac), unnamed = words(nil)
            return Refusals(unreachable: named.unreachable, notAnswering: named.notAnswering,
                            otherKeyUnreachable: unnamed.unreachable, otherKeyNotAnswering: unnamed.notAnswering,
                            unauthorized: "missing or invalid local API key — get it from `\(cli) local`")
        }

        /// Before the cluster service gives the pair's words (and in the checks).
        public static let generic = pair(otherMac: nil, cli: "darkbloom")
    }

    /// After a 503's "Requests resume when …": how to serve this Mac alone instead, and exactly when `start --solo` by
    /// itself is refused: while this Mac's part holds its serving lock, which it keeps while the pair runs here
    /// (`ClusterPairWatch`: up to `giveUpSeconds` after the other Mac last answered over the cable). Hence `stop` first.
    static func servingAlone(cli: String) -> String {
        ", or run `\(cli) stop`, then `\(cli) start --solo`, to serve this Mac alone (`\(cli) start --solo` by itself is "
            + "refused while this Mac's part of the pair holds its serving lock: up to \(Int(ClusterPairWatch.giveUpSeconds / 60)) "
            + "minutes after the other Mac last answered over the cable)."
    }

    /// What a pair's own API answers a caller with a key while its pair doesn't serve (`ClusterPairAPIRefusal`): words
    /// true on every Mac of the pair, and through a relay too, saying what to do as the relay's own 503s do.
    public static func pairNotServing(cli: String) -> String {
        "The pair's API takes no requests right now: the pair is starting or stopping. Requests resume when it serves"
            + servingAlone(cli: cli)
    }

    /// The `code` of a 503 while rank 0's Mac can't be reached.
    public static let unreachableCode = "pair_mac_unreachable"
    /// The `code` of a 503 while rank 0's API doesn't listen.
    public static let notAnsweringCode = "pair_api_unavailable"

    /// The 503s' words for a caller the local API takes without a key: no names, chip, memory or commands.
    public static let unnamedUnreachable = "The pair's other Mac isn't reachable; this Mac relays to it. Requests resume "
        + "when it's back."
    public static let unnamedNotAnswering = "The pair's API isn't answering yet; this Mac relays to it. Requests resume "
        + "when it answers."

    /// Why a request can't be passed on to rank 0.
    enum Reason: Equatable {
        /// Rank 0's Mac can't be reached: away, or no answer to the connection within `connectSeconds`.
        case unreachable
        /// Rank 0's Mac refused the connection: its API doesn't listen.
        case notAnswering

        var code: String { self == .unreachable ? ClusterLocalRelay.unreachableCode : ClusterLocalRelay.notAnsweringCode }
    }

    /// Who sent a request the relay can't pass on, as the local API's own key check reads it (`LocalAuthPolicy.authorize`).
    enum Caller: Equatable {
        /// Its `Authorization` is `Bearer` with this Mac's own key or the pair's.
        case keyed
        /// `Bearer` with a key in the local key format (`LocalEndpoint.isToken`) that is neither: the other Mac's own, which
        /// rank 0's API takes on that Mac, or a wrong one. This Mac can't tell which.
        case otherKey
        /// No key, where the local API takes none: a CORS preflight (`OPTIONS`), or a liveness check (`GET` or `HEAD` of
        /// `/`, `/health` or `/v1/health`). A relay without keys knows no caller's, so every caller is this.
        case open
        /// Any other, which the local API answers 401.
        case unknown
    }

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

    /// The local API's 401 (`LocalAuthPolicy.unauthorizedResponse`): its body, `WWW-Authenticate: Bearer`, any origin.
    static func unauthorized(message: String) -> [UInt8] {
        let error = ["message": message, "type": "authentication_error"]
        let body = (try? JSONSerialization.data(withJSONObject: ["error": error], options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data(#"{"error":{"message":"missing or invalid local API key","type":"authentication_error"}}"#.utf8)
        let head = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nWWW-Authenticate: Bearer\r\n"
            + "Access-Control-Allow-Origin: *\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n"
        return Array(head.utf8) + Array(body)
    }

    /// What the relay answers a request it can't pass on for `reason`, from `caller`: the 503 in `refusals`' words, the
    /// same without the other Mac's name, in words with no names or commands, or the local API's 401.
    static func answer(_ reason: Reason, to caller: Caller, refusals: Refusals) -> [UInt8] {
        let words: (unreachable: String, notAnswering: String)
        switch caller {
        case .keyed: words = (refusals.unreachable, refusals.notAnswering)
        case .otherKey: words = (refusals.otherKeyUnreachable, refusals.otherKeyNotAnswering)
        case .open: words = (unnamedUnreachable, unnamedNotAnswering)
        case .unknown: return unauthorized(message: refusals.unauthorized)
        }
        return refusal(code: reason.code, message: reason == .unreachable ? words.unreachable : words.notAnswering)
    }

    /// Answers `client` instead of closing its connection, as the local API would answer it (`answer`, with `keys` to
    /// tell its caller): its request is read first (`readRequest`, bounded), so the answer isn't lost to a reset, then
    /// the answer, then what the client still sends is read until it closes (at most a second).
    static func refuse(_ client: Int32, _ reason: Reason, refusals: Refusals, keys: Keys?) {
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let caller = readRequest(client, keys: keys)
        guard writeAll(client, answer(reason, to: caller, refusals: refusals)[...]) else { return }
        shutdown(client, SHUT_WR)
        wait = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        while readSome(client, into: &buffer) > 0 {}
    }
}
