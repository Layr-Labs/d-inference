import Foundation

struct GenerationPairControlResult: Encodable {
    let cases: [String]
    let nativeDriverTypechecked = false
    let nativeModelExecutionPerformed = false
    let physicalTransportExecuted = false
}

/// Two independent controls exchange actual encoded packets and ACK digests.
/// This validates common history/retirement transitions; it does not run or
/// emulate MLX, Collective completion, peer fencing or a native request owner.
func checkGenerationPairControl() throws -> GenerationPairControlResult {
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProbeError("Generation pair fixture: " + message) }
    }
    func agreement() throws -> QwenLayerStageGenerationAgreement {
        let profile = try QwenLayerStageGenerationProfile(identifier: "pair-fixture", vocabularySize: 32,
            hiddenSize: 4, activationDType: "bfloat16", maximumPromptTokens: 5,
            maximumChunkTokens: 2, maximumOutputTokens: 4, maximumContextTokens: 9)
        let request = try QwenLayerStageGenerationRequest(profile: profile,
            requestID: UUID(uuidString: "20000000-0000-0000-0000-000000000099")!,
            promptTokenIDs: [1, 2, 3, 4, 5], chunkSize: 2, outputCount: 4, stopTokenIDs: [31])
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating: "a", count: 64),
            artifactAggregateSHA256: String(repeating: "b", count: 64), storageCommitmentSHA256: String(repeating: "c", count: 64),
            planFingerprint: String(repeating: "d", count: 64), producerStageFingerprint: String(repeating: "e", count: 64))
        return try .init(request: request, membershipEpoch: UUID(uuidString: "10000000-0000-0000-0000-000000000099")!,
            source: source, consumerStageFingerprint: String(repeating: "f", count: 64),
            rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
            numericalPolicySHA256: String(repeating: "3", count: 64))
    }
    let a = try agreement()
    var cases = [String]()
    for (name, stopOrdinal, eos, expectedReason) in [
        ("four greedy outputs agree after six frames", 3, false, QwenLayerStageGenerationFinishReason.length),
        ("EOS from final prefill avoids decode", 0, true, .eos),
        ("client stop after one decode is clean", 1, false, .clientStop)
    ] {
        let producer = QwenLayerStageGenerationControl(agreement: a)
        let consumer = QwenLayerStageGenerationControl(agreement: a)
        var published = [Int]()
        var finalDecision: QwenLayerStageGenerationDecisionPacket?
        while producer.phase == .frame {
            let pExpected = try producer.beginFrame(), cExpected = try consumer.beginFrame()
            let bytes = Data(repeating: UInt8(producer.completedFrames), count: pExpected.byteCount)
            let sent = try QwenLayerStageGenerationBoundaryPacket(expected: pExpected, payloadSHA256: sha256(bytes))
            try producer.acknowledgeFrame(rank: 0, packet: sent,
                nativeCommittedTokens: pExpected.frame.tokenOffset + pExpected.frame.tokenCount)
            let received = try QwenLayerStageGenerationBoundaryPacket.decode(sent.encoded(), expected: cExpected)
            try received.validatePayload(bytes)
            for rank in [0, 1] {
                try consumer.acknowledgeFrame(rank: rank, packet: received,
                    nativeCommittedTokens: cExpected.frame.tokenOffset + cExpected.frame.tokenCount)
            }
            let consumed = try QwenLayerStageGenerationAcknowledgement.values(agreement: a,
                phase: .boundaryConsumed, packetFingerprint: received.fingerprint, rank: 1)
            try QwenLayerStageGenerationAcknowledgement.validate(consumed, agreement: a,
                phase: .boundaryConsumed, packetFingerprint: sent.fingerprint, rank: 1)
            try producer.acknowledgeFrame(rank: 1, packet: sent,
                nativeCommittedTokens: pExpected.frame.tokenOffset + pExpected.frame.tokenCount)
            try require(producer.committedTokens == consumer.committedTokens, "frame frontier split")
            guard producer.phase == .token else { continue }
            let ordinal = consumer.selectedTokenCount
            let selected = eos && ordinal == stopOrdinal ? 31 : 8 + ordinal
            let token = try QwenLayerStageGenerationTokenPacket(agreement: a, boundaryFingerprint: received.fingerprint,
                previousTokenChainSHA256: consumer.tokenChainSHA256, ordinal: ordinal,
                committedTokens: consumer.committedTokens, tokenID: selected)
            try consumer.acknowledgeToken(rank: 1, packet: token)
            let returned = try QwenLayerStageGenerationTokenPacket.decode(token.encoded(), agreement: a,
                boundaryFingerprint: sent.fingerprint, previousTokenChainSHA256: producer.tokenChainSHA256,
                ordinal: producer.selectedTokenCount, committedTokens: producer.committedTokens)
            for rank in [1, 0] { try producer.acknowledgeToken(rank: rank, packet: returned) }
            let accepted = try QwenLayerStageGenerationAcknowledgement.values(agreement: a,
                phase: .tokenAccepted, packetFingerprint: returned.fingerprint, rank: 0)
            try QwenLayerStageGenerationAcknowledgement.validate(accepted, agreement: a,
                phase: .tokenAccepted, packetFingerprint: token.fingerprint, rank: 0)
            try consumer.acknowledgeToken(rank: 0, packet: token)
            published.append(try producer.takeCommittedToken())
            try require(try consumer.takeCommittedToken() == selected, "agreed scalar changed")
            let decision = try producer.decide(continueRequested: ordinal < stopOrdinal || eos)
            try producer.acknowledgeDecision(rank: 0, packet: decision)
            let delivered = try QwenLayerStageGenerationDecisionPacket.decode(decision.encoded(), agreement: a, token: token)
            let local = try consumer.decide(continueRequested: delivered.content.decision == .proceed)
            try require(local.content == delivered.content, "stop classification split")
            for rank in [0, 1] { try consumer.acknowledgeDecision(rank: rank, packet: delivered) }
            let decisionAck = try QwenLayerStageGenerationAcknowledgement.values(agreement: a,
                phase: .decisionAccepted, packetFingerprint: delivered.fingerprint, rank: 1)
            try QwenLayerStageGenerationAcknowledgement.validate(decisionAck, agreement: a,
                phase: .decisionAccepted, packetFingerprint: decision.fingerprint, rank: 1)
            try producer.acknowledgeDecision(rank: 1, packet: decision)
            try require(producer.tokenChainSHA256 == consumer.tokenChainSHA256, "selected history split")
            finalDecision = decision
        }
        try require(producer.finishReason == expectedReason && consumer.finishReason == expectedReason,
            "clean stop differs")
        try require(published.count == stopOrdinal + 1 && producer.committedTokens == 5 + stopOrdinal,
            "early stop allocated extra forward")
        guard let finalDecision else { throw ProbeError("Pair fixture has no decision") }
        try producer.acknowledgeRetirement(rank: 0, disposition: .retired)
        try consumer.acknowledgeRetirement(rank: 1, disposition: .retired)
        try require(!producer.isRetired && !consumer.isRetired, "local cleanup became pair cleanup")
        for (control, peer) in [(producer, 1), (consumer, 0)] {
            let ack = try QwenLayerStageGenerationAcknowledgement.values(agreement: a,
                phase: .requestRetired, packetFingerprint: finalDecision.fingerprint, rank: peer)
            try QwenLayerStageGenerationAcknowledgement.validate(ack, agreement: a,
                phase: .requestRetired, packetFingerprint: finalDecision.fingerprint, rank: peer)
            try control.acknowledgeRetirement(rank: peer, disposition: .retired)
            try require(control.isRetired && !control.isFailed, "pair did not retire cleanly")
        }
        cases.append(name)
    }
    let failed = QwenLayerStageGenerationControl(agreement: a)
    _ = try failed.beginFrame()
    failed.cancel()
    try failed.acknowledgeRetirement(rank: 0, disposition: .retired)
    try require(!failed.isRetired, "local failed cleanup implied peer fence")
    try failed.acknowledgeRetirement(rank: 1, disposition: .fenced)
    try require(failed.isRetired && failed.isFailed && failed.finishReason == nil, "fence erased failed status")
    cases.append("mid-frame cancel requires distinct local retirement and peer fence")

    let fp = String(repeating: "a", count: 64)
    try require(QwenLongPrefillReadinessMaterial.request(agreementFingerprint: fp).digest
        == sha256(Data(("qwen-profiled-prefill-readiness-v1|" + fp).utf8)), "old request domain changed")
    try require(QwenLongPrefillReadinessMaterial.residentCohort(agreementFingerprint: fp).digest
        == sha256(Data(("qwen-long-prefill-resident-cohort-readiness-v1|" + fp).utf8)), "old cohort domain changed")
    let new = QwenLongPrefillReadinessMaterial.generation(agreementFingerprint: fp).digest
    try require(new != QwenLongPrefillReadinessMaterial.request(agreementFingerprint: fp).digest
        && new != QwenLongPrefillReadinessMaterial.residentCohort(agreementFingerprint: fp).digest, "generation domain aliased")
    cases.append("generation readiness domain preserves both existing domains")
    return .init(cases: cases)
}
