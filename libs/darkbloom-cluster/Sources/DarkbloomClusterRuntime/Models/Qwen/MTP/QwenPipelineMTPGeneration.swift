import DarkbloomClusterSecurity
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// The decode phase of a Qwen `pipeline_mtp_v1` request, after the prompt and
/// the first selected token, until both ranks agree to stop. The same round
/// contract as MiMo's (`MiMoMTPGeneration`): the wire packets, the acceptance
/// walk and the replay through the unchanged generation control are shared;
/// only the stages' verify window is Qwen's own (`QwenLayerStageSession`'s
/// captured window: every recurrent layer keeps its state at each window
/// position, so keeping fewer rows selects the state at the kept position and
/// rolls the attention rows back by the rest).
///
/// One step: rank 1 (the consumer stage, which also holds the model's head
/// and a copy of the token embedding) drafts up to `depth` tokens from the
/// carry and sends the window `[last, d1 ... dk]` (k = 0 for a plain step);
/// rank 0 runs it through its stage in one forward and sends the residual
/// rows; rank 1 runs them through its stage, takes the target's own token at
/// every column (greedy argmax, or the product's keyed target sample: the
/// target-prefix acceptance), keeps the longest prefix of drafts equal to the
/// target token before each and the target token after, and sends the kept
/// tokens with their residual digests; rank 0 checks both against its own
/// window. Both stages keep exactly those rows, and both ranks take the kept
/// tokens through the generation control one decode frame each (as a phase
/// split relays them), so the history, token chain and stop decisions are the
/// pipeline's own. Rank 0 publishes and decides; a client stop may leave kept
/// rows unpublished (`discarded`).
enum QwenPipelineMTPGeneration {
    struct Outcome {
        let selected: [Int]
        let finalDecision: QwenLayerStageGenerationDecisionPacket
        let discardedDecodeForwards: Int
        let statistics: QwenMTPStatistics?
    }

    private static func scope(_ agreement: QwenLayerStageGenerationAgreement, _ type: ClusterRecordType,
                              _ label: String) -> CollectiveRecordScope {
        .request(type, requestID: agreement.request.requestID, agreementFingerprint: agreement.fingerprint, label)
    }

    private static func sendFrame(_ body: Data, frameBytes: Int, collective: Collective,
                                  scope: CollectiveRecordScope, check: () throws -> Void) throws {
        let frame = try QwenControlFrame.encode(body, frameBytes: frameBytes)
        _ = try collective.sendCompleted(MLXArray(Array(frame)), to: 1 - collective.rank, maximumBytes: frameBytes,
            scope: scope, check: check)
    }

    private static func receiveFrame(frameBytes: Int, collective: Collective, scope: CollectiveRecordScope,
                                     check: () throws -> Void) throws -> Data {
        let data = try collective.receiveCompleted(shape: [frameBytes], dtype: .uint8, from: 1 - collective.rank,
            maximumBytes: frameBytes, scope: scope, check: check).asData().data
        try check()
        return try QwenControlFrame.decode(data, frameBytes: frameBytes)
    }

    /// The window's residual rows in an allocation of their own (a captured
    /// forward may return a view of a larger buffer).
    private static func owned(_ residual: MLXArray) throws -> MLXArray {
        if let buffer = try residual.evaluatedBufferInfo(), buffer.isUnique, buffer.isRowContiguous,
           buffer.dataOffset == 0, buffer.dataElements == residual.size {
            return residual
        }
        let copy = try copySelectedTensor(residual, selection: .all)
        eval(copy); Stream.gpu.synchronize()
        guard copy.shape == residual.shape, copy.dtype == residual.dtype else {
            throw ProbeError("Speculative window residual copy changed its native contract")
        }
        return copy
    }

