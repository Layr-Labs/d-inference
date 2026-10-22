import Foundation

/// Local semantic joins only. The immutable request scope is shared by every
/// operation; record counters belong to the Collective session, not this value.
struct QwenGenerationRecordScopes {
    let request: CollectiveRequestScope

    init(agreement: QwenLayerStageGenerationAgreement) throws {
        guard let epoch = UUID(uuidString: agreement.descriptor.membershipEpoch) else {
            throw ProbeError("Generation record scope lacks its admitted epoch")
        }
        request = try .init(requestID: agreement.request.requestID, epoch: epoch,
            planSHA256: agreement.descriptor.planFingerprint, agreementSHA256: agreement.fingerprint)
    }

    func readiness() throws -> CollectiveOperationScope {
        try request.operation(.requestAgreement, metadata: Data("generation-readiness".utf8))
    }
    func header(_ expected: QwenLayerStageGenerationBoundaryExpectation) throws -> CollectiveOperationScope {
        try request.operation(.residualHeader, metadata: canonicalJSONData(expected))
    }
    func payload(_ packet: QwenLayerStageGenerationBoundaryPacket) throws -> CollectiveOperationScope {
        // Receiver uses this only after the header's AEAD and exact local
        // expectation check. No unauthenticated packet determines allocation.
        try request.operation(.residualPayload, metadata: Data(packet.fingerprint.utf8))
    }
    func token(boundaryFingerprint: String, previousChain: String, ordinal: Int,
               committedTokens: Int) throws -> CollectiveOperationScope {
        struct Expected: Encodable {
            let boundaryFingerprint: String
            let previousChain: String
            let ordinal: Int
            let committedTokens: Int
        }
        guard qwenStageWireIsSHA256(boundaryFingerprint), qwenStageWireIsSHA256(previousChain),
              (0..<4096).contains(ordinal), (1...32_768).contains(committedTokens) else {
            throw ProbeError("Generation token record context exceeds its admitted domain")
        }
        return try request.operation(.targetToken, metadata: canonicalJSONData(Expected(
            boundaryFingerprint: boundaryFingerprint, previousChain: previousChain,
            ordinal: ordinal, committedTokens: committedTokens)))
    }
    func decision(tokenFingerprint: String) throws -> CollectiveOperationScope {
        guard qwenStageWireIsSHA256(tokenFingerprint) else { throw ProbeError("Generation decision record context is malformed") }
        return try request.operation(.generationDecision, metadata: Data(tokenFingerprint.utf8))
    }
    func acknowledgement(_ phase: QwenLayerStageGenerationAcknowledgement.Phase,
                         fingerprint: String) throws -> CollectiveOperationScope {
        guard qwenStageWireIsSHA256(fingerprint) else { throw ProbeError("Generation acknowledgement record context is malformed") }
        return try request.operation(phase == .requestRetired ? .requestRetired : .acknowledgement,
            metadata: Data((phase.rawValue + "|" + fingerprint).utf8))
    }
}
