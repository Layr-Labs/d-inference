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
func runQwenLayerStageGenerationRequest(loaded: LoadedQwenLayerStage,
    plan: QwenLayerStagePlan, agreement: QwenLayerStageGenerationAgreement,
    collective: Collective, onCommittedToken: (Int) throws -> Bool,
    check: () throws -> Void
) throws -> QwenLayerStageGenerationResult {
    try runQwenLayerStageGenerationCore(loaded: loaded, plan: plan, agreement: agreement,
        collective: collective, diagnostics: nil, onCommittedToken: onCommittedToken, check: check)
}

/// Explicit diagnostic entry for an already owned reservation. The owner must
/// pass the exact allowance derived for that reservation and retain all existing
/// build/source/arithmetic, deadline and cancellation checks. There is no default
/// diagnostic mode or permissive resource callback. Do not time this as serving.
func recordQwenLayerStageGenerationRequest(loaded: LoadedQwenLayerStage,
    profile: QwenRegisteredDenseModelProfile,
    plan: QwenLayerStagePlan, agreement: QwenLayerStageGenerationAgreement,
    collective: Collective, requestAllowance: QwenResidentRequestAllowance,
    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void
) throws -> QwenGenerationDiagnosticEvidence {
    let resources = try MLX.withError { nativeError in
        do {
            try check(); try nativeError.check()
            let value = try QwenGenerationDiagnosticResources(loaded: loaded, profile: profile,
                plan: plan, request: agreement.request,
                rank: collective.rank, requestAllowance: requestAllowance)
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
    let result = try runQwenLayerStageGenerationCore(loaded: loaded, plan: plan, agreement: agreement,
        collective: collective, diagnostics: capture, onCommittedToken: onCommittedToken, check: check)
    // The core has validated both retirement acknowledgements and its final
    // native error check. Only CPU values are assembled outside that scope.
    return try capture.finish(execution: result, agreement: agreement, stage: plan.stages[collective.rank])
}

private func runQwenLayerStageGenerationCore(loaded: LoadedQwenLayerStage,
    plan: QwenLayerStagePlan, agreement: QwenLayerStageGenerationAgreement,
    collective: Collective, diagnostics: QwenGenerationDiagnosticCapture?,
    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void
) throws -> QwenLayerStageGenerationResult {
    try MLX.withError { nativeError in
        func checked() throws {
            try nativeError.check(); try check()
            try diagnostics?.resources.requireLive()
            try nativeError.check()
        }
        do {
            try requireGenerationSource(loaded: loaded, plan: plan, agreement: agreement, collective: collective)
            try checked()
            _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                material: { .generation(agreementFingerprint: agreement.fingerprint) },
                disagreementMessage: "Generation membership/request/source readiness differs",
                recordScope: { try QwenGenerationRecordScopes(agreement: agreement).readiness() }, check: checked)
            let control = QwenLayerStageGenerationControl(agreement: agreement)
            let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: collective)
            var session: QwenLayerStageSession?
            var producer: QwenGenerationLookaheadProducer?
            do {
                let owned = try QwenLayerStageSession(stage: loaded, plan: plan, generationRequest: agreement.request)
                session = owned
                if agreement.prefillPolicy == .oneChunkLookahead, collective.rank == 0 {
                    producer = try .init(request: agreement.request)
                }
                var selectedTokens = [Int]()
                var finalDecision: QwenLayerStageGenerationDecisionPacket?
                while control.phase == .frame {
                    try autoreleasepool {
                        try checked()
                        let expected = try control.beginFrame()
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
                guard control.phase == .retiring, !control.isFailed,
                      let reason = control.finishReason, let lastToken = control.lastTokenID,
                      let finalDecision, selectedTokens.count == control.selectedTokenCount else {
                    throw ProbeError("Generation ended without agreed clean stop")
                }
                try checked()
                guard producer == nil || producer!.isComplete else {
                    throw ProbeError("Generation ended with a prepared or pending prompt boundary")
                }
                // Snapshot committed local state before finishGeneration retires it.
                // No extra collective is introduced: the existing retirement ACK
                // exchange cannot complete until both local captures have returned.
                try diagnostics?.captureState(session: owned, stage: plan.stages[collective.rank],
                    selectedTokenIDs: selectedTokens, completedFrames: control.completedFrames,
                    committedTokens: control.committedTokens, reason: reason, check: checked)
                try owned.finishGeneration(reason, selectedTokenCount: control.selectedTokenCount, lastTokenID: lastToken)
                guard owned.isClosed, !owned.isFailed else { throw ProbeError("Generation native state failed retirement") }
                try control.acknowledgeRetirement(rank: collective.rank, disposition: .retired)
                try transport.exchangeRetirement(decision: finalDecision, check: checked)
                try control.acknowledgeRetirement(rank: 1 - collective.rank, disposition: .retired)
                try checked()
                guard control.isRetired, !control.isFailed, !transport.isFailed else {
                    throw ProbeError("Generation both-rank retirement is incomplete")
                }
                return .init(agreementFingerprint: agreement.fingerprint,
                    membershipEpoch: agreement.descriptor.membershipEpoch, identity: owned.identity,
                    selectedTokenIDs: selectedTokens, tokenChainSHA256: control.tokenChainSHA256,
                    completedFrames: control.completedFrames, committedTokens: control.committedTokens,
                    finishReason: reason, prefillSchedule: agreement.prefillPolicy == .serial ? nil
                        : .init(policy: agreement.prefillPolicy.rawValue, rank: collective.rank,
                            preparedAheadFrames: producer?.preparedAheadFrames ?? 0,
                            maximumPreparedBoundaries: producer?.maximumPreparedBoundaries ?? 0))
            } catch {
                // Prefer a recorded native fault before invoking any cleanup. The
                // normal withError epilogue is skipped when its body throws Swift.
                var primary: Error = error
                do { try nativeError.check() } catch { primary = error }
                producer?.cancel()
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
