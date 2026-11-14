import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import NIOEmbedded
import Testing
@testable import ProviderCore

/// SSE passthrough: an upstream answer reaches the client chunk by chunk, as it arrives, and the product's URLSession
/// client streams, never follows a redirect and fails plainly. The coordinator stand-ins listen on 127.0.0.1 with a
/// kernel-chosen port.
@Suite("Local router streaming")
struct LocalRouterStreamingTests {
    /// An inner responder standing for this Mac's engine: it doesn't serve the model.
    struct NotHere: HTTPResponder {
        func respond(to request: Request, context: BasicRequestContext) async throws -> Response {
            LocalRouter.errorResponse(.notFound, message: "model not found")
        }
    }

    /// The upstream's second chunk is produced only after the client has received the first: a router that held the
    /// stream back would never see it.
    @Test func anUpstreamStreamReachesTheClientChunkByChunk() async throws {
        let gate = RouterGate()
        let upstream = GatedUpstream(gate: gate)
        let router = LocalRouter(config: LocalRouterConfig(
            settings: LocalSettings(route: .myMacs), upstreamBaseURL: URL(string: "http://coordinator.invalid")!,
            takesCoordinatorWork: false, accountKeys: InMemoryLocalRouterAccountKeyStore("sk-stream-fixture"),
            makeTransport: { upstream }, log: { _ in }), localModels: { [] })
        let responder = LocalRouterResponder(inner: NotHere(), router: router)
        let request = Request(head: .init(method: .post, scheme: "http", authority: "localhost",
                                          path: "/v1/chat/completions"),
                              body: .init(buffer: ByteBuffer(string: RouterFixture.chat("absent", stream: true))))
        let context = BasicRequestContext(source: ApplicationRequestContextSource(
            channel: EmbeddedChannel(), logger: Logger(label: #function)))
        let response = try await responder.respond(to: request, context: context)
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "text/event-stream")
        let writer = RouterRecordingWriter(onChunk: { count in if count == 1 { gate.open() } })
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await response.body.write(writer) }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            }
            try await group.next()
            group.cancelAll()
        }
        #expect(writer.text == GatedUpstream.first + GatedUpstream.second)
        #expect(writer.chunkCount == 2)
    }

    // MARK: - URLSession transport

    @Test func theURLSessionClientStreamsSendsOnlyItsHeadersAndFollowsNoRedirect() async throws {
        let seen = SeenHeaders()
        let router = Router()
        router.post("/v1/chat/completions") { request, _ -> Response in
            seen.record(request.headers)
            let body = AsyncStream<ByteBuffer> { continuation in
                Task {
                    continuation.yield(ByteBuffer(string: "data: one\n\n"))
                    try? await Task.sleep(for: .milliseconds(300))
                    continuation.yield(ByteBuffer(string: "data: two\n\n"))
                    continuation.finish()
                }
            }
            return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(asyncSequence: body))
        }
        router.get("/moved") { _, _ -> Response in
            Response(status: .temporaryRedirect, headers: [.location: "http://example.invalid/elsewhere"])
        }
        router.post("/slow-head") { _, _ -> Response in
            try await Task.sleep(for: .milliseconds(1500))
            return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "late")))
        }
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let base = "http://localhost:\(port)"
            let transport = URLSessionLocalRouterTransport()
            let response = try await transport.send(.init(
                url: URL(string: base + "/v1/chat/completions")!, method: "POST",
                headers: ["Authorization": "Bearer sk-live-fixture", "X-Darkbloom-Route": "self",
                          "Content-Type": "application/json", "Accept-Encoding": "identity"],
                body: ByteBuffer(string: "{}"), connectTimeout: .seconds(5), idleTimeout: .seconds(5)))
            #expect(response.status == 200)
            var chunks: [(String, ContinuousClock.Instant)] = []
            for try await chunk in response.body { chunks.append((String(buffer: chunk), .now)) }
            #expect(chunks.map(\.0).joined() == "data: one\n\ndata: two\n\n")
            // The first chunk arrived before the stub wrote the second: nothing waits for the end.
            if chunks.count >= 2 { #expect(chunks[1].1 - chunks[0].1 > .milliseconds(150)) }
            #expect(chunks.count >= 2)
            #expect(seen.last?[.authorization] == "Bearer sk-live-fixture")
            #expect(seen.last?[HTTPField.Name("X-Darkbloom-Route")!] == "self")

            let moved = try await transport.send(.init(
                url: URL(string: base + "/moved")!, method: "GET", headers: [:], body: nil,
                connectTimeout: .seconds(5), idleTimeout: .seconds(5)))
            #expect(moved.status == 307)

            // Connected, its body sent, then a head slower than the connect timeout: still answered.
            let slow = try await transport.send(.init(
                url: URL(string: base + "/slow-head")!, method: "POST", headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: "{}"), connectTimeout: .milliseconds(500), idleTimeout: .seconds(5)))
            #expect(slow.status == 200)
        }
    }

    @Test func theUpstreamSessionKeepsNothingAndOpensEnoughConnectionsPerHost() {
        let configuration = URLSessionLocalRouterTransport.sessionConfiguration()
        #expect(configuration.httpMaximumConnectionsPerHost >= 32)
        #expect(configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil && configuration.urlCredentialStorage == nil)
        #expect(!configuration.waitsForConnectivity)
    }

    /// A plain-HTTP coordinator (HTTP/1.1, as the V0 harness through a tunnel) takes one request per connection, so
    /// URLSession's default of 6 connections per host would hold a 7th concurrent pass-on until one ended, and the
    /// connect watchdog would fail it. Each stand-in stream here stays open until all ten requests have arrived.
    @Test func tenConcurrentPassOnsReachAPlainHTTPCoordinatorAtOnce() async throws {
        let concurrent = 10
        let arrivals = Arrivals()
        let router = Router()
        router.post("/v1/chat/completions") { _, _ -> Response in
            arrivals.arrive()
            let body = AsyncStream<ByteBuffer> { continuation in
                Task {
                    continuation.yield(ByteBuffer(string: "data: one\n\n"))
                    await arrivals.all(concurrent, within: .seconds(6))
                    continuation.yield(ByteBuffer(string: "data: two\n\n"))
                    continuation.finish()
                }
            }
            return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(asyncSequence: body))
        }
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let transport = URLSessionLocalRouterTransport()
            let request = LocalRouterUpstreamRequest(
                url: URL(string: "http://localhost:\(port)/v1/chat/completions")!, method: "POST",
                headers: ["Content-Type": "application/json"], body: ByteBuffer(string: "{}"),
                connectTimeout: .seconds(3), idleTimeout: .seconds(10))
            let started = ContinuousClock.now
            let answers = try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<concurrent {
                    group.addTask {
                        let response = try await transport.send(request)
                        var text = "\(response.status) "
                        for try await chunk in response.body { text += String(buffer: chunk) }
                        return text
                    }
                }
                return try await group.reduce(into: [String]()) { $0.append($1) }
            }
            #expect(answers == Array(repeating: "200 data: one\n\ndata: two\n\n", count: concurrent))
            #expect(arrivals.received == concurrent)
            #expect(ContinuousClock.now - started < .seconds(3))
        }
    }

    /// A reader that stops taking a passed-on answer (the relay waiting on a client that stopped reading): URLSession
    /// hands each chunk on as it arrives, so what waits for the reader is bounded by stopping the request, never by
    /// making the session's delegate queue, which every request shares, wait. Meanwhile another request on the same
    /// transport is answered.
    @Test func aStalledReaderIsStoppedAtTheBacklogCeilingWhileOtherRequestsAreAnswered() async throws {
        let ceiling = 32 * 1024 * 1024
        let flood = FloodStandIn(total: 4 * ceiling, pauseAfter: ceiling / 2)
        let router = Router()
        router.post("/flood") { _, _ -> Response in flood.response() }
        router.post("/v1/chat/completions") { _, _ -> Response in
            Response(status: .ok, headers: [.contentType: "text/event-stream"],
                     body: .init(byteBuffer: ByteBuffer(string: "data: one\n\ndata: [DONE]\n\n")))
        }
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let transport = URLSessionLocalRouterTransport()
            func request(_ path: String) -> LocalRouterUpstreamRequest {
                .init(url: URL(string: "http://localhost:\(port)\(path)")!, method: "POST",
                      headers: ["Content-Type": "application/json"], body: ByteBuffer(string: "{}"),
                      connectTimeout: .seconds(5), idleTimeout: .seconds(30))
            }
            // Its body is not read until the end.
            let stalled = try await transport.send(request("/flood"))
            #expect(stalled.status == 200)
            await flood.paused.wait()
            let other = try await transport.send(request("/v1/chat/completions"))
            var text = ""
            for try await chunk in other.body { text += String(buffer: chunk) }
            #expect(text == "data: one\n\ndata: [DONE]\n\n")
            flood.resumed.open()

            let outcome = try await flood.outcome(within: .seconds(20))
            print("router backlog (stalled reader): the stand-in's answer was \(outcome)")
            #expect(outcome.cut, "the whole answer was taken in while nothing read it: \(outcome)")
            // The ceiling, plus what the sockets on the way hold and what arrived before the cancel took effect.
            #expect(outcome.written < 2 * ceiling, "\(outcome)")
            var handedOn = 0
            do {
                for try await chunk in stalled.body { handedOn += chunk.readableBytes }
                Issue.record("the stalled answer ended as if whole after \(handedOn) bytes")
            } catch let error as LocalRouterUpstreamError {
                #expect(error == .readerFellBehind)
            }
            #expect(handedOn <= ceiling)
        }
    }

    /// The same through the local API: a client that stops reading a passed-on answer and stays connected. The relay
    /// waits on its write; past the ceiling the request is stopped at the coordinator, and a client that reads again
    /// gets what was already written to it, then a closed connection without the body's end.
    @Test func aClientThatStopsReadingIsCutOffAtTheBacklogCeiling() async throws {
        let ceiling = 32 * 1024 * 1024
        let flood = FloodStandIn(total: 4 * ceiling)
        let router = Router()
        router.post("/v1/chat/completions") { _, _ -> Response in flood.response() }
        let standIn = try await LoopbackStandIn(router)
        defer { standIn.stop() }
        let endpoint = try await RouterLiveEndpoint(upstreamPort: standIn.port)
        defer { endpoint.stop() }
        let connection = try await StalledRouterClient.postAndStopReading(port: endpoint.port)
        let outcome = try await flood.outcome(within: .seconds(20))
        let received = try await StalledRouterClient.readToEnd(connection, within: .seconds(20))
        print("router backlog (client stopped reading): the stand-in's answer was \(outcome); the client then "
            + "read \(received.bytes / (1024 * 1024)) MiB, \(received.ended ? "to the body's end" : "cut off")")
        #expect(outcome.cut, "the whole answer was taken in while the client read nothing: \(outcome)")
        // The ceiling, plus what the sockets to the client and from the stand-in hold.
        #expect(outcome.written < 2 * ceiling, "\(outcome)")
        #expect(!received.ended)
        #expect(received.bytes < outcome.written)
    }

    @Test func aClosedPortFailsPlainlyAndQuickly() async throws {
        // A port that was just free; nothing listens there.
        let port = try LocalRouterStreamingTests.freePort()
        let transport = URLSessionLocalRouterTransport()
        let started = ContinuousClock.now
        do {
            _ = try await transport.send(.init(
                url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!, method: "POST", headers: [:],
                body: ByteBuffer(string: "{}"), connectTimeout: .seconds(5), idleTimeout: .seconds(5)))
            Issue.record("a closed port answered")
        } catch let error as LocalRouterUpstreamError {
            #expect(error == .unreachable("Darkbloom refused the connection"))
            #expect(!error.description.contains("127.0.0.1"))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// The requests a stand-in has received, and a wait until all have.
final class Arrivals: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var received: Int { lock.withLock { count } }

    func arrive() { lock.withLock { count += 1 } }

    /// Waits until `expected` requests have arrived, or `limit` passes.
    func all(_ expected: Int, within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while received < expected, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

/// Opens once; waits until then.
final class RouterGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            opened = true
            defer { waiters = [] }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// Streams one chunk, then the next only once the gate opens.
struct GatedUpstream: LocalRouterTransport {
    static let first = "data: {\"n\":1}\n\n"
    static let second = "data: {\"n\":2}\n\ndata: [DONE]\n\n"
    let gate: RouterGate

    func send(_ request: LocalRouterUpstreamRequest) async throws -> LocalRouterUpstreamResponse {
        let (body, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        let gate = gate
        Task {
            continuation.yield(ByteBuffer(string: Self.first))
            await gate.wait()
            continuation.yield(ByteBuffer(string: Self.second))
            continuation.finish()
        }
        return LocalRouterUpstreamResponse(status: 200, headers: ["content-type": "text/event-stream"], body: body)
    }
}

final class SeenHeaders: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [HTTPFields] = []
    func record(_ headers: HTTPFields) { lock.withLock { all.append(headers) } }
    var last: HTTPFields? { lock.withLock { all.last } }
}

/// A coordinator stand-in's answer of `total` bytes, a 64 KiB chunk a millisecond (about 64 MB/s, a fast coordinator):
/// at loopback speed, what still arrives before a cancel takes effect would swamp what the router holds. With
/// `pauseAfter`, it opens `paused` there and waits for `resumed`. Notes how much it wrote and whether its connection
/// was cut under it (a write failed) before the end.
final class FloodStandIn: @unchecked Sendable {
    struct Outcome: CustomStringConvertible {
        var written: Int
        var cut: Bool
        var description: String { "\(cut ? "cut" : "completed") after \(written / (1024 * 1024)) MiB" }
    }

    static let chunk = ByteBuffer(repeating: UInt8(ascii: "x"), count: 64 * 1024)
    let total: Int
    /// A multiple of `chunk`'s size.
    let pauseAfter: Int?
    let paused = RouterGate()
    let resumed = RouterGate()
    private let lock = NSLock()
    private var result: Outcome?

    init(total: Int, pauseAfter: Int? = nil) {
        self.total = total
        self.pauseAfter = pauseAfter
    }

    func response() -> Response {
        Response(status: .ok, headers: [.contentType: "text/event-stream"], body: ResponseBody { writer in
            var written = 0
            do {
                while written < self.total {
                    if written == self.pauseAfter {
                        self.paused.open()
                        await self.resumed.wait()
                    }
                    try await writer.write(Self.chunk)
                    written += Self.chunk.readableBytes
                    try? await Task.sleep(for: .milliseconds(1))
                }
                try await writer.finish(nil)
                self.end(Outcome(written: written, cut: false))
            } catch {
                self.end(Outcome(written: written, cut: true))
                throw error
            }
        })
    }

    func outcome(within limit: Duration) async throws -> Outcome {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let result = lock.withLock({ result }) { return result }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw POSIXError(.ETIMEDOUT)
    }

    private func end(_ outcome: Outcome) { lock.withLock { result = outcome } }
}

/// `router` on 127.0.0.1 with a kernel-chosen port, for `RouterLiveEndpoint`, which dials 127.0.0.1: the live test
/// mode binds `localhost`, which can be IPv6 only.
final class LoopbackStandIn: @unchecked Sendable {
    let port: Int
    private let task: Task<Void, Error>

    init(_ router: Router<BasicRequestContext>) async throws {
        let (bound, continuation) = AsyncStream<Int>.makeStream()
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)),
                              onServerRunning: { channel in
                                  continuation.yield(channel.localAddress?.port ?? 0)
                                  continuation.finish()
                              })
        task = Task { try await app.runService(gracefulShutdownSignals: []) }
        var port = 0
        for await value in bound { port = value }
        guard port > 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        self.port = port
    }

    func stop() { task.cancel() }
}

/// A client on a plain socket that posts a streamed chat for a model this Mac doesn't serve, reads the response head,
/// then reads nothing more, staying connected, until `readToEnd`.
enum StalledRouterClient {
    static func postAndStopReading(port: Int) async throws -> Int32 {
        try await blocking {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EMFILE) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = UInt16(port).bigEndian
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            guard connected else { close(fd); throw POSIXError(.ECONNREFUSED) }
            let body = RouterFixture.chat("absent", stream: true)
            let request = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n"
                + "Authorization: Bearer \(RouterFixture.localKey)\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
            _ = request.withCString { send(fd, $0, strlen($0), 0) }
            // One byte at a time up to the head's end, so nothing of the body is taken.
            var head = [UInt8]()
            var byte: UInt8 = 0
            while !head.suffix(4).elementsEqual(Array("\r\n\r\n".utf8)) {
                let count = recv(fd, &byte, 1, 0)
                if count < 0, errno == EINTR { continue }
                guard count == 1 else {
                    let reason = count == 0 ? "the connection closed" : "recv failed, errno \(errno)"
                    close(fd)
                    throw UnexpectedAnswer(text: "\(reason) after: \(String(decoding: head, as: UTF8.self))")
                }
                head.append(byte)
            }
            guard String(decoding: head.prefix(12), as: UTF8.self) == "HTTP/1.1 200" else {
                var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var rest = [UInt8](repeating: 0, count: 2048)
                let count = max(0, recv(fd, &rest, rest.count, 0))
                close(fd)
                throw UnexpectedAnswer(text: String(decoding: head + rest.prefix(count), as: UTF8.self))
            }
            return fd
        }
    }

    struct UnexpectedAnswer: Error, CustomStringConvertible {
        let text: String
        var description: String { "the local API answered: \(text)" }
    }

    /// Reads until the connection closes or `limit` passes, then closes the socket: the body bytes read (chunk
    /// framing included), and whether they ended with the chunked body's end.
    static func readToEnd(_ fd: Int32, within limit: Duration) async throws -> (bytes: Int, ended: Bool) {
        try await blocking {
            defer { close(fd) }
            var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let end = Array("0\r\n\r\n".utf8)
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var bytes = 0
            var tail = [UInt8]()
            let deadline = ContinuousClock.now + limit
            while ContinuousClock.now < deadline {
                let count = recv(fd, &buffer, buffer.count, 0)
                if count == 0 { return (bytes, tail == end) }
                if count < 0 {
                    guard errno == EAGAIN || errno == EINTR else { return (bytes, false) }
                    continue
                }
                bytes += count
                tail = Array((tail + buffer[max(0, count - end.count)..<count]).suffix(end.count))
            }
            throw POSIXError(.ETIMEDOUT)
        }
    }

    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }
}
