import Foundation
import MLX

/// Runs one request on an already exclusively owned, admitted resident stage.
/// The owner validates both build identities and enforces live resources,
/// deadline and cancellation through `check`. It runs this blocking function on
/// its private executor; only rank0 calls the synchronous token callback.
///
/// A successful return follows both native request-state retirements. On error,
/// this function retires local state and throws; the owner MUST cancel/fence the
/// peer out of band before claiming lease retirement or releasing resources.
///
/// `producerStage` is the stage-0 model a phase-split rank 1 also holds. It is
/// touched only after rank 0 has handed its request state over.
func runQwenLayerStageGenerationRequest(loaded: LoadedQwenLayerStage,
    producerStage: LoadedQwenLayerStage? = nil, speculativeHead: QwenMTPHead? = nil,
    plan: QwenLayerStagePlan, agreement: QwenLayerStageGenerationAgreement,
    collective: Collective, prefixCache: QwenStagePrefixCache? = nil, onCommittedToken: (Int) throws -> Bool,
    check: () throws -> Void
) throws -> QwenLayerStageGenerationResult {
    try runQwenLayerStageGenerationCore(loaded: loaded, producerStage: producerStage, speculativeHead: speculativeHead,
        plan: plan, agreement: agreement,
        collective: collective, diagnostics: nil, prefixCache: prefixCache, onCommittedToken: onCommittedToken,
        check: check).result
}

/// Explicit diagnostic entry for an already owned reservation. The owner must
/// pass the exact allowance derived for that reservation and retain all existing
/// build/source/arithmetic, deadline and cancellation checks. There is no default
/// diagnostic mode or permissive resource callback. Do not time this as serving.
func recordQwenLayerStageGenerationRequest(loaded: LoadedQwenLayerStage,
    producerStage: LoadedQwenLayerStage? = nil, speculativeHead: QwenMTPHead? = nil,
    plan: QwenLayerStagePlan, agreement: QwenLayerStageGenerationAgreement,
    collective: Collective, resources makeResources: () throws -> QwenGenerationDiagnosticResources,
    phaseSplitFault: QwenPhaseSplitFault? = nil, prefixCache: QwenStagePrefixCache? = nil,
    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void
) throws -> QwenGenerationDiagnosticEvidence {
    let resources = try MLX.withError { nativeError in
        do {
            try check(); try nativeError.check()
            // The loaded stage's own family binds the capture to its source and
            // rederives the reserved allowance with the actual allocator.
            let value = try makeResources()
            try nativeError.check(); try check(); try nativeError.check()
            return value
        } catch {
            try nativeError.check()
            throw error
        }
    }
    let capture = QwenGenerationDiagnosticCapture(request: agreement.request,
        rank: collective.rank, resources: resources)
    defer { capture.discard() }
    let (result, handedOver) = try runQwenLayerStageGenerationCore(loaded: loaded, producerStage: producerStage,
        speculativeHead: speculativeHead, plan: plan, agreement: agreement,
        collective: collective, diagnostics: capture, phaseSplitFault: phaseSplitFault, prefixCache: prefixCache,
        onCommittedToken: onCommittedToken, check: check)
    // The core has validated both retirement acknowledgements and its final
    // native error check. Only CPU values are assembled outside that scope.
    guard let handedOver else {
        return try capture.finish(execution: result, agreement: agreement, stage: plan.stages[collective.rank])
    }
    // After a hand-off the final state is not divided by stage: rank 1 owns
    // every layer and records all of them, rank 0 owns and records none. The
    // record keeps its type, so both ranks' records still join into one state.
    let stage = plan.stages[collective.rank]
    guard result.bothRequestStatesRetired, result.identity.stageIndex == collective.rank,
          (handedOver.finalLogits != nil) == (collective.rank == 1),
          result.completedFrames == handedOver.finalFrame.sequence + 1, resources.observationCount > 0 else {
        throw ProbeError("Phase-split diagnostic publication precedes complete retirement/evidence")
    }
    return .init(execution: result, agreement: agreement.descriptor,
        requestFingerprint: agreement.request.fingerprint, profileFingerprint: agreement.request.profile.fingerprint,
        rank: collective.rank, sourceLayerStart: collective.rank == 0 ? stage.sourceRange.lowerBound : 0,
        sourceLayerEnd: stage.sourceRange.upperBound, finalFrame: handedOver.finalFrame,
        stateEntries: handedOver.entries, logicalStateBytes: handedOver.logicalBytes,
        stageStateSHA256: handedOver.fingerprint, finalLogits: handedOver.finalLogits,
        captureBudget: resources.budget, resourceObservationCount: resources.observationCount,
        minimumObservedActualFreeBytes: resources.minimumActualFreeBytes,
        minimumObservedAllocatorLimitBytes: resources.minimumAllocatorLimitBytes)
}

