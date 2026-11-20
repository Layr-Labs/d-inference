import Foundation
import Network

extension CoordinatorClient {
    internal func installNativePairMember(_ control: NativePairMemberControl) throws {
        guard config.executionRole == .clusterMember, !sessionRegistered, nwConnection == nil,
              nativePairMember == nil, config.hardware.chipName == control.installation.chip, config.models.contains(where: { $0.id == control.installation.policy.model }),
              ModelRuntimeRequirements.isEligible(modelID: control.installation.policy.model,
                  available: config.runtimeCapabilities) else { throw NativePairMemberError.unconfigured }
        nativePairMember = control
    }
    internal func nativePairMemberAccepted() throws {
        guard let nativePairMember else { return }
        guard config.executionRole == .clusterMember, sessionRegistered,
              let negotiation = memberNegotiation, let connection = nwConnection,
              let scheme = URL(string: config.url)?.scheme?.lowercased(), ["wss", "https"].contains(scheme),
              case .ready = connection.state else { throw NativePairMemberError.inactive }
        // connectAndRun constructed NWParameters.tls and awaited its real ready
        // state; no X-Forwarded-Proto, supplied hash, or copied grant substitutes.
        let accepted = try nativePairMember.attach(nonce: negotiation.nonce, connection: connection)
        nativePairConnection = accepted
        try nativePairMember.publishConfiguration(on: accepted)
    }
    internal func detachNativePairMember() {
        if let nativePairConnection { nativePairMember?.detach(nativePairConnection) }
        nativePairConnection = nil
    }
    internal func consumeNativePairFrame(_ data: Data, sourceConnection: NWConnection?,
                                        receivedAt: UInt64, wallUnixNanoseconds: Int64) throws -> Bool {
        // The raw scanner below is authoritative for duplicate/unknown fields;
        // this small discriminator only selects the closed message decoder.
        guard config.executionRole == .clusterMember else { return false }
        struct Kind: Decodable { let type: String }
        guard let kind = try? JSONDecoder().decode(Kind.self, from: data), kind.type.hasPrefix("native_pair_") else { return false }
        guard config.executionRole == .clusterMember, sessionRegistered,
              let sourceConnection, sourceConnection === nwConnection,
              let nativePairMember, let nativePairConnection else { throw NativePairMemberError.inactive }
        let message = try NativePairMessage.decodePublicFrame(data)
        try nativePairMember.receive(message, on: nativePairConnection,
            receivedAt: receivedAt, wallUnixNanoseconds: wallUnixNanoseconds)
        return true
    }
}
