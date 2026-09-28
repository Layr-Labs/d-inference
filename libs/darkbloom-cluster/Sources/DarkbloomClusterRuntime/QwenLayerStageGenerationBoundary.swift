import Foundation

/// Every receive allocation comes from this local expectation, never a packet.
struct QwenLayerStageGenerationBoundaryExpectation: Encodable, Equatable {
    let schema = "qwen_stage_generation_boundary_v1"
    let agreementFingerprint: String
    let membershipEpoch: String
    let requestFingerprint: String
    let frame: QwenLayerStageFrame
    let tokenIDsSHA256: String
    let previousTokenChainSHA256: String
    let shape: [Int]
    let dtype: String
    let byteCount: Int

    init(agreement: QwenLayerStageGenerationAgreement, frame: QwenLayerStageFrame,
         tokenIDs: [Int], previousTokenChainSHA256: String) throws {
        let request = agreement.request
        guard frame == (try request.frame(sequence: frame.sequence)),
              tokenIDs.count == frame.tokenCount,
              tokenIDs.allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }),
              qwenStageWireIsSHA256(previousTokenChainSHA256) else {
            throw ProbeError("Generation boundary differs from admitted geometry/tokens/history")
        }
        if frame.phase == .prefill {
            guard tokenIDs == Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)]),
                  previousTokenChainSHA256 == agreement.initialTokenChainSHA256 else {
                throw ProbeError("Generation prefill must use the exact admitted prompt")
            }
        }
        agreementFingerprint = agreement.fingerprint; membershipEpoch = agreement.descriptor.membershipEpoch
        requestFingerprint = request.fingerprint; self.frame = frame
        tokenIDsSHA256 = qwenGenerationTokenHash(tokenIDs)
        self.previousTokenChainSHA256 = previousTokenChainSHA256
        shape = [1, frame.tokenCount, request.profile.hiddenSize]; dtype = request.profile.activationDType
        byteCount = frame.tokenCount * request.profile.hiddenSize * (try qwenStageWireElementBytes(dtype))
    }
}

/// Header-only codec; the actual transport must validate payload bytes and
/// finish the consumer's native commit before its consumed acknowledgement.
struct QwenLayerStageGenerationBoundaryPacket {
    struct Content: Encodable {
        let expectation: QwenLayerStageGenerationBoundaryExpectation
        let payloadSHA256: String
    }
    static let maximumEncodedBytes = 16_384
    let content: Content
    let fingerprint: String
    private let data: Data

    init(expected: QwenLayerStageGenerationBoundaryExpectation, payloadSHA256: String) throws {
        guard qwenStageWireIsSHA256(payloadSHA256) else { throw ProbeError("Generation payload digest malformed") }
        content = .init(expectation: expected, payloadSHA256: payloadSHA256)
        data = try canonicalJSONData(content)
        guard data.count <= Self.maximumEncodedBytes else { throw ProbeError("Generation boundary packet too large") }
        fingerprint = try qwenGenerationFingerprint("boundary", content)
    }
    func encoded() -> Data { data }
    func validatePayload(_ bytes: Data) throws {
        guard bytes.count == content.expectation.byteCount, sha256(bytes) == content.payloadSHA256 else {
            throw ProbeError("Generation boundary payload length/digest differs")
        }
    }
    static func decode(_ data: Data, expected: QwenLayerStageGenerationBoundaryExpectation) throws -> Self {
        let object = try QwenLayerStageGenerationWireJSON.object(data, maximumBytes: maximumEncodedBytes)
        guard let digest = object["payloadSHA256"] as? String else { throw ProbeError("Generation payload digest missing") }
        let result = try Self(expected: expected, payloadSHA256: digest)
        try QwenLayerStageGenerationWireJSON.requireExact(object, result.content)
        return result
    }
}
