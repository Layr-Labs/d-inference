import Foundation
import MLX

/// What one rank can say about a finished request without a tensor leaving
/// the process: enough to compare two runs of the same request.
struct MiMoRequestEvidence: Encodable, Equatable {
    let rank: Int
    /// Chain over the SHA-256 of every residual that crossed the cut.
    let boundaryChainSHA256: String
    /// Rank 1 only: SHA-256 of the logits row the last token was selected from.
    let lastRowSHA256: String?
    /// Rank 1, when step evidence was asked for: one record per selected token.
    var steps: [MiMoStepEvidence] = []
}

/// Runs one request on an already exclusively owned, admitted resident MiMo
/// stage: the two-stage pipeline, with the serial prefill schedule and either
/// decode framing. The frame, token, decision and retirement exchanges are the
/// dense adapter's own control and transport, used unchanged; only the stage
/// session differs. The owner enforces live resources, deadline and
/// cancellation through `check`; only rank 0 calls the token callback.
///
/// A successful return follows both native request-state retirements. On
/// error this retires local state and throws; the owner must fence the peer
/// out of band before it claims retirement or releases anything.
func runMiMoLayerStageGenerationRequest(loaded: LoadedMiMoLayerStage, plan: MiMoLayerStagePlan,
    agreement: QwenLayerStageGenerationAgreement, collective: Collective, recordsSteps: Bool = false,
    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void
) throws -> (result: QwenLayerStageGenerationResult, evidence: MiMoRequestEvidence) {
    try MLX.withError { nativeError in
        func checked() throws { try nativeError.check(); try check(); try nativeError.check() }
        do {
            try requireMiMoGenerationSource(loaded: loaded, plan: plan, agreement: agreement, collective: collective)
            try checked()
            _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                material: { .generation(agreementFingerprint: agreement.fingerprint) },
                disagreementMessage: "Generation membership/request/source readiness differs", check: checked)
            let control = QwenLayerStageGenerationControl(agreement: agreement)
            let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: collective)
            var session: MiMoLayerStageSession?
            do {
                let owned = try MiMoLayerStageSession(stage: loaded, plan: plan, generationRequest: agreement.request,
                                                      recordsSteps: recordsSteps)
                session = owned
                var selectedTokens = [Int]()
                var finalDecision: QwenLayerStageGenerationDecisionPacket?
                while control.phase == .frame {
                    try autoreleasepool {
                        try checked()
                        let expected = try control.beginFrame()
                        if agreement.compactDecode, expected.frame.phase == .decode {
                            let step = try runMiMoCompactDecodeFrame(session: owned, control: control,
                                transport: transport, expected: expected, onCommittedToken: onCommittedToken,
                                check: checked)
                            selectedTokens.append(step.selected)
                            if control.phase == .retiring { finalDecision = step.decision }
                            return
                        }
                        let (packet, row) = try runMiMoGenerationFrame(session: owned, control: control,
                            transport: transport, expected: expected, check: checked)
                        guard control.phase == .token else { return }
                        let token = try agreeMiMoGenerationToken(row: row, boundary: packet, control: control,
                            transport: transport, check: checked)
                        let selected = try control.takeCommittedToken()
                        selectedTokens.append(selected)
                        // The scalar agreement is complete. No next forward runs
                        // while this callback is active or before the decision.
                        let decision: QwenLayerStageGenerationDecisionPacket
                        if collective.rank == 0 {
                            try checked()
                            let keepGoing = try onCommittedToken(selected)
                            try checked()
                            decision = try control.decide(continueRequested: keepGoing)
                            try control.acknowledgeDecision(rank: 0, packet: decision)
                            try transport.sendDecision(decision, check: checked)
                            try control.acknowledgeDecision(rank: 1, packet: decision)
                        } else {
                            decision = try transport.receiveDecision(token: token, check: checked)
                            let local = try control.decide(continueRequested: decision.content.decision == .proceed)
                            guard local.content == decision.content else {
                                throw ProbeError("Generation owner decision differs from local token/stop policy")
                            }
                            try control.acknowledgeDecision(rank: 0, packet: decision)
                            try control.acknowledgeDecision(rank: 1, packet: decision)
                            try transport.acknowledgeDecision(decision, check: checked)
                        }
                        if control.phase == .retiring { finalDecision = decision }
                    }
                }
                guard control.phase == .retiring, !control.isFailed,
                      let reason = control.finishReason, let lastToken = control.lastTokenID,
                      let finalDecision, selectedTokens.count == control.selectedTokenCount else {
                    throw ProbeError("Generation ended without agreed clean stop")
                }
                try checked()
                let evidence = MiMoRequestEvidence(rank: collective.rank,
                    boundaryChainSHA256: owned.boundaryChainSHA256, lastRowSHA256: owned.lastRowSHA256,
                    steps: owned.steps)
                try owned.finishGeneration(reason, selectedTokenCount: control.selectedTokenCount, lastTokenID: lastToken)
                guard owned.isClosed, !owned.isFailed else { throw ProbeError("Generation native state failed retirement") }
                try control.acknowledgeRetirement(rank: collective.rank, disposition: .retired)
                try transport.exchangeRetirement(decision: finalDecision, check: checked)
                try control.acknowledgeRetirement(rank: 1 - collective.rank, disposition: .retired)
                try checked()
                guard control.isRetired, !control.isFailed, !transport.isFailed else {
                    throw ProbeError("Generation both-rank retirement is incomplete")
                }
                return (QwenLayerStageGenerationResult(agreementFingerprint: agreement.fingerprint,
                    membershipEpoch: agreement.descriptor.membershipEpoch, identity: owned.identity,
                    selectedTokenIDs: selectedTokens, tokenChainSHA256: control.tokenChainSHA256,
                    completedFrames: control.completedFrames, committedTokens: control.committedTokens,
                    finishReason: reason), evidence)
            } catch {
                // Prefer a recorded native fault before any cleanup.
                var primary: Error = error
                do { try nativeError.check() } catch { primary = error }
                control.cancel(); transport.retire()
                do { try session?.cancel() }
                catch { throw ProbeError("Generation failed (\(primary)); local retirement also failed (\(error))") }
                throw primary
            }
        } catch {
            try nativeError.check()
            throw error
        }
    }
}

