import Foundation
import Testing
@testable import ProviderCore

/// A client that leaves a passed-on stream ends it at the coordinator too: on `prefer` the network would otherwise go
/// on generating, billed, and on `self` the owner's other Mac would stay busy. Everything is real sockets on
/// 127.0.0.1 with kernel-chosen ports: the client, the local API with the product's URLSession client, and a
/// coordinator stand-in that notes when its connection closes.
@Suite("Local router: a client that leaves", .serialized)
struct LocalRouterDisconnectTests {
    /// While events flow: the stand-in streams one event per 100 ms; the client leaves after the third.
    @Test func aPassedOnStreamEndsAtTheCoordinatorWhenTheClientLeavesMidStream() async throws {
        let standIn = try RawSSEStandIn(events: 60, gap: .milliseconds(100))
        defer { standIn.stop() }
        let endpoint = try await RouterLiveEndpoint(upstreamPort: standIn.port)
        defer { endpoint.stop() }
        let left = try await RawRouterClient.postAndLeave(port: endpoint.port, after: "\"n\":2")
        let outcome = try await standIn.outcome(within: .seconds(10))
        print("router disconnect (mid-stream): the coordinator's stream \(outcome), \(outcome.ended - left) after the client left")
        #expect(outcome.cut, "the coordinator's stream ran to its end: \(outcome)")
        #expect(outcome.ended - left < .milliseconds(1500), "\(outcome.ended - left) after the client left")
        #expect(outcome.written < 30)
    }

    /// While nothing flows (a long prompt at the other Mac): the stand-in sends one event, then waits 4 s; the client
    /// leaves after the first event, resetting its connection. Only the closed connection can end it: no chunk will
    /// fail to write for 4 s. (A client that only half-closes is noticed at the next chunk, as for this Mac's own
    /// streams: the server allows half-close.)
    @Test func aPassedOnStreamEndsAtTheCoordinatorWhenTheClientLeavesWhileNothingFlows() async throws {
        let standIn = try RawSSEStandIn(events: 3, gap: .milliseconds(100), pauseAfterFirst: .seconds(4))
        defer { standIn.stop() }
        let endpoint = try await RouterLiveEndpoint(upstreamPort: standIn.port)
        defer { endpoint.stop() }
        let left = try await RawRouterClient.postAndLeave(port: endpoint.port, after: "\"n\":0", reset: true)
        let outcome = try await standIn.outcome(within: .seconds(10))
        print("router disconnect (nothing flowing): the coordinator's stream \(outcome), \(outcome.ended - left) after the client left")
        #expect(outcome.cut, "the coordinator's stream ran to its end: \(outcome)")
        #expect(outcome.ended - left < .milliseconds(1500), "\(outcome.ended - left) after the client left")
        #expect(outcome.written == 1)
    }
}

/// The local API on 127.0.0.1 with a router whose coordinator is the stand-in, over the product's URLSession client.
final class RouterLiveEndpoint: @unchecked Sendable {
    let port: Int
    private let task: Task<Void, Error>

    init(upstreamPort: Int) async throws {
        let router = LocalRouterConfig(
            settings: LocalSettings(route: .myMacs),
            upstreamBaseURL: URL(string: "http://127.0.0.1:\(upstreamPort)")!, takesCoordinatorWork: false,
            accountKeys: InMemoryLocalRouterAccountKeyStore(RouterFixture.accountKey), log: { _ in })
        let (bound, continuation) = AsyncStream<Int>.makeStream()
        let app = RouterFixture.makeApp(router: router, engine: RouterStubEngine(),
                                        localModels: RouterStubEngine.servedModels,
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

/// A client on a plain socket: posts a streamed chat for a model this Mac doesn't serve, reads until `after`
/// arrives, then closes the connection.
enum RawRouterClient {
    /// - Parameter reset: leave with a reset (`SO_LINGER` 0), as a client that is killed or aborts often does.
    static func postAndLeave(port: Int, after marker: String, reset: Bool = false) async throws -> ContinuousClock.Instant {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try blocking(port: port, marker: marker, reset: reset) })
            }
        }
    }

    private static func blocking(port: Int, marker: String, reset: Bool) throws -> ContinuousClock.Instant {
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
        let request = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Authorization: Bearer \(RouterFixture.localKey)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var received = ""
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !received.contains(marker) {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count > 0 { received += String(decoding: buffer[0..<count], as: UTF8.self) }
        }
        if reset {
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        }
        close(fd)
        guard received.contains(marker) else { throw POSIXError(.EPROTO) }
        return .now
    }
}

