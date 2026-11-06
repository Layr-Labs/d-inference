import Foundation
import Testing
@_spi(Benchmark) @testable import DarkbloomClusterRuntime

@Suite struct QwenRecordScopeTests {
    @Test func actualWireExpectationsAndRetainedLookaheadScope() throws {
        func hash(_ value: String) -> String { String(repeating: value, count: 64) }
        // Metadata-only software profile. It grants no model/load authority.
        let profile = try QwenLayerStageGenerationProfile(identifier: "record-scope-fixture", vocabularySize: 32,
            hiddenSize: 32, activationDType: "bfloat16", maximumPromptTokens: 4,
            maximumChunkTokens: 2, maximumOutputTokens: 2, maximumContextTokens: 6)
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: [1, 2, 3, 4], chunkSize: 2, outputCount: 2, stopTokenIDs: [])
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: hash("1"),
            artifactAggregateSHA256: hash("2"), storageCommitmentSHA256: hash("3"),
            planFingerprint: hash("4"), producerStageFingerprint: hash("5"))
        let agreement = try QwenLayerStageGenerationAgreement(request: request, membershipEpoch: UUID(),
            source: source, consumerStageFingerprint: hash("6"), rankBuildSHA256: [hash("7"), hash("8")],
            numericalPolicySHA256: hash("9"), prefillPolicy: .oneChunkLookahead)
        let scopes = try QwenGenerationRecordScopes(agreement: agreement)
        let first = try QwenLayerStageGenerationBoundaryExpectation(agreement: agreement, frame: request.frame(sequence: 0),
            tokenIDs: [1, 2], previousTokenChainSHA256: agreement.initialTokenChainSHA256)
        let second = try QwenLayerStageGenerationBoundaryExpectation(agreement: agreement, frame: request.frame(sequence: 1),
            tokenIDs: [3, 4], previousTokenChainSHA256: agreement.initialTokenChainSHA256)
        let packet1 = try QwenLayerStageGenerationBoundaryPacket(expected: first, payloadSHA256: hash("a"))
        let packet2 = try QwenLayerStageGenerationBoundaryPacket(expected: second, payloadSHA256: hash("b"))
        let retained = try scopes.acknowledgement(.boundaryConsumed, fingerprint: packet1.fingerprint)
        let oldDigest = retained.context.expectationSHA256
        #expect(try scopes.header(first).context.expectationSHA256 != scopes.header(second).context.expectationSHA256)
        #expect(try scopes.payload(packet1).context.expectationSHA256 != scopes.payload(packet2).context.expectationSHA256)
        #expect(try scopes.acknowledgement(.boundaryConsumed, fingerprint: packet2.fingerprint).context.expectationSHA256 != oldDigest)
        #expect(retained.context.expectationSHA256 == oldDigest)
        let token = try QwenLayerStageGenerationTokenPacket(agreement: agreement, boundaryFingerprint: packet2.fingerprint,
            previousTokenChainSHA256: agreement.initialTokenChainSHA256, ordinal: 0, committedTokens: 4, tokenID: 12)
        let sender = try scopes.token(boundaryFingerprint: token.content.boundaryFingerprint,
            previousChain: token.content.previousTokenChainSHA256, ordinal: token.content.ordinal,
            committedTokens: token.content.committedTokens)
        let receiver = try scopes.token(boundaryFingerprint: packet2.fingerprint,
            previousChain: agreement.initialTokenChainSHA256, ordinal: 0, committedTokens: 4)
        #expect(sender.context.expectationSHA256 == receiver.context.expectationSHA256)
        #expect(try scopes.token(boundaryFingerprint: packet2.fingerprint,
            previousChain: agreement.initialTokenChainSHA256, ordinal: 1, committedTokens: 5).context.expectationSHA256 != sender.context.expectationSHA256)
        let decision = try QwenLayerStageGenerationDecisionPacket(agreement: agreement, token: token, continueRequested: false)
        #expect(try scopes.decision(tokenFingerprint: decision.content.tokenFingerprint).context.expectationSHA256
            == scopes.decision(tokenFingerprint: token.fingerprint).context.expectationSHA256)
        let retired = try scopes.acknowledgement(.requestRetired, fingerprint: decision.fingerprint)
        #expect(retired.context.type == .requestRetired)
        #expect(try scopes.acknowledgement(.decisionAccepted, fingerprint: decision.fingerprint).context.expectationSHA256 != retired.context.expectationSHA256)
    }
}
