import Foundation

/// Cancellation deliberately binds identity, not an equal frontier: a failed
/// peer may have committed farther locally. It never permits state reuse.
struct QwenLayerStageGenerationCancelPacket {
    enum Reason: String, Encodable { case callerCancelled, deadline, peerFailure, runtimeError }
    struct Content: Encodable, Equatable {
        let schema = "qwen_stage_generation_cancel_v1"
        let agreementFingerprint: String
        let membershipEpoch: String
        let requestFingerprint: String
        let reason: Reason
    }
    let content: Content
    let fingerprint: String

    init(agreement: QwenLayerStageGenerationAgreement, reason: Reason) throws {
        content = .init(agreementFingerprint: agreement.fingerprint,
            membershipEpoch: agreement.descriptor.membershipEpoch,
            requestFingerprint: agreement.request.fingerprint, reason: reason)
        fingerprint = try qwenGenerationFingerprint("cancel", content)
    }
    func encoded() throws -> Data { try canonicalJSONData(content) }
    static func decode(_ data: Data, agreement: QwenLayerStageGenerationAgreement) throws -> Self {
        let object = try QwenLayerStageGenerationWireJSON.object(data, maximumBytes: 4096)
        guard let spelling = object["reason"] as? String, let reason = Reason(rawValue: spelling) else {
            throw ProbeError("Unknown generation cancellation reason")
        }
        let result = try Self(agreement: agreement, reason: reason)
        try QwenLayerStageGenerationWireJSON.requireExact(object, result.content)
        return result
    }
}
