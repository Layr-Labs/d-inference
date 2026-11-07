import Darwin
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import Testing
@testable import ProviderCore

// Every Mac of a pair answers locally: in Both, me first as in `cluster local`, each Mac whose part isn't rank 0 runs a
// relay on its own port that passes connections over the cable to rank 0's API. Tools on that Mac use its own key
// (`local_token`), which the relay passes on as the pair's; rank 0's API takes its own key and the pair's. Everything
// here is CPU only: rosters are values, rank 0's API is a stand-in or the local API's real stack on 127.0.0.1 port 0,
// and the pair's owner is scripted.

private let ownKey = "dk-local-MemberOwnKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
private let pairKey = "dk-local-PairKeyBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
private let leaderKey = "dk-local-LeaderOwnKeyCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
private let relayKeys = ClusterLocalRelay.Keys(own: ownKey, pair: pairKey)

/// Loopback sockets for the relay's checks: a listener on a port the OS picks, whole writes and reads to the end.
enum RelaySockets {
    static func listen() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0 && Darwin.listen(fd, 16) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }

    /// A free loopback port the OS assigns (never 8000 or a cable port: macOS picks from 49152 up).
    static func freePort() throws -> Int {
        let (fd, port) = try listen()
        close(fd)
        return port
    }

    static func relay(to port: Int, keys: ClusterLocalRelay.Keys?) throws -> ClusterLocalRelay {
        for _ in 0..<8 {
            if let relay = ClusterLocalRelay(port: try freePort(), bind: "127.0.0.1",
                                             target: .init(host: "127.0.0.1", port: port), keys: keys) { return relay }
        }
        throw RelayCheckFailure("the relay did not listen on a loopback port")
    }

    /// A client connection whose reads give up after `readTimeout` seconds, so a check whose answer never ends fails
    /// instead of waiting out the relay's own idle bound (`ClusterLocalRelay.idleSeconds`).
    static func connect(_ port: Int, readTimeout: Int = 20) throws -> Int32 {
        guard let fd = ClusterLocalRelay.connect(.init(host: "127.0.0.1", port: port)) else {
            throw RelayCheckFailure("nothing answers on port \(port)")
        }
        var timeout = timeval(tv_sec: readTimeout, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    static func write(_ fd: Int32, _ text: String) { write(fd, Array(text.utf8)) }

    static func write(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return }
            offset += written
        }
    }

    /// Where a head's blank line ends in `bytes`; nil before it came.
    static func headEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4)
        where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index + 4
        }
        return nil
    }

    /// Accepts connections on `listener` and hands each to `serve` on a thread of its own, until `stopped` says so; the
    /// listener is closed by this loop alone (`wake` unblocks its `accept`: macOS doesn't wake one on shutdown).
    static func acceptLoop(_ listener: Int32, stopped: @escaping @Sendable () -> Bool, serve: @escaping @Sendable (Int32) -> Void) {
        Thread.detachNewThread {
            defer { close(listener) }
            while true {
                let client = accept(listener, nil, nil)
                if stopped() {
                    if client >= 0 { close(client) }
                    return
                }
                guard client >= 0 else { continue }
                Thread.detachNewThread { serve(client) }
            }
        }
    }

    /// Unblocks the accept loop of the listener on `port`.
    static func wake(_ port: Int) {
        if let fd = ClusterLocalRelay.connect(.init(host: "127.0.0.1", port: port)) { close(fd) }
    }

    /// Reads until `done` holds for what came, or the other side ends.
    static func read(_ fd: Int32, until done: (String) -> Bool = { _ in false }) -> String {
        var received = [UInt8](), chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while !done(String(decoding: received, as: UTF8.self)) {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            received += chunk[0..<count]
        }
        return String(decoding: received, as: UTF8.self)
    }
}

struct RelayCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The port a server reports once it is bound.
final class BoundPort: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?
    var port: Int? { lock.withLock { value } }
    func set(_ port: Int?) { lock.withLock { value = port } }
}

/// Rank 0's API as a stand-in on loopback: records every byte each connection brings, and answers each request it reads
/// (a head, then its Content-Length body) with a two-byte 200. A request with any other framing is answered once its
/// sender half-closes.
final class RecordingAPI: @unchecked Sendable {
    static let reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
    let port: Int
    private let lock = NSLock()
    private var connections: [[UInt8]] = []
    private var stopped = false

