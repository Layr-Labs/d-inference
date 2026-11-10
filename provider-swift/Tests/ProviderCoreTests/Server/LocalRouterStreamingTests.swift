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
