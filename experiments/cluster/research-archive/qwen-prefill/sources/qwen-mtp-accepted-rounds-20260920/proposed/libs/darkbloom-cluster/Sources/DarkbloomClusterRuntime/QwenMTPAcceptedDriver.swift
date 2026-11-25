import Foundation
import MLX

struct QwenMTPAcceptedRoundEvidence: Encodable {
    let proposal: QwenResidentMTPProposal
    let verificationFingerprint: String
    let stagedInputs: Int
    let keptInputs: Int
    let selectedTokens: [Int]
    let receipts: [[QwenTargetVerificationLocalReceipt]]
}
struct QwenMTPAcceptedEvidence: Encodable {
    let schema = "qwen_registered_mtp_accepted_depth1_v1"
    let policySHA256: String
    let target: QwenGenerationDiagnosticEvidence
    let rounds: [QwenMTPAcceptedRoundEvidence]
    let assistantRequestReleased: Bool?
    let mtpEnabled = true
    let correctnessOnly = true
    let encryptedTransportQualified = false
    let throughputMeasurementValid = false
}

private final class QwenMTPAcceptedHistoryOwner: QwenGenerationHistoryOwner {
    let owner: QwenResidentMTPRequest
    init(_ owner: QwenResidentMTPRequest) { self.owner = owner }
    func forward(tokens: [Int], frame: QwenLayerStageFrame, incoming: QwenLayerStageBoundary,
                 check: () throws -> Void) throws -> QwenLayerStageOutput {
        if frame.phase == .prefill {
            return try owner.prefill(tokens: tokens, frame: frame, incoming: incoming, check: check)
        }
        // The final single remaining target input needs no unusable draft.
        guard tokens.count == 1 else { throw ProbeError("MTP ordinary tail requires one input") }
        return try owner.probeSession.decode(tokens[0], offset: frame.tokenOffset, incoming: incoming, check: check)
    }
}