    init() throws {
        let (listener, port) = try RelaySockets.listen()
        self.port = port
        RelaySockets.acceptLoop(listener, stopped: { [self] in lock.withLock { stopped } }) { [self] client in
            let index = lock.withLock { connections.append([]); return connections.count - 1 }
            serve(client, index)
        }
    }

    /// What each connection brought, in the order they came.
    var received: [String] { lock.withLock { connections.map { String(decoding: $0, as: UTF8.self) } } }

    private func serve(_ client: Int32, _ index: Int) {
        defer { close(client) }
        var pending = [UInt8](), chunk = [UInt8](repeating: 0, count: 16 * 1024)
        func readMore() -> Bool {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { return false }
            pending += chunk[0..<count]
            lock.withLock { connections[index] += chunk[0..<count] }
            return true
        }
        while true {
            var end = RelaySockets.headEnd(pending)
            while end == nil {
                guard readMore() else { return }
                end = RelaySockets.headEnd(pending)
            }
            let headEnd = end!
            let head = String(decoding: pending[..<headEnd], as: UTF8.self).lowercased()
            if head.contains("transfer-encoding:") {
                while readMore() {}
                RelaySockets.write(client, Self.reply)
                return
            }
            let length = head.components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            while pending.count < headEnd + length { guard readMore() else { return } }
            pending.removeFirst(headEnd + length)
            RelaySockets.write(client, Self.reply)
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        RelaySockets.wake(port)
    }
}

@Suite("A pair's every Mac answers locally: the member relay", .serialized, .timeLimit(.minutes(2)))
struct ClusterPairMemberRelayTests {
    static let both = ClusterServingScope.publicServingWithLocalAPI(bind: "0.0.0.0")
    static let localOnly = ClusterServingScope.localOnly(bind: "0.0.0.0")

    /// `macs` Macs on the cable's subnet, rank 0 first: "mac-0" at 10.219.1.1, "mac-1" at 10.219.2.2, …
    static func roster(_ macs: Int) -> [ClusterLocalRelay.RosterMac] {
        (0..<macs).map { .init(id: "mac-\($0)", rank: $0, host: "10.219.\($0 + 1).\($0 + 1)") }
    }

    // MARK: - Who relays, and to where

