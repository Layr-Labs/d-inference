import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
import NIOEmbedded
import Testing
@testable import ProviderCore

/// What the router costs a request this Mac serves: the same streamed chat, over the same stub engine, through the
/// endpoint without a router and through the endpoint with one (a key saved, so the router is fully on), interleaved.
/// Measured in process (no sockets: the router's own cost) and over loopback (what a client sees). CPU only.
///
/// `DARKBLOOM_ROUTER_BENCH_ITERATIONS` raises the sample count; the printed p50/p99 lines are the evidence.
@Suite("Local router overhead", .serialized)
struct LocalRouterOverheadTests {
    static var iterations: Int {
        Int(ProcessInfo.processInfo.environment["DARKBLOOM_ROUTER_BENCH_ITERATIONS"] ?? "") ?? 400
    }
    static let body = RouterFixture.chat("here", stream: true)

    @Test func thisMacsPathCostsNegligibleTimeInProcess() async throws {
        let plain = RouterFixture(router: false), routed = RouterFixture(route: .myMacs)
        let plainApp = plain.app, routedApp = routed.app
        let context = LocalDisconnectContext(source: ApplicationRequestContextSource(
            channel: EmbeddedChannel(), logger: Logger(label: #function)))
        func once(_ app: LocalInferenceApplication) async throws -> Sample {
            let request = Request(head: .init(method: .post, scheme: "http", authority: "localhost",
                                              path: "/v1/chat/completions", headerFields: RouterFixture.authorized),
                                  body: .init(buffer: ByteBuffer(string: Self.body)))
            let start = ContinuousClock.now
            let response = try await app.responder.respond(to: request, context: context)
            let head = ContinuousClock.now
            let writer = RouterRecordingWriter()
            try await response.body.write(writer)
            let end = ContinuousClock.now
            #expect(response.status == .ok)
            return Sample(head: head - start, firstByte: (writer.firstByte ?? end) - start, whole: end - start)
        }
        var without: [Sample] = [], with: [Sample] = []
        for index in 0..<(Self.iterations + 50) {
            let a = try await once(plainApp), b = try await once(routedApp)
            if index >= 50 { without.append(a); with.append(b) }
        }
        let report = Report(name: "in process", without: without, with: with)
        print(report.lines.joined(separator: "\n"))
        #expect(routed.factory.count == 0 && routed.upstream.requests.isEmpty)
        // Negligible: under 0.5 ms added at the median, against first tokens of tens to hundreds of milliseconds.
        #expect(report.added(\.firstByte, 0.5) < .microseconds(500), "\(report.lines)")
    }

    @Test func thisMacsPathCostsNegligibleTimeOverLoopback() async throws {
        let plain = try await LiveEndpoint(RouterFixture(router: false))
        let routed = try await LiveEndpoint(RouterFixture(route: .myMacs))
        defer { plain.stop(); routed.stop() }
        var without: [Sample] = [], with: [Sample] = []
        for index in 0..<(Self.iterations + 50) {
            let a = try await plain.post(Self.body), b = try await routed.post(Self.body)
            if index >= 50 { without.append(a); with.append(b) }
        }
        let report = Report(name: "loopback", without: without, with: with)
        print(report.lines.joined(separator: "\n"))
        #expect(report.added(\.firstByte, 0.5) < .milliseconds(1), "\(report.lines)")
    }
}

struct Sample {
    var head: Duration
    var firstByte: Duration
    var whole: Duration
}

struct Report {
    let name: String
    let without: [Sample]
    let with: [Sample]

    static func percentile(_ values: [Duration], _ p: Double) -> Duration {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    /// The router's added time at percentile `p` of `metric` (with minus without).
    func added(_ metric: KeyPath<Sample, Duration>, _ p: Double) -> Duration {
        Self.percentile(with.map { $0[keyPath: metric] }, p) - Self.percentile(without.map { $0[keyPath: metric] }, p)
    }

    var lines: [String] {
        func micro(_ duration: Duration) -> String {
            String(format: "%.1f µs", Double(duration.components.attoseconds) / 1e12
                + Double(duration.components.seconds) * 1e6)
        }
        return [("response head", \Sample.head), ("first byte", \.firstByte), ("whole response", \.whole)].map {
            label, metric in
            let p50a = Self.percentile(without.map { $0[keyPath: metric] }, 0.5)
            let p50b = Self.percentile(with.map { $0[keyPath: metric] }, 0.5)
            let p99a = Self.percentile(without.map { $0[keyPath: metric] }, 0.99)
            let p99b = Self.percentile(with.map { $0[keyPath: metric] }, 0.99)
            return "router overhead (\(name), n=\(with.count)), \(label): p50 \(micro(p50a)) without, \(micro(p50b)) with "
                + "(\(micro(p50b - p50a)) added); p99 \(micro(p99a)) without, \(micro(p99b)) with (\(micro(p99b - p99a)) added)"
        }
    }
}

/// The fixture's app listening on 127.0.0.1 with a kernel-chosen port, and a plain HTTP/1.1 client over a POSIX
/// socket that notes when the response head and the first body byte arrive.
final class LiveEndpoint: @unchecked Sendable {
    let fixture: RouterFixture
    let port: Int
    private let task: Task<Void, Error>

    init(_ fixture: RouterFixture) async throws {
        self.fixture = fixture
        let (bound, continuation) = AsyncStream<Int>.makeStream()
        let app = fixture.makeApp(onServerRunning: { channel in
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

    func post(_ body: String) async throws -> Sample {
        let port = port
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.blockingPost(port: port, body: body) })
            }
        }
    }

    private static func blockingPost(port: Int, body: String) throws -> Sample {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let start = ContinuousClock.now
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { throw POSIXError(.ECONNREFUSED) }
        let request = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(RouterFixture.localKey)\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        let sent = request.withCString { send(fd, $0, strlen($0), 0) }
        guard sent == request.utf8.count else { throw POSIXError(.EPIPE) }
        var received: [UInt8] = []
        var head: ContinuousClock.Instant?
        var firstByte: ContinuousClock.Instant?
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            received.append(contentsOf: buffer[0..<count])
            if head == nil, let end = Self.headEnd(received) {
                head = .now
                if received.count > end { firstByte = head }
            } else if head != nil, firstByte == nil {
                firstByte = .now
            }
        }
        let end = ContinuousClock.now
        guard let head, String(decoding: received.prefix(12), as: UTF8.self) == "HTTP/1.1 200" else {
            throw POSIXError(.EPROTO)
        }
        return Sample(head: head - start, firstByte: (firstByte ?? end) - start, whole: end - start)
    }

    private static func headEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 3..<bytes.count where bytes[index - 3] == 13 && bytes[index - 2] == 10
            && bytes[index - 1] == 13 && bytes[index] == 10 { return index + 1 }
        return nil
    }
}
