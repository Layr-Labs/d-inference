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