    /// Rank 0: run each window rank 1 asks for, check what it keeps, publish.
    static func runProducer(session: QwenLayerStageSession, control: QwenLayerStageGenerationControl,
                            terms: QwenMTPTerms, collective: Collective,
                            recording: QwenGenerationDiagnosticCapture? = nil,
                            onCommittedToken: (Int) throws -> Bool, check: () throws -> Void) throws -> Outcome {
        let agreement = control.agreement, request = agreement.request
        guard collective.rank == 0, agreement.speculativeRoundsFraming == terms.pipelineDecodeFraming else {
            throw ProbeError("Only rank 0 of an agreed speculative pipeline runs the producer side of a round")
        }
        var selected: [Int] = [], discarded = 0
        var finalDecision: QwenLayerStageGenerationDecisionPacket?
        while control.phase == .frame {
            try autoreleasepool {
                try check()
                guard let last = control.lastTokenID else { throw ProbeError("Speculative decode lacks an agreed token") }
                let round = try MiMoMTPRoundPacket.decode(
                    receiveFrame(frameBytes: MiMoMTPRoundPacket.frameBytes, collective: collective,
                        scope: scope(agreement, .tokenRelay, "qwen-round"), check: check),
                    agreement: agreement, terms: terms, firstOrdinal: control.selectedTokenCount,
                    previousTokenChainSHA256: control.tokenChainSHA256, lastTokenID: last)
                guard round.content.committedTokens == session.committedTokens else {
                    throw ProbeError("Speculative round frontier differs from this stage's")
                }
                let window = round.window, width = window.count
                let ids = MLXArray(window.map(Int32.init)).reshaped([1, width])
                let opened = try session.beginWindow(tokens: ids, offset: session.committedTokens)
                eval(opened.outputs + opened.roots)
                try check()
                try session.confirmWindow(check: check)
                // The sender inspects the residual's storage: drain the stream first.
                Stream.gpu.synchronize(); try check()
                let residual = try owned(opened.outputs[0])
                guard residual.shape == [1, width, request.profile.hiddenSize] else {
                    throw ProbeError("Speculative window residual differs from the native [1,S,H] contract")
                }
                let rows = try MiMoWindowRows.rowSHA256(residual)
                _ = try collective.sendCompleted(residual, to: 1, maximumBytes: residual.nbytes,
                    scope: scope(agreement, .residualPayload, "qwen-window|" + round.fingerprint), check: check)
                let result = try MiMoMTPRoundResultPacket.decode(
                    receiveFrame(frameBytes: MiMoMTPRoundResultPacket.frameBytes, collective: collective,
                        scope: scope(agreement, .tokenRelay, "qwen-result"), check: check),
                    agreement: agreement, round: round)
                let kept = result.content.tokenIDs.count
                guard result.content.payloadSHA256 == Array(rows.prefix(kept)) else {
                    throw ProbeError("Speculative round result names residual rows this stage did not produce")
                }
                let settled = try session.settleWindow(keeping: kept)
                eval(settled); try check()
                try session.confirmSettled(check: check)
                var accepted = 0
                var published: QwenLayerStageGenerationDecisionPacket?
                for (index, token) in result.content.tokenIDs.enumerated() {
                    let frame = try request.frame(sequence: control.completedFrames)
                    let decision = try QwenPhaseSplitGeneration.replay(tokenID: token, payloadSHA256: rows[index],
                        control: control) { value in
                        try check()
                        let proceed = try onCommittedToken(value)
                        try check()
                        return proceed
                    }
                    selected.append(token); accepted += 1; published = decision
                    // A recording's final frame: rank 0 owns no row of it.
                    if let recording, control.phase == .retiring {
                        try recording.captureFinalRow(nil, frame: frame, tokenID: token, check: check)
                    }
                    if decision.content.decision != .proceed { break }
                }
                guard let published else { throw ProbeError("Speculative round kept no token") }
                // Only a stop leaves kept tokens unpublished; EOS and the limit cannot.
                guard accepted == kept || published.content.decision == .clientStop else {
                    throw ProbeError("Speculative round kept tokens past an agreed stop")
                }
                discarded += kept - accepted
                let decision = try MiMoMTPRoundDecisionPacket(agreement: agreement, result: result, acceptedCount: accepted,
                    selectedTokenCount: control.selectedTokenCount, tokenChainSHA256: control.tokenChainSHA256,
                    decision: published.content.decision)
                try sendFrame(try decision.encoded(), frameBytes: MiMoMTPRoundDecisionPacket.frameBytes,
                    collective: collective, scope: scope(agreement, .relayDecision, "qwen-decision"), check: check)
                if control.phase == .retiring { finalDecision = published }
            }
        }
        guard let finalDecision else { throw ProbeError("Speculative decode ended without an agreed stop") }
        return .init(selected: selected, finalDecision: finalDecision, discardedDecodeForwards: discarded, statistics: nil)
    }

