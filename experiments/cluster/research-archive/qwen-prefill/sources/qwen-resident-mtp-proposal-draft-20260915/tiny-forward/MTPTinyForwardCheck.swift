import Foundation
import MLX
@_spi(Cluster) import MLXLLM
import MLXLMCommon

/// Build-only private test overlay; no product or worker path calls this SPI.
@_spi(ClusterTesting) public enum MTPTinyForwardCheck {
    public static func run() throws -> Data {
        try MLX.withError { native in
            do { return try perform(check: native.check) }
            catch { try native.check(); throw error }
        }
    }

    private static func perform(check: () throws -> Void) throws -> Data {
        func require(_ value: Bool, _ message: String) throws {
            try check(); guard value else { throw ProbeError(message) }
        }
        func difference(_ left: MLXArray, _ right: MLXArray) throws -> Float {
            eval(left, right); try check()
            try require(left.shape == right.shape, "Tiny numeric comparison shape differs")
            let a = left.asType(.float32).asArray(Float.self), b = right.asType(.float32).asArray(Float.self)
            try check(); try require(a.allSatisfy(\.isFinite) && b.allSatisfy(\.isFinite), "Tiny forward is nonfinite")
            return zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
        }
        let loaded = try MTPTinyModel.target(check: check), plan = loaded.plan
        let profile = try QwenLayerStageGenerationProfile(identifier: "fabricated-tiny-MTP", vocabularySize: 128,
            hiddenSize: 64, activationDType: "float32", maximumPromptTokens: 5,
            maximumChunkTokens: 2, maximumOutputTokens: 4, maximumContextTokens: 9)
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: [1, 2, 3, 4, 5], chunkSize: 2, outputCount: 4, stopTokenIDs: [])
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: loaded.receipt.sourceConfigurationSHA256,
            artifactAggregateSHA256: loaded.receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: loaded.receipt.storageCommitmentSHA256,
            planFingerprint: plan.fingerprint, producerStageFingerprint: plan.stages[0].fingerprint)
        let fake = sha256(Data("tiny-build-only".utf8))
        let agreement = try QwenLayerStageGenerationAgreement(request: request, membershipEpoch: UUID(), source: source,
            consumerStageFingerprint: plan.stages[1].fingerprint, rankBuildSHA256: [fake, fake], numericalPolicySHA256: fake)
        let generation = QwenLayerStageGenerationControl(agreement: agreement)
        let control = try QwenResidentMTPProposalControl(agreement: agreement)
        let ordinary = try QwenLayerStageSession(stage: loaded, plan: plan, generationRequest: request)
        let captured = try QwenLayerStageSession(stage: loaded, plan: plan, generationRequest: request)
        let assistant = try MTPTinyModel.assistant(target: loaded, check: check)
        let chunked = assistant.makeRequestState(), whole = assistant.makeRequestState()
        defer {
            assistant.discardRound(requestState: chunked); assistant.releaseRequestState(chunked)
            assistant.discardRound(requestState: whole); assistant.releaseRequestState(whole)
            try? ordinary.cancel(); try? captured.cancel()
        }
        try assistant.configureRequestState(chunked, maximumSequenceLength: request.maximumTokens)
        try assistant.configureRequestState(whole, maximumSequenceLength: request.maximumTokens)
        var hiddenRows = [MLXArray](), finalLogits: MLXArray?, lastPacket: QwenLayerStageGenerationBoundaryPacket?
        var largestOutputDifference: Float = 0
        while control.phase == .observing {
            let expected = try generation.beginFrame(), frame = expected.frame
            let end = frame.tokenOffset + frame.tokenCount
            let tokens = Array(request.promptTokenIDs[frame.tokenOffset..<end])
            let residual = MLXArray((0..<(frame.tokenCount * 64)).map { i in
                Float(((frame.tokenOffset * 64 + i) * 11) % 37 - 18) * 0.007
            }).reshaped([1, frame.tokenCount, 64])
            eval(residual); try check()
            let payload = sha256(residual.asData().data)
            let incoming = QwenLayerStageBoundary(requestFingerprint: request.fingerprint,
                sourceConfigurationSHA256: source.sourceConfigurationSHA256,
                artifactAggregateSHA256: source.artifactAggregateSHA256,
                storageCommitmentSHA256: source.storageCommitmentSHA256,
                planFingerprint: plan.fingerprint, producerStageFingerprint: plan.stages[0].fingerprint,
                frame: frame, tokenIDsSHA256: QwenLayerStageBoundary.tokenHash(tokens), payloadSHA256: payload, array: residual)
            let old = try ordinary.prefillChunk(tokens, offset: frame.tokenOffset, final: frame.finalPromptChunk,
                incoming: incoming, check: check)
            let new = try captured.prefillChunkCapturingMTP(tokens, offset: frame.tokenOffset, final: frame.finalPromptChunk,
                incoming: incoming, check: check)
            let oldValue: MLXArray, newValue: MLXArray
            switch old {
            case .logits(let value), .evaluationHandle(let value): oldValue = value
            case .hidden: throw ProbeError("Final stage returned a producer boundary")
            }
            switch new.output {
            case .logits(let value), .evaluationHandle(let value): newValue = value
            case .hidden: throw ProbeError("Captured final stage returned a producer boundary")
            }
            largestOutputDifference = max(largestOutputDifference, try difference(oldValue, newValue))
            try require(largestOutputDifference <= 0.00001, "Captured target output differs from ordinary path")
            let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: payload)
            try generation.acknowledgeFrame(rank: 0, packet: packet, nativeCommittedTokens: end)
            try generation.acknowledgeFrame(rank: 1, packet: packet, nativeCommittedTokens: captured.committedTokens)
            try control.observe(frame: frame, tokenIDs: tokens, generation: generation)
            let hidden = try new.committed.takeHidden(); hiddenRows.append(hidden)
            assistant.observeCommittedTarget(.init(tokens: MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count]),
                hidden: hidden), requestState: chunked)
            eval(assistant.evaluationTargets(for: chunked)); try check()
            try require(chunked.committedInputCount == end - 1 && chunked.stagedInputCount == 0,
                "Chunked assistant pairing frontier differs")
            lastPacket = packet
            if frame.finalPromptChunk { finalLogits = newValue }
        }
        let allHidden = concatenated(hiddenRows, axis: 1)
        let allTokens = MLXArray(request.promptTokenIDs.map(Int32.init)).reshaped([1, request.promptCount])
        assistant.observeCommittedTarget(.init(tokens: allTokens, hidden: allHidden), requestState: whole)
        eval(assistant.evaluationTargets(for: whole)); try check()
        try require(whole.committedInputCount == 4 && chunked.committedInputCount == 4, "Trusted history must omit unconsumed seed")
        let seedArray = argMax(finalLogits!, axis: -1).asType(.int32)
        eval(seedArray); try check(); let seed = Int(seedArray.asArray(Int32.self)[0])
        let selected = try QwenLayerStageGenerationTokenPacket(agreement: agreement,
            boundaryFingerprint: lastPacket!.fingerprint, previousTokenChainSHA256: generation.tokenChainSHA256,
            ordinal: 0, committedTokens: 5, tokenID: seed)
        for rank in [0, 1] { try generation.acknowledgeToken(rank: rank, packet: selected) }
        _ = try generation.takeCommittedToken()
        let decision = try generation.decide(continueRequested: true)
        for rank in [0, 1] { try generation.acknowledgeDecision(rank: rank, packet: decision) }
        try control.begin(generation: generation, roundID: UUID())
        let carry = allHidden[0..., 4..<5, 0...], token = MLXArray([Int32(seed)]).reshaped([1, 1])
        let a = assistant.draftStep(tokens: token, hidden: carry, shortlist: nil, requestState: chunked)
        let b = assistant.draftStep(tokens: token, hidden: carry, shortlist: nil, requestState: whole)
        eval([a.tokens, a.hidden, b.tokens, b.hidden] + assistant.evaluationTargets(for: chunked) + assistant.evaluationTargets(for: whole))
        try check()
        try require(a.tokens.asArray(Int32.self) == b.tokens.asArray(Int32.self), "Chunked and whole history propose different tokens")
        let hiddenDifference = try difference(a.hidden, b.hidden)
        try require(hiddenDifference <= 0.00001 && chunked.committedInputCount == 5 && whole.committedInputCount == 5,
            "Proposal hidden or consumed-seed frontier differs")
        let proposal = try control.proposed(Int(a.tokens.asArray(Int32.self)[0]))
        try require(!proposal.accepted && captured.committedTokens == 5 && ordinary.committedTokens == 5,
            "Proposal advanced target or published acceptance")
        assistant.discardRound(requestState: chunked); assistant.discardRound(requestState: whole)
        try control.discarded()
        assistant.releaseRequestState(chunked); assistant.releaseRequestState(whole)
        try ordinary.cancel(); try captured.cancel(); try check()
        try require(chunked.materializedBytes == 0 && whole.materializedBytes == 0
            && assistant.evaluationTargets(for: chunked).isEmpty && assistant.evaluationTargets(for: whole).isEmpty
            && captured.isClosed && ordinary.isClosed, "Tiny request roots did not retire")
        return try JSONSerialization.data(withJSONObject: ["fixture": "fabricated-tiny-final-rank",
            "promptTokens": 5, "targetFrontier": 5, "unacceptedProposal": proposal.proposedTokenID,
            "maximumTargetOutputDifference": largestOutputDifference, "proposalHiddenDifference": hiddenDifference,
            "targetVerificationExecuted": false, "registeredResourceGateExercised": false], options: [.sortedKeys])
    }
}
