import Darwin
import Foundation
import SandboxGuestAgentCore
import SandboxGuestProtocol
import SandboxRuntime
import Testing

@testable import SandboxRuntimeLume

// The real host client against the real agent session, and the transport seam
// on top of both.
//
// swift-testing rather than XCTest so these actually run: XCTest has no
// linkable framework under Command Line Tools, so an XCTest file here could
// only ever be compile-checked.
//
// A socketpair stands in for the vsock connection, because AF_VSOCK can only be
// created inside a virtual machine. Everything above the socket family is the
// production code both sides use over vsock.

private func connectedPair() -> (host: Int32, guest: Int32)? {
    var pair = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
    return (pair[0], pair[1])
}

private func channelToAgent(
    imageID: String = "img-1",
    executionEnabled: Bool = false
) -> SandboxGuestChannelClient? {
    guard let pair = connectedPair() else { return nil }
    let session = SandboxGuestAgentSession(
        configuration: .init(
            agentVersion: "0.1.0",
            imageID: imageID,
            executionEnabled: executionEnabled,
            guestHome: "/tmp"
        )
    )
    let thread = Thread {
        session.serve(descriptor: pair.guest)
        close(pair.guest)
    }
    thread.stackSize = 1024 * 1024
    thread.start()
    return try? SandboxGuestChannelClient(descriptor: pair.host)
}

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

// MARK: - Channel client

@Test("the handshake carries the agent's identity")
func handshakeCarriesIdentity() throws {
    let client = try #require(channelToAgent(imageID: "img-42"))
    defer { client.close() }
    let handshake = try client.handshake(expectedImageID: "img-42", timeout: 5)
    #expect(handshake.agentVersion == "0.1.0")
    #expect(handshake.imageID == "img-42")
    #expect(handshake.protocolVersion == SandboxGuestHandshake.currentProtocolVersion)
}

@Test("a mismatched image identity is rejected")
func mismatchedImageIsRejected() throws {
    let client = try #require(channelToAgent(imageID: "img-test"))
    defer { client.close() }
    #expect(throws: SandboxGuestChannelClient.ClientError.self) {
        try client.handshake(expectedImageID: "a-different-image", timeout: 5)
    }
}

@Test("a well-formed command is refused while execution is disabled")
func commandRefusedWhileExecutionDisabled() throws {
    let client = try #require(channelToAgent())
    defer { client.close() }
    _ = try client.handshake(timeout: 5)

    var code: String?
    do {
        _ = try client.execute(
            SandboxGuestCommandWire(request: try request()),
            timeout: 5
        )
    } catch let error as SandboxGuestChannelClient.ClientError {
        if case .agentFailure(let failureCode, _) = error { code = failureCode }
    }
    #expect(code == "execution_disabled")
}

@Test("the agent re-validates rather than trusting the host")
func agentRevalidates() throws {
    let client = try #require(channelToAgent())
    defer { client.close() }
    _ = try client.handshake(timeout: 5)

    // A relative executable: the host would never construct this, so a refusal
    // proves the agent does not trust the channel.
    var code: String?
    do {
        _ = try client.execute(
            SandboxGuestCommandWire(
                idempotencyKey: UUID().uuidString,
                executable: "echo",
                arguments: [],
                environment: [:],
                workingDirectory: "/tmp",
                timeoutSeconds: 30
            ),
            timeout: 5
        )
    } catch let error as SandboxGuestChannelClient.ClientError {
        if case .agentFailure(let failureCode, _) = error { code = failureCode }
    }
    #expect(code == "invalid_request")
}

@Test("the handshake times out rather than hanging with no agent")
func handshakeTimesOut() throws {
    let pair = try #require(connectedPair())
    defer { close(pair.guest) }
    let client = try SandboxGuestChannelClient(descriptor: pair.host)
    defer { client.close() }

    let started = Date()
    #expect(throws: SandboxGuestChannelClient.ClientError.self) {
        try client.handshake(timeout: 1)
    }
    #expect(Date().timeIntervalSince(started) < 10, "the deadline must bound the wait")
}

@Test("an executed command returns a real envelope over the channel")
func executedCommandReturnsEnvelope() throws {
    let client = try #require(channelToAgent(executionEnabled: true))
    defer { client.close() }
    _ = try client.handshake(timeout: 5)

    let bytes = try client.execute(
        SandboxGuestCommandWire(
            idempotencyKey: UUID().uuidString,
            executable: "/bin/echo",
            arguments: ["channel"],
            environment: [:],
            workingDirectory: "/tmp",
            timeoutSeconds: 30
        ),
        timeout: 30
    )
    // Decoded through the REAL host decoder, not a second parser.
    let decoded = try LumeGuestCommandResultDecoder.decode(bytes)
    #expect(decoded.exitCode == 0)
    #expect(String(decoding: decoded.standardOutput, as: UTF8.self) == "channel\n")
    #expect(!decoded.timedOut)
}

// MARK: - Transport seam

@Test("the SSH transport preserves the bootstrap grace periods")
func sshTransportGracePeriods() {
    // Existing failure tests pin these numbers.
    #expect(LumeGuestSSHTransport.lumeGraceSeconds == 5)
    #expect(LumeGuestSSHTransport.hostGraceSeconds == 10)
}

