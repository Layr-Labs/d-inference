import Foundation

func fixtureAgreement(outputCount: Int = 4, policy: QwenResidentPrefillPolicy = .serial) throws -> QwenLayerStageGenerationAgreement {
    let profile = try QwenLayerStageGenerationProfile(identifier: "mtp-control-fixture", vocabularySize: 32,
        hiddenSize: 4, activationDType: "bfloat16", maximumPromptTokens: 5,
        maximumChunkTokens: 2, maximumOutputTokens: 4, maximumContextTokens: 9)
    let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
        promptTokenIDs: [1,2,3,4,5], chunkSize: 2, outputCount: outputCount, stopTokenIDs: [31])
    let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating:"a",count:64),
        artifactAggregateSHA256: String(repeating:"b",count:64), storageCommitmentSHA256: String(repeating:"c",count:64),
        planFingerprint: String(repeating:"d",count:64), producerStageFingerprint: String(repeating:"e",count:64))
    return try .init(request: request, membershipEpoch: UUID(), source: source,
        consumerStageFingerprint: String(repeating:"f",count:64), rankBuildSHA256: [String(repeating:"1",count:64),String(repeating:"2",count:64)],
        numericalPolicySHA256: String(repeating:"3",count:64), prefillPolicy: policy)
}

final class PairFixture {
    let agreement: QwenLayerStageGenerationAgreement
    let generation: QwenLayerStageGenerationControl
    let mtp: QwenResidentMTPProposalControl
    var lastBoundary: QwenLayerStageGenerationBoundaryPacket?
    init(outputCount: Int = 4) throws {
        agreement = try fixtureAgreement(outputCount: outputCount); generation = .init(agreement: agreement)
        mtp = try .init(agreement: agreement)
    }
    func frame(complete: Bool = true, corruptTokens: Bool = false) throws {
        let expected = try generation.beginFrame()
        let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: String(repeating:"0",count:64))
        let end = expected.frame.tokenOffset+expected.frame.tokenCount
        try generation.acknowledgeFrame(rank: 0, packet: packet, nativeCommittedTokens: end)
        if complete { try generation.acknowledgeFrame(rank: 1, packet: packet, nativeCommittedTokens: end) }
        var tokens = Array(agreement.request.promptTokenIDs[expected.frame.tokenOffset..<end])
        if corruptTokens { tokens[0] = 9 }
        try mtp.observe(frame: expected.frame, tokenIDs: tokens, generation: generation)
        lastBoundary = packet
    }
    func history() throws {
        while mtp.phase == .observing { try frame() }
    }
    func firstToken(_ token: Int = 8, continueRequested: Bool = true, decisionComplete: Bool = true) throws {
        let packet = try QwenLayerStageGenerationTokenPacket(agreement: agreement,
            boundaryFingerprint: lastBoundary!.fingerprint, previousTokenChainSHA256: generation.tokenChainSHA256,
            ordinal: 0, committedTokens: generation.committedTokens, tokenID: token)
        for rank in [0,1] { try generation.acknowledgeToken(rank: rank, packet: packet) }
        _ = try generation.takeCommittedToken()
        let decision = try generation.decide(continueRequested: continueRequested)
        try generation.acknowledgeDecision(rank: 0, packet: decision)
        if decisionComplete { try generation.acknowledgeDecision(rank: 1, packet: decision) }
    }
    func ready() throws { try history(); try firstToken() }
}

