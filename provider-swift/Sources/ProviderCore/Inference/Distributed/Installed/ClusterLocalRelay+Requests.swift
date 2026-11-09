import Foundation
import Darwin

// A relay with keys reads each request's head on its way to rank 0's API: this Mac's own key goes on as the pair's,
// and every other byte as it came. It never reads an answer: that direction stays `pump`'s byte copy, so nothing is
// done per token. Heads are framed as HTTP/1.1 frames them, a body by its Content-Length. A request the relay doesn't
// frame that way (chunked, an upgrade) is its connection's last: its head says `Connection: close`, and the rest passes
// as it comes. A head the relay can't read passes as it came, for rank 0's API to refuse.
extension ClusterLocalRelay {
    /// The longest head the relay reads, the API's own limit: a longer one passes as it came, and the API refuses it.
    static let maximumHeadBytes = 80 * 1024

    /// One request head as it goes on to rank 0's API.
    struct RelayedHead: Equatable {
        enum Body: Equatable {
            /// This many bytes of body follow; the next head comes after them.
            case length(Int)
            /// The relay reads no further on this connection: the rest passes as it comes.
            case rest
        }
        var bytes: [UInt8]
        var body: Body
    }

    /// `head` (up to and including its blank line) as it goes on: an `Authorization` that carries this Mac's own key
    /// carries the pair's, and a request whose body isn't framed by its length says `Connection: close` in place of any
    /// other. Unchanged when it can't be read.
    static func relayedHead(_ head: ArraySlice<UInt8>, keys: Keys) -> RelayedHead {
        let unchanged = RelayedHead(bytes: Array(head), body: .rest)
        let lines = split(head.dropLast(4))
        // A bare CR or LF is read differently by different parsers: such a head is never guessed at either.
        guard let requestLine = lines.first, let method = method(of: requestLine),
              !lines.contains(where: { $0.contains(cr) || $0.contains(lf) }) else { return unchanged }
        let ownBearer = Array("Bearer \(keys.own)".utf8)
        var headers: [[UInt8]] = [], lengths: [Int?] = [], framedByLength = method != "CONNECT"
        for line in lines.dropFirst() {
            // Folded lines and names with spaces are read differently by different parsers: never guessed at.
            guard let first = line.first, first != space, first != tab, let colon = line.firstIndex(of: UInt8(ascii: ":")) else {
                return unchanged
            }
            let name = line[line.startIndex..<colon]
            guard !name.isEmpty, !name.contains(space), !name.contains(tab) else { return unchanged }
            let value = trimmed(line[line.index(after: colon)...])
            switch lowercased(name) {
            case "authorization" where constantTimeEquals(value, ownBearer):
                headers.append(Array(name) + Array(": Bearer \(keys.pair)".utf8))
                continue
            case "content-length": lengths.append(decimal(value))
            case "transfer-encoding", "upgrade": framedByLength = false
            default: break
            }
            headers.append(Array(line))
        }
        // No body, or one Content-Length the relay can read.
        let length: Int? = lengths.isEmpty ? 0 : lengths.count == 1 ? lengths[0] : nil
        if framedByLength, let length {
            return RelayedHead(bytes: joined(requestLine, headers), body: .length(length))
        }
        let closing = headers.filter { lowercased(headerName(of: $0)) != "connection" } + [Array("Connection: close".utf8)]
        return RelayedHead(bytes: joined(requestLine, closing), body: .rest)
    }

    /// Copies the requests `client` sends to `upstream`, head by head (`relayedHead`), until the client ends, the relay
    /// reads no further, or `upstream` takes no more; then half-closes as `pump` does.
    static func pumpRequests(from client: Int32, to upstream: Int32, keys: Keys) {
        var pending: [UInt8] = [], buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // False when `upstream` takes no more: the client's side is shut down, as `pump` does.
        func send(_ bytes: ArraySlice<UInt8>) -> Bool {
            guard writeAll(upstream, bytes) else { shutdown(client, SHUT_RD); return false }
            return true
        }
        while true {
            var end = headEnd(pending, from: 0)
            while end == nil, pending.count <= maximumHeadBytes {
                let searched = max(0, pending.count - 3)
                let count = readSome(client, into: &buffer)
                guard count > 0 else {
                    // The client ended, between requests or inside a head: what came still goes on, then the end.
                    if !pending.isEmpty { _ = send(pending[...]) }
                    shutdown(upstream, SHUT_WR)
                    return
                }
                pending += buffer[..<count]
                end = headEnd(pending, from: searched)
            }
            guard let headLength = end, headLength <= maximumHeadBytes else {
                // Longer than any head the API takes: it passes as it came, for the API to refuse.
                guard send(pending[...]) else { return }
                return pump(from: client, to: upstream)
            }
            let head = relayedHead(pending[..<headLength], keys: keys)
            pending.removeFirst(headLength)
            guard send(head.bytes[...]) else { return }
            guard case .length(var remaining) = head.body else {
                guard send(pending[...]) else { return }
                return pump(from: client, to: upstream)
            }
            let buffered = min(remaining, pending.count)
            guard send(pending[..<buffered]) else { return }
            pending.removeFirst(buffered)
            remaining -= buffered
            while remaining > 0 {
                let count = readSome(client, into: &buffer, upTo: remaining)
                guard count > 0 else { shutdown(upstream, SHUT_WR); return }
                guard send(buffer[..<count]) else { return }
                remaining -= count
            }
        }
    }

    /// The longest body the relay reads before it answers a request it can't pass on (`refuse`).
    static let maximumRefusedBodyBytes = 16 << 20

