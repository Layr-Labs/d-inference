import Foundation
import Network

extension CoordinatorClient {
    func answerAppAttestResume(_ challenge: AppAttestResumeChallenge, on connection: NWConnection) {
        guard !shutdownRequested, !Task.isCancelled, sessionRegistered,
              nwConnection === connection, !appAttestResumeAnswered,
              let nonce = appAttestResumeNonce, let respond = appAttestResumeResponder else { return }
        do {
            // Intentionally synchronous: no Apple work or actor suspension between
            // validating this transport's nonce and writing to its exact socket.
            let response = try respond(challenge, nonce)
            guard response.id == challenge.id else { throw AppAttestResumeError.invalidBinding }
            let data = try ProviderProtocolCodec.encodeProviderMessage(.appAttestResume(response))
            try AppAttestResumeWire.validateMessage(data, action: "response")
            guard !shutdownRequested, !Task.isCancelled, nwConnection === connection,
                  appAttestResumeNonce == nonce, !appAttestResumeAnswered else { return }
            appAttestResumeAnswered = true
            // Never use the stable outbound router: an old response must not be
            // delivered to a replacement connection, even during teardown.
            sendTextFrame(String(decoding: data, as: UTF8.self), on: connection, identifier: "app_attest_resume")
        } catch {
            logger.warning("Rejected App Attest endpoint resumption challenge")
        }
    }
}
