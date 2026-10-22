import DarkbloomClusterSecurity
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Per draft position, how often a round reached it and how often its draft
/// was the target's own token; and where rank 1's round time went.
struct MiMoMTPStatistics: Encodable, Equatable {
    var depth: Int
    var rounds = 0
    var plainSteps = 0
    var emittedTokens = 0
    var examinedByPosition: [Int]
    var acceptedByPosition: [Int]
    var draftNanoseconds: UInt64 = 0
    var waitNanoseconds: UInt64 = 0
    var verifyNanoseconds: UInt64 = 0
    var settleNanoseconds: UInt64 = 0
    var promptObserveNanoseconds: UInt64 = 0

    init(depth: Int) {
        self.depth = depth
        examinedByPosition = Array(repeating: 0, count: depth)
        acceptedByPosition = Array(repeating: 0, count: depth)
    }

    var drafted: Int { examinedByPosition.reduce(0, +) }
    var accepted: Int { acceptedByPosition.reduce(0, +) }

    mutating func record(drafts: Int, acceptedDrafts: Int, emitted: Int) {
        emittedTokens += emitted
        guard drafts > 0 else { plainSteps += 1; return }
        rounds += 1
        for position in 0..<min(acceptedDrafts + 1, drafts) { examinedByPosition[position] += 1 }
        for position in 0..<acceptedDrafts { acceptedByPosition[position] += 1 }
    }

    var diagnosticFields: [String] {
        ["mtp_depth=\(depth)", "mtp_rounds=\(rounds)", "mtp_plain_steps=\(plainSteps)",
         "mtp_emitted=\(emittedTokens)", "mtp_drafted=\(drafted)", "mtp_accepted=\(accepted)",
         "mtp_examined_by_position=" + examinedByPosition.map(String.init).joined(separator: "-"),
         "mtp_accepted_by_position=" + acceptedByPosition.map(String.init).joined(separator: "-"),
         "mtp_draft_ns=\(draftNanoseconds)", "mtp_wait_ns=\(waitNanoseconds)",
         "mtp_verify_ns=\(verifyNanoseconds)", "mtp_settle_ns=\(settleNanoseconds)",
         "mtp_prompt_observe_ns=\(promptObserveNanoseconds)"]
    }
}

/// Rank 1's speculative state for one request: the product drafter's request
/// state (`MiMoV26MTPAssistant`, its own history, priming and round rules)
/// and the carry (the last selected token and the post-final-norm row that
/// produced it).
///
/// The drafter observes every committed prompt chunk (tokens and the stage's
/// normalized rows), drafts from the carry, and after each window keeps only
/// the verified target history (`finalizeRound`), exactly as the single-Mac
/// engine drives it. Its requested observation fence is honoured: each
/// observation's roots are evaluated before the next mutation. The SDK's
/// residency measurement of that state (`requestStateDidFinishEvaluation`,
/// the CBv2 engine's accounting) is not used: this runtime charges the state
/// through the head's bounded request declaration (`MiMoMTPHead.requestBytes`)
/// in the rank's request allowance, and the measurement's sole-owner proof
/// does not hold while the stage still holds the rows it observed.
final class MiMoMTPDecoder {
    let head: MiMoMTPHead
    let terms: MiMoMTPTerms
    let request: QwenLayerStageGenerationRequest
    private var state: any CBv2MTPRequestState
    private var promptFrontier: MLXArray?
    private var carry: (token: Int, hidden: MLXArray)?
    private var fencePending = false
    private var released = false
    private(set) var statistics: MiMoMTPStatistics

    init(head: MiMoMTPHead, terms: MiMoMTPTerms, request: QwenLayerStageGenerationRequest) throws {
        guard head.assistant.maximumDraftTokens.map({ terms.depth <= $0 }) ?? false,
              head.assistant.maximumSpeculativeBatch == 1, request.profile.vocabularySize == head.vocabularySize else {
            throw ProbeError("MiMo speculative head cannot draft the agreed depth for this request")
        }
        self.head = head; self.terms = terms; self.request = request
        state = head.assistant.makeRequestState()
        statistics = .init(depth: terms.depth)
        try head.assistant.configureRequestState(state, maximumSequenceLength: request.maximumTokens)
    }

    /// Joins the drafter's queued work (the product's committed-observation fence).
    private func fence() throws {
        guard fencePending else { return }
        eval(head.assistant.evaluationTargets(for: state))
        fencePending = false
    }