private func requireMiMoGenerationSource(loaded: LoadedMiMoLayerStage, plan: MiMoLayerStagePlan,
    agreement: QwenLayerStageGenerationAgreement, collective: Collective) throws {
    let source = agreement.descriptor, receipt = loaded.receipt
    guard collective.size == 2, (0...1).contains(collective.rank), loaded.stageIndex == collective.rank,
          plan.stages.count == 2, source.planFingerprint == plan.fingerprint,
          loaded.plan.fingerprint == plan.fingerprint,
          source.stageFingerprints == plan.stages.map(\.fingerprint),
          source.sourceConfigurationSHA256 == sha256(plan.originalConfiguration),
          receipt.sourceConfigurationSHA256 == source.sourceConfigurationSHA256,
          receipt.verifiedAggregateSHA256 == source.artifactAggregateSHA256,
          receipt.storageCommitmentSHA256 == source.storageCommitmentSHA256,
          receipt.stagePlanSHA256 == source.stageFingerprints[collective.rank],
          receipt.planSHA256 == source.planFingerprint,
          agreement.phaseSplit == nil, agreement.prefillPolicy == .serial,
          agreement.request.profile.vocabularySize == loaded.vocabularySize,
          agreement.request.profile.activationDType == String(describing: loaded.activationDType) else {
        throw ProbeError("Generation actual loaded MiMo stage/source/rank differs from agreement")
    }
    // The transport's own limit, before readiness or request-state construction.
    _ = try CollectivePointToPointShape(
        shape: [1, min(agreement.request.chunkSize, agreement.request.promptCount), agreement.request.profile.hiddenSize],
        dtype: loaded.activationDType, maximumBytes: CollectivePointToPointShape.hardByteLimit)
}

