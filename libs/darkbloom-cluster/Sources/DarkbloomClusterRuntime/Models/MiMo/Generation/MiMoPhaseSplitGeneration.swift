import Foundation
import MLX

/// The part of a MiMo phase-split request that follows the first selected
/// token, and the whole of a request the decoding rank serves alone. Rank 0
/// hands its producer stage's state to rank 1 and then only publishes; rank 1
/// adopts the state into the producer stage it holds beside its own and
/// decodes with both, with no transfer per token. The control state machine,
/// the hand-off header and segments, the relay batches and the alone-route
/// packets are the dense adapter's own (`QwenPhaseSplitGeneration`), used
/// unchanged; only the stage sessions differ.
///
/// The caller is the MiMo generation request, inside its native error scope.
/// On a throw the caller retires `session`; a producer session made or
/// adopted here is retired here.
enum MiMoPhaseSplitGeneration {
    struct Outcome {
        let finalDecision: QwenLayerStageGenerationDecisionPacket
        let summary: QwenPhaseSplitSummary
        /// Rank 1: the evidence of the producer stage it ran (adopted or alone).
        let producerBoundaryChainSHA256: String?
    }

    static func run(producerStage: LoadedMiMoLayerStage?, plan: MiMoLayerStagePlan, split: QwenPhaseSplitPlan,
                    control: QwenLayerStageGenerationControl, transport: QwenLayerStageGenerationTransport,
                    session: MiMoLayerStageSession, selectedTokens: inout [Int], fault: QwenPhaseSplitFault? = nil,
                    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void) throws -> Outcome {
        let alone = control.agreement.request.decodingRankAlone
        let frontierSelected = alone ? 0 : split.terms.handoffSelectedTokens
        let frontierCommitted = alone ? 0 : split.terms.handoffCommittedTokens
        guard control.phase == .frame, !control.isFailed,
              control.selectedTokenCount == frontierSelected, control.committedTokens == frontierCommitted,
              session.committedTokens == frontierCommitted, !session.isClosed,
              selectedTokens.count == control.selectedTokenCount else {
            throw ProbeError("Hand-off point differs from the agreed frontier")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let limit = started + UInt64(split.terms.handoffLimitMilliseconds) * 1_000_000
        func handoffCheck() throws {
            try check()
            guard DispatchTime.now().uptimeNanoseconds < limit else { throw ProbeError("Hand-off exceeded its agreed time limit") }
        }
        try handoffCheck()
        let before = QwenPhaseSplitGeneration.memory()
        if transport.rank == 0 {
            return try publish(split: split, control: control, transport: transport, session: session,
                selectedTokens: &selectedTokens, started: started, before: before, fault: fault,
                onCommittedToken: onCommittedToken, check: check, handoffCheck: handoffCheck)
        }
        return try decodeAlone(producerStage: producerStage, plan: plan, split: split, control: control,
            transport: transport, session: session, selectedTokens: &selectedTokens, started: started, before: before,
            fault: fault, check: check, handoffCheck: handoffCheck)
    }

    /// Rank 1, serving a request alone: both stages prefill the whole prompt
    /// here, frame by frame on the request's own grid, the residual passed
    /// between them in this process exactly as the single-Mac reference passes
    /// it; the first token is selected from the last row. The digests of the
    /// frames before the last go to rank 0, and both ranks take those frames
    /// through their control state.
    private static func prefillAlone(producerStage: LoadedMiMoLayerStage, plan: MiMoLayerStagePlan,
                                     control: QwenLayerStageGenerationControl, transport: QwenLayerStageGenerationTransport,
                                     session: MiMoLayerStageSession, check: () throws -> Void)
        throws -> (producer: MiMoLayerStageSession, token: Int, payloadSHA256: String) {
        let agreement = control.agreement, request = agreement.request
        guard request.decodingRankAlone, transport.rank == 1, control.phase == .frame, control.completedFrames == 0,
              session.committedTokens == 0 else {
            throw ProbeError("A request served alone starts at the empty frontier on the decoding rank")
        }
        let producer = try MiMoLayerStageSession(stage: producerStage, plan: plan, generationRequest: request)
        do {
            var payloads: [String] = []
            var first: (token: Int, payload: String)?
            for sequence in 0..<request.prefillFrameCount {
                try autoreleasepool {
                    try check()
                    let frame = try request.frame(sequence: sequence)
                    guard frame.phase == .prefill else { throw ProbeError("A prompt frame is not a prefill frame") }
                    let tokens = Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
                    guard case .hidden(let produced) = try producer.prefillChunk(tokens, offset: frame.tokenOffset,
                        final: frame.finalPromptChunk, check: check) else {
                        throw ProbeError("The producer stage did not return a residual")
                    }
                    // The consumer stage requires an owned compact residual, as across the cable.
                    var incoming = produced
                    if !produced.hasOwnedCompactStorage { incoming = try produced.ownedCopy(check: check) }
                    let output = try session.prefillChunk(tokens, offset: frame.tokenOffset, final: frame.finalPromptChunk,
                        incoming: incoming, check: check)
                    payloads.append(produced.payloadSHA256)
                    switch output {
                    case .evaluationHandle where !frame.finalPromptChunk: break
                    case .logits(let row) where frame.finalPromptChunk:
                        first = (try QwenLayerStageGenerationSelection.token(row, request: request, check: check), produced.payloadSHA256)
                    default: throw ProbeError("The consumer stage's output does not match its prompt frame")
                    }
                }
            }
            guard let first, payloads.count == request.prefillFrameCount else {
                throw ProbeError("A request served alone ended its prompt without a first token")
            }
            let earlier = Array(payloads.dropLast())
            var index = 0
            while index < earlier.count {
                let batch = Array(earlier[index..<min(earlier.count, index + QwenAlonePromptPacket.payloadsPerPacket)])
                try transport.sendAlonePrompt(.init(agreement: agreement, firstFrame: index, payloadSHA256: batch), check: check)
                index += batch.count
            }
            for payload in earlier { try QwenPhaseSplitGeneration.replayPromptFrame(payloadSHA256: payload, control: control) }
            return (producer, first.token, first.payload)
        } catch {
            try? producer.cancel()
            throw error
        }
    }

    /// Rank 0: export, send, release, then publish what rank 1 relays.
    private static func publish(split: QwenPhaseSplitPlan, control: QwenLayerStageGenerationControl,
        transport: QwenLayerStageGenerationTransport, session: MiMoLayerStageSession,
        selectedTokens: inout [Int], started: UInt64, before: QwenPhaseSplitSummary.Memory, fault: QwenPhaseSplitFault?,
        onCommittedToken: (Int) throws -> Bool, check: () throws -> Void, handoffCheck: () throws -> Void
    ) throws -> Outcome {
        let agreement = control.agreement, request = agreement.request
        let alone = request.decodingRankAlone
        var exported: UInt64 = 0
        let handoffFingerprint: String
        if alone {
            // Nothing ran here: rank 1 prefills the whole prompt by itself and
            // sends the digests of its frames before the last.
            try session.retireUnusedForDecodingRankAlone()
            exported = DispatchTime.now().uptimeNanoseconds
            var payloads: [String] = []
            while payloads.count < request.prefillFrameCount - 1 {
                payloads += try transport.receiveAlonePrompt(firstFrame: payloads.count, check: check).content.payloadSHA256
            }
            for payload in payloads { try QwenPhaseSplitGeneration.replayPromptFrame(payloadSHA256: payload, control: control) }
            handoffFingerprint = QwenAlonePromptPacket.relayFingerprint(agreement)
        } else {
            // The exported bytes live only inside this scope.
            handoffFingerprint = try autoreleasepool {
                let sender = try QwenPhaseSplitHandoffSender(agreement: agreement, tokenChainSHA256: control.tokenChainSHA256,
                    components: try session.handoffComponents(split: split, check: handoffCheck))
                exported = DispatchTime.now().uptimeNanoseconds
                try transport.sendHandoff(sender, fault: fault, check: handoffCheck)
                return sender.header.fingerprint
            }
            // Rank 1 holds the verified state; this rank's copy is released now.
            try session.retireAfterHandoff()
        }
        guard session.isClosed, !session.isFailed else { throw ProbeError("Producer state survived its hand-off") }
        let handed = DispatchTime.now().uptimeNanoseconds
        let after = QwenPhaseSplitGeneration.memory()
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
                let decision = try QwenPhaseSplitGeneration.replay(tokenID: tokenID,
                    payloadSHA256: relay.content.payloadSHA256[index], control: control) { selected in
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
        let accepted = control.selectedTokenCount - (alone ? 0 : split.terms.handoffSelectedTokens)
        return .init(finalDecision: finalDecision, summary: .init(rank: 0, handoffPerformed: !alone,
            handoffEntries: alone ? 0 : split.terms.entryCount, handoffSegments: alone ? 0 : split.terms.segmentCount,
            handoffLogicalBytes: alone ? 0 : split.terms.logicalBytes, handoffNanoseconds: handed - started,
            handoffLocalStateNanoseconds: exported - started, relayBatches: batches,
            soloDecodeForwards: relayed, discardedDecodeForwards: relayed - accepted,
            beforeHandoff: before, afterHandoff: after, afterRetirement: QwenPhaseSplitGeneration.memory()),
            producerBoundaryChainSHA256: nil)
    }

    /// Rank 1: receive, verify, adopt, then decode with both stages and no
    /// transfer per token. Tokens reach the request owner in batches.
    private static func decodeAlone(producerStage: LoadedMiMoLayerStage?, plan: MiMoLayerStagePlan,
        split: QwenPhaseSplitPlan, control: QwenLayerStageGenerationControl,
        transport: QwenLayerStageGenerationTransport, session: MiMoLayerStageSession,
        selectedTokens: inout [Int], started: UInt64, before: QwenPhaseSplitSummary.Memory, fault: QwenPhaseSplitFault?,
        check: () throws -> Void, handoffCheck: () throws -> Void
    ) throws -> Outcome {
        let agreement = control.agreement, request = agreement.request
        guard let producerStage, producerStage.stageIndex == 0, producerStage.plan.fingerprint == plan.fingerprint else {
            throw ProbeError("Phase-split rank1 does not hold the producer stage of this Plan")
        }
        let alone = request.decodingRankAlone
        var aloneFirst: (producer: MiMoLayerStageSession, token: Int, payloadSHA256: String)?
        if alone {
            aloneFirst = try prefillAlone(producerStage: producerStage, plan: plan, control: control, transport: transport,
                session: session, check: check)
        }
        let receiver = try QwenPhaseSplitHandoffReceiver(agreement: agreement, tokenChainSHA256: control.tokenChainSHA256)
        let intake = QwenPhaseSplitHandoffIntake(receiver: receiver)
        if !alone { try transport.receiveHandoff(intake, fault: fault, check: handoffCheck) }
        let received = DispatchTime.now().uptimeNanoseconds
        let adopted: MiMoLayerStageSession
        if let aloneFirst {
            adopted = aloneFirst.producer
        } else { do {
            // Every digest is checked here, before any array reaches a model.
            let state = try intake.adoptedState(check: handoffCheck)
            adopted = try MiMoLayerStageSession(stage: producerStage, plan: plan, generationRequest: request,
                                                adopting: state, split: split)
            try handoffCheck()
        } catch {
            intake.discard()
            // Tell rank 0 now; it is waiting for this answer and nothing else.
            try? transport.concludeHandoff(receiver.header, accepted: false, check: {})
            throw error
        } }
        do {
            let handoffFingerprint: String
            if alone {
                handoffFingerprint = QwenAlonePromptPacket.relayFingerprint(agreement)
            } else {
                try transport.concludeHandoff(receiver.header, accepted: true, check: handoffCheck)
                guard let value = receiver.header?.fingerprint else { throw ProbeError("Hand-off header missing") }
                handoffFingerprint = value
            }
            let handed = DispatchTime.now().uptimeNanoseconds
            let after = QwenPhaseSplitGeneration.memory()
            var finalDecision: QwenLayerStageGenerationDecisionPacket?
            var batches = 0, forwards = 0, batchLimit = 1
            guard var lastToken = aloneFirst?.token ?? control.lastTokenID else {
                throw ProbeError("Solo decode lacks the agreed first token")
            }
            // The next ordinal this rank will select; it runs ahead of the
            // control state, which only advances when rank 0 has answered.
            var nextOrdinal = control.selectedTokenCount
            var queue: [(token: Int, payload: String)] = []
            var decodedOrdinal = control.selectedTokenCount
            if let aloneFirst {
                // The first token, selected after the prompt here, is the first relayed.
                queue = [(aloneFirst.token, aloneFirst.payloadSHA256)]
                decodedOrdinal += 1; forwards += 1
            }
            var unanswered: (relay: QwenPhaseSplitRelayPacket, tokenIDs: [Int], payloads: [String])?

            /// Reads rank 0's answer to the batch in flight and takes exactly the
            /// tokens it published through the control state machine.
            func settle() throws {
                guard let sent = unanswered else { return }
                unanswered = nil
                let verdict = try transport.receiveRelayDecision(relay: sent.relay, check: check).content
                var last: QwenLayerStageGenerationDecisionPacket?
                for index in 0..<verdict.acceptedCount {
                    let proceed = index + 1 < verdict.acceptedCount || verdict.decision == .proceed
                    last = try QwenPhaseSplitGeneration.replay(tokenID: sent.tokenIDs[index], payloadSHA256: sent.payloads[index],
                                                               control: control) { _ in proceed }
                    selectedTokens.append(sent.tokenIDs[index])
                }
                guard let last, last.content.decision == verdict.decision,
                      control.selectedTokenCount == verdict.selectedTokenCount,
                      control.tokenChainSHA256 == verdict.tokenChainSHA256,
                      verdict.acceptedCount == sent.tokenIDs.count || control.phase == .retiring else {
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
                        if queue.isEmpty {
                            let offset = request.promptCount + decodedOrdinal - 1
                            guard case .hidden(let produced) = try adopted.decode(lastToken, offset: offset, check: check) else {
                                throw ProbeError("Adopted producer stage did not return a residual")
                            }
                            // The consumer stage requires an owned compact residual; one that
                            // is not is copied bit for bit, as the reference does.
                            var incoming = produced
                            if !produced.hasOwnedCompactStorage { incoming = try produced.ownedCopy(check: check) }
                            guard case .logits(let row) = try session.decode(lastToken, offset: offset, incoming: incoming,
                                                                              check: check) else {
                                throw ProbeError("Consumer stage did not return target logits")
                            }
                            let token = try QwenLayerStageGenerationSelection.token(row, request: request, check: check)
                            guard decodedOrdinal + 1 <= request.outputCount else {
                                throw ProbeError("Solo decode emitted past the request's output limit")
                            }
                            queue.append((token, produced.payloadSHA256))
                            forwards += 1; decodedOrdinal += 1; lastToken = token
                        }
                        let item = queue.removeFirst()
                        let ordinal = firstOrdinal + tokenIDs.count
                        tokenIDs.append(item.token); payloads.append(item.payload)
                        terminal = request.stopTokenIDs.contains(item.token) || ordinal + 1 == request.outputCount
                        if terminal { guard queue.isEmpty else { throw ProbeError("Solo decode emitted past a stop") } }
                    }
                }
                nextOrdinal += tokenIDs.count
                // The previous batch's answer fixes the history this one extends;
                // after a stop this batch was decoded for nothing and is dropped.
                try settle()
                guard control.phase == .frame else { break }
                guard control.selectedTokenCount == firstOrdinal else {
                    throw ProbeError("Relayed history differs from the tokens this rank selected")
                }
                let relay = try QwenPhaseSplitRelayPacket(agreement: agreement, handoffFingerprint: handoffFingerprint,
                    firstOrdinal: firstOrdinal, previousTokenChainSHA256: control.tokenChainSHA256,
                    tokenIDs: tokenIDs, payloadSHA256: payloads)
                try transport.sendRelay(relay, check: check)
                unanswered = (relay, tokenIDs, payloads)
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
            let discarded = forwards - (control.selectedTokenCount - (alone ? 0 : split.terms.handoffSelectedTokens))
            let producerChain = adopted.boundaryChainSHA256
            try adopted.finishGeneration(reason, selectedTokenCount: control.selectedTokenCount,
                lastTokenID: lastTokenID, discardedDecodeForwards: discarded)
            try session.finishGeneration(reason, selectedTokenCount: control.selectedTokenCount,
                lastTokenID: lastTokenID, discardedDecodeForwards: discarded)
            guard adopted.isClosed, !adopted.isFailed else { throw ProbeError("Adopted producer state failed retirement") }
            return .init(finalDecision: finalDecision, summary: .init(rank: 1, handoffPerformed: !alone,
                handoffEntries: alone ? 0 : split.terms.entryCount, handoffSegments: alone ? 0 : split.terms.segmentCount,
                handoffLogicalBytes: alone ? 0 : split.terms.logicalBytes, handoffNanoseconds: handed - started,
                handoffLocalStateNanoseconds: handed - received, relayBatches: batches,
                soloDecodeForwards: forwards, discardedDecodeForwards: discarded,
                beforeHandoff: before, afterHandoff: after, afterRetirement: QwenPhaseSplitGeneration.memory()),
                producerBoundaryChainSHA256: producerChain)
        } catch {
            try? adopted.cancel()
            throw error
        }
    }
}
