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
    /// `maximumRefusedBodyBytes`), until the client stops sending (its read bound passes) or ends.
    static func readRequest(_ client: Int32) {
        var pending: [UInt8] = [], buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var end = headEnd(pending, from: 0)
        while end == nil, pending.count <= maximumHeadBytes {
            let searched = max(0, pending.count - 3)
            let count = readSome(client, into: &buffer)
            guard count > 0 else { return }
            pending += buffer[..<count]
            end = headEnd(pending, from: searched)
        }
        guard let headLength = end else { return }
        let lengths = split(pending[..<headLength].dropLast(4)).dropFirst().compactMap { line -> Int? in
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")),
                  lowercased(line[line.startIndex..<colon]) == "content-length" else { return nil }
            return decimal(trimmed(line[line.index(after: colon)...]))
        }
        var remaining = min(lengths.first ?? 0, maximumRefusedBodyBytes) - (pending.count - headLength)
        while remaining > 0 {
            let count = readSome(client, into: &buffer, upTo: remaining)
            guard count > 0 else { return }
            remaining -= count
        }
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
