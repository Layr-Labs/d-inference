import Darwin
import Foundation
import SandboxGuestAgentCore
import SandboxGuestProtocol
import SandboxRuntime
import XCTest

@testable import SandboxRuntimeLume

/// Covers the transport seam: that the two transports are interchangeable
/// because both return the same raw envelope bytes, and that the SSH transport
/// still produces byte-identical invocations so the fake-`lume` fixtures and
/// the tests that pin its error strings keep passing.
final class GuestCommandTransportTests: XCTestCase {
    private func request(
        executable: String = "/bin/echo",
        arguments: [String] = ["hello"],
        environment: [String: String] = [:],
        timeoutSeconds: UInt32 = 30
    ) throws -> SandboxGuestCommandRequest {
        try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: "/tmp",
            timeoutSeconds: timeoutSeconds
        )
    }

    // MARK: - SSH transport shape

    func testSSHTransportPreservesTheBootstrapGracePeriods() {
        // The bootstrap path gave Lume the guest budget plus five seconds and
        // the host process another five. Existing tests pin those numbers.
        XCTAssertEqual(LumeGuestSSHTransport.lumeGraceSeconds, 5)
        XCTAssertEqual(LumeGuestSSHTransport.hostGraceSeconds, 10)
    }

    func testSSHTransportKeepsTheErrorNameCallersAssertOn() {
        let transport = LumeGuestSSHTransport(
            runner: SandboxProcessRunner(),
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            storagePath: "/tmp",
            environment: [:]
        )
        // `commandFailed(command: "lume ssh", ...)` is asserted verbatim by
        // existing failure tests; renaming it silently breaks them.
        XCTAssertEqual(transport.description, "lume ssh")
    }

    func testSSHTransportPreparesTheSameEncodedScriptAsBefore() throws {
        let transport = LumeGuestSSHTransport(
            runner: SandboxProcessRunner(),
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            storagePath: "/tmp",
            environment: [:]
        )
        let request = try request()
        let prepared = try transport.prepare(request)
        guard case .encodedScript(let script) = prepared.payload else {
            return XCTFail("SSH transport must prepare an encoded script")
        }
        XCTAssertEqual(
            script,
            try LumeGuestCommandEncoder.encode(request),
            "the encoder is the contract the fake-lume fixture decodes"
        )
    }

    func testTransportsRejectCommandsPreparedForTheOtherTransport() throws {
        let ssh = LumeGuestSSHTransport(
            runner: SandboxProcessRunner(),
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            storagePath: "/tmp",
            environment: [:]
        )
        let wirePrepared = LumeGuestPreparedCommand(
            payload: .wire(SandboxGuestCommandWire(request: try request()))
        )
        // Handing a transport the other's payload is a programming error and
        // must fail loudly rather than silently doing nothing.
        var thrown: Error?
        let expectation = expectation(description: "ssh rejects wire payload")
        Task {
            do {
                _ = try await ssh.deliver(
                    virtualMachineName: "vm",
                    prepared: wirePrepared,
                    guestTimeoutSeconds: 5
                )
            } catch {
                thrown = error
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
        XCTAssertNotNil(thrown)
    }

    // MARK: - Request to wire conversion

    func testRequestConvertsToWireWithALowercasedKey() throws {
        // The bootstrap path lowercases the idempotency key when it reaches the
        // guest; the wire form must agree so a command sees the same value
        // whichever transport carried it.
        let request = try request()
        let wire = SandboxGuestCommandWire(request: request)
        XCTAssertEqual(
            wire.idempotencyKey,
            request.idempotencyKey.uuidString.lowercased()
        )
        XCTAssertEqual(wire.executable, request.executable)
        XCTAssertEqual(wire.arguments, request.arguments)
        XCTAssertEqual(wire.workingDirectory, request.workingDirectory)
        XCTAssertEqual(wire.timeoutSeconds, request.timeoutSeconds)
        XCTAssertTrue(wire.isWellFormed)
    }

    func testEveryHostAcceptedRequestConvertsToAWellFormedWire() throws {
        // The host validator must never admit something the agent then
        // refuses, or a legal request would fail only on the vsock transport.
        let cases: [SandboxGuestCommandRequest] = [
            try request(),
            try request(arguments: []),
            try request(environment: ["USER_DEFINED": "x"]),
            try request(timeoutSeconds: 1),
            try request(timeoutSeconds: 900),
            try request(arguments: Array(repeating: "a", count: 256)),
        ]
        for request in cases {
            XCTAssertTrue(
                SandboxGuestCommandWire(request: request).isWellFormed,
                "host-accepted request must be agent-acceptable: \(request.executable)"
            )
        }
    }

    // MARK: - vsock transport against the real agent

    private func channelToAgent(
        imageID: String = "img-1",
        executionEnabled: Bool = true
    ) throws -> SandboxGuestChannelClient {
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw XCTSkip("socketpair unavailable")
        }
        let session = SandboxGuestAgentSession(
            configuration: .init(
                agentVersion: "0.1.0",
                imageID: imageID,
                executionEnabled: executionEnabled,
                guestHome: "/tmp"
            )
        )
        let thread = Thread {
            session.serve(descriptor: pair[1])
            close(pair[1])
        }
        thread.stackSize = 1024 * 1024
        thread.start()
        return try SandboxGuestChannelClient(descriptor: pair[0])
    }

    func testVsockTransportReturnsBytesTheHostDecoderAccepts() async throws {
        let channel = try channelToAgent()
        defer { channel.close() }
        _ = try LumeGuestChannelReadinessProbe.run(
            channel: channel,
            expectedImageID: "img-1"
        )

        let transport = LumeGuestVsockTransport(channel: channel)
        let request = try request(arguments: ["seam"])
        let envelope = try await transport.deliver(
            virtualMachineName: "vm",
            prepared: try transport.prepare(request),
            guestTimeoutSeconds: request.timeoutSeconds
        )

        // The whole point of the seam: the bytes decode through the SAME host
        // decoder the SSH transport's bytes go through, so the journal cannot
        // tell which transport ran.
        let decoded = try LumeGuestCommandResultDecoder.decode(envelope)
        XCTAssertEqual(decoded.exitCode, 0)
        XCTAssertEqual(
            String(decoding: decoded.standardOutput, as: UTF8.self),
            "seam\n"
        )
        XCTAssertFalse(decoded.timedOut)
    }

    func testVsockTransportMapsAgentRefusalToACommandFailure() async throws {
        let channel = try channelToAgent(executionEnabled: false)
        defer { channel.close() }
        _ = try LumeGuestChannelReadinessProbe.run(
            channel: channel,
            expectedImageID: nil
        )

        let transport = LumeGuestVsockTransport(channel: channel)
        let request = try request()
        do {
            _ = try await transport.deliver(
                virtualMachineName: "vm",
                prepared: try transport.prepare(request),
                guestTimeoutSeconds: request.timeoutSeconds
            )
            XCTFail("execution is disabled; this must fail")
        } catch let error as SandboxRuntimeError {
            guard case .commandFailed(let command, _, let stderr) = error else {
                return XCTFail("expected a command failure, got \(error)")
            }
            XCTAssertEqual(command, "guest agent")
            XCTAssertTrue(stderr.contains("execution_disabled"), stderr)
        }
    }

    // MARK: - Readiness over the channel

    func testChannelReadinessReportsAgentIdentity() throws {
        let channel = try channelToAgent(imageID: "img-42")
        defer { channel.close() }
        let outcome = try LumeGuestChannelReadinessProbe.run(
            channel: channel,
            expectedImageID: "img-42"
        )
        XCTAssertEqual(outcome.agentVersion, "0.1.0")
        XCTAssertEqual(outcome.imageID, "img-42")
    }

    func testChannelReadinessFailsClosedOnAMismatchedImage() throws {
        // An agent reporting an image this host did not provision is not our
        // agent, so readiness must fail rather than warn.
        let channel = try channelToAgent(imageID: "img-other")
        defer { channel.close() }
        XCTAssertThrowsError(
            try LumeGuestChannelReadinessProbe.run(
                channel: channel,
                expectedImageID: "img-1"
            )
        ) { error in
            guard case SandboxRuntimeError.malformedOutput = error as? SandboxRuntimeError
            else {
                return XCTFail("expected a protocol violation, got \(error)")
            }
        }
    }

    func testChannelReadinessTimesOutRatherThanHanging() throws {
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw XCTSkip("socketpair unavailable")
        }
        defer { close(pair[1]) }
        let channel = try SandboxGuestChannelClient(descriptor: pair[0])
        defer { channel.close() }

        let started = Date()
        XCTAssertThrowsError(
            try LumeGuestChannelReadinessProbe.run(
                channel: channel,
                expectedImageID: nil,
                timeout: 1
            )
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}