    /// Rank 1: draft, verify each window rank 0 runs, keep, and follow rank
    /// 0's publication.
    static func runConsumer(session: QwenLayerStageSession, decoder: QwenMTPDecoder,
                            control: QwenLayerStageGenerationControl, collective: Collective,
                            recording: QwenGenerationDiagnosticCapture? = nil,
                            check: () throws -> Void) throws -> Outcome {
        let agreement = control.agreement, request = agreement.request
        guard collective.rank == 1, agreement.speculativeRoundsFraming == decoder.terms.pipelineDecodeFraming else {
            throw ProbeError("Only rank 1 of an agreed speculative pipeline runs the consumer side of a round")
        }
        let stopTokens = Set(request.stopTokenIDs)
        var selected: [Int] = [], discarded = 0
        var finalDecision: QwenLayerStageGenerationDecisionPacket?
        while control.phase == .frame {
            try autoreleasepool {
                try check()
                guard let last = control.lastTokenID else { throw ProbeError("Speculative decode lacks an agreed token") }
                let remaining = request.outputCount - control.selectedTokenCount
                let drafts = try decoder.draft(lastToken: last, remaining: remaining, check: check)
                let round = try MiMoMTPRoundPacket(agreement: agreement, terms: decoder.terms,
                    firstOrdinal: control.selectedTokenCount, previousTokenChainSHA256: control.tokenChainSHA256,
                    lastTokenID: last, draftTokenIDs: drafts)
                guard round.content.committedTokens == session.committedTokens else {
                    throw ProbeError("Speculative round frontier differs from this stage's")
                }
                try sendFrame(try round.encoded(), frameBytes: MiMoMTPRoundPacket.frameBytes, collective: collective,
                    scope: scope(agreement, .tokenRelay, "qwen-round"), check: check)
                let window = round.window, width = window.count
                let waited = DispatchTime.now().uptimeNanoseconds
                let residual = try collective.receiveCompleted(shape: [1, width, request.profile.hiddenSize],
                    dtype: try QwenPipelineMTPGeneration.activationDType(request), from: 0,
                    maximumBytes: width * request.profile.hiddenSize * qwenStageWireElementBytes(request.profile.activationDType),
                    scope: scope(agreement, .residualPayload, "qwen-window|" + round.fingerprint), check: check)
                let verifying = DispatchTime.now().uptimeNanoseconds
                let rows = try MiMoWindowRows.rowSHA256(residual)
                let ids = MLXArray(window.map(Int32.init)).reshaped([1, width])
                let opened = try session.beginWindow(tokens: ids, offset: session.committedTokens, residual: residual)
                let logits = opened.outputs[0], hidden = opened.outputs[1]
                let targets: MLXArray?
                if drafts.isEmpty {
                    targets = nil
                } else {
                    // Greedy: the argmax per column. Sampled: the product's
                    // target-prefix pre-sampling, column j at output index
                    // `nextOutputIndex + j`.
                    targets = request.sampler?.verify(logits)?.reshaped([-1]).asType(.int32)
                        ?? argMax(logits[0], axis: -1).asType(.int32)
                }
                let finite = all(isFinite(logits))
                eval([logits, hidden, finite] + (targets.map { [$0] } ?? []) + opened.roots)
                try check()
                try session.confirmWindow(check: check)
                guard finite.item(Bool.self) else { throw ProbeError("Speculative window produced non-finite logits") }
                let kept: (tokens: [Int], acceptedDrafts: Int)
                if let targets {
                    let chosen = targets.asArray(Int32.self).map(Int.init)
                    guard chosen.count == width, chosen.allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }) else {
                        throw ProbeError("Speculative window selected a token outside the vocabulary")
                    }
                    kept = try MiMoMTPAcceptance.kept(drafts: drafts, targets: chosen, remaining: remaining,
                        stopTokens: stopTokens)
                    request.sampler?.commitRound(kept.tokens)
                } else {
                    // A plain step selects exactly as the pipeline's own step.
                    kept = ([try QwenLayerStageGenerationSelection.token(logits[0..., 0, 0...], request: request,
                        check: check)], 0)
                }
                let settling = DispatchTime.now().uptimeNanoseconds
                let settled = try session.settleWindow(keeping: kept.tokens.count)
                try decoder.finalize(drafts: drafts, tokens: kept.tokens, acceptedDrafts: kept.acceptedDrafts,
                    hidden: hidden, alsoEvaluate: settled)
                try check()
                try session.confirmSettled(check: check)
                let result = try MiMoMTPRoundResultPacket(agreement: agreement, round: round, tokenIDs: kept.tokens,
                    payloadSHA256: Array(rows.prefix(kept.tokens.count)))
                try sendFrame(try result.encoded(), frameBytes: MiMoMTPRoundResultPacket.frameBytes,
                    collective: collective, scope: scope(agreement, .tokenRelay, "qwen-result"), check: check)
                let done = DispatchTime.now().uptimeNanoseconds
                let verdict = try MiMoMTPRoundDecisionPacket.decode(
                    receiveFrame(frameBytes: MiMoMTPRoundDecisionPacket.frameBytes, collective: collective,
                        scope: scope(agreement, .relayDecision, "qwen-decision"), check: check),
                    agreement: agreement, result: result).content
                var lastDecision: QwenLayerStageGenerationDecisionPacket?
                for index in 0..<verdict.acceptedCount {
                    let proceed = index + 1 < verdict.acceptedCount || verdict.decision == .proceed
                    let frame = try request.frame(sequence: control.completedFrames)
                    lastDecision = try QwenPhaseSplitGeneration.replay(tokenID: kept.tokens[index],
                        payloadSHA256: rows[index], control: control) { _ in proceed }
                    selected.append(kept.tokens[index])
                    // A recording keeps each accepted token's own column (the
                    // accepted timeline) and the last one's whole row.
                    if let recording {
                        let row = logits[0..., index, 0...]
                        try recording.captureStep(row, frame: frame, tokenID: kept.tokens[index], check: check)
                        if control.phase == .retiring {
                            try recording.captureFinalRow(row, frame: frame, tokenID: kept.tokens[index], check: check)
                        }
                    }
                }
                guard let lastDecision, lastDecision.content.decision == verdict.decision,
                      control.selectedTokenCount == verdict.selectedTokenCount,
                      control.tokenChainSHA256 == verdict.tokenChainSHA256,
                      verdict.acceptedCount == kept.tokens.count || control.phase == .retiring else {
                    throw ProbeError("Speculative round decision differs from the locally kept history")
                }
                discarded += kept.tokens.count - verdict.acceptedCount
                if control.phase == .retiring { finalDecision = lastDecision }
                decoder.recordTimes(wait: verifying - waited, verify: settling - verifying, settle: done - settling)
            }
        }
        guard let finalDecision else { throw ProbeError("Speculative decode ended without an agreed stop") }
        return .init(selected: selected, finalDecision: finalDecision, discardedDecodeForwards: discarded,
            statistics: decoder.statistics)
    }

    /// The residual's native dtype, from the agreed profile (the stage's own).
    static func activationDType(_ request: QwenLayerStageGenerationRequest) throws -> DType {
        switch request.profile.activationDType {
        case "bfloat16": return .bfloat16
        case "float16": return .float16
        case "float32": return .float32
        default: throw ProbeError("Speculative window residual has no supported native dtype")
        }
    }
}
