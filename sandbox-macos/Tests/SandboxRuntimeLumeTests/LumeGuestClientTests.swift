import Darwin
import Foundation
import SandboxGuestProtocol
@testable import SandboxRuntimeLume
import XCTest

final class LumeGuestClientTests: XCTestCase {
    func testAuthenticatesReplyAndRejectsDifferentRequestIdentity() async throws {
        for wrongID in [false, true] {
            let fixture = try GuestSocketFixture()
            let server = Task.detached {
                let connection = try fixture.acceptClient()
                defer { close(connection) }
                let hello = try GuestHello(instanceID: fixture.instanceID)
                try GuestSocketFixture.send(hello, to: connection)
                var authenticator = try GuestSessionAuthenticator(
                    hello: hello, expectedInstanceID: fixture.instanceID, credential: fixture.credential)
                let frame = try GuestSocketFixture.receive(GuestAuthenticatedFrame.self, from: connection)
                let request = try authenticator.accept(frame)
                let response = GuestResponse(id: wrongID ? UUID() : request.id, success: true)
                try GuestSocketFixture.send(authenticator.seal(response, sequence: 1, direction: .response), to: connection)
            }
            do {
                let reply = try await fixture.client.request(GuestRequest(operation: .ping))
                XCTAssertFalse(wrongID, "reply for a different request must be rejected")
                XCTAssertTrue(reply.success)
            } catch {
                XCTAssertTrue(wrongID)
                XCTAssertEqual(error as? GuestProtocolError, .invalidMessage)
            }
            try await server.value
        }
    }

    func testRejectsUnauthenticatedGuestReply() async throws {
        let fixture = try GuestSocketFixture()
        let server = Task.detached {
            let connection = try fixture.acceptClient()
            defer { close(connection) }
            let hello = try GuestHello(instanceID: fixture.instanceID)
            try GuestSocketFixture.send(hello, to: connection)
            let requestFrame = try GuestSocketFixture.receive(GuestAuthenticatedFrame.self, from: connection)
            let good = try GuestSessionAuthenticator(hello: hello, expectedInstanceID: fixture.instanceID,
                                                     credential: fixture.credential)
            let request = try good.open(requestFrame, as: GuestRequest.self, direction: .request)
            let bad = try GuestSessionAuthenticator(hello: hello, expectedInstanceID: fixture.instanceID,
                                                    credential: Data(repeating: 7, count: 32))
            try GuestSocketFixture.send(bad.seal(GuestResponse(id: request.id, success: true),
                                                sequence: 1, direction: .response), to: connection)
        }
        do {
            _ = try await fixture.client.request(GuestRequest(operation: .ping))
            XCTFail("forged response accepted")
        } catch { XCTAssertEqual(error as? GuestProtocolError, .unauthenticated) }
        try await server.value
    }

    func testCancellationInterruptsStalledHandshake() async throws {
        let fixture = try GuestSocketFixture()
        let started = expectation(description: "accepted")
        let server = Task.detached {
            let connection = try fixture.acceptClient()
            defer { close(connection) }
            started.fulfill()
            var byte: UInt8 = 0
            XCTAssertEqual(read(connection, &byte, 1), 0)
        }
        let request = Task { try await fixture.client.request(GuestRequest(operation: .ping), timeoutSeconds: 30) }
        await fulfillment(of: [started], timeout: 2)
        let start = ContinuousClock.now
        request.cancel()
        do { _ = try await request.value; XCTFail("cancelled request completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        try await server.value
    }
}

private final class GuestSocketFixture: @unchecked Sendable {
    let directory: URL
    let url: URL
    let instanceID = UUID()
    let credential = Data(repeating: 3, count: 32)
    let listener: Int32
    var client: LumeGuestClient { get throws { try LumeGuestClient(socketURL: url, instanceID: instanceID, credential: credential) } }

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dbgc-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent("s")
        // Darwin's UNIX path limit is 104 bytes; the normal test TMPDIR may be longer.
        guard url.path.utf8.count < 104 else { throw GuestProtocolError.invalidConfiguration }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw GuestProtocolError.unavailable }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(url.path.utf8) + [0]) }
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0, chmod(url.path, 0o600) == 0, listen(listener, 1) == 0 else {
            throw GuestProtocolError.unavailable
        }
    }
    deinit { close(listener); try? FileManager.default.removeItem(at: directory) }
    func acceptClient() throws -> Int32 {
        var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&event, 1, 3000) > 0 else { throw GuestProtocolError.unavailable }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { throw GuestProtocolError.unavailable }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return client
    }
    static func send<T: Encodable>(_ value: T, to descriptor: Int32) throws {
        let bytes = try GuestFrameCodec.encode(value)
        let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw GuestProtocolError.disconnected }
    }
    static func receive<T: Decodable>(_ type: T.Type, from descriptor: Int32) throws -> T {
        func readExactly(_ count: Int) throws -> Data {
            var data = Data(count: count), offset = 0
            while offset < count {
                let readCount = data.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset) }
                guard readCount > 0 else { throw GuestProtocolError.disconnected }
                offset += readCount
            }
            return data
        }
        let size = try GuestFrameCodec.frameSize(header: readExactly(4))
        return try GuestFrameCodec.decode(readExactly(size), as: type)
    }
}
