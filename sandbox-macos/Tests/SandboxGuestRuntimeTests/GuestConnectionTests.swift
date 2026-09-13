import Darwin
import Foundation
import XCTest
import SandboxGuestProtocol
@testable import SandboxGuestRuntime

private struct NeverExecute: GuestCommandExecuting {
    func execute(_ command: GuestCommand, id: UUID) async throws -> GuestResponse {
        throw GuestProtocolError.unavailable
    }
}

final class GuestConnectionTests: XCTestCase, @unchecked Sendable {
    private func handler() throws -> GuestRequestHandler {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guest-connection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return GuestRequestHandler(executor: NeverExecute(), workspace: try GuestWorkspace(
            path: root.path, tenantUID: getuid(), tenantGID: getgid(), requireSeparateVolume: false))
    }

    func testAuthenticatedSocketSessionRoundTripAndReplayRejection() async throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        let server = GuestConnection(descriptor: descriptors[0]), handler = try handler()
        let id = UUID(), key = Data(repeating: 9, count: 32)
        let task = Task { try await server.serve(instanceID: id, credential: key, handler: handler) }
        let hello = try await read(descriptors[1], as: GuestHello.self)
        let auth = try GuestSessionAuthenticator(hello: hello, expectedInstanceID: id, credential: key)
        let ping = GuestRequest(operation: .ping)
        let signed = try auth.seal(ping, sequence: 1, direction: .request)
        try GuestDescriptor.write(descriptors[1], data: GuestFrameCodec.encode(signed))
        let reply = try await read(descriptors[1], as: GuestAuthenticatedFrame.self)
        let response = try auth.open(reply, as: GuestResponse.self, direction: .response)
        XCTAssertTrue(response.success); XCTAssertEqual(response.id, ping.id); XCTAssertEqual(reply.sequence, 1)
        try GuestDescriptor.write(descriptors[1], data: GuestFrameCodec.encode(signed))
        do { try await task.value; XCTFail("Replay must close the server session") }
        catch { XCTAssertEqual(error as? GuestProtocolError, .invalidSequence) }
        await handler.disconnect(); await server.waitForResponses()
    }

    func testUnauthenticatedSocketCannotExecuteCommand() async throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        let server = GuestConnection(descriptor: descriptors[0]), handler = try handler()
        let id = UUID()
        let task = Task { try await server.serve(instanceID: id, credential: Data(repeating: 1, count: 32), handler: handler) }
        let hello = try await read(descriptors[1], as: GuestHello.self)
        let wrong = try GuestSessionAuthenticator(hello: hello, expectedInstanceID: id, credential: Data(repeating: 2, count: 32))
        let request = GuestRequest(operation: .execute, command: GuestCommand(executable: "/bin/echo"))
        let frame = try wrong.seal(request, sequence: 1, direction: .request)
        try GuestDescriptor.write(descriptors[1], data: GuestFrameCodec.encode(frame))
        do { try await task.value; XCTFail("Wrong credential must close the server session") }
        catch { XCTAssertEqual(error as? GuestProtocolError, .unauthenticated) }
        await handler.disconnect(); await server.waitForResponses()
    }

    private func read<T: Decodable & Sendable>(_ descriptor: Int32, as type: T.Type) async throws -> T {
        try await Task.detached {
            let header = try GuestDescriptor.read(descriptor, count: 4)
            let bytes = try GuestDescriptor.read(descriptor, count: GuestFrameCodec.frameSize(header: header))
            return try GuestFrameCodec.decode(bytes, as: type)
        }.value
    }
}