/// A coordinator stand-in on a plain socket: answers the chat request with a chunked SSE stream of `events` events,
/// `gap` apart (`pauseAfterFirst` after the first), and notes when that connection closes under it, between writes
/// as well as on a write.
final class RawSSEStandIn: @unchecked Sendable {
    struct Outcome: CustomStringConvertible {
        var ended: ContinuousClock.Instant
        var written: Int
        var cut: Bool
        var description: String { "\(cut ? "cut" : "completed") after \(written) events" }
    }

    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var result: Outcome?

    init(events: Int, gap: Duration, pauseAfterFirst: Duration? = nil) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, length) == 0 && listen(listener, 4) == 0
                    && getsockname(listener, $0, &length) == 0
            }
        }
        guard bound else { close(listener); throw POSIXError(.EADDRNOTAVAIL) }
        self.listener = listener
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [weak self] in
            while true {
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else { return }
                Thread.detachNewThread { self?.serve(fd, events: events, gap: gap, pauseAfterFirst: pauseAfterFirst) }
            }
        }
    }

    func stop() { close(listener) }

    func outcome(within limit: Duration) async throws -> Outcome {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let result = lock.withLock({ result }) { return result }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw POSIXError(.ETIMEDOUT)
    }

    /// The chat request gets the stream; anything else (the router's catalog read) a plain 404.
    private func serve(_ fd: Int32, events: Int, gap: Duration, pauseAfterFirst: Duration?) {
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard let requestLine = Self.readRequest(fd) else { return }
        guard requestLine.hasPrefix("POST /v1/chat/completions ") else {
            _ = Self.write(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        guard Self.write(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n") else { return finish(written: 0, cut: true) }
        for index in 0..<events {
            let event = "data: {\"n\":\(index)}\n\n"
            guard Self.write(fd, String(event.utf8.count, radix: 16) + "\r\n" + event + "\r\n") else {
                return finish(written: index, cut: true)
            }
            let wait = index == 0 ? (pauseAfterFirst ?? gap) : gap
            if Self.closedWithin(fd, wait) { return finish(written: index + 1, cut: true) }
        }
        finish(written: events, cut: !Self.write(fd, "0\r\n\r\n"))
    }

    private func finish(written: Int, cut: Bool) {
        lock.withLock { result = Outcome(ended: .now, written: written, cut: cut) }
    }

    /// Reads the request head and its `Content-Length` body; returns the request line.
    private static func readRequest(_ fd: Int32) -> String? {
        var received = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            received += buffer[0..<count]
            let text = String(decoding: received, as: UTF8.self)
            guard let headEnd = text.range(of: "\r\n\r\n") else { continue }
            let head = text[..<headEnd.lowerBound]
            let length = head.lowercased().split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            if received.count - text[..<headEnd.upperBound].utf8.count >= length {
                return head.split(separator: "\r\n").first.map(String.init)
            }
        }
    }

    private static func write(_ fd: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let sent = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            guard sent > 0 else { return false }
            offset += sent
        }
        return true
    }

    /// Whether the peer closed the connection within `duration`.
    private static func closedWithin(_ fd: Int32, _ duration: Duration) -> Bool {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            let remaining = deadline - ContinuousClock.now
            let milliseconds = Int32(max(1, remaining.components.seconds * 1000
                + remaining.components.attoseconds / 1_000_000_000_000_000))
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, milliseconds)
            guard ready > 0 else { continue }
            var byte: UInt8 = 0
            let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count == 0 || (count < 0 && errno != EAGAIN) { return true }
            if poller.revents & Int16(POLLHUP | POLLERR) != 0 { return true }
        }
        return false
    }
}