@Test("the SSH transport keeps the error name callers assert on")
func sshTransportErrorName() {
    let transport = LumeGuestSSHTransport(
        runner: SandboxProcessRunner(),
        executable: URL(fileURLWithPath: "/usr/bin/true"),
        storagePath: "/tmp",
        environment: [:]
    )
    // `commandFailed(command: "lume ssh", ...)` is asserted verbatim elsewhere.
    #expect(transport.description == "lume ssh")
}

@Test("the SSH transport prepares the same encoded script as before")
func sshTransportPreparesSameScript() throws {
    let transport = LumeGuestSSHTransport(
        runner: SandboxProcessRunner(),
        executable: URL(fileURLWithPath: "/usr/bin/true"),
        storagePath: "/tmp",
        environment: [:]
    )
    let request = try request()
    guard case .encodedScript(let script) = try transport.prepare(request).payload else {
        Issue.record("SSH transport must prepare an encoded script")
        return
    }
    #expect(script == (try LumeGuestCommandEncoder.encode(request)))
}

@Test("a request converts to a wire form with a lowercased key")
func requestConvertsToWire() throws {
    // The bootstrap path lowercases the key when it reaches the guest; the wire
    // form must agree so a command sees the same value either way.
    let request = try request()
    let wire = SandboxGuestCommandWire(request: request)
    #expect(wire.idempotencyKey == request.idempotencyKey.uuidString.lowercased())
    #expect(wire.executable == request.executable)
    #expect(wire.arguments == request.arguments)
    #expect(wire.timeoutSeconds == request.timeoutSeconds)
    #expect(wire.isWellFormed)
}

@Test("every host-accepted request converts to a well-formed wire")
func hostAcceptedRequestsAreAgentAcceptable() throws {
    // The host validator must never admit something the agent then refuses, or
    // a legal request would fail only on the vsock transport.
    let cases = [
        try request(),
        try request(arguments: []),
        try request(environment: ["USER_DEFINED": "x"]),
        try request(timeoutSeconds: 1),
        try request(timeoutSeconds: 900),
        try request(arguments: Array(repeating: "a", count: 256)),
    ]
    for candidate in cases {
        #expect(SandboxGuestCommandWire(request: candidate).isWellFormed)
    }
}

@Test("the vsock transport returns bytes the host decoder accepts")
func vsockTransportReturnsDecodableBytes() async throws {
    let channel = try #require(channelToAgent(executionEnabled: true))
    defer { channel.close() }
    _ = try LumeGuestChannelReadinessProbe.run(channel: channel, expectedImageID: "img-1")

    let transport = LumeGuestVsockTransport(channel: channel)
    let request = try request(arguments: ["seam"])
    let envelope = try await transport.deliver(
        virtualMachineName: "vm",
        prepared: try transport.prepare(request),
        guestTimeoutSeconds: request.timeoutSeconds
    )

    // The point of the seam: these bytes go through the SAME host decoder the
    // SSH transport's bytes do, so the journal cannot tell which ran.
    let decoded = try LumeGuestCommandResultDecoder.decode(envelope)
    #expect(decoded.exitCode == 0)
    #expect(String(decoding: decoded.standardOutput, as: UTF8.self) == "seam\n")
    #expect(!decoded.timedOut)
}

@Test("the vsock transport maps an agent refusal to a command failure")
func vsockTransportMapsRefusal() async throws {
    let channel = try #require(channelToAgent(executionEnabled: false))
    defer { channel.close() }
    _ = try LumeGuestChannelReadinessProbe.run(channel: channel, expectedImageID: nil)

    let transport = LumeGuestVsockTransport(channel: channel)
    let request = try request()
    var seen: SandboxRuntimeError?
    do {
        _ = try await transport.deliver(
            virtualMachineName: "vm",
            prepared: try transport.prepare(request),
            guestTimeoutSeconds: request.timeoutSeconds
        )
    } catch let error as SandboxRuntimeError {
        seen = error
    }
    guard case .commandFailed(let command, _, let stderr) = seen else {
        Issue.record("expected a command failure, got \(String(describing: seen))")
        return
    }
    #expect(command == "guest agent")
    #expect(stderr.contains("execution_disabled"))
}

// MARK: - Readiness over the channel

@Test("channel readiness reports the agent's identity")
func channelReadinessReportsIdentity() throws {
    let channel = try #require(channelToAgent(imageID: "img-42"))
    defer { channel.close() }
    let outcome = try LumeGuestChannelReadinessProbe.run(
        channel: channel,
        expectedImageID: "img-42"
    )
    #expect(outcome.agentVersion == "0.1.0")
    #expect(outcome.imageID == "img-42")
}

@Test("channel readiness fails closed on a mismatched image")
func channelReadinessFailsClosed() throws {
    // An agent reporting an image this host did not provision is not our agent,
    // so readiness must fail rather than warn.
    let channel = try #require(channelToAgent(imageID: "img-other"))
    defer { channel.close() }
    #expect(throws: SandboxRuntimeError.self) {
        try LumeGuestChannelReadinessProbe.run(channel: channel, expectedImageID: "img-1")
    }
}

@Test("channel readiness times out rather than hanging")
func channelReadinessTimesOut() throws {
    let pair = try #require(connectedPair())
    defer { close(pair.guest) }
    let channel = try SandboxGuestChannelClient(descriptor: pair.host)
    defer { channel.close() }

    let started = Date()
    #expect(throws: SandboxRuntimeError.self) {
        try LumeGuestChannelReadinessProbe.run(
            channel: channel,
            expectedImageID: nil,
            timeout: 1
        )
    }
    #expect(Date().timeIntervalSince(started) < 10)
}
