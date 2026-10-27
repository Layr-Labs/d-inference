import Darwin
import Foundation
import Testing

@testable import ProviderCore

/// Blocking line client for the add-on socket, as an add-on would use it.
final class AddonSocketClient {
    private let fd: Int32
    private var buffer = Data()

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { target.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
    }

    deinit { close(fd) }

    func send(_ text: String) {
        let data = Data(text.utf8)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if written <= 0 { return }
            offset += written
        }
    }

    /// The next response line, or nil at end of stream.
    func readLine() -> String? {
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer = Data(buffer[buffer.index(after: newline)...])
                return line
            }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    func request(_ json: String) throws -> [String: Any] {
        send(json + "\n")
        let line = try #require(readLine())
        return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}

@Suite("Add-on IPC server", .serialized)
struct AddonIPCServerTests {
    private static let peer = AddonPeer(identifier: "io.darkbloom.sandbox")

    private func makeServer(
        _ fixture: AddonRuntimeFixture,
        authenticate: @escaping AddonIPCServer.Authenticate = { _ in AddonIPCServerTests.peer },
        handle: @escaping AddonIPCServer.Handle = { request, _ in
            request == .hello ? .hello(providerVersion: "test") : .failure(.notFound)
        }
    ) throws -> AddonIPCServer {
        let server = AddonIPCServer(socketURL: fixture.paths.socket, authenticate: authenticate, handle: handle)
        try server.start()
        return server
    }

    @Test func servesManyRequestsPerConnectionOnAnOwnerOnlySocket() throws {
        let fixture = try AddonRuntimeFixture()
        defer { fixture.remove() }
        let server = try makeServer(fixture)
        defer { server.stop() }
        #expect(AddonRuntimeFixture.mode(fixture.paths.socket) == 0o600)
        #expect(AddonRuntimeFixture.mode(fixture.directory) == 0o700)
        let client = try AddonSocketClient(path: fixture.paths.socket.path)
        let hello = try client.request(#"{"v":1,"op":"hello"}"#)
        #expect(hello["capabilities"] as? [String] == ["hold.v1"] && hello["provider_version"] as? String == "test")
        #expect(try client.request(#"{"v":1,"op":"status","hold_id":"x"}"#)["error"] as? String == "not_found")
        #expect(try client.request(#"{"v":9,"op":"hello"}"#)["error"] as? String == "unsupported_version")
        #expect(try client.request("garbage")["error"] as? String == "invalid_request")
        // Two requests in one write still get one response line each, in order.
        client.send("{\"v\":1,\"op\":\"hello\"}\n{\"v\":1,\"op\":\"status\",\"hold_id\":\"y\"}\n")
        #expect(client.readLine()?.contains("hold.v1") == true)
        #expect(client.readLine()?.contains("not_found") == true)
    }

    @Test func anOversizedLineIsAnsweredOnceThenClosed() throws {
        let fixture = try AddonRuntimeFixture()
        defer { fixture.remove() }
        let server = try makeServer(fixture)
        defer { server.stop() }
        let client = try AddonSocketClient(path: fixture.paths.socket.path)
        client.send(String(repeating: "x", count: AddonIPC.maximumMessageBytes + 1))
        let line = try #require(client.readLine())
        #expect(line.contains("invalid_request"))
        #expect(client.readLine() == nil)
    }

    @Test func anUnauthenticatedPeerIsRefusedAndDisconnected() throws {
        let fixture = try AddonRuntimeFixture()
        defer { fixture.remove() }
        let handled = AddonLockedFlag()
        // The real policy: this test process is not a signed add-on.
        let policy = AddonPeerPolicy.current(environment: [:])
        let server = try makeServer(fixture, authenticate: { policy.authenticate($0) }, handle: { _, _ in
            handled.set()
            return .hello(providerVersion: "test")
        })
        defer { server.stop() }
        let client = try AddonSocketClient(path: fixture.paths.socket.path)
        #expect(try client.request(#"{"v":1,"op":"hello"}"#)["error"] as? String == "unauthorized")
        #expect(client.readLine() == nil)
        #expect(!handled.value)
    }

    @Test func aStaleSocketIsReplacedButALiveOneIsNeverTakenOver() throws {
        let fixture = try AddonRuntimeFixture()
        defer { fixture.remove() }
        let first = try makeServer(fixture)
        #expect(throws: (any Error).self) { _ = try makeServer(fixture) }
        // Simulate a crash: the socket file stays but nothing listens.
        first.stop()
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(fixture.paths.socket.path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { target in bytes.withUnsafeBytes { target.copyMemory(from: $0) } }
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(stale)
        let second = try makeServer(fixture)
        defer { second.stop() }
        #expect(try AddonSocketClient(path: fixture.paths.socket.path).request(#"{"v":1,"op":"hello"}"#)["ok"] as? Bool == true)
        // A non-socket at the path is never removed.
        second.stop()
        try Data().write(to: fixture.paths.socket)
        #expect(throws: (any Error).self) { _ = try makeServer(fixture) }
    }

    @Test func stopUnlinksTheSocketAndClosesConnections() throws {
        let fixture = try AddonRuntimeFixture()
        defer { fixture.remove() }
        let server = try makeServer(fixture)
        let client = try AddonSocketClient(path: fixture.paths.socket.path)
        #expect(try client.request(#"{"v":1,"op":"hello"}"#)["ok"] as? Bool == true)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.socket.path))
        #expect(client.readLine() == nil)
    }
}

final class AddonLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
