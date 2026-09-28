import Foundation

/// Target-selected scalar metadata. Construction does not perform argmax or
/// prove native evaluation; only the last-stage owner may produce this packet.
struct QwenLayerStageGenerationTokenPacket {
    struct Content: Encodable, Equatable {
        let schema = "qwen_stage_generation_token_v1"
        let agreementFingerprint: String
        let membershipEpoch: String
        let requestFingerprint: String
        let boundaryFingerprint: String
        let previousTokenChainSHA256: String
        let ordinal: Int
        let committedTokens: Int
        let tokenID: Int
    }
    static let maximumEncodedBytes = 4096
    let content: Content
    let fingerprint: String
    let nextTokenChainSHA256: String

    init(agreement: QwenLayerStageGenerationAgreement, boundaryFingerprint: String,
         previousTokenChainSHA256: String, ordinal: Int, committedTokens: Int, tokenID: Int) throws {
        guard qwenStageWireIsSHA256(boundaryFingerprint), qwenStageWireIsSHA256(previousTokenChainSHA256),
              (0..<agreement.request.outputCount).contains(ordinal),
              committedTokens == agreement.request.promptCount + ordinal,
              (0..<agreement.request.profile.vocabularySize).contains(tokenID) else {
            throw ProbeError("Generation token differs from selected/committed bounds")
        }
        content = .init(agreementFingerprint: agreement.fingerprint, membershipEpoch: agreement.descriptor.membershipEpoch,
            requestFingerprint: agreement.request.fingerprint, boundaryFingerprint: boundaryFingerprint,
            previousTokenChainSHA256: previousTokenChainSHA256, ordinal: ordinal,
            committedTokens: committedTokens, tokenID: tokenID)
        fingerprint = try qwenGenerationFingerprint("token", content)
        nextTokenChainSHA256 = sha256(Data(("qwen-generation-token-chain-v1|" + previousTokenChainSHA256 + "|" + fingerprint).utf8))
    }
    func encoded() throws -> Data { try canonicalJSONData(content) }
    static func decode(_ data: Data, agreement: QwenLayerStageGenerationAgreement,
                       boundaryFingerprint: String, previousTokenChainSHA256: String,
                       ordinal: Int, committedTokens: Int) throws -> Self {
        let object = try QwenLayerStageGenerationWireJSON.object(data, maximumBytes: maximumEncodedBytes)
        guard let token = BoundedProbeInput.integer(object["tokenID"]) else { throw ProbeError("Generation token must be an integer") }
        let result = try Self(agreement: agreement, boundaryFingerprint: boundaryFingerprint,
            previousTokenChainSHA256: previousTokenChainSHA256, ordinal: ordinal, committedTokens: committedTokens, tokenID: token)
        try QwenLayerStageGenerationWireJSON.requireExact(object, result.content)
        return result
    }
}

enum QwenLayerStageGenerationDecision: String, Encodable { case proceed, eos, length, clientStop }

struct QwenLayerStageGenerationDecisionPacket {
    struct Content: Encodable, Equatable {
        let schema = "qwen_stage_generation_decision_v1"
        let agreementFingerprint: String
        let membershipEpoch: String
        let requestFingerprint: String
        let tokenFingerprint: String
        let tokenChainSHA256: String
        let selectedTokenCount: Int
        let decision: QwenLayerStageGenerationDecision
    }
    let content: Content
    let fingerprint: String

    init(agreement: QwenLayerStageGenerationAgreement, token: QwenLayerStageGenerationTokenPacket,
         continueRequested: Bool) throws {
        guard token.content.agreementFingerprint == agreement.fingerprint else { throw ProbeError("Generation decision request differs") }
        let decision: QwenLayerStageGenerationDecision
        if agreement.request.stopTokenIDs.contains(token.content.tokenID) { decision = .eos }
        else if token.content.ordinal + 1 == agreement.request.outputCount { decision = .length }
        else { decision = continueRequested ? .proceed : .clientStop }
        content = .init(agreementFingerprint: agreement.fingerprint, membershipEpoch: agreement.descriptor.membershipEpoch,
            requestFingerprint: agreement.request.fingerprint, tokenFingerprint: token.fingerprint,
            tokenChainSHA256: token.nextTokenChainSHA256, selectedTokenCount: token.content.ordinal + 1, decision: decision)
        fingerprint = try qwenGenerationFingerprint("decision", content)
    }
    func encoded() throws -> Data { try canonicalJSONData(content) }
    static func decode(_ data: Data, agreement: QwenLayerStageGenerationAgreement,
                       token: QwenLayerStageGenerationTokenPacket) throws -> Self {
        let object = try QwenLayerStageGenerationWireJSON.object(data, maximumBytes: 4096)
        guard let spelling = object["decision"] as? String,
              let decision = QwenLayerStageGenerationDecision(rawValue: spelling) else { throw ProbeError("Unknown generation decision") }
        let result = try Self(agreement: agreement, token: token, continueRequested: decision == .proceed)
        try QwenLayerStageGenerationWireJSON.requireExact(object, result.content)
        return result
    }
}

enum QwenLayerStageGenerationAcknowledgement {
    enum Phase: String { case boundaryReady, boundaryConsumed, tokenAccepted, decisionAccepted, requestRetired }
    static func values(agreement: QwenLayerStageGenerationAgreement, phase: Phase,
                       packetFingerprint: String, rank: Int) throws -> [Int32] {
        guard (0...1).contains(rank), qwenStageWireIsSHA256(packetFingerprint) else { throw ProbeError("Generation acknowledgement identity malformed") }
        let digest = sha256(Data(["qwen-generation-ack-v1", agreement.fingerprint, phase.rawValue,
            packetFingerprint, String(rank)].joined(separator: "|").utf8))
        return digest.utf8.map(Int32.init)
    }
    static func validate(_ values: [Int32], agreement: QwenLayerStageGenerationAgreement,
                         phase: Phase, packetFingerprint: String, rank: Int) throws {
        guard values == (try self.values(agreement: agreement, phase: phase, packetFingerprint: packetFingerprint, rank: rank)) else {
            throw ProbeError("Generation acknowledgement phase/rank/packet differs")
        }
    }
}