    /// Both, me first relays as `cluster local` does: every Mac but rank 0's, to rank 0's cable address, whatever the
    /// number of Macs or the order of the roster.
    @Test(arguments: [2, 3])
    func everyMacButRankZerosRelaysToRankZero(macs: Int) {
        let roster = Self.roster(macs)
        for scope in [Self.both, Self.localOnly] {
            #expect(scope.answersOnEveryMac, "\(scope)")
            #expect(ClusterLocalRelay.rankZeroHost(serving: true, scope: scope, memberID: "mac-0", roster: roster,
                                                   partRuns: true) == nil, "rank 0 relays to nobody: \(scope)")
            for rank in 1..<macs {
                for listed in [roster, roster.reversed()] {
                    #expect(ClusterLocalRelay.rankZeroHost(serving: true, scope: scope, memberID: "mac-\(rank)",
                                                           roster: listed, partRuns: true) == "10.219.1.1",
                            "rank \(rank) of \(macs), \(scope)")
                }
            }
        }
    }

    /// No relay while the pair doesn't serve, serves Darkbloom alone, keeps its API on one address (loopback or a chosen
    /// one, which the cable doesn't reach), or while this Mac's part doesn't run.
    @Test func noRelayWithoutTheAPIOnEveryAddressOrWithoutThisMacsPart() {
        let roster = Self.roster(3)
        func host(serving: Bool = true, scope: ClusterServingScope = Self.both, member: String = "mac-2",
                  partRuns: Bool = true) -> String? {
            ClusterLocalRelay.rankZeroHost(serving: serving, scope: scope, memberID: member, roster: roster, partRuns: partRuns)
        }
        #expect(host() == "10.219.1.1")
        #expect(host(serving: false) == nil)
        #expect(host(scope: .publicServing) == nil, "Darkbloom network: no local API anywhere")
        for bind in ["127.0.0.1", "::1", "localhost", "192.168.1.5"] {
            #expect(host(scope: .publicServingWithLocalAPI(bind: bind)) == nil, "Both on \(bind)")
            #expect(host(scope: .localOnly(bind: bind)) == nil, "local only on \(bind)")
            #expect(!ClusterServingScope.publicServingWithLocalAPI(bind: bind).answersOnEveryMac)
        }
        #expect(!ClusterServingScope.publicServing.answersOnEveryMac)
        #expect(host(partRuns: false) == nil)
        #expect(host(member: "mac-9") == nil, "a Mac the roster doesn't name")
    }

    // MARK: - Rank 0's port

    /// Rank 0's Mac says where the pair's API listens (`pairAPIPort`, once bound, Both or local only); an older build's
    /// `cluster local` says it through its ready session, as before; no other Mac says it.
    @Test func rankZerosPortComesFromItsStatus() throws {
        func status(_ json: String) throws -> ClusterServiceStatus {
            try JSONDecoder().decode(ClusterServiceStatus.self, from: Data(json.utf8))
        }
        let child = #""child":{"running":true,"starts":1}"#
        #expect(ClusterLocalRelay.rankZeroPort(in: try status(#"{"serving":true,"sessionLeader":true,\#(child),"pairAPIPort":8003}"#)) == 8003)
        let ready = #""session":{"observed":true,"ready":true,"readyRanks":2,"ranks":2,"port":8000}"#
        #expect(ClusterLocalRelay.rankZeroPort(in: try status(#"{"serving":true,"sessionLeader":true,\#(child),\#(ready)}"#)) == 8000)
        let loading = #""session":{"observed":true,"ready":false,"readyRanks":1,"ranks":2,"port":8000}"#
        #expect(ClusterLocalRelay.rankZeroPort(in: try status(#"{"serving":true,"sessionLeader":true,\#(child),\#(loading)}"#)) == nil)
        #expect(ClusterLocalRelay.rankZeroPort(in: try status(#"{"serving":true,"sessionLeader":false,\#(child),"pairAPIPort":8003}"#)) == nil,
                "a Mac that doesn't run rank 0")
        #expect(ClusterLocalRelay.rankZeroPort(in: try status(#"{"serving":true,"sessionLeader":true,\#(child)}"#)) == nil)
        var sent = try status(#"{"serving":true,"sessionLeader":true,\#(child)}"#)
        sent.pairAPIPort = 8011
        #expect(try JSONDecoder().decode(ClusterServiceStatus.self, from: JSONEncoder().encode(sent)).pairAPIPort == 8011)
    }

    /// The relay takes rank 0's port when it is free here, so the address is the same on every Mac. Beside Darkbloom
    /// (Both), anything else is the first free port the pair's API may take: never 8000 or a cable port, which are
    /// never even test-bound. `cluster local` keeps its own rule.
    @Test func theRelayTakesRankZerosPortElseNeverAReservedOne() {
        let target = ClusterLocalRelay.Target(host: "10.219.1.1", port: 8003)
        #expect(ClusterLocalRelay.port(for: target, scope: Self.both, isFree: { _ in true }) == 8003)
        var asked: [Int] = []
        #expect(ClusterLocalRelay.port(for: target, scope: Self.both, isFree: { asked.append($0); return ![8001, 8003].contains($0) }) == 8002)
        for reserved in ClusterLocalServing.neverChosenPorts {
            asked = []
            let port = ClusterLocalRelay.port(for: .init(host: "10.219.1.1", port: reserved), scope: Self.both,
                                              isFree: { asked.append($0); return true })
            #expect(port == 8001, "rank 0 said \(reserved)")
            #expect(!asked.contains { ClusterLocalServing.neverChosenPorts.contains($0) }, "probed \(asked)")
        }
        #expect(ClusterLocalRelay.port(for: .init(host: "10.219.1.1", port: 8000), scope: Self.localOnly, isFree: { _ in true }) == 8000,
                "cluster local: the same port as rank 0, as before")
    }

    // MARK: - The keys

    /// A request with this Mac's own key reaches rank 0 with the pair's; every other byte is as it was sent, and a route
    /// header the client sent rides along unchanged (rank 0's API drops it, as for any client).
    @Test func thisMacsOwnKeyGoesOnAsThePairsAndNothingElseChanges() throws {
        let api = try RecordingAPI()
        defer { api.stop() }
        let relay = try RelaySockets.relay(to: api.port, keys: relayKeys)
        defer { relay.stop() }
        let body = #"{"model":"m","messages":[{"role":"user","content":"Authorization: Bearer \#(ownKey)"}]}"#
        let request = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nauthorization: Bearer \(ownKey)\r\n"
            + "X-Darkbloom-Route: prefer\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        let client = try RelaySockets.connect(relay.port)
        defer { close(client) }
        RelaySockets.write(client, request)
        shutdown(client, SHUT_WR)
        #expect(RelaySockets.read(client) == RecordingAPI.reply)
        let expected = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nauthorization: Bearer \(pairKey)\r\n"
            + "X-Darkbloom-Route: prefer\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        #expect(api.received == [expected], "the body's text is never touched")
    }

    /// The pair's key, no key and another key pass as they came: rank 0's API decides, as for any client (its liveness
    /// routes; 401 for the rest).
    @Test func everyOtherRequestPassesAsItCame() throws {
        let api = try RecordingAPI()
        defer { api.stop() }
        let relay = try RelaySockets.relay(to: api.port, keys: relayKeys)
        defer { relay.stop() }
        let requests = ["GET /v1/models HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer \(pairKey)\r\n\r\n",
                        "GET /health HTTP/1.1\r\nHost: h\r\n\r\n",
                        "OPTIONS /v1/chat/completions HTTP/1.1\r\nHost: h\r\nOrigin: http://x\r\n\r\n",
                        "GET /v1/models HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer \(ownKey)x\r\n\r\n",
                        "GET /v1/models HTTP/1.1\r\nHost: h\r\nAuthorization: bearer \(ownKey)\r\n\r\n"]
        for request in requests {
            let client = try RelaySockets.connect(relay.port)
            RelaySockets.write(client, request)
            shutdown(client, SHUT_WR)
            #expect(RelaySockets.read(client) == RecordingAPI.reply)
            close(client)
        }
        #expect(api.received == requests)
    }

    /// A kept-alive connection: each request's head is read and its key swapped, its body passed by its length, so a
    /// client that reuses its connection (URLSession, httpx, Node) is never refused on its second request.
    @Test func everyRequestOfAKeptAliveConnectionHasItsKeySwapped() throws {
        let api = try RecordingAPI()
        defer { api.stop() }
        let relay = try RelaySockets.relay(to: api.port, keys: relayKeys)
        defer { relay.stop() }
        func request(_ body: String) -> String {
            "POST /v1/chat/completions HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer \(ownKey)\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        }
        // The first body ends with what looks like a head: it is body, and stays as it is.
        let first = "{\"a\":1}\r\nGET / HTTP/1.1\r\nAuthorization: Bearer \(ownKey)\r\n\r\n"
        let second = "{\"b\":2}"
        let client = try RelaySockets.connect(relay.port)
        defer { close(client) }
        RelaySockets.write(client, request(first))
        #expect(RelaySockets.read(client, until: { $0.hasSuffix("ok") }) == RecordingAPI.reply)
        RelaySockets.write(client, request(second))
        #expect(RelaySockets.read(client, until: { $0.hasSuffix("ok") }) == RecordingAPI.reply)
        shutdown(client, SHUT_WR)
        let swapped = { (body: String) in
            "POST /v1/chat/completions HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer \(pairKey)\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        }
        #expect(api.received == [swapped(first) + swapped(second)], "one connection, both keys swapped, bodies untouched")
        // Pipelined: both requests sent before either answer.
        let pipelined = try RelaySockets.connect(relay.port)
        defer { close(pipelined) }
        RelaySockets.write(pipelined, request(second) + request(second))
        shutdown(pipelined, SHUT_WR)
        #expect(RelaySockets.read(pipelined) == RecordingAPI.reply + RecordingAPI.reply)
        #expect(api.received.last == swapped(second) + swapped(second))
    }

    /// A body whose end the relay doesn't frame by its length (chunked) ends the connection after it: the head says
    /// `Connection: close` in place of any other, and the rest passes as it comes.
    @Test func aChunkedRequestEndsItsConnection() throws {
        let api = try RecordingAPI()
        defer { api.stop() }
        let relay = try RelaySockets.relay(to: api.port, keys: relayKeys)
        defer { relay.stop() }
        let body = "4\r\nabcd\r\n0\r\n\r\n"
        let next = "GET /v1/models HTTP/1.1\r\nAuthorization: Bearer \(ownKey)\r\n\r\n"
        let client = try RelaySockets.connect(relay.port)
        defer { close(client) }
        RelaySockets.write(client, "POST /v1/chat/completions HTTP/1.1\r\nHost: h\r\nConnection: keep-alive\r\n"
            + "Authorization: Bearer \(ownKey)\r\nTransfer-Encoding: chunked\r\n\r\n" + body + next)
        shutdown(client, SHUT_WR)
        #expect(RelaySockets.read(client) == RecordingAPI.reply)
        #expect(api.received == ["POST /v1/chat/completions HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer \(pairKey)\r\n"
            + "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n" + body + next])
    }

    /// A head longer than any the API takes, or one the relay can't read, passes as it came (rank 0's API refuses it).
    @Test func aHeadTheRelayCannotReadPassesAsItCame() throws {
        let api = try RecordingAPI()
        defer { api.stop() }
        let relay = try RelaySockets.relay(to: api.port, keys: relayKeys)
        defer { relay.stop() }
        let long = "GET /v1/models HTTP/1.1\r\nAuthorization: Bearer \(ownKey)\r\nX-Pad: "
            + String(repeating: "p", count: 100 * 1024) + "\r\n\r\n"
        let folded = "GET /v1/models HTTP/1.1\r\nX-Folded: a\r\n b\r\nAuthorization: Bearer \(ownKey)\r\n\r\n"
        for request in [long, folded] {
            let client = try RelaySockets.connect(relay.port)
            RelaySockets.write(client, request)
            shutdown(client, SHUT_WR)
            _ = RelaySockets.read(client)
            close(client)
        }
        #expect(api.received == [long, folded])
    }

    /// Without keys (the relay as it was), every byte passes as it comes, the key included.
    @Test func withoutKeysEveryBytePasses() throws {
        let api = try RecordingAPI()
        defer { api.stop() }
        let relay = try RelaySockets.relay(to: api.port, keys: nil)
        defer { relay.stop() }
        let request = "GET /v1/models HTTP/1.1\r\nAuthorization: Bearer \(ownKey)\r\n\r\n"
        let client = try RelaySockets.connect(relay.port)
        defer { close(client) }
        RelaySockets.write(client, request)
        shutdown(client, SHUT_WR)
        #expect(RelaySockets.read(client) == RecordingAPI.reply)
        #expect(api.received == [request])
    }

    // MARK: - Rank 0's API

    /// Rank 0's API takes its own Mac's key and the pair's, which every relay passes requests on with; never another
    /// Mac's own key. Its open routes stay open. A single Mac's API (no pair key) is as before.
    @Test func rankZerosAPITakesItsOwnKeyAndThePairsAndNoOtherMacsOwn() {
        func authorized(_ header: String?, path: String = "/v1/chat/completions", pair: String? = pairKey) -> Bool {
            LocalAuthPolicy.authorize(method: .post, path: path, authorizationHeader: header, token: leaderKey, pairToken: pair)
        }
        #expect(authorized("Bearer \(leaderKey)"))
        #expect(authorized("Bearer \(pairKey)"))
        #expect(!authorized("Bearer \(ownKey)"), "a member's own key works on its own relay only")
        #expect(!authorized(nil))
        #expect(!authorized(pairKey), "the scheme is required")
        #expect(!authorized("Bearer \(pairKey)", pair: nil), "without a pair key, only its own")
        #expect(!authorized("Bearer ", pair: ""), "an empty pair key opens nothing")
        #expect(LocalAuthPolicy.authorize(method: .get, path: "/health", authorizationHeader: nil, token: leaderKey, pairToken: pairKey))
    }

    /// A member's whole path, on the local API's real stack: its tools' requests on one kept-alive connection reach rank
    /// 0's API through its relay with its own key, while rank 0's API refuses that key from anyone else.
    @Test func aMembersToolsUseItsOwnKeyThroughItsRelay() async throws {
        let engine = RouterStubEngine()
        let bound = BoundPort()
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: leaderKey, pairToken: pairKey, router: nil),
            defaultMaxTokens: 32,
            acquire: { throw MultiModelBatchSchedulerEngineError.modelNotLoaded($0) },
            tokenizerProvider: { _ in throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization },
            availableModels: { ["here"] }, mtpSlots: { [] },
            onServerRunning: { bound.set($0.localAddress?.port) },
            managedSuperEngine: { _, _, _ in engine })
        let server = Task { try await app.runService(gracefulShutdownSignals: []) }
        defer { server.cancel() }
        #expect(await clusterPairWait { bound.port != nil })
        let leaderPort = try #require(bound.port)
        let relay = try RelaySockets.relay(to: leaderPort, keys: relayKeys)
        defer { relay.stop() }
        // One session: it keeps its connection to the relay alive between requests.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func chat(_ port: Int, key: String) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"model":"here","messages":[{"role":"user","content":"hi"}]}"#.utf8)
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        for _ in 0..<3 { #expect(try await chat(relay.port, key: ownKey) == 200, "through the relay, with its own key") }
        #expect(try await chat(relay.port, key: pairKey) == 200, "tools set up with the pair's key keep working")
        #expect(try await chat(relay.port, key: "dk-local-not-a-key") == 401)
        #expect(try await chat(leaderPort, key: ownKey) == 401, "a member's own key works on its relay only")
        #expect(try await chat(leaderPort, key: leaderKey) == 200)
        #expect(try await chat(leaderPort, key: pairKey) == 200)
        #expect(engine.requests.count == 6)
    }

    // MARK: - Me first and the paid network

    /// A request through a member's relay is the owner's use on rank 0: the pair pauses while it runs or waits for a
    /// lane, exactly as for a request on rank 0's own API.
    @Test func aRequestThroughAMembersRelayPausesThePair() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("member-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = ProcessInfo.processInfo.environment["DARKBLOOM_LOCAL_DIR"]
        setenv("DARKBLOOM_LOCAL_DIR", directory.path, 1)
        defer { if let previous { setenv("DARKBLOOM_LOCAL_DIR", previous, 1) } else { unsetenv("DARKBLOOM_LOCAL_DIR") } }
        let clock = MeFirstTestClock()
        let endpoint = LocalInferenceHTTPConfig(host: "127.0.0.1", port: 0, authToken: leaderKey, pairToken: pairKey)
        let leader = try ProviderLoop(
            config: .init(coordinatorURL: "ws://127.0.0.1:9/ws", hardware: ModelLoadingFixtures.defaultHardware,
                models: [.init(id: clusterPairFixtureModel, modelType: "qwen3_5", sizeBytes: 1, estimatedMemoryGb: 1)],
                config: .init(provider: .init(name: "member-relay", autoUpdate: false), backend: .init(),
                    coordinator: .init(url: "ws://127.0.0.1:9/ws", heartbeatIntervalSecs: 1)),
                localEndpoint: endpoint, executionRole: .clusterMember),
            attestationSigner: ServeLoopTestSigner())
        await leader.setEngineV2RuntimeForTesting(EngineV2Runtime())
        await leader.setServeUsesHostServicesForTesting(false)
        await leader.setDaemonStateFileForTesting(directory.appendingPathComponent("state.json"))
        await leader.setClusterPairWarmupForTesting(timeoutSeconds: nil)
        await leader.useMeFirstClockForTesting(clock)
        try await leader.hostClusterPairSlotForTesting()
        try await leader.prepareClusterMemberControlForTesting()
        let owner = ScriptedPairOwner()
        let hold = DispatchSemaphore(value: 0)
        owner.hold = hold
        try await leader.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        await leader.stopClusterPairCapacityRefreshForTesting()
        await leader.startLocalEndpoint(endpoint)
        do {
            #expect(await clusterPairWait { LocalEndpoint.readInfo() != nil })
            let leaderPort = Int(try #require(LocalEndpoint.readInfo()).port)
            let state = await leader.state
            #expect(!state.ownerPausesPublic)

            let relay = try RelaySockets.relay(to: leaderPort, keys: relayKeys)
            defer { relay.stop() }
            let client = try RelaySockets.connect(relay.port)
            defer { close(client) }
            let body = #"{"model":"\#(clusterPairFixtureModel)","messages":[{"role":"user","content":"local"}],"#
                + #""max_tokens":3,"stream":true,"temperature":0,"reasoning_parser":"none"}"#
            RelaySockets.write(client, "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(ownKey)\r\n"
                + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body)
            #expect(await clusterPairWait { state.ownerPausesPublic }, "the relayed request pauses the pair")
            #expect(await leader.meFirstSnapshot?.localRequestsInFlight == 1)
            #expect(state.busy?.reason == .owner)
            hold.signal()
            let answer = RelaySockets.read(client, until: { $0.contains("data: [DONE]") })
            #expect(answer.hasPrefix("HTTP/1.1 200"), "\(answer.prefix(300))")
            #expect(await clusterPairWait { await leader.meFirstSnapshot?.localRequestsInFlight == 0 })
            #expect(state.ownerPausesPublic, "the pause outlasts the owner's last request, as on rank 0's own API")
        } catch {
            await leader.stopLocalEndpoint()
            throw error
        }
        await leader.stopLocalEndpoint()
        #expect(await leader.retireClusterPairSlot(reason: "test"))
    }

    /// A request through a member's relay reaches rank 0's API from that member's cable address, the relay's own
    /// connection: another machine, so it never takes the paid network, whoever gave it to the relay. A program on rank
    /// 0's own Mac keeps `my-macs-first`.
    @Test(arguments: [2, 3])
    func aRelayedRequestNeverTakesThePaidNetwork(macs: Int) async throws {
        for member in Self.roster(macs).dropFirst() {
            #expect(ClusterLocalRelay.rankZeroHost(serving: true, scope: Self.both, memberID: member.id,
                                                   roster: Self.roster(macs), partRuns: true) == Self.roster(macs)[0].host,
                    "the relay dials rank 0 over the cable, from \(member.host)")
            let fixture = LocalRouterRemoteClientTests.fixture()
            let answer = try await LocalRouterRemoteClientTests.respond(fixture, peer: member.host, method: .post,
                                                                        path: "/v1/chat/completions", body: RouterFixture.chat("elsewhere"))
            #expect(answer.routeUsed == "self", "\(member.host)")
            #expect(fixture.upstream.posts.map(\.route) == ["self"], "\(member.host): never prefer")
        }
        let fixture = LocalRouterRemoteClientTests.fixture()
        let here = try await LocalRouterRemoteClientTests.respond(fixture, peer: "127.0.0.1", method: .post,
                                                                  path: "/v1/chat/completions", body: RouterFixture.chat("elsewhere"))
        #expect(here.routeUsed == "prefer")
    }

    // MARK: - Overhead

    /// The relay adds no work per token: the answer's direction is the same byte copy as `cluster local`'s, with or
    /// without keys. Rank 0's stand-in streams frames 50 µs apart, each stamped when sent; the latency of each, direct and
    /// through both relays, is printed (best of three interleaved runs), and so is the cost of the key check per request.
    @Test func theRelayAddsNoWorkPerToken() throws {
        let streamer = try StreamingAPI(frames: 2_000)
        defer { streamer.stop() }
        let plain = try RelaySockets.relay(to: streamer.port, keys: nil)
        defer { plain.stop() }
        let keyed = try RelaySockets.relay(to: streamer.port, keys: relayKeys)
        defer { keyed.stop() }
        var best: [String: (median: Double, p99: Double)] = [:]
        for _ in 0..<3 {
            for (name, port) in [("direct", streamer.port), ("cluster local's byte copy", plain.port), ("with this Mac's key", keyed.port)] {
                let run = try streamer.measure(through: port, key: ownKey)
                #expect(run.frames == 2_000, "\(name): every frame, in order")
                if run.median < best[name]?.median ?? .infinity { best[name] = (run.median, run.p99) }
            }
        }
        for (name, run) in best.sorted(by: { $0.key < $1.key }) {
            print("relay overhead: \(name): per frame median \(String(format: "%.1f", run.median)) µs, p99 \(String(format: "%.1f", run.p99)) µs")
        }
        let plainRun = try #require(best["cluster local's byte copy"]), keyedRun = try #require(best["with this Mac's key"])
        print("relay overhead: per frame, with the key check minus without: \(String(format: "%.1f", keyedRun.median - plainRun.median)) µs (median)")
        #expect(keyedRun.median < 5_000, "a frame through the relay within 5 ms")

        let api = try RecordingAPI()
        defer { api.stop() }
        let plainRequests = try RelaySockets.relay(to: api.port, keys: nil)
        defer { plainRequests.stop() }
        let keyedRequests = try RelaySockets.relay(to: api.port, keys: relayKeys)
        defer { keyedRequests.stop() }
        func perRequest(_ port: Int) throws -> Double {
            let request = "POST /v1/chat/completions HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer \(ownKey)\r\nContent-Length: 2\r\n\r\n{}"
            let start = ContinuousClock.now
            for _ in 0..<200 {
                let client = try RelaySockets.connect(port)
                RelaySockets.write(client, request)
                _ = RelaySockets.read(client, until: { $0.hasSuffix("ok") })
                close(client)
            }
            let elapsed = ContinuousClock.now - start
            return Double(elapsed.components.seconds) * 1e6 / 200 + Double(elapsed.components.attoseconds) / 1e12 / 200
        }
        var plainCost = Double.infinity, keyedCost = Double.infinity
        for _ in 0..<3 {
            plainCost = min(plainCost, try perRequest(plainRequests.port))
            keyedCost = min(keyedCost, try perRequest(keyedRequests.port))
        }
        print("relay overhead: per request (connect, head, answer): byte copy \(String(format: "%.1f", plainCost)) µs, "
            + "with the key check \(String(format: "%.1f", keyedCost)) µs")
    }
}

