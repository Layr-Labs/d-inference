import Foundation
import MLX

/// What a recording run keeps of a phase-split request's final state. After the
/// hand-off rank 1 owns every layer, so its record covers the whole model and
/// rank 0's lists no state at all.
struct QwenPhaseSplitRecordedState {
    let finalFrame: QwenLayerStageFrame
    let entries: [QwenRecordedState.Entry]
    let logicalBytes: Int
    let fingerprint: String
    let finalLogits: QwenRecordedLogits?
}

struct QwenPhaseSplitOutcome {
    let finalDecision: QwenLayerStageGenerationDecisionPacket
    let summary: QwenPhaseSplitSummary
    let recorded: QwenPhaseSplitRecordedState?
}

/// The part of a declared phase-split request that follows the first selected
/// token: rank 0 hands its request state to rank 1 and then only publishes;
/// rank 1 adopts the state and decodes alone.
///
/// The caller is the generation driver, inside its native error scope, with
/// both ranks at the agreed frontier and the first token's decision `proceed`.
/// On a throw the caller retires `session`; the adopted producer session is
/// retired here.
enum QwenPhaseSplitGeneration {
    static func memory() -> QwenPhaseSplitSummary.Memory {
        let value = Memory.snapshot()
        return .init(activeBytes: value.activeMemory, cacheBytes: value.cacheMemory)
    }

