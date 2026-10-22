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
        // A request served alone also takes its last prompt frame and first token this way.
        guard expected.frame.phase == .decode
                || (control.agreement.request.decodingRankAlone && expected.frame.finalPromptChunk) else {
            throw ProbeError("A token decoded alone follows the prompt")
        }
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

    /// A prompt frame before the last of a request the decoding rank served
    /// alone, taken through the unchanged control state machine on either
    /// rank with the residual digest that rank computed.
    static func replayPromptFrame(payloadSHA256: String, control: QwenLayerStageGenerationControl) throws {
        let expected = try control.beginFrame()
        guard control.agreement.request.decodingRankAlone, expected.frame.phase == .prefill, !expected.frame.finalPromptChunk else {
            throw ProbeError("Only a request served alone replays its prompt frames")
        }
        let boundary = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: payloadSHA256)
        let committed = expected.frame.tokenOffset + expected.frame.tokenCount
        try control.acknowledgeFrame(rank: 0, packet: boundary, nativeCommittedTokens: committed)
        try control.acknowledgeFrame(rank: 1, packet: boundary, nativeCommittedTokens: committed)
        guard control.phase == .frame else { throw ProbeError("A prompt frame before the last selected a token") }
    }

    /// The first token of a request the decoding rank serves alone, and the
    /// producer stage's session it prefilled by itself.
    struct AloneFirst {
        let producer: QwenLayerStageSession
        let token: Int
        let payloadSHA256: String
        let row: MLXArray
    }

    /// Rank 1, serving a request alone: both stages prefill the whole prompt
    /// here, frame by frame on the request's own frame grid, the residual
    /// passed between them in this process exactly as the single-Mac
    /// reference passes it; the first token is selected from the last row.
    /// The digests of the frames before the last go to rank 0, and both ranks
    /// take those frames through their control state.
    static func prefillAlone(producerStage: LoadedQwenLayerStage, plan: QwenLayerStagePlan,
                             control: QwenLayerStageGenerationControl, transport: QwenLayerStageGenerationTransport,
                             session: QwenLayerStageSession, check: () throws -> Void) throws -> AloneFirst {
        let agreement = control.agreement, request = agreement.request
        guard request.decodingRankAlone, transport.rank == 1, control.phase == .frame, control.completedFrames == 0,
              session.committedTokens == 0 else {
            throw ProbeError("A request served alone starts at the empty frontier on the decoding rank")
        }
        let producer = try QwenLayerStageSession(stage: producerStage, plan: plan, generationRequest: request)
        do {
            var payloads: [String] = []
            var first: (token: Int, payload: String, row: MLXArray)?
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
                        let token = try QwenLayerStageGenerationSelection.token(row, request: request, check: check)
                        first = (token, produced.payloadSHA256, row)
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
            for payload in earlier { try replayPromptFrame(payloadSHA256: payload, control: control) }
            return .init(producer: producer, token: first.token, payloadSHA256: first.payload, row: first.row)
        } catch {
            try? producer.cancel()
            throw error
        }
    }

    static func run(producerStage: LoadedQwenLayerStage?, plan: QwenLayerStagePlan, split: QwenPhaseSplitPlan,
                    control: QwenLayerStageGenerationControl, transport: QwenLayerStageGenerationTransport,
                    session: QwenLayerStageSession, selectedTokens: inout [Int],
                    recording: QwenGenerationDiagnosticCapture?, fault: QwenPhaseSplitFault? = nil,
                    decoder: QwenMTPDecoder? = nil,
                    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void
    ) throws -> QwenPhaseSplitOutcome {
        // A request the decoding rank serves alone starts there at the empty frontier.
        let alone = control.agreement.request.decodingRankAlone
        let frontierSelected = alone ? 0 : split.terms.handoffSelectedTokens
        let frontierCommitted = alone ? 0 : split.terms.handoffCommittedTokens
        guard control.phase == .frame, !control.isFailed,
              control.selectedTokenCount == frontierSelected,
              control.committedTokens == frontierCommitted,
              session.committedTokens == frontierCommitted, !session.isClosed,
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
        guard (decoder != nil) == (transport.rank == 1 && control.agreement.speculativeHead != nil) else {
            throw ProbeError("Speculative head differs from this rank's role in the agreed phase split")
        }
        if transport.rank == 0 {
            return try publish(split: split, control: control, transport: transport, session: session,
                selectedTokens: &selectedTokens, recording: recording != nil, fault: recording == nil ? nil : fault,
                started: started, before: before,
                onCommittedToken: onCommittedToken, check: check, handoffCheck: handoffCheck)
        }
        return try decodeAlone(producerStage: producerStage, plan: plan, split: split, control: control,
            transport: transport, session: session, selectedTokens: &selectedTokens, recording: recording != nil,
            fault: recording == nil ? nil : fault, decoder: decoder, started: started, before: before,
            check: check, handoffCheck: handoffCheck)
    }

    /// Rank 0: export, send, release, then publish what rank 1 relays.
    private static func publish(split: QwenPhaseSplitPlan, control: QwenLayerStageGenerationControl,
        transport: QwenLayerStageGenerationTransport, session: QwenLayerStageSession,
        selectedTokens: inout [Int], recording: Bool, fault: QwenPhaseSplitFault?,
        started: UInt64, before: QwenPhaseSplitSummary.Memory,
        onCommittedToken: (Int) throws -> Bool, check: () throws -> Void, handoffCheck: () throws -> Void
    ) throws -> QwenPhaseSplitOutcome {
        let agreement = control.agreement, request = agreement.request
        let alone = request.decodingRankAlone
        var exported: UInt64 = 0
        let handoffFingerprint: String
        if alone {
            // Nothing ran here: rank 1 prefills the whole prompt by itself and
            // sends the digests of its frames before the last. This rank takes
            // them through its control state, then publishes what it relays.
            try session.retireUnusedForDecodingRankAlone()
            exported = DispatchTime.now().uptimeNanoseconds
            var payloads: [String] = []
            while payloads.count < request.prefillFrameCount - 1 {
                payloads += try transport.receiveAlonePrompt(firstFrame: payloads.count, check: check).content.payloadSHA256
            }
            for payload in payloads { try replayPromptFrame(payloadSHA256: payload, control: control) }
            handoffFingerprint = QwenAlonePromptPacket.relayFingerprint(agreement)
        } else {
            // The exported bytes live only inside this scope.
            handoffFingerprint = try autoreleasepool {
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
        }
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
        let accepted = control.selectedTokenCount - (alone ? 0 : split.terms.handoffSelectedTokens)
        var recorded: QwenPhaseSplitRecordedState?
        if recording {
            recorded = .init(finalFrame: try request.frame(sequence: control.completedFrames - 1), entries: [],
                logicalBytes: 0, fingerprint: sha256(Data(["cbv2-owned-state-v1", "tokens=\(control.committedTokens)"]
                    .joined(separator: "\n").utf8)), finalLogits: nil)
        }
        return .init(finalDecision: finalDecision, summary: .init(rank: 0, handoffPerformed: !alone,
            handoffEntries: alone ? 0 : split.terms.entryCount, handoffSegments: alone ? 0 : split.terms.segmentCount,
            handoffLogicalBytes: alone ? 0 : split.terms.logicalBytes, handoffNanoseconds: handed - started,
            handoffLocalStateNanoseconds: exported - started, relayBatches: batches,
            soloDecodeForwards: relayed, discardedDecodeForwards: relayed - accepted,
            beforeHandoff: before, afterHandoff: after, afterRetirement: memory()), recorded: recorded)
    }

    /// Rank 1: receive, verify, adopt, then decode with both stages and no
    /// transfer per token. Tokens reach the request owner in batches.
    ///
    /// With a speculative head (`decoder`), each decode call is a round that
    /// yields one to depth + 1 tokens; a batch is filled from those in order
    /// and a round's remainder waits for the next batch. Rank 0 sees the same
    /// relay either way.
    private static func decodeAlone(producerStage: LoadedQwenLayerStage?, plan: QwenLayerStagePlan,
        split: QwenPhaseSplitPlan, control: QwenLayerStageGenerationControl,
        transport: QwenLayerStageGenerationTransport, session: QwenLayerStageSession,
        selectedTokens: inout [Int], recording: Bool, fault: QwenPhaseSplitFault?,
        decoder: QwenMTPDecoder?,
        started: UInt64, before: QwenPhaseSplitSummary.Memory,
        check: () throws -> Void, handoffCheck: () throws -> Void
    ) throws -> QwenPhaseSplitOutcome {
        let agreement = control.agreement, request = agreement.request
        guard let producerStage, producerStage.stageIndex == 0, producerStage.plan.fingerprint == plan.fingerprint else {
            throw ProbeError("Phase-split rank1 does not hold the producer stage of this Plan")
        }
        let alone = request.decodingRankAlone
        var aloneFirst: AloneFirst?
        if alone {
            aloneFirst = try prefillAlone(producerStage: producerStage, plan: plan, control: control, transport: transport,
                session: session, check: check)
        }
        let receiver = try QwenPhaseSplitHandoffReceiver(agreement: agreement, tokenChainSHA256: control.tokenChainSHA256)
        let intake = QwenPhaseSplitHandoffIntake(receiver: receiver)
        if !alone { try transport.receiveHandoff(intake, fault: fault, check: handoffCheck) }
        let received = DispatchTime.now().uptimeNanoseconds
        let adopted: QwenLayerStageSession
        if let aloneFirst {
            adopted = aloneFirst.producer
        } else { do {
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
            let after = memory()

            var finalDecision: QwenLayerStageGenerationDecisionPacket?
            var finalLogits: QwenRecordedLogits?
            var batches = 0, forwards = 0, batchLimit = 1
            guard var lastToken = aloneFirst?.token ?? control.lastTokenID else { throw ProbeError("Solo decode lacks the agreed first token") }
            try decoder?.begin(firstToken: lastToken)
            // The next ordinal this rank will select. It runs ahead of the
            // control state, which only advances when rank 0 has answered.
            var nextOrdinal = control.selectedTokenCount
            // Tokens decoded but not yet put in a batch, in order, and the
            // ordinal the next decode starts at.
            struct Decoded { let token: Int; let payload: String; let emitted: QwenMTPDecoder.Emitted; let column: Int }
            var queue: [Decoded] = []
            var decodedOrdinal = control.selectedTokenCount
            if let aloneFirst {
                // The first token, selected after the prompt here, is the first relayed.
                queue = [.init(token: aloneFirst.token, payload: aloneFirst.payloadSHA256,
                    emitted: .init(tokens: [aloneFirst.token], payloadSHA256: [aloneFirst.payloadSHA256],
                        logits: aloneFirst.row, round: false), column: 0)]
                decodedOrdinal += 1; forwards += 1
            }
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
                        if queue.isEmpty {
                            let offset = request.promptCount + decodedOrdinal - 1
                            let emitted: QwenMTPDecoder.Emitted
                            if let decoder {
                                emitted = try decoder.step(producer: adopted, consumer: session, lastToken: lastToken,
                                    offset: offset, remaining: request.outputCount - decodedOrdinal, check: check)
                            } else {
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
                                emitted = .init(tokens: [token], payloadSHA256: [produced.payloadSHA256], logits: row, round: false)
                            }
                            guard !emitted.tokens.isEmpty, emitted.tokens.count == emitted.payloadSHA256.count,
                                  decodedOrdinal + emitted.tokens.count <= request.outputCount else {
                                throw ProbeError("Solo decode emitted past the request's output limit")
                            }
                            for (column, token) in emitted.tokens.enumerated() {
                                queue.append(.init(token: token, payload: emitted.payloadSHA256[column],
                                    emitted: emitted, column: column))
                            }
                            forwards += emitted.tokens.count
                            decodedOrdinal += emitted.tokens.count
                            lastToken = emitted.tokens[emitted.tokens.count - 1]
                        }
                        let item = queue.removeFirst()
                        let ordinal = firstOrdinal + tokenIDs.count
                        tokenIDs.append(item.token); payloads.append(item.payload)
                        terminal = request.stopTokenIDs.contains(item.token) || ordinal + 1 == request.outputCount
                        if terminal {
                            guard queue.isEmpty else { throw ProbeError("Solo decode emitted past a stop") }
                        }
                        if terminal, recording {
                            let row = item.emitted.row(item.column)
                            let captured = try QwenRecordedLogits(row, vocabularySize: request.profile.vocabularySize, check: check)
                            guard let maximum = captured.record.values.max(), request.sampler != nil
                                    || captured.record.values.firstIndex(of: maximum) == item.token else {
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
            let discarded = forwards - (control.selectedTokenCount - (alone ? 0 : split.terms.handoffSelectedTokens))
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
            let statistics = decoder?.statistics
            decoder?.release()
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
                beforeHandoff: before, afterHandoff: after, afterRetirement: memory(), mtp: statistics),
                recorded: recorded)
        } catch {
            decoder?.release()
            try? adopted.cancel()
            throw error
        }
    }
}

extension QwenPhaseSplitSummary {
    /// One line a launcher can read from the worker's diagnostics. It carries
    /// sizes and durations only.
    func diagnosticLine(requestID: UUID) -> String {
        (["darkbloom-phase-split-v1", "rank=\(rank)", "request=\(requestID.uuidString.lowercased())",
         "handoff=\(handoffPerformed ? 1 : 0)", "entries=\(handoffEntries)", "segments=\(handoffSegments)",
         "bytes=\(handoffLogicalBytes)", "handoff_ns=\(handoffNanoseconds)",
         "local_state_ns=\(handoffLocalStateNanoseconds)", "relay_batches=\(relayBatches)",
         "solo_forwards=\(soloDecodeForwards)", "discarded_forwards=\(discardedDecodeForwards)",
         "active_before=\(beforeHandoff.activeBytes)", "cache_before=\(beforeHandoff.cacheBytes)",
         "active_after_handoff=\(afterHandoff.activeBytes)", "cache_after_handoff=\(afterHandoff.cacheBytes)",
         "active_after_retirement=\(afterRetirement.activeBytes)", "cache_after_retirement=\(afterRetirement.cacheBytes)",
        ] + (mtp?.diagnosticFields ?? [])).joined(separator: " ")
    }
}
