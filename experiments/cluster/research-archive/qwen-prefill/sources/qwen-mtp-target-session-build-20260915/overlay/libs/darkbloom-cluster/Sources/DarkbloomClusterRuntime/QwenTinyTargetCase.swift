#if QWEN_TARGET_TINY_FIXTURE
import Foundation
import MLX

final class QwenTinyTargetCase {
    let resources: QwenTinyTargetFixtureResources
    var ordinary: QwenTinyTargetPair
    let target: QwenTinyTargetPair
    let generation: QwenLayerStageGenerationControl
    private(set) var seed = -1
    private(set) var maximumDifference: Float = 0
    private(set) var stagedPayloadHashes: [String] = []
    private(set) var selectedTokens: [Int] = []
    private(set) var provisionalTokens: [Int] = []

    init(model: QwenTinyTargetModel, outputCount: Int = 4, stops: Set<Int> = [],
         check: @escaping () throws -> Void) throws {
        let profile = try QwenLayerStageGenerationProfile(identifier: "fabricated-tiny-target-session-v1",
            vocabularySize: 128, hiddenSize: 64, activationDType: "float32", maximumPromptTokens: 5,
            maximumChunkTokens: 2, maximumOutputTokens: 4, maximumContextTokens: 9)
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: [1, 2, 3, 4, 5], chunkSize: 2, outputCount: outputCount, stopTokenIDs: stops)
        resources = try .init(model: model, request: request, check: check)
        ordinary = try .init(resources: resources)
        target = try .init(resources: resources)
        let stage = model.stages[0], source = try QwenLayerStageWireSourceIdentity(
            sourceConfigurationSHA256: stage.receipt.sourceConfigurationSHA256,
            artifactAggregateSHA256: stage.receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: stage.receipt.storageCommitmentSHA256,
            planFingerprint: stage.plan.fingerprint, producerStageFingerprint: stage.plan.stages[0].fingerprint)
        let fixture = sha256(Data("fabricated-target-session-control-v1".utf8))
        let agreement = try QwenLayerStageGenerationAgreement(request: request, membershipEpoch: UUID(), source: source,
            consumerStageFingerprint: stage.plan.stages[1].fingerprint,
            rankBuildSHA256: [fixture, fixture], numericalPolicySHA256: fixture)
        generation = .init(agreement: agreement)
    }

    func prefillAndSelectSeed() throws {
        let request = resources.request
        for _ in 0..<request.prefillFrameCount {
            let expected = try generation.beginFrame(), frame = expected.frame
            let tokens = Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset+frame.tokenCount)])
            let a = try ordinary.forward(frame, tokens: tokens), b = try target.forward(frame, tokens: tokens)
            if frame.finalPromptChunk {
                maximumDifference = max(maximumDifference, try QwenTinyTargetAssertions.logits(a.value, b.value, check: resources.requireLive))
            }
            let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: b.boundary.payloadSHA256)
            for rank in [0, 1] { try generation.acknowledgeFrame(rank: rank, packet: packet,
                nativeCommittedTokens: target.sessions[rank].committedTokens) }
            if frame.finalPromptChunk {
                seed = try QwenTinyTargetAssertions.token(b.value, check: resources.requireLive)
                try publish(token: seed, boundary: packet, continueRequested: true)
            }
        }
        try QwenTinyTargetAssertions.state(ordinary, target)
    }

    func proposal(_ draft: Int) -> QwenResidentMTPProposal {
        .init(requestID: resources.request.requestID, roundID: UUID(),
            agreementFingerprint: generation.agreement.fingerprint, committedTargetInputs: generation.committedTokens,
            seedTokenID: seed, previousTokenChainSHA256: generation.tokenChainSHA256, proposedTokenID: draft)
    }

    func begin(_ proposal: QwenResidentMTPProposal) throws {
        for session in target.sessions {
            _ = try session.beginTinyTargetVerification(resources: resources, proposal: proposal,
                generation: generation, ownerCheck: { _ in try self.resources.requireLive() })
        }
    }

    func stage(_ proposal: QwenResidentMTPProposal) throws {
        let count = min(2, resources.request.outputCount-1)
        for step in 0..<count {
            let first = try target.sessions[0].stageTargetVerification(roundID: proposal.roundID, step: step,
                ownerCheck: { _ in try self.resources.requireLive() })
            guard case .provisionalHidden(let boundary) = first else { throw ProbeError("Tiny target producer output differs") }
            let owned = try boundary.ownedCopy(check: resources.requireLive)
            let last = try target.sessions[1].stageTargetVerification(roundID: proposal.roundID, step: step,
                incoming: owned, ownerCheck: { _ in try self.resources.requireLive() })
            guard case .provisionalLogits(let logits) = last else { throw ProbeError("Tiny target consumer output differs") }
            let input = step == 0 ? proposal.seedTokenID : proposal.proposedTokenID
            let reference = try ordinary.decode(input)
            maximumDifference = max(maximumDifference, try QwenTinyTargetAssertions.logits(reference, logits, check: resources.requireLive))
            stagedPayloadHashes.append(boundary.payloadSHA256)
            provisionalTokens.append(try QwenTinyTargetAssertions.token(logits, check: resources.requireLive))
        }
    }

    func reconcile(_ proposal: QwenResidentMTPProposal, keeping count: Int) throws {
        let rows = try target.sessions.map { try $0.reconcileTargetVerification(roundID: proposal.roundID,
            keepingInputs: count, ownerCheck: { _ in try self.resources.requireLive() }) }
        try join(rows, retained: count, final: true)
    }

    func commit(_ proposal: QwenResidentMTPProposal, prefix: Int) throws {
        let rows = try target.sessions.map { try $0.commitNextTargetVerification(roundID: proposal.roundID,
            ownerCheck: { _ in try self.resources.requireLive() }) }
        try join(rows, retained: prefix, final: false)
    }

    private func join(_ values: [QwenTargetVerificationCommit], retained: Int, final: Bool) throws {
        defer { values.forEach { $0.discard() } }
        let first = values[0].localReceipt, second = values[1].localReceipt
        try QwenTinyTargetAssertions.require(first.rank == 0 && second.rank == 1
            && first.verificationFingerprint == second.verificationFingerprint
            && first.base == 5 && second.base == 5 && first.retainedInputs == retained && second.retainedInputs == retained
            && first.committedInputs == 5+retained && second.committedInputs == 5+retained
            && first.pendingInputs == second.pendingInputs && first.stagedInputs == second.stagedInputs
            && first.isFinal == final && second.isFinal == final,
            "Actual two-stage local commit receipts differ")
        let firstRows = try values[0].takeLocalHiddenRows(), secondRows = try values[1].takeLocalHiddenRows()
        try QwenTinyTargetAssertions.require(firstRows.isEmpty && secondRows.count == second.newlyCommittedInputs,
            "Committed pre-norm row ownership differs")
        for row in secondRows {
            try QwenTinyTargetAssertions.require(row.shape == [1, 1, 64] && row.dtype == .float32,
                "Committed tiny pre-norm row geometry differs")
        }
    }

    func publishCommittedStep(_ step: Int, continueRequested: Bool) throws {
        // Ordinary existing control consumes actual local receipts above. No
        // wire/peer ACK is fabricated or claimed by this local fixture.
        let expected = try generation.beginFrame()
        let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: stagedPayloadHashes[step])
        for rank in [0, 1] { try generation.acknowledgeFrame(rank: rank, packet: packet,
            nativeCommittedTokens: target.sessions[rank].committedTokens) }
        try publish(token: provisionalTokens[step], boundary: packet, continueRequested: continueRequested)
    }

    private func publish(token: Int, boundary: QwenLayerStageGenerationBoundaryPacket, continueRequested: Bool) throws {
        let packet = try QwenLayerStageGenerationTokenPacket(agreement: generation.agreement,
            boundaryFingerprint: boundary.fingerprint, previousTokenChainSHA256: generation.tokenChainSHA256,
            ordinal: generation.selectedTokenCount, committedTokens: generation.committedTokens, tokenID: token)
        for rank in [0, 1] { try generation.acknowledgeToken(rank: rank, packet: packet) }
        selectedTokens.append(try generation.takeCommittedToken())
        let decision = try generation.decide(continueRequested: continueRequested)
        for rank in [0, 1] { try generation.acknowledgeDecision(rank: rank, packet: decision) }
    }

    func replayOrdinary(keeping count: Int, proposal: QwenResidentMTPProposal) throws {
        try ordinary.cancel(); ordinary = try .init(resources: resources)
        _ = try ordinary.prefill()
        if count >= 1 { _ = try ordinary.decode(proposal.seedTokenID) }
        if count == 2 { _ = try ordinary.decode(proposal.proposedTokenID) }
        try QwenTinyTargetAssertions.state(ordinary, target)
    }

    func finishTarget() throws {
        guard let reason = generation.finishReason, let last = generation.lastTokenID else {
            throw ProbeError("Tiny generation lacks an agreed terminal decision")
        }
        for session in target.sessions {
            try session.finishGeneration(reason, selectedTokenCount: generation.selectedTokenCount, lastTokenID: last)
        }
        try QwenTinyTargetAssertions.require(target.sessions.allSatisfy { $0.isClosed && !$0.isFailed },
            "Tiny clean finish did not retire actual state")
    }

    func cancel() throws {
        var first: Error?
        do { try ordinary.cancel() } catch { first = error }
        do { try target.cancel() } catch { first = first ?? error }
        if let first { throw first }
    }
    deinit { try? ordinary.cancel(); try? target.cancel() }
}
#endif
