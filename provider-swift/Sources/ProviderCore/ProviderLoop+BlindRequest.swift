import Foundation
import MLXLMServer

// Blind requests: the client sealed the request body to this Mac's X25519 key
// and the coordinator relayed it unopened, under terms it signed
// (`BlindSignedTerms`). The handler checks the frame before it opens the body
// and the body against the terms, and refuses with a refusal signed by this
// Mac's Secure Enclave key.
extension ProviderLoop {
    /// Whether this Mac may open a blind request body now: its Secure Enclave
    /// signer is present, it serves alone (never as a cluster member), and
    /// its posture holds SIP on, Secure Boot full, debugger attachment denied
    /// and core dumps off. Inference always runs in this process, with no
    /// proxy (`registrationPrivacyCapabilities`).
    func blindServingPostureHolds() -> Bool {
        guard signer != nil, !isClusterMember, let posture = securityPosture else { return false }
        return posture.sipEnabled && posture.bootSecurity.secureBoot == .full
            && posture.antiDebugEnabled && posture.coreDumpsDisabled
    }

    /// What this Mac registers for blind requests: nil when it pins no
    /// request-signing key or cannot serve them (`blindServingPostureHolds`).
    func blindRequestRegistration() -> BlindRequestRegistration? {
        guard !blindRequestPins.isEmpty, blindServingPostureHolds() else { return nil }
        return BlindRequestRegistration(pins: blindRequestPins)
    }

    /// The checks of a blind frame before its body is opened.
    func admitBlindFrame(
        _ frame: BlindFrame, requestId: String, serviceReservationID: String?,
        senderPublicKey: Data, ciphertext: Data
    ) -> Result<VerifiedBlindFrame, BlindRefusal> {
        let checked = BlindFrameCheck.verify(
            frame, requestID: requestId, serviceReservationID: serviceReservationID,
            ownPublicKey: keyPair.publicKeyBytes, senderPublicKey: senderPublicKey, ciphertext: ciphertext,
            pins: blindRequestPins, now: Date())
        guard case .success(let verified) = checked else { return checked }
        guard blindServingPostureHolds() else { return .failure(verified.refusal(.posture)) }
        return .success(verified)
    }

    /// The checks of an opened blind body against its signed terms; a client
    /// nonce is served once.
    func checkBlindBody(_ inbound: InboundChatRequest, frame: VerifiedBlindFrame)
        -> Result<BlindServingTerms, BlindRefusal> {
        let request = inbound.request
        let facts = BlindBodyFacts(
            binding: inbound.extensions.blindBinding, model: request.model, maxTokens: request.maxTokens,
            maxCompletionTokens: inbound.extensions.maxCompletionTokens,
            declaresTools: request.tools?.isEmpty == false, hasMedia: MediaIngest.hasMedia(request))
        let now = Date()
        return BlindBodyCheck.check(facts, frame: frame, now: now) {
            servedBlindClientNonces.admitBlindClientNonce(frame.terms, now: now)
        }.mapError(frame.refusal)
    }

    /// The failure that answers a refused blind request, its refusal signed by
    /// `signer`. Without a signer, or when signing fails, it carries no refusal.
    nonisolated static func blindRefusalFailure(
        _ refusal: BlindRefusal, requestId: String, signer: (any AttestationSigner)?
    ) -> InferenceFailure {
        var failure = InferenceFailure(code: .blindRefused, statusCode: refusal.reason.statusCode)
        let statement = BlindStatement.refusal(
            requestID: requestId, signedRequestSHA256: refusal.signedRequestSHA256, reason: refusal.reason,
            issuedAtMs: Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)))
        failure.blindRefusal = signer.flatMap { try? statement.signed(by: $0) }
        return failure
    }
}
