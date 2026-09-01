import Darwin
import Foundation
import SandboxGuestAgentCore
import SandboxGuestProtocol
import XCTest

@testable import SandboxRuntime

/// Exercises the real host client against the real agent session.
///
/// A socketpair stands in for the vsock connection, because `AF_VSOCK` can only
/// be created inside a virtual machine. Everything above the socket family is
/// the production code both sides use over vsock.
final class SandboxGuestChannelClientTests: XCTestCase {
    private var openDescriptors: [Int32] = []

    override func tearDown() {
        for descriptor in openDescriptors where descriptor >= 0 {
            close(descriptor)
        }
        openDescriptors = []
        super.tearDown()
    }

    private func connectedPair() throws -> (host: Int32, guest: Int32) {
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw XCTSkip("socketpair unavailable")
        }
        return (pair[0], pair[1])
    }

    private func startAgent(
        on descriptor: Int32,
        imageID: String = "img-test",
        executionEnabled: Bool = false
    ) {
        let session = SandboxGuestAgentSession(
            configuration: .init(
                agentVersion: "0.1.0",
                imageID: imageID,
                executionEnabled: executionEnabled
            )
        )
        let thread = Thread {
            session.serve(descriptor: descriptor)
            close(descriptor)
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func command(
        executable: String = "/bin/echo",
        timeoutSeconds: UInt32 = 30
    ) -> SandboxGuestCommandWire {
        SandboxGuestCommandWire(
            idempotencyKey: UUID().uuidString,
            executable: executable,
            arguments: ["hello"],
            environment: [:],
            workingDirectory: "/Users/lume",
            timeoutSeconds: timeoutSeconds
        )
    }

    func testHandshakeCarriesAgentIdentity() throws {
        let pair = try connectedPair()
        startAgent(on: pair.guest)
        let client = try SandboxGuestChannelClient(descriptor: pair.host)
        defer { client.close() }

        let handshake = try client.handshake(expectedImageID: "img-test", timeout: 5)
        XCTAssertEqual(handshake.agentVersion, "0.1.0")
        XCTAssertEqual(handshake.imageID, "img-test")
        XCTAssertEqual(
            handshake.protocolVersion,
            SandboxGuestHandshake.currentProtocolVersion
        )
    }

    func testMismatchedImageIdentityIsRejected() throws {
        let pair = try connectedPair()
        startAgent(on: pair.guest, imageID: "img-test")
        let client = try SandboxGuestChannelClient(descriptor: pair.host)
        defer { client.close() }

        XCTAssertThrowsError(
            try client.handshake(expectedImageID: "a-different-image", timeout: 5)
        ) { error in
            guard case SandboxGuestChannelClient.ClientError.protocolViolation =
                error as? SandboxGuestChannelClient.ClientError
            else {
                return XCTFail("expected a protocol violation, got \(error)")
            }
        }
    }

    func testWellFormedCommandIsRefusedWhileExecutionIsDisabled() throws {
        let pair = try connectedPair()
        startAgent(on: pair.guest)
        let client = try SandboxGuestChannelClient(descriptor: pair.host)
        defer { client.close() }
        _ = try client.handshake(timeout: 5)

        XCTAssertThrowsError(try client.execute(command(), timeout: 5)) { error in
            guard case SandboxGuestChannelClient.ClientError.agentFailure(let code, _) =
                error as? SandboxGuestChannelClient.ClientError
            else {
                return XCTFail("expected an agent failure, got \(error)")
            }
            XCTAssertEqual(code, "execution_disabled")
        }
    }

    func testAgentRevalidatesCommandsRatherThanTrustingTheHost() throws {
        let pair = try connectedPair()
        startAgent(on: pair.guest)
        let client = try SandboxGuestChannelClient(descriptor: pair.host)
        defer { client.close() }
        _ = try client.handshake(timeout: 5)

        // A relative executable: the host would never construct this, so a
        // refusal proves the agent does not trust the channel.
        XCTAssertThrowsError(
            try client.execute(command(executable: "echo"), timeout: 5)
        ) { error in
            guard case SandboxGuestChannelClient.ClientError.agentFailure(let code, _) =
                error as? SandboxGuestChannelClient.ClientError
            else {
                return XCTFail("expected an agent failure, got \(error)")
            }
            XCTAssertEqual(code, "invalid_request")
        }
    }

    func testHandshakeTimesOutRatherThanHangingWithNoAgent() throws {
        let pair = try connectedPair()
        openDescriptors.append(pair.guest)
        let client = try SandboxGuestChannelClient(descriptor: pair.host)
        defer { client.close() }

        let started = Date()
        XCTAssertThrowsError(try client.handshake(timeout: 1)) { error in
            guard case SandboxGuestChannelClient.ClientError.timedOut =
                error as? SandboxGuestChannelClient.ClientError
            else {
                return XCTFail("expected a timeout, got \(error)")
            }
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            10,
            "the deadline must actually bound the wait"
        )
    }

    func testClosedChannelRefusesFurtherWork() throws {
        let pair = try connectedPair()
        startAgent(on: pair.guest)
        let client = try SandboxGuestChannelClient(descriptor: pair.host)
        _ = try client.handshake(timeout: 5)
        client.close()

        XCTAssertThrowsError(try client.execute(command(), timeout: 1))
    }
}
