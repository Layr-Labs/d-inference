import Foundation
import SandboxGuestProtocol
import SandboxRuntime

/// Readiness over the guest channel.
///
/// The bootstrap probe proves readiness by running `/usr/bin/true` through the
/// whole launchd wrapper, because reachability over SSH says nothing about
/// whether the executor works. Over vsock a completed handshake proves more
/// with less: the connection only exists because the agent bound its port, and
/// the handshake carries the agent version and image identity the host wanted
/// to verify anyway.
///
/// It also removes a dependency that matters later. The bootstrap probe is
/// gated on Lume's `sshAvailable`, which comes from scraping DHCP leases and
/// the ARP table for the guest's IP. A packet gateway replaces that networking,
/// so readiness has to stop depending on guest IP discovery before the gateway
/// can land.
package enum LumeGuestChannelReadinessProbe {
    /// A handshake should arrive as soon as the channel opens; this only
    /// bounds a peer that connects and then says nothing.
    package static let handshakeTimeoutSeconds: TimeInterval = 10

    package struct Outcome: Sendable, Equatable {
        package let agentVersion: String
        package let imageID: String
        /// What the agent said about its own executor. Not a readiness
        /// condition: an agent that refuses commands is still a valid,
        /// identity-proving peer. It decides transport selection, not trust.
        package let executionEnabled: Bool
    }

    /// Guest budget for the no-op that proves the executor.
    ///
    /// Ten seconds for the same reason the SSH probe uses ten: a guest a minute
    /// out of a fresh install sits near load 60, and a tighter budget measures
    /// load rather than readiness.
    package static let commandTimeoutSeconds: UInt32 = 10

    /// The one path guaranteed to exist on any guest, whatever its accounts
    /// are. The agent forces its own HOME regardless of what is asked for.
    static let probeWorkingDirectory = "/"

    /// Proves the agent will actually run something, not merely that it
    /// answered a handshake.
    ///
    /// 🛑 Requires the handshake to have been consumed already. The agent sends
    /// it as the first frame on the connection, so a command issued before
    /// `run(channel:expectedImageID:)` reads a handshake where it expects a
    /// result and fails as a protocol violation. Production satisfies this by
    /// construction: adoption validates the handshake before the channel is
    /// ever routed to.
    ///
    /// The handshake says the agent bound its port and is the image this host
    /// provisioned. It says nothing about whether the executor works, which is
    /// the whole thing the SSH probe existed to establish -- so readiness over
    /// the channel runs a real no-op and checks a real envelope. Dropping that
    /// would quietly weaken readiness while looking like an improvement.
    static func runCommandProbe(
        channel: SandboxGuestChannelClient
    ) async -> LumeCredentialedGuestReadinessProbe.Readiness {
        let transport = LumeGuestVsockTransport(channel: channel)
        let request: SandboxGuestCommandRequest
        do {
            request = try SandboxGuestCommandRequest(
                idempotencyKey: UUID(),
                executable: "/usr/bin/true",
                workingDirectory: probeWorkingDirectory,
                timeoutSeconds: commandTimeoutSeconds
            )
        } catch {
            return .notReady("the readiness command could not be built: \(error)")
        }

        let envelope: Data
        do {
            envelope = try await transport.deliver(
                virtualMachineName: "",
                prepared: try transport.prepare(request),
                guestTimeoutSeconds: commandTimeoutSeconds
            )
        } catch {
            return .notReady("the agent did not serve a command: \(error)")
        }

        guard let result = try? LumeGuestCommandResultDecoder.decode(envelope)
        else {
            return .notReady("the agent returned no decodable result envelope")
        }
        guard !result.timedOut else {
            return .notReady(
                "the agent's command hit its \(commandTimeoutSeconds)s deadline"
            )
        }
        guard result.exitCode == 0 else {
            return .notReady("the agent's command exited \(result.exitCode)")
        }
        return .ready
    }

    /// Returns the agent's identity, or throws if it cannot be trusted.
    ///
    /// A handshake that does not validate is a readiness failure, never a
    /// warning: an agent reporting an unexpected image or protocol version is
    /// not the agent this host provisioned.
    package static func run(
        channel: SandboxGuestChannelClient,
        expectedImageID: String?,
        timeout: TimeInterval = handshakeTimeoutSeconds
    ) throws -> Outcome {
        do {
            let handshake = try channel.handshake(
                expectedImageID: expectedImageID,
                timeout: timeout
            )
            return Outcome(
                agentVersion: handshake.agentVersion,
                imageID: handshake.imageID,
                executionEnabled: handshake.executionEnabled
            )
        } catch let error as SandboxGuestChannelClient.ClientError {
            throw LumeGuestVsockTransport.mapped(error)
        }
    }
}
