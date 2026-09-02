import Foundation
import SandboxGuestProtocol
import SandboxRuntime

/// The vsock transport: structured frames to the signed guest agent over the
/// descriptor Lume patch 0005 hands the daemon.
///
/// Unlike the SSH transport this carries no shell, no launchd job, and no
/// shared credential — the channel itself is the authorisation, and the agent
/// runs the command under its own identity.
///
/// It returns the same raw envelope bytes as the SSH transport, so the journal
/// and the host decoder are unaffected by which one ran.
package struct LumeGuestVsockTransport: LumeGuestCommandTransport {
    /// Allows for the guest deadline plus the agent's own reporting.
    static let clientGraceSeconds: TimeInterval = 10

    let channel: SandboxGuestChannelClient

    package init(channel: SandboxGuestChannelClient) {
        self.channel = channel
    }

    package var description: String { "guest agent" }

    package func prepare(
        _ request: SandboxGuestCommandRequest
    ) throws -> LumeGuestPreparedCommand {
        let wire = SandboxGuestCommandWire(request: request)
        // The agent will refuse anything malformed, but failing here keeps an
        // unusable request from ever reaching the durable journal claim.
        guard wire.isWellFormed else {
            throw SandboxRuntimeError.unsupported(
                "guest command is not valid for the agent transport"
            )
        }
        return LumeGuestPreparedCommand(payload: .wire(wire))
    }

    package func deliver(
        virtualMachineName name: String,
        prepared: LumeGuestPreparedCommand,
        guestTimeoutSeconds: UInt32
    ) async throws -> Data {
        guard case .wire(let wire) = prepared.payload else {
            throw SandboxRuntimeError.unsupported(
                "the agent transport was handed a command prepared for another transport"
            )
        }

        // `channel.execute` polls the descriptor and blocks until the agent
        // answers. This function is `async` but awaits nothing else, so called
        // straight from the runtime actor it would hold that actor for the
        // whole command budget -- up to 910 seconds at the 900-second cap --
        // and stall every other operation on it, `stop` included. The SSH
        // transport has no such hazard because its runner is genuinely async.
        //
        // Detached rather than wrapped at the call site, so the transport is
        // correct however it is called. The client is `@unchecked Sendable`
        // and guards its descriptor with a lock, so moving the call off the
        // actor is safe.
        let channel = channel
        let timeout = TimeInterval(guestTimeoutSeconds) + Self.clientGraceSeconds
        do {
            return try await Task.detached(priority: .userInitiated) {
                try channel.execute(wire, timeout: timeout)
            }.value
        } catch let error as SandboxGuestChannelClient.ClientError {
            throw Self.mapped(error)
        }
    }

    /// Translates channel failures into the runtime's vocabulary so callers
    /// see the same error shapes regardless of transport.
    static func mapped(
        _ error: SandboxGuestChannelClient.ClientError
    ) -> SandboxRuntimeError {
        switch error {
        case .timedOut(let stage):
            return .operationTimedOut("guest agent \(stage)")
        case .agentFailure(let code, let message):
            return .commandFailed(
                command: "guest agent",
                exitCode: 1,
                stderr: "\(code): \(message)"
            )
        case .protocolViolation(let reason):
            return .malformedOutput("guest agent protocol violation: \(reason)")
        case .closed, .peerClosed, .readFailed, .writeFailed:
            return .unsupported("guest agent channel failed: \(error)")
        }
    }
}
