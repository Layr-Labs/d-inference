import Foundation
import Network
import ProviderAppAttest

/// A reply to one App Attest request on its originating transport. Sending does
/// not acknowledge delivery or grant local authorization.
public struct AppAttestShadowReply: Sendable {
    private let deliver: @Sendable (AppAttestShadowPayload) async -> Void

    fileprivate init(deliver: @escaping @Sendable (AppAttestShadowPayload) async -> Void) {
        self.deliver = deliver
    }

    public func send(_ payload: AppAttestShadowPayload) async {
        await deliver(payload)
    }
}

extension CoordinatorClient {
    func appAttestShadowReply(to request: AppAttestShadowPayload, on connection: NWConnection) -> AppAttestShadowReply {
        AppAttestShadowReply { [weak self] response in
            await self?.sendAppAttestShadow(response, inReplyTo: request, on: connection)
        }
    }

    private func sendAppAttestShadow(_ response: AppAttestShadowPayload,
        inReplyTo request: AppAttestShadowPayload, on connection: NWConnection) {
        guard response.session == request.session, response.protocolVersion == request.protocolVersion,
              response.action == ["prepare": "ready", "attest": "attestation", "assert": "assertion"][request.action],
              let json = try? ProviderProtocolCodec.encodeProviderMessageString(.appAttestShadow(response)),
              json.utf8.count <= 64 * 1024 else { return }
        // This check and exact-socket submission share one actor turn. The
        // ProviderLoop may not yet have consumed this transport's disconnect.
        guard nwConnection === connection, sessionRegistered, !shutdownRequested, !Task.isCancelled else { return }
        sendTextFrame(json, on: connection, identifier: "app_attest_shadow")
    }
}
