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
///
/// `speculativeRounds` (`pipeline_mtp_v1`): the agreed terms on both ranks;
/// rank 1 is also handed the head. Decode then runs as speculative rounds
/// (`QwenPipelineMTPGeneration`) after the prompt and the first token.
func runQwenLayerStageGenerationRequest(loaded: LoadedQwenLayerStage,
    producerStage: LoadedQwenLayerStage? = nil, speculativeHead: QwenMTPHead? = nil,
    speculativeRounds: QwenMTPTerms? = nil,
    plan: QwenLayerStagePlan, agreement: QwenLayerStageGenerationAgreement,
    collective: Collective, prefixCache: QwenStagePrefixCache? = nil, onCommittedToken: (Int) throws -> Bool,
    check: () throws -> Void
) throws -> QwenLayerStageGenerationResult {
    try runQwenLayerStageGenerationCore(loaded: loaded, producerStage: producerStage, speculativeHead: speculativeHead,
        speculativeRounds: speculativeRounds, plan: plan, agreement: agreement,
        collective: collective, diagnostics: nil, prefixCache: prefixCache, onCommittedToken: onCommittedToken,
        check: check).result
}

/// Explicit diagnostic entry for an already owned reservation. The owner must
/// pass the exact allowance derived for that reservation and retain all existing
/// build/source/arithmetic, deadline and cancellation checks. There is no default
/// diagnostic mode or permissive resource callback. Do not time this as serving.
///
/// `speculativeRounds` (`pipeline_mtp_v1`): the request runs its rounds as
/// served, and rank 1 also records one step per selected token from the row
/// that token was taken from (`QwenRecordedStep`): the accepted timeline.
func recordQwenLayerStageGenerationRequest(loaded: LoadedQwenLayerStage,
    producerStage: LoadedQwenLayerStage? = nil, speculativeHead: QwenMTPHead? = nil,
    speculativeRounds: QwenMTPTerms? = nil, plan: QwenLayerStagePlan, agreement: QwenLayerStageGenerationAgreement,
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
        speculativeHead: speculativeHead, speculativeRounds: speculativeRounds, plan: plan, agreement: agreement,
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
    speculativeRounds: QwenMTPTerms? = nil, plan: QwenLayerStagePlan, agreement unplannedAgreement: QwenLayerStageGenerationAgreement,
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
            // The decoding rank of a speculative phase split, and the last rank
            // of a speculative pipeline, hold the head; no other rank, and no
            // other request, may be handed one. A pipeline's rounds are the
            // agreement's decode framing, on both ranks; a recording request
            // runs them too (its rank 1 records the accepted timeline).
            try requireQwenSpeculativeRole(agreement: unplannedAgreement, rounds: speculativeRounds,
                holdsHead: speculativeHead != nil, rank: collective.rank)
            try checked()
            _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                material: { .generation(agreementFingerprint: unplannedAgreement.fingerprint) },
                disagreementMessage: "Generation membership/request/source readiness differs",
                scope: .request(.requestAgreement, requestID: unplannedAgreement.request.requestID,
                    agreementFingerprint: unplannedAgreement.fingerprint, "generation-readiness"), check: checked)
            // Before the session: the consumer stage's computed prompt rows are
            // the head's history. A prefix reused from the cache is not observed
            // again (exact tokens either way; the head drafts from what it saw).
            var decoder: QwenMTPDecoder?
            if let speculativeHead, let terms = unplannedAgreement.speculativeHead ?? speculativeRounds {
                decoder = try QwenMTPDecoder(head: speculativeHead, terms: terms, request: unplannedAgreement.request)
            }
            // Prefix plan, before the first forward: both ranks agree what to
            // reuse, restore it, and confirm; anything else prefills from zero
            // on both ranks.
            var session: QwenLayerStageSession?
            let prefix: QwenStagePrefixSummary
            let agreement: QwenLayerStageGenerationAgreement
            // A request routed to the decoding rank alone reuses and keeps no
            // prompt prefix: both ranks skip the prefix exchanges alike (the
            // route is in the agreement both checked above).
            let alone = unplannedAgreement.request.decodingRankAlone
            if alone {
                agreement = unplannedAgreement
                session = try QwenLayerStageSession(stage: loaded, plan: plan, generationRequest: agreement.request,
                    hiddenTap: collective.rank == 1 ? decoder?.tap() : nil)
                prefix = .init(reusedPromptTokens: 0, agreedPromptTokens: 0, splitFinalToken: false, storedFrontiers: [],
                    cacheEntries: prefixCache?.count ?? 0)
            } else {
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
                owned.prefixCaptureMaximumFrontiers = prefixCache.frontiersPerPrompt
                // The history cost the reservation charged: measured once a capture
                // of this stage was, conservative before (F32 rows and an Int32
                // token), so the session keeps what its charge was computed for.
                owned.prefixHistoryBytesPerToken = decoder == nil ? 0
                    : prefixCache.historyBytesPerToken(estimate: agreement.request.profile.hiddenSize * 4 + 4)
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
            if let prefixCache, prefixCache.enabled, let owned = session {
                // The running check may withdraw this capture when memory runs
                // short (`QwenStagePrefixCache.withdrawCapture`): the session lets
                // go of its frontiers and the head of its history, and the
                // request goes on. The head keeps a history only for a prompt
                // the session keeps.
                decoder?.historyWanted = { [weak owned] in owned?.keepsPrefixCapture ?? false }
                prefixCache.beginCapture { [weak owned, weak decoder] in
                    owned?.withdrawPrefixCapture(); decoder?.dropKeptHistory()
                }
            }
            defer { prefixCache?.endCapture() }
            diagnostics?.request = agreement.request
            diagnostics?.recordsSteps = speculativeRounds != nil && collective.rank == 1
            let control = QwenLayerStageGenerationControl(agreement: agreement)
            let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: collective)
            var producer: QwenGenerationLookaheadProducer?
            do {
                let owned = session!
                if agreement.prefillPolicy == .oneChunkLookahead, collective.rank == 0, !alone {
                    producer = try .init(request: agreement.request)
                }
                var selectedTokens = [Int]()
                var finalDecision: QwenLayerStageGenerationDecisionPacket?
                var discardedDecodeForwards = 0
                var roundStatistics: QwenMTPStatistics?
                // A phase-split request leaves this loop after its first agreed
                // token and decision; a pipeline request runs it to the end.
                let split = agreement.phaseSplit
                // A request the decoding rank serves alone runs no pair frame at all.
                while control.phase == .frame, !alone,
                      split.map({ control.selectedTokenCount < $0.terms.handoffSelectedTokens }) ?? true {
                    try autoreleasepool {
                        try checked()
                        if let speculativeRounds, control.selectedTokenCount > 0 {
                            // The prompt and the first token ran as frames; decode runs as rounds.
                            guard producer == nil || producer!.isComplete else {
                                throw ProbeError("Speculative rounds precede lookahead prompt drain")
                            }
                            let outcome: QwenPipelineMTPGeneration.Outcome
                            if collective.rank == 0 {
                                outcome = try QwenPipelineMTPGeneration.runProducer(session: owned, control: control,
                                    terms: speculativeRounds, collective: collective, recording: diagnostics,
                                    onCommittedToken: onCommittedToken, check: checked)
                            } else {
                                guard let decoder else { throw ProbeError("Speculative rounds need the head on rank 1") }
                                try decoder.begin(firstToken: selectedTokens[0])
                                outcome = try QwenPipelineMTPGeneration.runConsumer(session: owned, decoder: decoder,
                                    control: control, collective: collective, recording: diagnostics, check: checked)
                            }
                            selectedTokens += outcome.selected
                            finalDecision = outcome.finalDecision
                            discardedDecodeForwards = outcome.discardedDecodeForwards
                            roundStatistics = outcome.statistics
                            return
                        }
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
                        // A recorded speculative pipeline's first token: its step, from this frame's row.
                        if let diagnostics, diagnostics.recordsSteps, let row {
                            try diagnostics.captureStep(row, frame: expected.frame, tokenID: selected, check: checked)
                        }
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
                    let scope = qwenStagePrefixScope(agreement)
                    prefixCache.insert(scope: scope, tokens: agreement.request.promptTokenIDs,
                        states: states, sharedBytes: owned.capturedSharedBytes + historyBytes)
                    // The SSD record (stage state and the head's history) is
                    // written behind; serving does not wait for it.
                    prefixCache.disk?.persist(scope: scope, tokens: agreement.request.promptTokenIDs, states: states,
                        blockTokens: prefixCache.stride(chunkSize: agreement.request.chunkSize))
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
                        + " captured_own=\(states.reduce(0) { $0 + $1.ownBytes })"
                        + " capture_withdrawn=\(owned.prefixCaptureWithdrawn)")
                }
                owned.discardCapturedPrefix()
                let prefixSummary = QwenStagePrefixSummary(reusedPromptTokens: prefix.reusedPromptTokens,
                    restoredTier: prefix.restoredTier,
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
                result.mtpEnabled = agreement.speculativeHead != nil || speculativeRounds != nil
                result.speculativeRounds = roundStatistics
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

/// The decoding rank of a speculative phase split, and the last rank of a
/// speculative pipeline, hold the head; no other rank, and no other request,
/// may be handed one. A pipeline's rounds are the agreement's decode framing
/// on both ranks, never a phase split's. A recording request runs its rounds
/// as a served one does (its rank 1 records the accepted timeline).
func requireQwenSpeculativeRole(agreement: QwenLayerStageGenerationAgreement, rounds: QwenMTPTerms?,
                                holdsHead: Bool, rank: Int) throws {
    guard agreement.speculativeRoundsFraming == rounds?.pipelineDecodeFraming,
          rounds == nil || agreement.phaseSplit == nil,
          holdsHead == ((agreement.speculativeHead != nil || rounds != nil) && rank == 1) else {
        throw ProbeError("Speculative head differs from this rank's agreed role")
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
    _ = try qwenGenerationBoundaryGeometry(request: agreement.request, dtype: loaded.activationDType)
}

/// The largest actual prefill boundary, admitted before readiness/native state.
/// The local profile supplies every residual dimension, including GLM's streams;
/// neither the peer's header nor a flattened width can lower this byte charge.
func qwenGenerationBoundaryGeometry(request: QwenLayerStageGenerationRequest,
                                    dtype: DType, authenticatedChunking: Bool = false) throws -> CollectivePointToPointShape {
    guard String(describing: dtype) == request.profile.activationDType else {
        throw ProbeError("Generation boundary dtype differs from its admitted profile")
    }
    let shape = request.profile.boundaryShape(tokenCount: min(request.chunkSize, request.promptCount))
    if authenticatedChunking {
        return try .authenticatedArray(shape: shape, dtype: dtype,
            maximumBytes: CollectivePointToPointShape.authenticatedArrayByteLimit)
    }
    return try CollectivePointToPointShape(shape: shape,
        dtype: dtype, maximumBytes: CollectivePointToPointShape.hardByteLimit)
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
/// A stage whose rows the prefix tiers can keep: full rows as a prefix of the
/// deepest copy, sliding-window rows (Gemma 4) as their own window at each
/// frontier (`QwenLayerStageSession.capturePrefix`). A stage that reports no
/// geometry offers nothing and asks for no split, which turns reuse off for
/// both ranks (one rank off is enough).
func qwenStageAdmitsPrefixCapture(_ loaded: LoadedQwenLayerStage) -> Bool {
    guard let forwarding = loaded.model as? any LayerStageFrameForwarding else { return true }
    return (try? forwarding.layerStageRequestGeometry(maximumTokens: 1)) != nil
}

private func agreeQwenStagePrefixPlan(cache: QwenStagePrefixCache?, loaded: LoadedQwenLayerStage,
    plan: QwenLayerStagePlan, agreement: QwenLayerStageGenerationAgreement, collective: Collective,
    hiddenTap: QwenLayerStageHiddenTap? = nil, check: () throws -> Void
) throws -> QwenStagePrefixPlanOutcome {
    let request = agreement.request, scope = qwenStagePrefixScope(agreement)
    let enabled = (cache?.enabled ?? false) && qwenStageAdmitsPrefixCapture(loaded)
    // Both tiers: the resident entries and the SSD records this rank holds.
    var resident: [Int] = [], onDisk: [Int] = []
    if enabled, let cache {
        resident = cache.frontiers(scope: scope, tokens: request.promptTokenIDs, maximumFrontier: request.promptCount - 1)
        onDisk = cache.disk?.frontiers(scope: scope, tokens: request.promptTokenIDs,
            maximumFrontier: request.promptCount - 1) ?? []
    }
    let offered = Array(Set(resident).union(onDisk).sorted(by: >).prefix(QwenStagePrefixCache.maximumOffered))
    let local = QwenStagePrefixOffer(enabled: enabled, frontiers: offered, onDisk: Set(onDisk).subtracting(resident))
    let record = CollectiveRecordScope.request(.prefixAgreement, requestID: request.requestID,
        agreementFingerprint: agreement.fingerprint, "prefix")
    let peer = QwenStagePrefixOffer(words: try exchangeQwenStagePrefixWords(collective: collective,
        words: local.words, scope: record.part("offer"), check: check), promptCount: request.promptCount)
    let choice = QwenStagePrefixChoice.choose(local: local, peer: peer, promptCount: request.promptCount)
    var restoredSession: QwenLayerStageSession?
    var key: String?
    var tier: String?
    var fromDisk: QwenStagePrefixState?
    var restoredState: QwenStagePrefixState?
    if choice.reusedPrefix > 0, let cache {
        if let state = cache.state(scope: scope, tokens: request.promptTokenIDs, frontier: choice.reusedPrefix) {
            restoredState = state; tier = "resident"
            cache.disk?.touch(scope: scope, tokens: request.promptTokenIDs, frontier: choice.reusedPrefix)
        } else if let disk = cache.disk,
                  let state = try disk.restore(scope: scope, tokens: request.promptTokenIDs,
                      frontier: choice.reusedPrefix, check: check) {
            restoredState = state; fromDisk = state; tier = "ssd"
        }
    }
    if let state = restoredState {
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
            if tier == "ssd" { cache?.disk?.forget(scope: scope, tokens: request.promptTokenIDs, frontier: choice.reusedPrefix) }
        }
        try check()
    }
    let confirmation = QwenStagePrefixConfirmation(choice: choice,
        restored: choice.reusedPrefix == 0 || restoredSession != nil, key: key)
    let peerConfirmation = QwenStagePrefixConfirmation(words: try exchangeQwenStagePrefixWords(collective: collective,
        words: confirmation.words, scope: record.part("confirmation"), check: check))
    let settled = QwenStagePrefixConfirmation.settle(local: confirmation, peer: peerConfirmation)
    if settled.reusedPrefix != choice.reusedPrefix || restoredSession == nil {
        // Both ranks prefill from zero. A state THIS rank read and adopted
        // from its SSD is still this rank's valid state at that frontier: it
        // stays resident (within the budget, giving way as any entry) so the
        // next offer finds it in memory instead of reading and decrypting the
        // record again (oMLX U#3327: no duplicate restore work).
        let ownRestoreHeld = restoredSession != nil
        try restoredSession?.cancel(); restoredSession = nil; tier = nil
        if ownRestoreHeld, let fromDisk, let cache {
            cache.insert(scope: scope, tokens: request.promptTokenIDs, states: [fromDisk], sharedBytes: fromDisk.sharedBytes)
            log("darkbloom-prefix-v1 rank=\(collective.rank) event=restore-kept frontier=\(choice.reusedPrefix) reason=peer_cold")
        }
    } else if let fromDisk, let cache {
        // Both ranks restored the same frontier from what each holds; a state
        // read from disk becomes resident too, on both ranks alike, so the
        // next repeat is a memory hit (it gives way under pressure as any entry).
        cache.insert(scope: scope, tokens: request.promptTokenIDs, states: [fromDisk], sharedBytes: fromDisk.sharedBytes)
    }
    fromDisk = nil; restoredState = nil
    let plannedRequest = try request.planned(reusedPrefix: settled.reusedPrefix, splitFinalToken: settled.splitFinalToken)
    let plannedAgreement = try agreement.planned(plannedRequest)
    let session = try restoredSession
        ?? QwenLayerStageSession(stage: loaded, plan: plan, generationRequest: plannedRequest, hiddenTap: hiddenTap)
    if enabled, let cache, settled.splitFinalToken {
        session.prefixCaptureFrontiers = plannedRequest.prefixCaptureFrontiers(stride: cache.stride(chunkSize: request.chunkSize))
    }
    if settled.reusedPrefix > 0 || choice.reusedPrefix > 0 {
        log("darkbloom-prefix-v1 rank=\(collective.rank) agreed=\(choice.reusedPrefix) reused=\(settled.reusedPrefix)"
            + " prompt=\(request.promptCount) tier=\(tier ?? "none") peer_disk=\(peer.onDisk.contains(choice.reusedPrefix))")
    }
    return .init(agreement: plannedAgreement, session: session, summary: .init(
        reusedPromptTokens: settled.reusedPrefix, restoredTier: tier, agreedPromptTokens: choice.reusedPrefix,
        splitFinalToken: settled.splitFinalToken, storedFrontiers: [], cacheEntries: cache?.count ?? 0))
}