    /// One committed prompt chunk: its tokens and the consumer stage's
    /// post-final-norm rows for them. The head's priming is queued behind the
    /// chunk on the stream and runs while rank 0 computes the next one.
    func observePrompt(tokens: [Int], hidden: MLXArray) throws {
        guard !released, carry == nil, !tokens.isEmpty, hidden.shape == [1, tokens.count, hidden.dim(2)] else {
            throw ProbeError("MiMo speculative head observed a prompt row outside its prompt")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        try fence()
        let ids = MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count])
        head.assistant.observeCommittedTarget(.init(tokens: ids, hidden: hidden), requestState: state)
        let last = tokens.count - 1
        promptFrontier = hidden[0..., last ..< (last + 1), 0...]
        asyncEval(head.assistant.evaluationTargets(for: state) + [promptFrontier!])
        fencePending = true
        statistics.promptObserveNanoseconds += DispatchTime.now().uptimeNanoseconds - started
    }

    /// After the last prompt chunk and the first selected token.
    func begin(firstToken: Int) throws {
        guard !released, carry == nil, let promptFrontier else {
            throw ProbeError("MiMo speculative head starts without an observed prompt")
        }
        try fence()
        carry = (firstToken, promptFrontier)
        self.promptFrontier = nil
    }

    /// The drafts of the next window from `lastToken` with `remaining` tokens
    /// left before the output limit: `depth` of them, fewer when fewer tokens
    /// are left (every window row may then be kept), or none (a plain step)
    /// when there is no carry, one token is left, or the request's sampler
    /// cannot verify drafts. Evaluated before return.
    func draft(lastToken: Int, remaining: Int, check: () throws -> Void) throws -> [Int] {
        guard !released, remaining >= 1 else { throw ProbeError("MiMo speculative decode stepped past its request") }
        let verifiable = request.sampler?.admitsSpeculativeVerification ?? true
        let depth = min(terms.depth, remaining - 1)
        guard verifiable, let carry, carry.token == lastToken, depth >= 1 else {
            self.carry = nil
            return []
        }
        let started = DispatchTime.now().uptimeNanoseconds
        try fence()
        let seed = MLXArray([Int32(lastToken)]).reshaped([1, 1])
        var feed = (tokens: seed, hidden: carry.hidden)
        var drafted: [MLXArray] = []
        for _ in 0..<depth {
            let next = head.assistant.draftStep(tokens: feed.tokens, hidden: feed.hidden, shortlist: nil,
                requestState: state)
            let token = next.tokens.reshaped([1, 1])
            drafted.append(token)
            feed = (token, next.hidden)
        }
        let drafts = concatenated(drafted, axis: 1)
        eval([drafts] + head.assistant.evaluationTargets(for: state))
        try check()
        let ids = drafts.asArray(Int32.self).map(Int.init)
        guard ids.count == depth, ids.allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }) else {
            throw ProbeError("MiMo speculative head drafted a token outside the vocabulary")
        }
        statistics.draftNanoseconds += DispatchTime.now().uptimeNanoseconds - started
        return ids
    }

    /// After both stages kept `tokens` of the window: the drafter keeps the
    /// verified history and the carry moves to the last kept row.
    func finalize(drafts: [Int], tokens: [Int], acceptedDrafts: Int, hidden: MLXArray) throws {
        guard !released, !tokens.isEmpty, hidden.dim(1) >= tokens.count else {
            throw ProbeError("MiMo speculative head finalized rows the window did not keep")
        }
        let carryHidden = hidden[0..., (tokens.count - 1) ..< tokens.count, 0...]
        if drafts.isEmpty {
            // A plain step: nothing to finalize; the row becomes the next carry
            // only if the head drafts again (it needs the history it skipped).
            carry = nil
            return
        }
        let committed = acceptedDrafts
        let draftArray = MLXArray(drafts.map(Int32.init)).reshaped([1, drafts.count])
        head.assistant.finalizeRound(requestState: state, confirmedInputTokens: 1 + committed,
            committedDraftTokens: draftArray[0..., 0 ..< committed],
            committedTargetHidden: hidden[0..., 0 ..< committed, 0...])
        eval(head.assistant.evaluationTargets(for: state) + [carryHidden])
        carry = (tokens[tokens.count - 1], carryHidden)
    }

    func release() {
        guard !released else { return }
        released = true
        carry = nil; promptFrontier = nil
        head.assistant.releaseRequestState(state)
    }

    deinit { release() }
}