    /// Reads one request from `client` and drops it: its head, then a body framed by its Content-Length (at most
    /// `maximumRefusedBodyBytes`), until the client stops sending (its read bound passes) or ends. Who sent it, as the
    /// local API's key check reads its head with `keys` (`caller`).
    @discardableResult
    static func readRequest(_ client: Int32, keys: Keys?) -> Caller {
        var pending: [UInt8] = [], buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var end = headEnd(pending, from: 0)
        while end == nil, pending.count <= maximumHeadBytes {
            let searched = max(0, pending.count - 3)
            let count = readSome(client, into: &buffer)
            guard count > 0 else { return caller(of: [], keys: keys) }
            pending += buffer[..<count]
            end = headEnd(pending, from: searched)
        }
        guard let headLength = end else { return caller(of: [], keys: keys) }
        let lines = split(pending[..<headLength].dropLast(4))
        let lengths = lines.dropFirst().compactMap { line -> Int? in
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")),
                  lowercased(line[line.startIndex..<colon]) == "content-length" else { return nil }
            return decimal(trimmed(line[line.index(after: colon)...]))
        }
        var remaining = min(lengths.first ?? 0, maximumRefusedBodyBytes) - (pending.count - headLength)
        while remaining > 0 {
            let count = readSome(client, into: &buffer, upTo: remaining)
            guard count > 0 else { break }
            remaining -= count
        }
        return caller(of: lines, keys: keys)
    }

    /// Who sent the request whose head is `lines` (its request line first), as the local API's key check reads it
    /// (`LocalAuthPolicy.authorize`): `Authorization` is `Bearer` with this Mac's own key or the pair's, each compared in
    /// constant time; else `Bearer` with another key in the local key format, which this Mac can't judge; else a CORS
    /// preflight or a liveness check, which the API takes without a key; else neither, as is a head the relay couldn't
    /// read. A relay without keys knows no caller's.
    static func caller(of lines: [ArraySlice<UInt8>], keys: Keys?) -> Caller {
        guard let keys else { return .open }
        let authorization = lines.dropFirst().lazy.compactMap { line -> ArraySlice<UInt8>? in
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")),
                  lowercased(line[line.startIndex..<colon]) == "authorization" else { return nil }
            return trimmed(line[line.index(after: colon)...])
        }.first
        if let authorization {
            // Both keys are always compared: how long it takes says nothing of which one came close.
            let own = constantTimeEquals(authorization, Array("Bearer \(keys.own)".utf8)) && !keys.own.isEmpty
            let pair = constantTimeEquals(authorization, Array("Bearer \(keys.pair)".utf8)) && !keys.pair.isEmpty
            if own || pair { return .keyed }
            let bearer = Array("Bearer ".utf8)
            if authorization.starts(with: bearer),
               LocalEndpoint.isToken(String(decoding: authorization.dropFirst(bearer.count), as: UTF8.self)) { return .otherKey }
        }
        guard let requestLine = lines.first, let method = method(of: requestLine) else { return .unknown }
        if method == "OPTIONS" { return .open }
        let target = requestLine.split(separator: space, omittingEmptySubsequences: false)[1]
        let path = String(decoding: target.prefix { $0 != UInt8(ascii: "?") }, as: UTF8.self)
        if method == "GET" || method == "HEAD", ["/", "/health", "/v1/health"].contains(path) { return .open }
        return .unknown
    }

    /// Where the blank line that ends a head ends in `bytes`, searching from `start`; nil before it came.
    static func headEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= 4, start <= bytes.count - 4 else { return nil }
        for index in start...(bytes.count - 4)
        where bytes[index] == cr && bytes[index + 1] == lf && bytes[index + 2] == cr && bytes[index + 3] == lf {
            return index + 4
        }
        return nil
    }

    private static let cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n"), space = UInt8(ascii: " "), tab = UInt8(ascii: "\t")

    /// A head's lines, without their CRLF.
    private static func split(_ bytes: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var lines: [ArraySlice<UInt8>] = [], start = bytes.startIndex, index = bytes.startIndex
        while index < bytes.endIndex {
            if bytes[index] == cr, bytes.index(after: index) < bytes.endIndex, bytes[bytes.index(after: index)] == lf {
                lines.append(bytes[start..<index])
                index = bytes.index(index, offsetBy: 2)
                start = index
            } else {
                index = bytes.index(after: index)
            }
        }
        lines.append(bytes[start..<bytes.endIndex])
        return lines
    }

    private static func joined(_ requestLine: ArraySlice<UInt8>, _ headers: [[UInt8]]) -> [UInt8] {
        var bytes = Array(requestLine) + [cr, lf]
        for header in headers { bytes += header + [cr, lf] }
        return bytes + [cr, lf]
    }

    /// The method of an HTTP/1 request line (`GET /path HTTP/1.1`); nil for anything else.
    private static func method(of line: ArraySlice<UInt8>) -> String? {
        let parts = line.split(separator: space, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, parts[2].starts(with: Array("HTTP/1.".utf8)),
              parts[0].allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        return String(decoding: parts[0], as: UTF8.self)
    }

    private static func headerName(of header: [UInt8]) -> ArraySlice<UInt8> {
        header[..<(header.firstIndex(of: UInt8(ascii: ":")) ?? header.endIndex)]
    }

    private static func lowercased(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
    }

    private static func trimmed(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var value = bytes
        while let first = value.first, first == space || first == tab { value = value.dropFirst() }
        while let last = value.last, last == space || last == tab { value = value.dropLast() }
        return value
    }

    /// A Content-Length's value: decimal digits only; nil for anything else.
    private static func decimal(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard (1...18).contains(bytes.count), bytes.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(String(decoding: bytes, as: UTF8.self))
    }

    /// Length-checked and constant-time, as the API compares its keys (`LocalAuthPolicy`): how long a request takes says
    /// nothing of how close its key came.
    private static func constantTimeEquals(_ a: ArraySlice<UInt8>, _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}