/// Rank 0's API as a streamer on loopback: for each request it answers a head, then `frames` frames of 64 bytes, 50 µs
/// apart, each holding the time it was sent (`DispatchTime` nanoseconds).
final class StreamingAPI: @unchecked Sendable {
    static let frameBytes = 64
    static let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
    let port: Int
    let frames: Int
    private let lock = NSLock()
    private var stopped = false

    init(frames: Int) throws {
        self.frames = frames
        let (listener, port) = try RelaySockets.listen()
        self.port = port
        RelaySockets.acceptLoop(listener, stopped: { [self] in lock.withLock { stopped } }) { [frames] client in
            defer { close(client) }
            var on: Int32 = 1
            _ = setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = RelaySockets.read(client, until: { $0.contains("\r\n\r\n") })
            RelaySockets.write(client, StreamingAPI.head)
            for _ in 0..<frames {
                let stamp = String(DispatchTime.now().uptimeNanoseconds)
                let frame = "data: " + stamp + String(repeating: " ", count: StreamingAPI.frameBytes - 8 - stamp.count) + "\n\n"
                RelaySockets.write(client, frame)
                usleep(50)
            }
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        RelaySockets.wake(port)
    }

    /// One request through `port`: how many frames came whole and in order, and their latency (µs, median and p99).
    func measure(through port: Int, key: String) throws -> (frames: Int, median: Double, p99: Double) {
        let client = try RelaySockets.connect(port)
        defer { close(client) }
        var on: Int32 = 1
        _ = setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        RelaySockets.write(client, "GET /v1/stream HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer \(key)\r\n\r\n")
        var pending = [UInt8](), chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var latencies: [Double] = [], last: UInt64 = 0, inOrder = true
        var headSkipped = false
        while latencies.count < frames {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { break }
            let now = DispatchTime.now().uptimeNanoseconds
            pending += chunk[0..<count]
            if !headSkipped {
                guard pending.count >= Self.head.utf8.count else { continue }
                pending.removeFirst(Self.head.utf8.count)
                headSkipped = true
            }
            while pending.count >= Self.frameBytes {
                let frame = String(decoding: pending[..<Self.frameBytes], as: UTF8.self)
                pending.removeFirst(Self.frameBytes)
                guard let sent = UInt64(frame.dropFirst(6).prefix { $0.isNumber }) else { inOrder = false; continue }
                if sent < last { inOrder = false }
                last = sent
                latencies.append(Double(now &- sent) / 1_000)
            }
        }
        let sorted = latencies.sorted()
        guard !sorted.isEmpty else { return (0, .infinity, .infinity) }
        return (inOrder ? sorted.count : 0, sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 99 / 100)])
    }
}