private func runMiMoGenerationFrame(session: MiMoLayerStageSession, control: QwenLayerStageGenerationControl,
    transport: QwenLayerStageGenerationTransport, expected: QwenLayerStageGenerationBoundaryExpectation,
    check: () throws -> Void
) throws -> (QwenLayerStageGenerationBoundaryPacket, MLXArray?) {
    let request = control.agreement.request, frame = expected.frame
    let tokens: [Int]
    if frame.phase == .prefill {
        tokens = Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
    } else {
        guard let token = control.lastTokenID else { throw ProbeError("Generation decode lacks an agreed target token") }
        tokens = [token]
    }
    func forward(_ incoming: QwenLayerStageBoundary?) throws -> QwenLayerStageOutput {
        if frame.phase == .prefill {
            return try session.prefillChunk(tokens, offset: frame.tokenOffset, final: frame.finalPromptChunk,
                                            incoming: incoming, check: check)
        }
        return try session.decode(tokens[0], offset: frame.tokenOffset, incoming: incoming, check: check)
    }
    if transport.rank == 0 {
        guard case .hidden(let boundary) = try forward(nil) else { throw ProbeError("Generation producer did not return a residual") }
        let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: boundary.payloadSHA256)
        try control.acknowledgeFrame(rank: 0, packet: packet, nativeCommittedTokens: session.committedTokens)
        try transport.sendBoundary(boundary, packet: packet, check: check)
        try control.acknowledgeFrame(rank: 1, packet: packet, nativeCommittedTokens: session.committedTokens)
        return (packet, nil)
    }
    let (row, packet): (MLXArray?, QwenLayerStageGenerationBoundaryPacket) = try transport.receiveBoundary(
        expected: expected, consume: { boundary, packet in
            // Header and payload identity establish the producer's completed
            // frame; no consumed acknowledgement is sent until this commit returns.
            try control.acknowledgeFrame(rank: 0, packet: packet,
                nativeCommittedTokens: frame.tokenOffset + frame.tokenCount)
            let output = try forward(boundary)
            try control.acknowledgeFrame(rank: 1, packet: packet, nativeCommittedTokens: session.committedTokens)
            switch output {
            case .evaluationHandle where frame.phase == .prefill && !frame.finalPromptChunk: return nil
            case .logits(let row) where frame.finalPromptChunk || frame.phase == .decode: return row
            default: throw ProbeError("Generation consumer output does not match its frame")
            }
        }, check: check)
    return (packet, row)
}