private func runQwenLayerStageGenerationCore(loaded: LoadedQwenLayerStage,
    producerStage: LoadedQwenLayerStage?, speculativeHead: QwenMTPHead? = nil,
    plan: QwenLayerStagePlan, agreement unplannedAgreement: QwenLayerStageGenerationAgreement,
    collective: Collective, diagnostics: QwenGenerationDiagnosticCapture?,
    phaseSplitFault: QwenPhaseSplitFault? = nil, prefixCache: QwenStagePrefixCache? = nil,
    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void
) throws -> (result: QwenLayerStageGenerationResult, handedOver: QwenPhaseSplitRecordedState?) {
    try MLX.withError { nativeError in
        func checked() throws {
            try nativeError.check(); try check()
            try diagnostics?.resources.requireLive()
            try nativeError.check()
        }
        do {
            try requireGenerationSource(loaded: loaded, plan: plan, agreement: unplannedAgreement, collective: collective)
            // A phase-split rank 1 must already hold the producer stage of this
            // exact source; a pipeline rank must not be handed one.
            if unplannedAgreement.phaseSplit != nil, collective.rank == 1 {
                guard let producerStage, producerStage.stageIndex == 0,
                      producerStage.plan.fingerprint == plan.fingerprint,
                      producerStage.receipt.stagePlanSHA256 == unplannedAgreement.descriptor.stageFingerprints[0],
                      producerStage.receipt.storageCommitmentSHA256 == unplannedAgreement.descriptor.storageCommitmentSHA256,
                      producerStage.receipt.verifiedAggregateSHA256 == unplannedAgreement.descriptor.artifactAggregateSHA256 else {
                    throw ProbeError("Phase-split rank1 does not hold the agreed producer stage")
                }
            } else if producerStage != nil {
                throw ProbeError("Only a phase-split rank1 runs with a producer stage")
            }
            // The decoding rank of a speculative phase split holds the head; no
            // other rank, and no other request, may be handed one.
            guard (speculativeHead != nil) == (unplannedAgreement.speculativeHead != nil && collective.rank == 1) else {
                throw ProbeError("Speculative head differs from this rank's agreed role")
            }
            try checked()
            _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                material: { .generation(agreementFingerprint: unplannedAgreement.fingerprint) },
                disagreementMessage: "Generation membership/request/source readiness differs", check: checked)
            // Before the session: the consumer stage's computed prompt rows are
            // the head's history. A prefix reused from the cache is not observed
            // again (exact tokens either way; the head drafts from what it saw).
            var decoder: QwenMTPDecoder?
            if let speculativeHead, let terms = unplannedAgreement.speculativeHead {
                decoder = try QwenMTPDecoder(head: speculativeHead, terms: terms, request: unplannedAgreement.request)
            }
            // Prefix plan, before the first forward: both ranks agree what to
            // reuse, restore it, and confirm; anything else prefills from zero
            // on both ranks.
            var session: QwenLayerStageSession?
            let prefix: QwenStagePrefixSummary
            let agreement: QwenLayerStageGenerationAgreement
            do {
                let planned = try agreeQwenStagePrefixPlan(cache: prefixCache, loaded: loaded, plan: plan,
                    agreement: unplannedAgreement, collective: collective, hiddenTap: decoder?.tap(), check: checked)
                agreement = planned.agreement; session = planned.session; prefix = planned.summary
            }
            // This request's capture, within what its reservation charged:
            // older entries make room first, so the entries and this capture
            // stay within the cache's budget together.
            let captureLimit = prefixCache?.takeAdmittedCapture()
            if let prefixCache, prefixCache.enabled, let owned = session, !owned.prefixCaptureFrontiers.isEmpty {
                owned.prefixCaptureLimitBytes = captureLimit
                owned.prefixCaptureMaximumFrontiers = prefixCache.entryLimit
                // Conservative until measured: F32 rows and an Int32 token.
                owned.prefixHistoryBytesPerToken = decoder == nil ? 0 : agreement.request.profile.hiddenSize * 4 + 4
                prefixCache.makeRoom(forCapture: captureLimit ?? 0)
            }
            if let decoder, let prefixCache, prefixCache.enabled {
                // The head keeps this prompt's history for the entries this
                // request stores, and a restored prefix brings its own back:
                // the head then drafts from the whole prompt, as a cold
                // request's does. Exactness never depends on it.
                decoder.keepsHistory = prefix.splitFinalToken
                let reused = prefix.reusedPromptTokens
                if reused > 0 {
                    let tokens = Array(unplannedAgreement.request.promptTokenIDs[0..<reused])
                    let history = prefixCache.state(scope: qwenStagePrefixScope(agreement),
                        tokens: unplannedAgreement.request.promptTokenIDs, frontier: reused)?.speculativeHistory
                    let adopted = history.map { decoder.adopt($0, prefixTokens: tokens) } ?? false
                    log("darkbloom-prefix-v1 rank=\(collective.rank) mtp-history=\(adopted ? "restored" : "absent")"
                        + " frontier=\(reused)")
                }
            }
            diagnostics?.request = agreement.request
            let control = QwenLayerStageGenerationControl(agreement: agreement)
            let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: collective)
            var producer: QwenGenerationLookaheadProducer?
            do {
                let owned = session!
                if agreement.prefillPolicy == .oneChunkLookahead, collective.rank == 0 {
                    producer = try .init(request: agreement.request)
                }
                var selectedTokens = [Int]()
                var finalDecision: QwenLayerStageGenerationDecisionPacket?
                // A phase-split request leaves this loop after its first agreed
                // token and decision; a pipeline request runs it to the end.
                let split = agreement.phaseSplit
                while control.phase == .frame,
                      split.map({ control.selectedTokenCount < $0.terms.handoffSelectedTokens }) ?? true {
                    try autoreleasepool {
                        try checked()
                        let expected = try control.beginFrame()
                        if agreement.compactDecode, expected.frame.phase == .decode {
                            guard producer == nil || producer!.isComplete else {
                                throw ProbeError("Generation decode precedes lookahead prompt drain")
                            }
                            // The same step with fewer transfers; see the transport.
                            let step = try runCompactDecodeFrame(session: owned, control: control, transport: transport,
                                expected: expected, onCommittedToken: onCommittedToken, check: checked)
                            selectedTokens.append(step.selected)
                            if control.phase == .retiring {
                                finalDecision = step.decision
                                try diagnostics?.captureFinalRow(step.row, frame: expected.frame,
                                    tokenID: step.selected, check: checked)
                            }
                            return
                        }
                        let packet: QwenLayerStageGenerationBoundaryPacket
                        let row: MLXArray?
                        if let producer, expected.frame.phase == .prefill {
                            packet = try producer.run(session: owned, control: control,
                                transport: transport, expected: expected, check: checked)
                            row = nil
                        } else {
                            guard producer == nil || producer!.isComplete else {
                                throw ProbeError("Generation decode precedes lookahead prompt drain")
                            }
                            (packet, row) = try runGenerationFrame(session: owned, control: control,
                                transport: transport, expected: expected, check: checked)
                        }
                        guard control.phase == .token else { return }
                        let token = try agreeGenerationToken(row: row, boundary: packet, control: control,
                            transport: transport, check: checked)
                        let selected = try control.takeCommittedToken()
                        selectedTokens.append(selected)
                        // The scalar agreement is complete. No next forward can run
                        // while this callback is active or before decision agreement.
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
                        if control.phase == .retiring {
                            finalDecision = decision
                            // Both decision ACKs are complete, and rank1 still owns
                            // the final native row inside this frame's pool.
                            try diagnostics?.captureFinalRow(row, frame: expected.frame,
                                tokenID: selected, check: checked)
                        }
                    }
                }
                var handedOver: QwenPhaseSplitOutcome?
                if let split, control.phase == .frame {
                    guard producer == nil || producer!.isComplete else {
                        throw ProbeError("Hand-off precedes lookahead prompt drain")
                    }
                    // Hand-off, then rank 1 decodes alone. Both sessions' request
                    // state is retired inside; only the retirement exchange is left.
                    let outcome = try QwenPhaseSplitGeneration.run(producerStage: producerStage, plan: plan,
                        split: split, control: control, transport: transport, session: owned,
                        selectedTokens: &selectedTokens, recording: diagnostics, fault: phaseSplitFault,
                        decoder: decoder, onCommittedToken: onCommittedToken, check: checked)
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
                if handedOver == nil {
                    // Snapshot committed local state before finishGeneration retires it.
                    // No extra collective is introduced: the existing retirement ACK
                    // exchange cannot complete until both local captures have returned.
                    try diagnostics?.captureState(session: owned, stage: plan.stages[collective.rank],
                        selectedTokenIDs: selectedTokens, completedFrames: control.completedFrames,
                        committedTokens: control.committedTokens, reason: reason, check: checked)
                    try owned.finishGeneration(reason, selectedTokenCount: control.selectedTokenCount, lastTokenID: lastToken)
                }
                guard owned.isClosed, !owned.isFailed else { throw ProbeError("Generation native state failed retirement") }
                try control.acknowledgeRetirement(rank: collective.rank, disposition: .retired)
                try transport.exchangeRetirement(decision: finalDecision, check: checked)
                try control.acknowledgeRetirement(rank: 1 - collective.rank, disposition: .retired)
                try checked()
                guard control.isRetired, !control.isFailed, !transport.isFailed else {
                    throw ProbeError("Generation both-rank retirement is incomplete")
                }
                // The head's history at each kept frontier, taken before the
                // decoder lets go of it.
                let histories = decoder.map { decoder in
                    { (frontier: Int) in decoder.prefixHistory(at: frontier) }
                }
                defer { decoder?.release() }
                // Both ranks retired cleanly: only now do this rank's captured
                // frontiers become reusable. A failed request stores nothing.
                var stored: [Int] = []
                if let prefixCache, prefixCache.enabled {
                    var states = owned.capturedPrefixStates()
                    if let histories {
                        for index in states.indices { states[index].speculativeHistory = histories(states[index].committedTokens) }
                    }
                    let historyBytes = states.isEmpty ? 0 : decoder?.keptHistoryBytes ?? 0
                    prefixCache.insert(scope: qwenStagePrefixScope(agreement), tokens: agreement.request.promptTokenIDs,
                        states: states, sharedBytes: owned.capturedSharedBytes + historyBytes)
                    if let cost = owned.prefixCaptureCost {
                        let tokens = max(1, agreement.request.promptCount - 1)
                        prefixCache.record(.init(attentionBytesPerToken: cost.attentionBytesPerToken,
                            recurrentBytesPerFrontier: cost.recurrentBytesPerFrontier,
                            historyBytesPerToken: historyBytes > 0 ? (historyBytes + tokens - 1) / tokens
                                : cost.historyBytesPerToken))
                    }
                    stored = states.map(\.committedTokens)
                    log("darkbloom-prefix-v1 rank=\(collective.rank) held_bytes=\(prefixCache.bytesInUse)"
                        + " budget_bytes=\(prefixCache.budgetBytes) capture_limit=\(captureLimit.map(String.init) ?? "none")"
                        + " captured_shared=\(owned.capturedSharedBytes + historyBytes)"
                        + " captured_own=\(states.reduce(0) { $0 + $1.ownBytes })")
                }
                owned.discardCapturedPrefix()
                let prefixSummary = QwenStagePrefixSummary(reusedPromptTokens: prefix.reusedPromptTokens,
                    agreedPromptTokens: prefix.agreedPromptTokens, splitFinalToken: prefix.splitFinalToken,
                    storedFrontiers: stored, cacheEntries: prefixCache?.count ?? 0)
                var result = QwenLayerStageGenerationResult(agreementFingerprint: agreement.fingerprint,
                    membershipEpoch: agreement.descriptor.membershipEpoch, identity: owned.identity,
                    selectedTokenIDs: selectedTokens, tokenChainSHA256: control.tokenChainSHA256,
                    completedFrames: control.completedFrames, committedTokens: control.committedTokens,
                    finishReason: reason, prefillSchedule: agreement.prefillPolicy == .serial ? nil
                        : .init(policy: agreement.prefillPolicy.rawValue, rank: collective.rank,
                            preparedAheadFrames: producer?.preparedAheadFrames ?? 0,
                            maximumPreparedBoundaries: producer?.maximumPreparedBoundaries ?? 0),
                    phaseSplit: handedOver?.summary, prefixCache: prefixCache == nil ? nil : prefixSummary)
                result.mtpEnabled = agreement.speculativeHead != nil
                return (result, handedOver?.recorded)
            } catch {
                // Prefer a recorded native fault before invoking any cleanup. The
                // normal withError epilogue is skipped when its body throws Swift.
                var primary: Error = error
                do { try nativeError.check() } catch { primary = error }
                producer?.cancel()
                decoder?.release()
                session?.discardCapturedPrefix()
                diagnostics?.discard()
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

private func requireGenerationSource(loaded: LoadedQwenLayerStage, plan: QwenLayerStagePlan,
    agreement: QwenLayerStageGenerationAgreement, collective: Collective) throws {
    let source = agreement.descriptor, receipt = loaded.receipt
    guard collective.size == 2, (0...1).contains(collective.rank),
          loaded.stageIndex == collective.rank, plan.stages.count == 2,
          source.planFingerprint == plan.fingerprint, loaded.plan.fingerprint == plan.fingerprint,
          source.stageFingerprints == plan.stages.map(\.fingerprint),
          source.sourceConfigurationSHA256 == sha256(plan.originalConfiguration),
          receipt.sourceConfigurationSHA256 == source.sourceConfigurationSHA256,
          receipt.verifiedAggregateSHA256 == source.artifactAggregateSHA256,
          receipt.storageCommitmentSHA256 == source.storageCommitmentSHA256,
          receipt.stagePlanSHA256 == source.stageFingerprints[collective.rank],
          receipt.planSHA256 == source.planFingerprint,
          agreement.request.profile.vocabularySize == loaded.vocabularySize,
          agreement.request.profile.activationDType == String(describing: loaded.activationDType) else {
        throw ProbeError("Generation actual loaded stage/source/rank differs from agreement")
    }
    // Reuse the actual transport's limit before readiness or request-state
    // construction. The session separately checks this profile's hidden width
    // against the loaded configuration before it constructs native state.
    _ = try CollectivePointToPointShape(
        shape: [1, min(agreement.request.chunkSize, agreement.request.promptCount), agreement.request.profile.hiddenSize],
        dtype: loaded.activationDType, maximumBytes: CollectivePointToPointShape.hardByteLimit)
}

private func runGenerationFrame(session: QwenLayerStageSession, control: QwenLayerStageGenerationControl,
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
            // Header/payload identity establishes the producer's completed frame;
            // no consumed ACK is sent until this actual consumer commit returns.
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

/// One decode step of a declared compact-decode request: four transfers. Each
/// control acknowledgement follows this rank's own commit or a validated
/// message from the peer, in the order the pipeline's step establishes them.
private func runCompactDecodeFrame(session: QwenLayerStageSession, control: QwenLayerStageGenerationControl,
    transport: QwenLayerStageGenerationTransport, expected: QwenLayerStageGenerationBoundaryExpectation,
    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void
) throws -> (selected: Int, decision: QwenLayerStageGenerationDecisionPacket, row: MLXArray?) {
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
        return (selected, decision, nil)
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
    return (selected, decision, row)
}

private func agreeGenerationToken(row: MLXArray?, boundary: QwenLayerStageGenerationBoundaryPacket,
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

/// The agreed prefix plan and this rank's session for it.
private struct QwenStagePrefixPlanOutcome {
    let agreement: QwenLayerStageGenerationAgreement
    let session: QwenLayerStageSession
    let summary: QwenStagePrefixSummary
}

/// Exchange 1: each rank offers the frontiers it holds for this prompt; both
/// derive the same choice. Each rank restores that frontier into a new
/// session. Exchange 2: both confirm the choice, the key and the restore;
/// unless all agree, both ranks discard what they restored and prefill from
/// zero. Both exchanges run whether or not a cache exists, so the two ranks
/// always take the same steps.
private func agreeQwenStagePrefixPlan(cache: QwenStagePrefixCache?, loaded: LoadedQwenLayerStage,
    plan: QwenLayerStagePlan, agreement: QwenLayerStageGenerationAgreement, collective: Collective,
    hiddenTap: QwenLayerStageHiddenTap? = nil, check: () throws -> Void
) throws -> QwenStagePrefixPlanOutcome {
    let request = agreement.request, scope = qwenStagePrefixScope(agreement)
    let enabled = cache?.enabled ?? false
    let local = QwenStagePrefixOffer(enabled: enabled, frontiers: enabled
        ? cache!.frontiers(scope: scope, tokens: request.promptTokenIDs, maximumFrontier: request.promptCount - 1) : [])
    let peer = QwenStagePrefixOffer(words: try exchangeQwenStagePrefixWords(collective: collective,
        words: local.words, check: check), promptCount: request.promptCount)
    let choice = QwenStagePrefixChoice.choose(local: local, peer: peer, promptCount: request.promptCount)
    var restoredSession: QwenLayerStageSession?
    var key: String?
    if choice.reusedPrefix > 0, let cache,
       let state = cache.state(scope: scope, tokens: request.promptTokenIDs, frontier: choice.reusedPrefix) {
        key = QwenStagePrefixCache.key(scope: scope, tokens: request.promptTokenIDs[0..<choice.reusedPrefix])
        do {
            let planned = try request.planned(reusedPrefix: choice.reusedPrefix, splitFinalToken: choice.splitFinalToken)
            restoredSession = try QwenLayerStageSession(stage: loaded, plan: plan, generationRequest: planned,
                adopting: state.adopted, hiddenTap: hiddenTap)
        } catch {
            // This rank could not restore; the confirmation says so and both
            // ranks prefill from zero. A native fault still surfaces below.
            log("darkbloom-prefix-v1 rank=\(collective.rank) restore-failed frontier=\(choice.reusedPrefix): \(error)")
            restoredSession = nil
        }
        try check()
    }
    let confirmation = QwenStagePrefixConfirmation(choice: choice,
        restored: choice.reusedPrefix == 0 || restoredSession != nil, key: key)
    let peerConfirmation = QwenStagePrefixConfirmation(words: try exchangeQwenStagePrefixWords(collective: collective,
        words: confirmation.words, check: check))
    let settled = QwenStagePrefixConfirmation.settle(local: confirmation, peer: peerConfirmation)
    if settled.reusedPrefix != choice.reusedPrefix || restoredSession == nil {
        try restoredSession?.cancel(); restoredSession = nil
    }
    let plannedRequest = try request.planned(reusedPrefix: settled.reusedPrefix, splitFinalToken: settled.splitFinalToken)
    let plannedAgreement = try agreement.planned(plannedRequest)
    let session = try restoredSession
        ?? QwenLayerStageSession(stage: loaded, plan: plan, generationRequest: plannedRequest, hiddenTap: hiddenTap)
    if enabled, let cache, settled.splitFinalToken {
        session.prefixCaptureFrontiers = plannedRequest.prefixCaptureFrontiers(stride: cache.stride(chunkSize: request.chunkSize))
    }
    if settled.reusedPrefix > 0 || choice.reusedPrefix > 0 {
        log("darkbloom-prefix-v1 rank=\(collective.rank) agreed=\(choice.reusedPrefix) reused=\(settled.reusedPrefix) prompt=\(request.promptCount)")
    }
    return .init(agreement: plannedAgreement, session: session, summary: .init(
        reusedPromptTokens: settled.reusedPrefix, agreedPromptTokens: choice.reusedPrefix,
        splitFinalToken: settled.splitFinalToken, storedFrontiers: [], cacheEntries: cache?.count ?? 0))
}
