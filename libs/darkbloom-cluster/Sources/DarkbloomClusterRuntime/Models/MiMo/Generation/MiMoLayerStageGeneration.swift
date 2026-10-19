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
    /// Rank 1 of `pipeline_mtp_v1`: the speculative rounds' counts and times.
    var speculative: MiMoMTPStatistics? = nil
}

/// What a `pipeline_mtp_v1` request runs with on one rank: the agreed terms,
/// and on rank 1 the loaded head.
struct MiMoSpeculativeDecode {
    let terms: MiMoMTPTerms
    let head: MiMoMTPHead?
}

/// Runs one request on an already exclusively owned, admitted resident MiMo
/// stage: the two-stage pipeline, with the serial or the one-chunk lookahead
/// prefill schedule and either decode framing, or a phase split (rank 1 also
/// holds the producer stage, `producerStage`, adopts rank 0's state after the
/// first token and decodes alone; or serves the whole request alone when the
/// request is routed to it). The frame, token, decision, hand-off, relay and
/// retirement exchanges are the dense adapter's own control and transport,
/// used unchanged; only the stage sessions differ. The owner enforces live
/// resources, deadline and cancellation through `check`; only rank 0 calls
/// the token callback.
///
/// A successful return follows both native request-state retirements. On
/// error this retires local state and throws; the owner must fence the peer
/// out of band before it claims retirement or releases anything.
///
/// With `prefixCache`, both ranks first agree a prompt-prefix plan before the
/// first forward (`agreeMiMoStagePrefixPlan`): reuse the deepest frontier both
/// hold, restored on both or neither, and keep this prompt's frontiers once
/// both ranks retired cleanly (`storeClusterStagePrefix`).
func runMiMoLayerStageGenerationRequest(loaded: LoadedMiMoLayerStage, plan: MiMoLayerStagePlan,
    agreement unplannedAgreement: QwenLayerStageGenerationAgreement, collective: Collective, recordsSteps: Bool = false,
    prefixCache requestedPrefixCache: QwenStagePrefixCache? = nil, speculative: MiMoSpeculativeDecode? = nil,
    producerStage: LoadedMiMoLayerStage? = nil, handoffFault: QwenPhaseSplitFault? = nil,
    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void
) throws -> (result: QwenLayerStageGenerationResult, evidence: MiMoRequestEvidence) {
    try MLX.withError { nativeError in
        func checked() throws { try nativeError.check(); try check(); try nativeError.check() }
        do {
            try requireMiMoGenerationSource(loaded: loaded, plan: plan, agreement: unplannedAgreement,
                                            collective: collective, speculative: speculative, producerStage: producerStage)
            try checked()
            _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                material: { .generation(agreementFingerprint: unplannedAgreement.fingerprint) },
                disagreementMessage: "Generation membership/request/source readiness differs",
                scope: .request(.requestAgreement, requestID: unplannedAgreement.request.requestID,
                    agreementFingerprint: unplannedAgreement.fingerprint, "generation-readiness"), check: checked)
            // Prefix plan, before the first forward. The planned agreement keeps
            // the request's fingerprint; only where prompt frames start and end moves.
            // A phase split (a hand-off mode, off by default) hands over state computed
            // from frame 0 and refuses a restored prefix, and a request routed to the
            // decoding rank alone runs no pair frame: neither plans, restores or keeps prefixes.
            let prefixCache = unplannedAgreement.phaseSplit == nil && !unplannedAgreement.request.decodingRankAlone
                ? requestedPrefixCache : nil
            let planned = try agreeMiMoStagePrefixPlan(cache: prefixCache, loaded: loaded, plan: plan,
                agreement: unplannedAgreement, collective: collective, recordsSteps: recordsSteps, check: checked)
            let agreement = planned.agreement
            let session: MiMoLayerStageSession? = planned.session
            let captureLimit = beginClusterStagePrefixCapture(cache: prefixCache, capture: planned.session.prefixCapture)
            defer { prefixCache?.endCapture() }
            let control = QwenLayerStageGenerationControl(agreement: agreement)
            let transport: QwenLayerStageGenerationTransport
            do { transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: collective) }
            catch { try? planned.session.cancel(); throw error }
            var decoder: MiMoMTPDecoder?
            defer { decoder?.release() }
            do {
                let owned = planned.session
                if let speculative, collective.rank == 1 {
                    // The head observes the prompt rows this request computes. After a
                    // restored prefix that is only the rest of the prompt: drafts stay
                    // verified by the target (tokens unaffected), only acceptance drops.
                    guard let head = speculative.head else { throw ProbeError("Speculative decode needs the head on rank 1") }
                    let owner = try MiMoMTPDecoder(head: head, terms: speculative.terms, request: agreement.request)
                    decoder = owner
                    owned.promptObserver = { tokens, hidden in try owner.observePrompt(tokens: tokens, hidden: hidden) }
                }
                var selectedTokens = [Int]()
                var finalDecision: QwenLayerStageGenerationDecisionPacket?
                var discardedDecodeForwards = 0
                var speculativeStatistics: MiMoMTPStatistics?
                // A phase-split request leaves this loop after its first agreed
                // token and decision; a request routed to the decoding rank alone
                // runs no pair frame at all; a pipeline request runs it to the end.
                let split = agreement.phaseSplit, alone = agreement.request.decodingRankAlone
                let producer = agreement.prefillPolicy == .oneChunkLookahead && collective.rank == 0 && !alone
                    ? try MiMoGenerationLookaheadProducer(request: agreement.request) : nil
                while control.phase == .frame, !alone,
                      split.map({ control.selectedTokenCount < $0.terms.handoffSelectedTokens }) ?? true {
                    try autoreleasepool {
                        try checked()
                        if let speculative, control.selectedTokenCount > 0 {
                            // The prompt and the first token ran as frames; decode runs as rounds.
                            guard producer == nil || producer!.isComplete else {
                                throw ProbeError("Generation rounds precede lookahead prompt drain")
                            }
                            let outcome: MiMoMTPGeneration.Outcome
                            if collective.rank == 0 {
                                outcome = try MiMoMTPGeneration.runProducer(session: owned, control: control,
                                    terms: speculative.terms, collective: collective,
                                    onCommittedToken: onCommittedToken, check: checked)
                            } else {
                                try decoder!.begin(firstToken: selectedTokens[0])
                                outcome = try MiMoMTPGeneration.runConsumer(session: owned, decoder: decoder!,
                                    control: control, collective: collective, check: checked)
                            }
                            selectedTokens += outcome.selected
                            finalDecision = outcome.finalDecision
                            discardedDecodeForwards = outcome.discardedDecodeForwards
                            speculativeStatistics = outcome.statistics
                            return
                        }
                        let expected = try control.beginFrame()
                        if let producer, expected.frame.phase == .prefill {
                            let packet = try producer.run(session: owned, control: control, transport: transport,
                                                          expected: expected, check: checked)
                            guard control.phase == .token else { return }
                            // The last prompt frame's token: rank 0 owns no logits.
                            let token = try agreeMiMoGenerationToken(row: nil, boundary: packet, control: control,
                                transport: transport, check: checked)
                            try decideMiMoToken(token: token, control: control, transport: transport, collective: collective,
                                selectedTokens: &selectedTokens, finalDecision: &finalDecision,
                                onCommittedToken: onCommittedToken, check: checked)
                            return
                        }
                        guard producer == nil || producer!.isComplete else {
                            throw ProbeError("Generation decode precedes lookahead prompt drain")
                        }
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
                        try decideMiMoToken(token: token, control: control, transport: transport, collective: collective,
                            selectedTokens: &selectedTokens, finalDecision: &finalDecision,
                            onCommittedToken: onCommittedToken, check: checked)
                    }
                }
                var handedOver: MiMoPhaseSplitGeneration.Outcome?
                if let split, control.phase == .frame {
                    guard producer == nil || producer!.isComplete else {
                        throw ProbeError("Hand-off precedes lookahead prompt drain")
                    }
                    // Hand-off (or the whole request on the decoding rank alone),
                    // then rank 1 decodes alone. Both stages' request state is
                    // retired inside; only the retirement exchange is left.
                    let outcome = try MiMoPhaseSplitGeneration.run(producerStage: producerStage, plan: plan, split: split,
                        control: control, transport: transport, session: owned, selectedTokens: &selectedTokens,
                        fault: handoffFault, onCommittedToken: onCommittedToken, check: checked)
                    log(outcome.summary.diagnosticLine(requestID: agreement.request.requestID))
                    finalDecision = outcome.finalDecision; handedOver = outcome
                }
                guard control.phase == .retiring, !control.isFailed,
                      let reason = control.finishReason, let lastToken = control.lastTokenID,
                      let finalDecision, selectedTokens.count == control.selectedTokenCount else {
                    throw ProbeError("Generation ended without agreed clean stop")
                }
                try checked()
                guard producer == nil || producer!.isComplete else {
                    throw ProbeError("Generation ended with a prepared or pending prompt boundary")
                }
                let evidence = MiMoRequestEvidence(rank: collective.rank,
                    boundaryChainSHA256: owned.boundaryChainSHA256, lastRowSHA256: owned.lastRowSHA256,
                    steps: owned.steps, speculative: speculativeStatistics)
                if handedOver == nil {
                    try owned.finishGeneration(reason, selectedTokenCount: control.selectedTokenCount, lastTokenID: lastToken,
                        discardedDecodeForwards: discardedDecodeForwards)
                }
                guard owned.isClosed, !owned.isFailed else { throw ProbeError("Generation native state failed retirement") }
                try control.acknowledgeRetirement(rank: collective.rank, disposition: .retired)
                try transport.exchangeRetirement(decision: finalDecision, check: checked)
                try control.acknowledgeRetirement(rank: 1 - collective.rank, disposition: .retired)
                try checked()
                guard control.isRetired, !control.isFailed, !transport.isFailed else {
                    throw ProbeError("Generation both-rank retirement is incomplete")
                }
                let stored = storeClusterStagePrefix(cache: prefixCache, capture: owned.prefixCapture, agreement: agreement,
                    rank: collective.rank, captureLimit: captureLimit, family: "mimo", skippedKey: "skipped_rotated")
                var result = QwenLayerStageGenerationResult(agreementFingerprint: agreement.fingerprint,
                    membershipEpoch: agreement.descriptor.membershipEpoch, identity: owned.identity,
                    selectedTokenIDs: selectedTokens, tokenChainSHA256: control.tokenChainSHA256,
                    completedFrames: control.completedFrames, committedTokens: control.committedTokens,
                    finishReason: reason)
                if let prefixCache {
                    let summary = planned.summary
                    result.prefixCache = .init(reusedPromptTokens: summary.reusedPromptTokens,
                        restoredTier: summary.restoredTier, agreedPromptTokens: summary.agreedPromptTokens,
                        splitFinalToken: summary.splitFinalToken, storedFrontiers: stored, cacheEntries: prefixCache.count)
                }
                return (result, evidence)
            } catch {
                // Prefer a recorded native fault before any cleanup.
                var primary: Error = error
                do { try nativeError.check() } catch { primary = error }
                session?.prefixCapture?.discard()
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
    agreement: QwenLayerStageGenerationAgreement, collective: Collective, speculative: MiMoSpeculativeDecode?,
    producerStage: LoadedMiMoLayerStage?) throws {
    guard agreement.speculativeRoundsFraming == speculative?.terms.decodeFraming,
          speculative == nil || (agreement.phaseSplit == nil && !agreement.compactDecode
              && (collective.rank == 0) == (speculative?.head == nil)) else {
        throw ProbeError("Generation speculative rounds differ from this rank's loaded head and terms")
    }
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
          agreement.prefillPolicy == .serial || agreement.prefillPolicy == .oneChunkLookahead,
          agreement.speculativeHead == nil, !(agreement.phaseSplit != nil && agreement.compactDecode),
          agreement.request.profile.vocabularySize == loaded.vocabularySize,
          agreement.request.profile.activationDType == String(describing: loaded.activationDType) else {
        throw ProbeError("Generation actual loaded MiMo stage/source/rank differs from agreement")
    }
    // Only a phase split's decoding rank holds the producer stage beside its own.
    if agreement.phaseSplit != nil, collective.rank == 1 {
        guard let producerStage, producerStage.stageIndex == 0, producerStage.plan.fingerprint == plan.fingerprint,
              producerStage.receipt.stagePlanSHA256 == source.stageFingerprints[0],
              producerStage.receipt.storageCommitmentSHA256 == source.storageCommitmentSHA256,
              producerStage.receipt.verifiedAggregateSHA256 == source.artifactAggregateSHA256 else {
            throw ProbeError("Phase-split rank1 does not hold the agreed MiMo producer stage")
        }
    } else if producerStage != nil {
        throw ProbeError("Only a phase-split rank1 runs with a MiMo producer stage")
    }
    // The transport's own limit, before readiness or request-state construction.
    _ = try CollectivePointToPointShape(
        shape: [1, min(agreement.request.chunkSize, agreement.request.promptCount), agreement.request.profile.hiddenSize],
        dtype: loaded.activationDType, maximumBytes: CollectivePointToPointShape.hardByteLimit)
}

/// The owner's decision on an agreed token, as the dense adapter takes it:
/// rank 0 calls the callback and sends; rank 1 receives and checks it
/// against its own token/stop policy.
private func decideMiMoToken(token: QwenLayerStageGenerationTokenPacket, control: QwenLayerStageGenerationControl,
    transport: QwenLayerStageGenerationTransport, collective: Collective, selectedTokens: inout [Int],
    finalDecision: inout QwenLayerStageGenerationDecisionPacket?,
    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void) throws {
    let selected = try control.takeCommittedToken()
    selectedTokens.append(selected)
    // The scalar agreement is complete. No next forward runs while this
    // callback is active or before the decision.
    let decision: QwenLayerStageGenerationDecisionPacket
    if collective.rank == 0 {
        try check()
        let keepGoing = try onCommittedToken(selected)
        try check()
        decision = try control.decide(continueRequested: keepGoing)
        try control.acknowledgeDecision(rank: 0, packet: decision)
        try transport.sendDecision(decision, check: check)
        try control.acknowledgeDecision(rank: 1, packet: decision)
    } else {
        decision = try transport.receiveDecision(token: token, check: check)
        let local = try control.decide(continueRequested: decision.content.decision == .proceed)
        guard local.content == decision.content else {
            throw ProbeError("Generation owner decision differs from local token/stop policy")
        }
        try control.acknowledgeDecision(rank: 0, packet: decision)
        try control.acknowledgeDecision(rank: 1, packet: decision)
        try transport.acknowledgeDecision(decision, check: check)
    }
    if control.phase == .retiring { finalDecision = decision }
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