/// One decode step of a declared compact-decode request: four transfers, in
/// the order the dense adapter's compact step establishes them.
private func runMiMoCompactDecodeFrame(session: MiMoLayerStageSession, control: QwenLayerStageGenerationControl,
    transport: QwenLayerStageGenerationTransport, expected: QwenLayerStageGenerationBoundaryExpectation,
    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void
) throws -> (selected: Int, decision: QwenLayerStageGenerationDecisionPacket) {
    let frame = expected.frame, committed = frame.tokenOffset + frame.tokenCount
    guard frame.phase == .decode, let target = control.lastTokenID else {
        throw ProbeError("Generation decode lacks an agreed target token")
    }
    if transport.rank == 0 {
        guard case .hidden(let boundary) = try session.decode(target, offset: frame.tokenOffset, check: check) else {
            throw ProbeError("Generation producer did not return a residual")
        }
        let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: boundary.payloadSHA256)
        try control.acknowledgeFrame(rank: 0, packet: packet, nativeCommittedTokens: session.committedTokens)
        try transport.sendCompactBoundary(boundary, packet: packet, check: check)
        // The token binds this boundary, so its arrival is rank 1's commit of the frame.
        let token = try transport.receiveCompactToken(boundaryFingerprint: packet.fingerprint,
            previousChain: control.tokenChainSHA256, ordinal: control.selectedTokenCount,
            committedTokens: committed, check: check)
        try control.acknowledgeFrame(rank: 1, packet: packet, nativeCommittedTokens: committed)
        try control.acknowledgeToken(rank: 1, packet: token)
        try control.acknowledgeToken(rank: 0, packet: token)
        let selected = try control.takeCommittedToken()
        try check()
        let keepGoing = try onCommittedToken(selected)
        try check()
        let decision = try control.decide(continueRequested: keepGoing)
        try control.acknowledgeDecision(rank: 0, packet: decision)
        try transport.sendCompactDecision(decision, check: check)
        try control.acknowledgeDecision(rank: 1, packet: decision)
        return (selected, decision)
    }
    let (boundary, packet) = try transport.receiveCompactBoundary(expected: expected, check: check)
    try control.acknowledgeFrame(rank: 0, packet: packet, nativeCommittedTokens: committed)
    guard case .logits(let row) = try session.decode(target, offset: frame.tokenOffset, incoming: boundary, check: check) else {
        throw ProbeError("Generation consumer output does not match its frame")
    }
    try control.acknowledgeFrame(rank: 1, packet: packet, nativeCommittedTokens: session.committedTokens)
    let tokenID = try QwenLayerStageGenerationSelection.token(row, request: control.agreement.request, check: check)
    let token = try QwenLayerStageGenerationTokenPacket(agreement: control.agreement, boundaryFingerprint: packet.fingerprint,
        previousTokenChainSHA256: control.tokenChainSHA256, ordinal: control.selectedTokenCount,
        committedTokens: control.committedTokens, tokenID: tokenID)
    try control.acknowledgeToken(rank: 1, packet: token)
    try transport.sendCompactToken(token, check: check)
    // The decision binds this token, so its arrival is rank 0's acceptance of it.
    let decision = try transport.receiveCompactDecision(token: token, check: check)
    try control.acknowledgeToken(rank: 0, packet: token)
    let selected = try control.takeCommittedToken()
    let local = try control.decide(continueRequested: decision.content.decision == .proceed)
    guard local.content == decision.content else {
        throw ProbeError("Generation owner decision differs from local token/stop policy")
    }
    try control.acknowledgeDecision(rank: 0, packet: decision)
    try control.acknowledgeDecision(rank: 1, packet: decision)
    try transport.acknowledgeDecision(decision, check: check)
    return (selected, decision)
}

private func agreeMiMoGenerationToken(row: MLXArray?, boundary: QwenLayerStageGenerationBoundaryPacket,
    control: QwenLayerStageGenerationControl, transport: QwenLayerStageGenerationTransport,
    check: () throws -> Void
) throws -> QwenLayerStageGenerationTokenPacket {
    let packet: QwenLayerStageGenerationTokenPacket
    if transport.rank == 1 {
        guard let row else { throw ProbeError("Generation target selection lacks committed final logits") }
        let selected = try QwenLayerStageGenerationSelection.token(row, request: control.agreement.request, check: check)
        packet = try .init(agreement: control.agreement, boundaryFingerprint: boundary.fingerprint,
            previousTokenChainSHA256: control.tokenChainSHA256, ordinal: control.selectedTokenCount,
            committedTokens: control.committedTokens, tokenID: selected)
        try control.acknowledgeToken(rank: 1, packet: packet)
        try transport.sendToken(packet, check: check)
        try control.acknowledgeToken(rank: 0, packet: packet)
    } else {
        guard case nil = row else { throw ProbeError("Generation rank0 unexpectedly owns logits") }
        packet = try transport.receiveToken(boundaryFingerprint: boundary.fingerprint,
            previousChain: control.tokenChainSHA256, ordinal: control.selectedTokenCount,
            committedTokens: control.committedTokens, check: check)
        try control.acknowledgeToken(rank: 1, packet: packet)
        try control.acknowledgeToken(rank: 0, packet: packet)
        try transport.acknowledgeToken(packet, check: check)
    }
    return packet
}