    /// One token selected by rank 1 alone, taken through the unchanged control
    /// state machine. Rank 1 runs this after its own forwards; rank 0 runs it
    /// for a relayed token. Both therefore hold the same frames, history, token
    /// chain and decision as after a pipeline step.
    static func replay(tokenID: Int, payloadSHA256: String, control: QwenLayerStageGenerationControl,
                       continueRequested: (Int) throws -> Bool) throws -> QwenLayerStageGenerationDecisionPacket {
        let expected = try control.beginFrame()
        guard expected.frame.phase == .decode else { throw ProbeError("A token decoded alone follows the prompt") }
        let boundary = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: payloadSHA256)
        let committed = expected.frame.tokenOffset + expected.frame.tokenCount
        try control.acknowledgeFrame(rank: 0, packet: boundary, nativeCommittedTokens: committed)
        try control.acknowledgeFrame(rank: 1, packet: boundary, nativeCommittedTokens: committed)
        let token = try QwenLayerStageGenerationTokenPacket(agreement: control.agreement,
            boundaryFingerprint: boundary.fingerprint, previousTokenChainSHA256: control.tokenChainSHA256,
            ordinal: control.selectedTokenCount, committedTokens: control.committedTokens, tokenID: tokenID)
        try control.acknowledgeToken(rank: 1, packet: token)
        try control.acknowledgeToken(rank: 0, packet: token)
        let selected = try control.takeCommittedToken()
        let decision = try control.decide(continueRequested: try continueRequested(selected))
        try control.acknowledgeDecision(rank: 0, packet: decision)
        try control.acknowledgeDecision(rank: 1, packet: decision)
        return decision
    }

    static func run(producerStage: LoadedQwenLayerStage?, plan: QwenLayerStagePlan, split: QwenPhaseSplitPlan,
                    control: QwenLayerStageGenerationControl, transport: QwenLayerStageGenerationTransport,
                    session: QwenLayerStageSession, selectedTokens: inout [Int],
                    recording: QwenGenerationDiagnosticCapture?, fault: QwenPhaseSplitFault? = nil,
                    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void
    ) throws -> QwenPhaseSplitOutcome {
        guard control.phase == .frame, !control.isFailed,
              control.selectedTokenCount == split.terms.handoffSelectedTokens,
              control.committedTokens == split.terms.handoffCommittedTokens,
              session.committedTokens == split.terms.handoffCommittedTokens, !session.isClosed,
              selectedTokens.count == control.selectedTokenCount else {
            throw ProbeError("Hand-off point differs from the agreed frontier")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let limit = started + UInt64(split.terms.handoffLimitMilliseconds) * 1_000_000
        func handoffCheck() throws {
            try check()
            guard DispatchTime.now().uptimeNanoseconds < limit else {
                throw ProbeError("Hand-off exceeded its agreed time limit")
            }
        }
        try handoffCheck()
        let before = memory()
        if transport.rank == 0 {
            return try publish(split: split, control: control, transport: transport, session: session,
                selectedTokens: &selectedTokens, recording: recording != nil, fault: recording == nil ? nil : fault,
                started: started, before: before,
                onCommittedToken: onCommittedToken, check: check, handoffCheck: handoffCheck)
        }
        return try decodeAlone(producerStage: producerStage, plan: plan, split: split, control: control,
            transport: transport, session: session, selectedTokens: &selectedTokens, recording: recording != nil,
            fault: recording == nil ? nil : fault, started: started, before: before, check: check, handoffCheck: handoffCheck)
    }

    /// Rank 0: export, send, release, then publish what rank 1 relays.
    private static func publish(split: QwenPhaseSplitPlan, control: QwenLayerStageGenerationControl,
        transport: QwenLayerStageGenerationTransport, session: QwenLayerStageSession,
        selectedTokens: inout [Int], recording: Bool, fault: QwenPhaseSplitFault?,
        started: UInt64, before: QwenPhaseSplitSummary.Memory,
        onCommittedToken: (Int) throws -> Bool, check: () throws -> Void, handoffCheck: () throws -> Void
    ) throws -> QwenPhaseSplitOutcome {
        let agreement = control.agreement, request = agreement.request
        var exported: UInt64 = 0
        // The exported bytes live only inside this scope.
        let handoffFingerprint: String = try autoreleasepool {
            let sender = try QwenPhaseSplitHandoffSender(agreement: agreement,
                tokenChainSHA256: control.tokenChainSHA256,
                components: try session.handoffComponents(check: handoffCheck))
            exported = DispatchTime.now().uptimeNanoseconds
            try transport.sendHandoff(sender, fault: fault, check: handoffCheck)
            return sender.header.fingerprint
        }
        // Rank 1 holds the verified state. This rank's copy is released now and
        // never again touched: from here it only answers relays and retirement.
        try session.retireAfterHandoff()
        guard session.isClosed, !session.isFailed else { throw ProbeError("Producer state survived its hand-off") }
        let handed = DispatchTime.now().uptimeNanoseconds
        let after = memory()

        var finalDecision: QwenLayerStageGenerationDecisionPacket?
        var batches = 0, relayed = 0
        while control.phase == .frame {
            try check()
            let relay = try transport.receiveRelay(handoffFingerprint: handoffFingerprint,
                firstOrdinal: control.selectedTokenCount, previousTokenChainSHA256: control.tokenChainSHA256, check: check)
            batches += 1; relayed += relay.content.tokenIDs.count
            var accepted = 0
            var last: QwenLayerStageGenerationDecisionPacket?
            for (index, tokenID) in relay.content.tokenIDs.enumerated() {
                let decision = try replay(tokenID: tokenID, payloadSHA256: relay.content.payloadSHA256[index],
                                          control: control) { selected in
                    // The scalar is agreed by construction; publish it as the pipeline does.
                    try check()
                    let keepGoing = try onCommittedToken(selected)
                    try check()
                    return keepGoing
                }
                selectedTokens.append(tokenID); accepted += 1; last = decision
                if decision.content.decision != .proceed { break }
            }
            guard let last else { throw ProbeError("Relay batch carried no token") }
            try transport.sendRelayDecision(.init(agreement: agreement, relay: relay, acceptedCount: accepted,
                selectedTokenCount: control.selectedTokenCount, tokenChainSHA256: control.tokenChainSHA256,
                decision: last.content.decision), check: check)
            if control.phase == .retiring { finalDecision = last }
        }
        guard control.phase == .retiring, !control.isFailed, let finalDecision else {
            throw ProbeError("Phase-split publication ended without an agreed stop")
        }
        let accepted = control.selectedTokenCount - split.terms.handoffSelectedTokens
        var recorded: QwenPhaseSplitRecordedState?
        if recording {
            recorded = .init(finalFrame: try request.frame(sequence: control.completedFrames - 1), entries: [],
                logicalBytes: 0, fingerprint: sha256(Data(["cbv2-owned-state-v1", "tokens=\(control.committedTokens)"]
                    .joined(separator: "\n").utf8)), finalLogits: nil)
        }
        return .init(finalDecision: finalDecision, summary: .init(rank: 0, handoffPerformed: true,
            handoffEntries: split.terms.entryCount, handoffSegments: split.terms.segmentCount,
            handoffLogicalBytes: split.terms.logicalBytes, handoffNanoseconds: handed - started,
            handoffLocalStateNanoseconds: exported - started, relayBatches: batches,
            soloDecodeForwards: relayed, discardedDecodeForwards: relayed - accepted,
            beforeHandoff: before, afterHandoff: after, afterRetirement: memory()), recorded: recorded)
    }

    /// Rank 1: receive, verify, adopt, then decode with both stages and no
    /// transfer per token. Tokens reach the request owner in batches.
    private static func decodeAlone(producerStage: LoadedQwenLayerStage?, plan: QwenLayerStagePlan,
        split: QwenPhaseSplitPlan, control: QwenLayerStageGenerationControl,
        transport: QwenLayerStageGenerationTransport, session: QwenLayerStageSession,
        selectedTokens: inout [Int], recording: Bool, fault: QwenPhaseSplitFault?,
        started: UInt64, before: QwenPhaseSplitSummary.Memory,
        check: () throws -> Void, handoffCheck: () throws -> Void
    ) throws -> QwenPhaseSplitOutcome {
        let agreement = control.agreement, request = agreement.request
        guard let producerStage, producerStage.stageIndex == 0, producerStage.plan.fingerprint == plan.fingerprint else {
            throw ProbeError("Phase-split rank1 does not hold the producer stage of this Plan")
        }
        let receiver = try QwenPhaseSplitHandoffReceiver(agreement: agreement, tokenChainSHA256: control.tokenChainSHA256)
        let intake = QwenPhaseSplitHandoffIntake(receiver: receiver)
        try transport.receiveHandoff(intake, fault: fault, check: handoffCheck)
        let received = DispatchTime.now().uptimeNanoseconds
        let adopted: QwenLayerStageSession
        do {
            // Every digest is checked here, before any array reaches a model.
            let state = try intake.adoptedState(check: handoffCheck)
            let value = try QwenLayerStageSession(stage: producerStage, plan: plan, generationRequest: request, adopting: state)
            // A recording run also rereads the adopted state and requires the
            // sender's own state fingerprint, position offsets included.
            if recording, let header = receiver.header {
                guard try value.stateFingerprint(check: handoffCheck) == header.content.stateSHA256 else {
                    throw ProbeError("Adopted state differs from the sender's state fingerprint")
                }
            }
            try handoffCheck()
            adopted = value
        } catch {
            intake.discard()
            // Tell rank 0 now; it is waiting for this answer and nothing else.
            try? transport.concludeHandoff(receiver.header, accepted: false, check: {})
            throw error
        }
        do {
            try transport.concludeHandoff(receiver.header, accepted: true, check: handoffCheck)
            guard let handoffFingerprint = receiver.header?.fingerprint else { throw ProbeError("Hand-off header missing") }
            let handed = DispatchTime.now().uptimeNanoseconds
            let after = memory()

            var finalDecision: QwenLayerStageGenerationDecisionPacket?
            var finalLogits: QwenRecordedLogits?
            var batches = 0, forwards = 0, batchLimit = 1
            guard var lastToken = control.lastTokenID else { throw ProbeError("Solo decode lacks the agreed first token") }
            // The next ordinal this rank will select. It runs ahead of the
            // control state, which only advances when rank 0 has answered.
            var nextOrdinal = control.selectedTokenCount
            struct Batch { let tokenIDs: [Int]; let payloads: [String] }
            var unanswered: (relay: QwenPhaseSplitRelayPacket, batch: Batch)?

            /// Reads rank 0's answer to the batch in flight and takes exactly the
            /// tokens it published through the control state machine.
            func settle() throws {
                guard let sent = unanswered else { return }
                unanswered = nil
                let verdict = try transport.receiveRelayDecision(relay: sent.relay, check: check).content
                var last: QwenLayerStageGenerationDecisionPacket?
                for index in 0..<verdict.acceptedCount {
                    let proceed = index + 1 < verdict.acceptedCount || verdict.decision == .proceed
                    last = try replay(tokenID: sent.batch.tokenIDs[index], payloadSHA256: sent.batch.payloads[index],
                                      control: control) { _ in proceed }
                    selectedTokens.append(sent.batch.tokenIDs[index])
                }
                // The owner's count, history and decision must be exactly what
                // this rank derives from the same tokens.
                guard let last, last.content.decision == verdict.decision,
                      control.selectedTokenCount == verdict.selectedTokenCount,
                      control.tokenChainSHA256 == verdict.tokenChainSHA256,
                      verdict.acceptedCount == sent.batch.tokenIDs.count || control.phase == .retiring else {
                    throw ProbeError("Relay decision differs from the locally selected history")
                }
                if control.phase == .retiring { finalDecision = last }
            }

            while control.phase == .frame {
                // Decode the next batch while rank 0 publishes the previous one.
                var tokenIDs: [Int] = [], payloads: [String] = []
                var terminal = false
                let firstOrdinal = nextOrdinal
                while tokenIDs.count < batchLimit, !terminal {
                    try autoreleasepool {
                        try check()
                        let ordinal = firstOrdinal + tokenIDs.count
                        let offset = request.promptCount + ordinal - 1
                        guard case .hidden(let produced) = try adopted.decode(lastToken, offset: offset, check: check) else {
                            throw ProbeError("Adopted producer stage did not return a residual")
                        }
                        // The consumer stage requires an owned compact residual. One
                        // that is not is copied bit for bit, as the reference does.
                        var incoming = produced
                        if !produced.hasOwnedCompactStorage { incoming = try produced.ownedCopy(check: check) }
                        guard case .logits(let row) = try session.decode(lastToken, offset: offset, incoming: incoming, check: check) else {
                            throw ProbeError("Consumer stage did not return target logits")
                        }
                        let token = try QwenLayerStageGenerationSelection.token(row, request: request, check: check)
                        forwards += 1
                        tokenIDs.append(token); payloads.append(produced.payloadSHA256); lastToken = token
                        terminal = request.stopTokenIDs.contains(token) || ordinal + 1 == request.outputCount
                        if terminal, recording {
                            let captured = try QwenRecordedLogits(row, vocabularySize: request.profile.vocabularySize, check: check)
                            guard let maximum = captured.record.values.max(),
                                  captured.record.values.firstIndex(of: maximum) == token else {
                                throw ProbeError("Recorded final row differs from the selected token")
                            }
                            finalLogits = captured
                        }
                    }
                }
                nextOrdinal += tokenIDs.count
                // The previous batch's answer fixes the history this one extends.
                // If it was a stop, this batch was decoded for nothing and is dropped.
                try settle()
                guard control.phase == .frame else { break }
                guard control.selectedTokenCount == firstOrdinal else {
                    throw ProbeError("Relayed history differs from the tokens this rank selected")
                }
                let relay = try QwenPhaseSplitRelayPacket(agreement: agreement, handoffFingerprint: handoffFingerprint,
                    firstOrdinal: firstOrdinal, previousTokenChainSHA256: control.tokenChainSHA256,
                    tokenIDs: tokenIDs, payloadSHA256: payloads)
                try transport.sendRelay(relay, check: check)
                unanswered = (relay, Batch(tokenIDs: tokenIDs, payloads: payloads))
                batches += 1
                batchLimit = min(split.terms.relayBatchTokens, batchLimit * 2)
                // Nothing can follow a stop token or the output limit: wait for the answer.
                if terminal { try settle() }
            }
            guard control.phase == .retiring, !control.isFailed, let finalDecision,
                  let reason = control.finishReason, let lastTokenID = control.lastTokenID else {
                throw ProbeError("Solo decode ended without an agreed stop")
            }
            try check()
            let discarded = forwards - (control.selectedTokenCount - split.terms.handoffSelectedTokens)
            var recorded: QwenPhaseSplitRecordedState?
            if recording {
                guard discarded == 0, let finalLogits else {
                    throw ProbeError("A recorded phase-split request must end at a stop token or its output limit")
                }
                let state = try QwenRecordedState(snapshots: [
                    try adopted.snapshot(includeBytes: false, check: check),
                    try session.snapshot(includeBytes: false, check: check),
                ], plan: plan, committedTokens: control.committedTokens)
                recorded = .init(finalFrame: try request.frame(sequence: control.completedFrames - 1),
                    entries: state.entries, logicalBytes: state.logicalByteCount, fingerprint: state.fingerprint,
                    finalLogits: finalLogits)
            }
            try adopted.finishGeneration(reason, selectedTokenCount: control.selectedTokenCount,
                lastTokenID: lastTokenID, discardedDecodeForwards: discarded)
            try session.finishGeneration(reason, selectedTokenCount: control.selectedTokenCount,
                lastTokenID: lastTokenID, discardedDecodeForwards: discarded)
            guard adopted.isClosed, !adopted.isFailed else { throw ProbeError("Adopted producer state failed retirement") }
            return .init(finalDecision: finalDecision, summary: .init(rank: 1, handoffPerformed: true,
                handoffEntries: split.terms.entryCount, handoffSegments: split.terms.segmentCount,
                handoffLogicalBytes: split.terms.logicalBytes, handoffNanoseconds: handed - started,
                handoffLocalStateNanoseconds: handed - received, relayBatches: batches,
                soloDecodeForwards: forwards, discardedDecodeForwards: discarded,
                beforeHandoff: before, afterHandoff: after, afterRetirement: memory()), recorded: recorded)
        } catch {
            try? adopted.cancel()
            throw error
        }
    }
}

extension QwenPhaseSplitSummary {
    /// One line a launcher can read from the worker's diagnostics. It carries
    /// sizes and durations only.
    func diagnosticLine(requestID: UUID) -> String {
        ["darkbloom-phase-split-v1", "rank=\(rank)", "request=\(requestID.uuidString.lowercased())",
         "handoff=\(handoffPerformed ? 1 : 0)", "entries=\(handoffEntries)", "segments=\(handoffSegments)",
         "bytes=\(handoffLogicalBytes)", "handoff_ns=\(handoffNanoseconds)",
         "local_state_ns=\(handoffLocalStateNanoseconds)", "relay_batches=\(relayBatches)",
         "solo_forwards=\(soloDecodeForwards)", "discarded_forwards=\(discardedDecodeForwards)",
         "active_before=\(beforeHandoff.activeBytes)", "cache_before=\(beforeHandoff.cacheBytes)",
         "active_after_handoff=\(afterHandoff.activeBytes)", "cache_after_handoff=\(afterHandoff.cacheBytes)",
         "active_after_retirement=\(afterRetirement.activeBytes)", "cache_after_retirement=\(afterRetirement.cacheBytes)",
        ].joined(separator: " ")
    }
}