/// The decode phase of a `pipeline_mtp_v1` request, after the prompt and the
/// first selected token, until both ranks agree to stop.
///
/// One step: rank 1 drafts up to `depth` tokens from the carry and sends the
/// window `[last, d1 ... dk]` (k = 0 for a plain step); rank 0 runs it through
/// its stage in one forward and sends the residual rows; rank 1 runs them
/// through its stage, takes the target's own token at every column (greedy
/// argmax, or the product's keyed target sample), keeps the longest prefix of
/// drafts equal to the target token before each and the target token after,
/// and sends the kept tokens with their residual digests; rank 0 checks both
/// against its own window. Both stages then keep exactly those rows and roll
/// the rest back, and both ranks take the kept tokens through the unchanged
/// generation control, one decode frame each (as a phase split relays them),
/// so the history, token chain and stop decisions are the pipeline's own.
/// Rank 0 publishes and decides; a client stop may leave kept rows
/// unpublished (`discarded`).
enum MiMoMTPGeneration {
    struct Outcome {
        let selected: [Int]
        let finalDecision: QwenLayerStageGenerationDecisionPacket
        let discardedDecodeForwards: Int
        let statistics: MiMoMTPStatistics?
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

    /// Rank 0: run each window rank 1 asks for, check what it keeps, publish.
    static func runProducer(session: MiMoLayerStageSession, control: QwenLayerStageGenerationControl,
                            terms: MiMoMTPTerms, collective: Collective,
                            onCommittedToken: (Int) throws -> Bool, check: () throws -> Void) throws -> Outcome {
        let agreement = control.agreement
        guard collective.rank == 0 else { throw ProbeError("Only rank 0 runs the producer side of a speculative round") }
        var selected: [Int] = [], discarded = 0
        var finalDecision: QwenLayerStageGenerationDecisionPacket?
        while control.phase == .frame {
            try autoreleasepool {
                try check()
                guard let last = control.lastTokenID else { throw ProbeError("Speculative decode lacks an agreed token") }
                let round = try MiMoMTPRoundPacket.decode(
                    receiveFrame(frameBytes: MiMoMTPRoundPacket.frameBytes, collective: collective,
                        scope: scope(agreement, .tokenRelay, "mimo-round"), check: check),
                    agreement: agreement, terms: terms, firstOrdinal: control.selectedTokenCount,
                    previousTokenChainSHA256: control.tokenChainSHA256, lastTokenID: last)
                guard round.content.committedTokens == session.committedTokens else {
                    throw ProbeError("Speculative round frontier differs from this stage's")
                }
                let window = round.window
                let (residual, rows) = try session.openWindow(window, offset: session.committedTokens, check: check)
                _ = try collective.sendCompleted(residual, to: 1, maximumBytes: residual.nbytes,
                    scope: scope(agreement, .residualPayload, "mimo-window|" + round.fingerprint), check: check)
                let result = try MiMoMTPRoundResultPacket.decode(
                    receiveFrame(frameBytes: MiMoMTPRoundResultPacket.frameBytes, collective: collective,
                        scope: scope(agreement, .tokenRelay, "mimo-result"), check: check),
                    agreement: agreement, round: round)
                let kept = result.content.tokenIDs.count
                guard result.content.payloadSHA256 == Array(rows.prefix(kept)) else {
                    throw ProbeError("Speculative round result names residual rows this stage did not produce")
                }
                try session.settleWindow(keeping: kept, rowSHA256: rows, check: check)
                var accepted = 0
                var published: QwenLayerStageGenerationDecisionPacket?
                for (index, token) in result.content.tokenIDs.enumerated() {
                    let decision = try QwenPhaseSplitGeneration.replay(tokenID: token, payloadSHA256: rows[index],
                        control: control) { value in
                        try check()
                        let proceed = try onCommittedToken(value)
                        try check()
                        return proceed
                    }
                    selected.append(token); accepted += 1; published = decision
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
                    collective: collective, scope: scope(agreement, .relayDecision, "mimo-decision"), check: check)
                if control.phase == .retiring { finalDecision = published }
            }
        }
        guard let finalDecision else { throw ProbeError("Speculative decode ended without an agreed stop") }
        return .init(selected: selected, finalDecision: finalDecision, discardedDecodeForwards: discarded, statistics: nil)
    }

