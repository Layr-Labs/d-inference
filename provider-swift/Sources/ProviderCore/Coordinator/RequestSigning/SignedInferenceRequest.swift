import Foundation

/// The payload of `signed_request`: every outer field a provider acts on,
/// plus the values that bind the request to one provider and one sealed body.
/// It is decoded from the verified bytes only, never re-encoded to compare.
/// An advisory field that fails to decode, or is empty or zero, reads as absent.
public struct SignedInferenceRequest: Decodable, Sendable, Equatable {
    public let issuedAtMs: Int64
    public let requestID: String
    public let serviceReservationID: String?
    /// The build the sealed body asks for.
    public let model: String
    /// Base64 of the provider's X25519 key the body is sealed to.
    public let recipientPublicKey: String
    /// Base64 of SHA-256 over the raw sender key followed by the raw ciphertext.
    public let sealedBodySHA256: String
    public let firstContentBudgetMs: Int64?
    public let promptWork: PromptWork?
    public let cacheReceiptNonce: String?
    public let cacheScope: String?
    public let prefixCacheProtocol: Int?
    public let cacheReceiptBoundaryMode: String?
    public let cacheRepeatedPrefixTokens: Int?
    public let toolSchemaMetadataProtocol: Int?
    public let gemmaPromptContract: Int?
    /// The coordinator-blind terms (`BlindSignedTerms`); present only on a
    /// blind request. Nil when absent or malformed.
    public let blind: BlindSignedTerms?
    /// Whether the payload has a `blind` member at all, decodable or not.
    public let hasBlindMember: Bool

    enum CodingKeys: String, CodingKey {
        case issuedAtMs = "issued_at_ms"
        case requestID = "request_id"
        case serviceReservationID = "service_reservation_id"
        case model
        case recipientPublicKey = "recipient_public_key"
        case sealedBodySHA256 = "sealed_body_sha256"
        case firstContentBudgetMs = "first_content_budget_ms"
        case promptWork = "prompt_work"
        case cacheReceiptNonce = "cache_receipt_nonce"
        case cacheScope = "cache_scope"
        case prefixCacheProtocol = "prefix_cache_protocol"
        case cacheReceiptBoundaryMode = "cache_receipt_boundary_mode"
        case cacheRepeatedPrefixTokens = "cache_repeated_prefix_tokens"
        case toolSchemaMetadataProtocol = "tool_schema_metadata_protocol"
        case gemmaPromptContract = "gemma_prompt_contract"
        case blind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issuedAtMs = try container.decode(Int64.self, forKey: .issuedAtMs)
        requestID = try container.decode(String.self, forKey: .requestID)
        serviceReservationID = try container.decodeIfPresent(String.self, forKey: .serviceReservationID)
        model = try container.decode(String.self, forKey: .model)
        recipientPublicKey = try container.decode(String.self, forKey: .recipientPublicKey)
        sealedBodySHA256 = try container.decode(String.self, forKey: .sealedBodySHA256)
        firstContentBudgetMs = try container.decodeIfPresent(Int64.self, forKey: .firstContentBudgetMs)
        promptWork = (try? container.decodeIfPresent(PromptWork.self, forKey: .promptWork)).flatMap { $0 }
        cacheReceiptNonce = try container.decodeIfPresent(String.self, forKey: .cacheReceiptNonce)
        cacheScope = (try? container.decodeIfPresent(String.self, forKey: .cacheScope))?.flatMap { $0.isEmpty ? nil : $0 }
        prefixCacheProtocol = try container.decodeIfPresent(Int.self, forKey: .prefixCacheProtocol)
        cacheReceiptBoundaryMode = try container.decodeIfPresent(String.self, forKey: .cacheReceiptBoundaryMode)
        cacheRepeatedPrefixTokens = try container.decodeIfPresent(Int.self, forKey: .cacheRepeatedPrefixTokens)
        toolSchemaMetadataProtocol = try container.decodeIfPresent(Int.self, forKey: .toolSchemaMetadataProtocol)
        gemmaPromptContract = (try? container.decodeIfPresent(Int.self, forKey: .gemmaPromptContract))?
            .flatMap { $0 == 0 ? nil : $0 }
        blind = (try? container.decodeIfPresent(BlindSignedTerms.self, forKey: .blind)).flatMap { $0 }
        hasBlindMember = container.contains(.blind)
    }

    /// The payload's bindings against the frame it arrived in, and the
    /// provider and sealed body it is for.
    func refusal(
        requestID frameRequestID: String, serviceReservationID frameReservationID: String?,
        recipientPublicKey ownKey: Data, sealedBodySHA256 actualDigest: Data
    ) -> CoordinatorRequestJWS.Refusal? {
        guard !requestID.isEmpty, requestID == frameRequestID, !model.isEmpty,
              serviceReservationID == frameReservationID,
              let recipient = Data(base64Encoded: recipientPublicKey), recipient.count == 32,
              let digest = Data(base64Encoded: sealedBodySHA256), digest.count == 32
        else { return .badPayload }
        guard recipient == ownKey else { return .wrongRecipient }
        guard digest == actualDigest else { return .wrongBody }
        return nil
    }
}
