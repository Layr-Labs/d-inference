// CoordinatorClient native-pair member binding. The member control is
// installed once, before the first connection, and outlives reconnects because
// it owns the member's native-owner obligation. Each connection gets its own
// attachment, made only after that connection's nonce-bound member acceptance
// on a real TLS transport and dropped at every connection boundary. An
// ordinary WebSocket acknowledgment, a supplied hash or a reconnect never
// activates or retains an attachment.

import Foundation
import Network

extension CoordinatorClient {
    /// Requires the member role, this Mac's chip and model, and the exact
    /// membership this client registers, so the registered `policy_sha256`
    /// always names the policy the control will require in a prepare frame.
    /// The existing signer and transport remain responsible for member
    /// identity; installing grants no trust or runtime approval.
    internal func installNativePairMember(_ control: NativePairMemberControl) throws {
        let installation = control.installation
        guard config.executionRole == .clusterMember, !sessionRegistered, nwConnection == nil,
              nativePairMember == nil, config.hardware.chipName == installation.chip,
              config.models.contains(where: { $0.id == installation.policy.model }),
              ModelRuntimeRequirements.isEligible(modelID: installation.policy.model,
                  available: config.runtimeCapabilities),
              let membership = try? installation.membership,
              config.clusterMembership == membership else { throw NativePairMemberError.unconfigured }
        nativePairMember = control
    }

    /// Called at this connection's member acceptance. The connection was built
    /// with `NWParameters.tls` and reached its real ready state; no forwarded
    /// header, supplied hash or copied grant substitutes for that.
    internal func nativePairMemberAccepted() throws {
        guard let nativePairMember else { return }
        guard config.executionRole == .clusterMember, sessionRegistered,
              let negotiation = memberNegotiation, let connection = nwConnection,
              let scheme = URL(string: config.url)?.scheme?.lowercased(), ["wss", "https"].contains(scheme),
              case .ready = connection.state else { throw NativePairMemberError.inactive }
        nativePairConnection = try nativePairMember.attach(nonce: negotiation.nonce, connection: connection)
    }

    /// Every connection boundary drops the attachment. Detaching cancels the
    /// session's native work independently of any signer or WebSocket write;
    /// the control keeps a committed obligation it could not release.
    internal func detachNativePairMember() {
        if let nativePairConnection { nativePairMember?.detach(nativePairConnection) }
        nativePairConnection = nil
    }

    /// Native-pair public frames bypass the ordinary coordinator-message codec:
    /// strict closed decode first, then the control's own epoch, generation and
    /// sequence checks. Returns false for every other frame. A native-pair
    /// frame that arrives with no attachment, from another connection, or
    /// fails either check throws; the caller drops the connection.
    internal func consumeNativePairFrame(_ data: Data, sourceConnection: NWConnection?,
                                        receivedAt: UInt64, wallUnixNanoseconds: Int64) throws -> Bool {
        guard config.executionRole == .clusterMember else { return false }
        // The closed decoder below is authoritative for duplicate and unknown
        // fields; this discriminator only selects it.
        struct Kind: Decodable { let type: String }
        guard let kind = try? JSONDecoder().decode(Kind.self, from: data),
              kind.type.hasPrefix("native_pair_") else { return false }
        guard sessionRegistered, let sourceConnection, sourceConnection === nwConnection,
              let nativePairMember, let nativePairConnection else { throw NativePairMemberError.inactive }
        let message = try NativePairMessage.decodePublicFrame(data)
        try nativePairMember.receive(message, on: nativePairConnection,
            receivedAt: receivedAt, wallUnixNanoseconds: wallUnixNanoseconds)
        return true
    }
}