    /// Rank 1: draft, verify each window rank 0 runs, keep, and follow rank
    /// 0's publication.
    static func runConsumer(session: MiMoLayerStageSession, decoder: MiMoMTPDecoder,
                            control: QwenLayerStageGenerationControl, collective: Collective,
                            check: () throws -> Void) throws -> Outcome {
        let agreement = control.agreement, request = agreement.request
        guard collective.rank == 1 else { throw ProbeError("Only rank 1 runs the consumer side of a speculative round") }
        let stopTokens = Set(request.stopTokenIDs)
        var selected: [Int] = [], discarded = 0
        var finalDecision: QwenLayerStageGenerationDecisionPacket?
        var statistics = MiMoMTPStatistics(depth: decoder.terms.depth)
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
                    scope: scope(agreement, .tokenRelay, "mimo-round"), check: check)
                let window = round.window, width = window.count
                let waited = DispatchTime.now().uptimeNanoseconds
                let residual = try collective.receiveCompleted(shape: [1, width, request.profile.hiddenSize],
                    dtype: .bfloat16, from: 0, maximumBytes: width * request.profile.hiddenSize * 2,
                    scope: scope(agreement, .residualPayload, "mimo-window|" + round.fingerprint), check: check)
                let verifying = DispatchTime.now().uptimeNanoseconds
                let rows = try MiMoWindowRows.rowSHA256(residual)
                let opened = try session.openWindow(window, offset: session.committedTokens, residual: residual, check: check)
                let logits = opened.logits
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
                eval([logits, opened.hidden, finite] + (targets.map { [$0] } ?? []) + opened.roots)
                try check()
                try session.confirmWindow(check: check)
                guard finite.item(Bool.self) else { throw ProbeError("Speculative window produced non-finite logits") }
                let kept: (tokens: [Int], acceptedDrafts: Int)
                if let targets {
                    let ids = targets.asArray(Int32.self).map(Int.init)
                    guard ids.count == width, ids.allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }) else {
                        throw ProbeError("Speculative window selected a token outside the vocabulary")
                    }
                    kept = try MiMoMTPAcceptance.kept(drafts: drafts, targets: ids, remaining: remaining, stopTokens: stopTokens)
                    request.sampler?.commitRound(kept.tokens)
                } else {
                    // A plain step selects exactly as the pipeline's own step.
                    kept = ([try QwenLayerStageGenerationSelection.token(logits[0..., 0, 0...], request: request,
                        check: check)], 0)
                }
                let settling = DispatchTime.now().uptimeNanoseconds
                try session.settleWindow(keeping: kept.tokens.count, rowSHA256: rows, check: check)
                try session.recordWindowRows(logits: logits, keeping: kept.tokens.count, rowSHA256: rows, check: check)
                try decoder.finalize(drafts: drafts, tokens: kept.tokens, acceptedDrafts: kept.acceptedDrafts,
                    hidden: opened.hidden)
                statistics.record(drafts: drafts.count, acceptedDrafts: kept.acceptedDrafts, emitted: kept.tokens.count)
                let result = try MiMoMTPRoundResultPacket(agreement: agreement, round: round, tokenIDs: kept.tokens,
                    payloadSHA256: Array(rows.prefix(kept.tokens.count)))
                try sendFrame(try result.encoded(), frameBytes: MiMoMTPRoundResultPacket.frameBytes,
                    collective: collective, scope: scope(agreement, .tokenRelay, "mimo-result"), check: check)
                let settled = DispatchTime.now().uptimeNanoseconds
                let verdict = try MiMoMTPRoundDecisionPacket.decode(
                    receiveFrame(frameBytes: MiMoMTPRoundDecisionPacket.frameBytes, collective: collective,
                        scope: scope(agreement, .relayDecision, "mimo-decision"), check: check),
                    agreement: agreement, result: result).content
                var lastDecision: QwenLayerStageGenerationDecisionPacket?
                for index in 0..<verdict.acceptedCount {
                    let proceed = index + 1 < verdict.acceptedCount || verdict.decision == .proceed
                    lastDecision = try QwenPhaseSplitGeneration.replay(tokenID: kept.tokens[index],
                        payloadSHA256: rows[index], control: control) { _ in proceed }
                    selected.append(kept.tokens[index])
                }
                guard let lastDecision, lastDecision.content.decision == verdict.decision,
                      control.selectedTokenCount == verdict.selectedTokenCount,
                      control.tokenChainSHA256 == verdict.tokenChainSHA256,
                      verdict.acceptedCount == kept.tokens.count || control.phase == .retiring else {
                    throw ProbeError("Speculative round decision differs from the locally kept history")
                }
                discarded += kept.tokens.count - verdict.acceptedCount
                if control.phase == .retiring { finalDecision = lastDecision }
                statistics.waitNanoseconds += verifying - waited
                statistics.verifyNanoseconds += settling - verifying
                statistics.settleNanoseconds += settled - settling
            }
        }
        guard let finalDecision else { throw ProbeError("Speculative decode ended without an agreed stop") }
        statistics.draftNanoseconds = decoder.statistics.draftNanoseconds
        statistics.promptObserveNanoseconds = decoder.statistics.promptObserveNanoseconds
        return .init(selected: selected, finalDecision: finalDecision, discardedDecodeForwards: discarded,
            statistics: statistics)
    }
}