/// One request under the original resident reservation and process fence.
/// Every thrown path retires local state; the external owner must still fence
/// the peer before releasing its lease. No successful throw-only retirement.
func runQwenMTPAcceptedRequest(loaded: QwenResidentLoadedStage, assets: QwenResidentStageWithMTPAssets?,
    plan: QwenLayerStagePlan, agreement: QwenLayerStageGenerationAgreement, collective: Collective,
    resources: QwenMTPAcceptedResources, deadline: UInt64,
    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void) throws -> QwenMTPAcceptedEvidence {
    try withoutActuallyEscaping(check) { borrowedCheck in
        try withoutActuallyEscaping(onCommittedToken) { borrowedToken in
            try MLX.withError { nativeError in
                do {
                    func checked() throws {
                        try nativeError.check(); try borrowedCheck(); try resources.requireLive(); try nativeError.check()
                    }
                    guard agreement.descriptor.mtpEnabled,
                          agreement.descriptor.mtpPolicySHA256 == QwenMTPAcceptedPolicy.registered9BDepth1Short.fingerprint else {
                        throw ProbeError("Accepted MTP driver requires its explicit agreement policy")
                    }
                    try requireGenerationSource(loaded: loaded.loaded, plan: plan, agreement: agreement, collective: collective)
                    let diagnostics = try QwenGenerationDiagnosticResources(loaded: loaded.loaded, profile: loaded.profile,
                        plan: plan, request: agreement.request, rank: collective.rank, requestAllowance: resources.base)
                    try resources.recording.requireCapture(diagnostics.budget)
                    let capture = QwenGenerationDiagnosticCapture(request: agreement.request, rank: collective.rank, resources: diagnostics)
                    defer { capture.discard() }
                    let generation = QwenLayerStageGenerationControl(agreement: agreement)
                    let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: collective)
                    let mtpTransport = try QwenMTPAcceptedTransport(collective: collective)
                    let rounds = QwenMTPAcceptedRoundControl()
                    var session: QwenLayerStageSession?
                    var history: QwenMTPAcceptedHistoryOwner?
                    do {
                        try checked()
                        _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                            material: { .generation(agreementFingerprint: agreement.fingerprint) },
                            disagreementMessage: "MTP policy/request/source readiness differs", check: checked)
                        let owned: QwenLayerStageSession
                        if collective.rank == 1 {
                            guard let assets else { throw ProbeError("Accepted MTP final rank lacks loaded assistant") }
                            let owner = try QwenResidentMTPRequest(assets: assets, plan: plan, agreement: agreement,
                                capacityLimitBytes: resources.reservedBytes, deadlineUptimeNanoseconds: deadline,
                                acceptedMode: true, check: checked)
                            history = .init(owner); owned = owner.probeSession
                        } else { owned = try .init(stage: loaded.loaded, plan: plan, generationRequest: agreement.request) }
                        session = owned
                        var selected = [Int](), evidence = [QwenMTPAcceptedRoundEvidence]()
                        var finalDecision: QwenLayerStageGenerationDecisionPacket?
        
                        func publish(row: MLXArray?, packet: QwenLayerStageGenerationBoundaryPacket,
                                     frame: QwenLayerStageFrame) throws -> Int {
                            let tokenPacket = try agreeGenerationToken(row: row, boundary: packet, control: generation,
                                transport: transport, check: checked)
                            let token = try generation.takeCommittedToken(); selected.append(token)
                            let decision = try mtpGenerationDecision(token: tokenPacket, generation: generation,
                                transport: transport, onCommittedToken: borrowedToken, check: checked)
                            if generation.phase == .retiring {
                                finalDecision = decision
                                try capture.captureFinalRow(row, frame: frame, tokenID: token, check: checked)
                            }
                            return token
                        }
        
                        while generation.phase == .frame {
                            try autoreleasepool {
                                try checked()
                                let remaining = agreement.request.forwardCount - generation.completedFrames
                                if generation.committedTokens < agreement.request.promptCount || remaining == 1 {
                                    let expected = try generation.beginFrame()
                                    let (packet, row) = try runGenerationFrame(session: owned, control: generation,
                                        transport: transport, expected: expected, probe: history, check: checked)
                                    if expected.frame.phase == .prefill {
                                        try history?.owner.observeCommitted(generation: generation, check: checked)
                                    }
                                    if generation.phase == .token { _ = try publish(row: row, packet: packet, frame: expected.frame) }
                                    return
                                }
        
                                let localProposal = try history?.owner.proposeAccepted(generation: generation,
                                    roundID: UUID(), check: checked)
                                let request = try mtpTransport.proposal(localProposal, ordinal: rounds.roundCount,
                                    admit: { try rounds.begin(proposal: $0, generation: generation) }, check: checked)
                                func ownerCheck(_ budget: QwenTargetVerificationBudget) throws {
                                    try checked(); try resources.requireVerification(budget)
                                }
                                _ = try owned.beginTargetVerification(profile: loaded.profile, proposal: request.proposal,
                                    generation: generation, ownerCheck: ownerCheck)
                                var packets = [QwenMTPAcceptedWire.Boundary](), rows = [MLXArray]()
                                for step in 0..<request.maximumSteps {
                                    if collective.rank == 0 {
                                        guard case .provisionalHidden(let boundary) = try owned.stageTargetVerification(
                                            roundID: request.proposal.roundID, step: step, ownerCheck: ownerCheck) else {
                                            throw ProbeError("MTP ingress stage did not return a provisional residual")
                                        }
                                        packets.append(try mtpTransport.sendBoundary(boundary, request: request, step: step, check: checked))
                                    } else {
                                        let (row, packet): (MLXArray, QwenMTPAcceptedWire.Boundary) = try mtpTransport.receiveBoundary(
                                            request: request, step: step, consume: { incoming in
                                                guard case .provisionalLogits(let row) = try owned.stageTargetVerification(
                                                    roundID: request.proposal.roundID, step: step, incoming: incoming, ownerCheck: ownerCheck) else {
                                                    throw ProbeError("MTP final stage did not return a provisional row")
                                                }
                                                return row
                                            }, check: checked)
                                        rows.append(row); packets.append(packet)
                                    }
                                    try rounds.didStage(step: step)
                                }
                                var hidden = [MLXArray](), receiptSets = [[QwenTargetVerificationLocalReceipt]]()
                                var roundTokens = [Int]()
                                for step in 0..<request.maximumSteps {
                                    try rounds.authorizeCommit(generation: generation)
                                    let expected = try generation.beginFrame()
                                    guard expected.frame == (try request.frame(step: step)) else { throw ProbeError("MTP commit frame differs") }
                                    let commit = try owned.commitNextTargetVerification(roundID: request.proposal.roundID, ownerCheck: ownerCheck)
                                    defer { commit.discard() }
                                    let receipts = try mtpTransport.receipts(commit.localReceipt, check: checked)
                                    let joined = try rounds.joinCommit(receipts)
                                    receiptSets.append(receipts)
                                    let localRows = try commit.takeLocalHiddenRows()
                                    guard localRows.count == (collective.rank == 1 ? 1 : 0),
                                          owned.committedTokens == joined.committedInputs else { throw ProbeError("MTP local commit rows/frontier differ") }
                                    hidden.append(contentsOf: localRows)
                                    let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: packets[step].payloadSHA256)
                                    // These frame acknowledgements follow BOTH real prefix
                                    // receipts. A provisional-staged ACK never reaches here.
                                    for rank in 0...1 {
                                        try generation.acknowledgeFrame(rank: rank, packet: packet, nativeCommittedTokens: joined.committedInputs)
                                    }
                                    let token = try publish(row: collective.rank == 1 ? rows[step] : nil, packet: packet, frame: expected.frame)
                                    roundTokens.append(token)
                                    if generation.phase != .frame || (step == 0 && token != request.proposal.proposedTokenID) { break }
                                }
                                let final = try owned.reconcileTargetVerification(roundID: request.proposal.roundID,
                                    keepingInputs: rounds.committed, ownerCheck: ownerCheck)
                                defer { final.discard() }
                                let receipts = try mtpTransport.receipts(final.localReceipt, check: checked)
                                let joined = try rounds.joinReconciliation(receipts)
                                receiptSets.append(receipts)
                                guard try final.takeLocalHiddenRows().isEmpty else { throw ProbeError("MTP final reconcile committed unpublished inputs") }
                                try history?.owner.finalizeAccepted(request: request, joined: joined, committedHidden: hidden, check: checked)
                                try rounds.finish(generation: generation)
                                evidence.append(.init(proposal: request.proposal, verificationFingerprint: request.fingerprint,
                                    stagedInputs: request.maximumSteps, keptInputs: joined.retainedInputs,
                                    selectedTokens: roundTokens, receipts: receiptSets))
                            }
                        }
                        guard generation.phase == .retiring, !generation.isFailed, let finalDecision,
                              let reason = generation.finishReason, let last = generation.lastTokenID,
                              selected.count == generation.selectedTokenCount, rounds.active == nil else {
                            throw ProbeError("Accepted MTP ended without reconciled agreed completion")
                        }
                        try capture.captureState(session: owned, stage: plan.stages[collective.rank], selectedTokenIDs: selected,
                            completedFrames: generation.completedFrames, committedTokens: generation.committedTokens, reason: reason, check: checked)
                        if let history { try history.owner.finishAccepted(reason: reason, selectedTokenCount: selected.count, lastTokenID: last, check: checked) }
                        else { try owned.finishGeneration(reason, selectedTokenCount: selected.count, lastTokenID: last) }
                        guard owned.isClosed, !owned.isFailed else { throw ProbeError("MTP native target state did not retire") }
                        try generation.acknowledgeRetirement(rank: collective.rank, disposition: .retired)
                        try transport.exchangeRetirement(decision: finalDecision, check: checked)
                        try generation.acknowledgeRetirement(rank: 1-collective.rank, disposition: .retired)
                        try checked()
                        guard generation.isRetired, !generation.isFailed, !transport.isFailed, !mtpTransport.failed else {
                            throw ProbeError("Accepted MTP bilateral retirement is incomplete")
                        }
                        var result = QwenLayerStageGenerationResult(agreementFingerprint: agreement.fingerprint,
                            membershipEpoch: agreement.descriptor.membershipEpoch, identity: owned.identity,
                            selectedTokenIDs: selected, tokenChainSHA256: generation.tokenChainSHA256,
                            completedFrames: generation.completedFrames, committedTokens: generation.committedTokens, finishReason: reason)
                        result.mtpEnabled = true
                        return .init(policySHA256: QwenMTPAcceptedPolicy.registered9BDepth1Short.fingerprint,
                            target: try capture.finish(execution: result, agreement: agreement, stage: plan.stages[collective.rank]),
                            rounds: evidence, assistantRequestReleased: history?.owner.probeAssistantRequestReleased)
                    } catch {
                        var primary: Error = error
                        do { try nativeError.check() } catch { primary = error }
                        capture.discard(); generation.cancel(); rounds.cancel(); transport.retire(); mtpTransport.retire()
                        var failures = [String]()
                        do { try history?.owner.retire(failed: true) } catch { failures.append("assistant: \(error)") }
                        do { try session?.cancel() } catch { failures.append("target: \(error)") }
                        guard failures.isEmpty else { throw ProbeError("MTP failed (\(primary)); retirement failed (\(failures.joined(separator: "; ")))") }
                        throw primary
                    }
                } catch { try nativeError.check(); throw error }
            }
        }
    }
}

private func mtpGenerationDecision(token: QwenLayerStageGenerationTokenPacket,
    generation: QwenLayerStageGenerationControl, transport: QwenLayerStageGenerationTransport,
    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void) throws -> QwenLayerStageGenerationDecisionPacket {
    if transport.rank == 0 {
        try check(); let proceed = try onCommittedToken(token.content.tokenID); try check()
        let decision = try generation.decide(continueRequested: proceed)
        try generation.acknowledgeDecision(rank: 0, packet: decision)
        try transport.sendDecision(decision, check: check)
        try generation.acknowledgeDecision(rank: 1, packet: decision)
        return decision
    }
    let decision = try transport.receiveDecision(token: token, check: check)
    let local = try generation.decide(continueRequested: decision.content.decision == .proceed)
    guard local.content == decision.content else { throw ProbeError("MTP owner decision differs from target stop policy") }
    try generation.acknowledgeDecision(rank: 0, packet: decision)
    try generation.acknowledgeDecision(rank: 1, packet: decision)
    try transport.acknowledgeDecision(decision, check: check)
    return decision
}
