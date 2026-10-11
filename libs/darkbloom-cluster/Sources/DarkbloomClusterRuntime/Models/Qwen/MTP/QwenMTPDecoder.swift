import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// The product's speculative decoding of one request on a rank that holds both
/// stages (the decoding rank of a phase-split session, or the staged reference
/// after its in-process hand-off).
///
/// One round: the product's head drafts `depth` tokens from the carry (the last
/// committed token and the target hidden row that produced it); both stages run
/// the window `[last, d1 ... dk]` in one evaluation, with every recurrent layer
/// capturing its state per position; the longest prefix of drafts equal to the
/// target's own greedy token at each column is kept, followed by the target's
/// token at the first mismatch (or the bonus column). So every emitted token is
/// the target's argmax at its own column, as in the product's exact acceptance
/// for greedy rows. A sampled request compares with the product's keyed target
/// sample at each column instead (target-prefix acceptance), so every emitted
/// token is the draw the ordinary path makes at that output index; one whose
/// transforms depend on its history decodes plainly, as the product gates it.
/// Both stages then keep that many positions (recurrent state
/// selected at the kept position, attention rows rolled back by the rest) and
/// the head keeps only trusted history, exactly as the product's finalize does.
///
/// The product's rules for when a round runs are kept: a round needs a carry and
/// at least `depth` tokens left before the output limit; otherwise one ordinary
/// decode step runs. The depth is fixed (`QwenMTPTerms`), not timing-adaptive.
final class QwenMTPDecoder {
    /// What one call produced, in order. `payloadSHA256[i]` is the digest of
    /// the stage-0 residual row whose input produced `tokens[i]`, as a plain
    /// decode step's boundary digest is. `logits` holds the target rows:
    /// `[1, n, V]` for a round (column i belongs to token i) or `[1, V]` for a
    /// plain step; use `row(_:)`.
    struct Emitted {
        let tokens: [Int]
        let payloadSHA256: [String]
        let logits: MLXArray
        let round: Bool

        func row(_ index: Int) -> MLXArray {
            round ? logits[0..., index, 0...] : logits
        }
    }

    let terms: QwenMTPTerms
    let request: QwenLayerStageGenerationRequest
    private let head: QwenMTPHead
    private let state: any CBv2MTPRequestState
    private let stopTokens: Set<Int>
    /// The last prompt row the consumer stage produced, pre-norm.
    private var promptFrontier: MLXArray?
    private var carry: (token: Int, hidden: MLXArray)?
    private var released = false
    private(set) var statistics: QwenMTPStatistics

    init(head: QwenMTPHead, terms: QwenMTPTerms, request: QwenLayerStageGenerationRequest) throws {
        guard head.assistant.maximumDraftTokens.map({ terms.depth <= $0 }) ?? false,
              head.assistant.maximumSpeculativeBatch == 1 else {
            throw ProbeError("Speculative head cannot draft the agreed depth for one request")
        }
        self.head = head; self.terms = terms; self.request = request
        self.stopTokens = Set(request.stopTokenIDs)
        self.state = head.assistant.makeRequestState()
        statistics = .init(depth: terms.depth)
        try head.assistant.configureRequestState(state, maximumSequenceLength: request.maximumTokens)
    }

    /// The consumer stage's tap for this request: every committed prompt
    /// chunk's tokens and pre-norm hidden rows become the head's history.
    func tap() -> QwenLayerStageHiddenTap {
        head.tap { [weak self] tokens, hidden in
            guard let self, !self.released, self.carry == nil else {
                throw ProbeError("Speculative head observed a prompt row outside its prompt")
            }
            guard tokens.ndim == 2, hidden.ndim == 3, tokens.dim(1) == hidden.dim(1), tokens.dim(1) > 0 else {
                throw ProbeError("Speculative head observation differs from the [1,n] / [1,n,H] contract")
            }
            self.head.assistant.observeCommittedTarget(.init(tokens: tokens, hidden: hidden), requestState: self.state)
            let last = hidden.dim(1) - 1
            self.promptFrontier = hidden[0..., last ..< (last + 1), 0...]
        }
    }

    /// After the last prompt chunk and the first selected token: that token and
    /// the prompt's last hidden row are the first carry.
    func begin(firstToken: Int) throws {
        guard !released, carry == nil, let promptFrontier else {
            throw ProbeError("Speculative head starts without a complete observed prompt")
        }
        carry = (firstToken, promptFrontier)
        self.promptFrontier = nil
    }

    /// Decodes from `lastToken` (the last selected token, not yet fed to the
    /// model) at `offset`, with `remaining` tokens left before the output
    /// limit. Emits 1 to depth + 1 tokens; never past a stop token or the limit.
    func step(producer: QwenLayerStageSession, consumer: QwenLayerStageSession,
              lastToken: Int, offset: Int, remaining: Int, check: () throws -> Void) throws -> Emitted {
        guard !released, remaining >= 1 else { throw ProbeError("Speculative decode stepped past its request") }
        let depth = terms.depth
        // A sampled request whose transforms depend on its history (logit
        // bias, penalties) is never speculated, as in the product.
        let verifiable = request.sampler?.admitsSpeculativeVerification ?? true
        guard verifiable, let carry, carry.token == lastToken, remaining >= depth else {
            // The product's own rule: no carry or too few tokens left, one plain step.
            self.carry = nil
            statistics.plainSteps += 1
            return try plainStep(producer: producer, consumer: consumer, lastToken: lastToken,
                offset: offset, check: check)
        }
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check() }
            let started = DispatchTime.now().uptimeNanoseconds
            // Draft: once from the carry, then on the head's own hidden.
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
            let window = concatenated([seed, drafts], axis: 1)
            // Verify: both stages over the window, one evaluation with the head.
            let w0 = try producer.beginWindow(tokens: window, offset: offset)
            let residual = w0.outputs[0]
            let w1 = try consumer.beginWindow(tokens: window, offset: offset, residual: residual)
            let logits = w1.outputs[0], targetHidden = w1.outputs[1]
            // Greedy: the target's argmax per column. Sampled: the product's
            // target-prefix pre-sampling, each column a keyed target sample at
            // its own output index; acceptance below is the same walk.
            let targets = request.sampler?.verify(logits)?.asType(.int32) ?? argMax(logits, axis: -1).asType(.int32)
            let finite = all(isFinite(logits))
            try checked()
            let built = DispatchTime.now().uptimeNanoseconds
            eval([residual, logits, targetHidden, targets, finite, drafts] + w0.roots + w1.roots
                + head.assistant.evaluationTargets(for: state))
            try checked()
            try producer.confirmWindow(check: checked)
            try consumer.confirmWindow(check: checked)
            let draftIDs = drafts.asArray(Int32.self).map(Int.init)
            let targetIDs = targets.asArray(Int32.self).map(Int.init)
            guard finite.item(Bool.self), draftIDs.count == depth, targetIDs.count == depth + 1,
                  (draftIDs + targetIDs).allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }) else {
                throw ProbeError("Speculative window produced non-finite logits or a token outside the vocabulary")
            }
            try checked()
            let evaluated = DispatchTime.now().uptimeNanoseconds

            // Exact acceptance: a draft is kept while it is the target's own token.
            var accepted = 0
            while accepted < depth, targetIDs[accepted] == draftIDs[accepted] { accepted += 1 }
            var emitted = min(accepted + 1, remaining)
            if let stop = targetIDs[..<emitted].firstIndex(where: stopTokens.contains) { emitted = stop + 1 }
            let tokens = Array(targetIDs[..<emitted])
            request.sampler?.commitRound(tokens)
            var digests: [String] = []
            for index in 0..<emitted {
                digests.append(sha256(residual[0..., index ..< (index + 1), 0...].asData().data))
            }
            try checked()

            // Keep: both stages, then the head's trusted history and the carry.
            let roots0 = try producer.settleWindow(keeping: emitted)
            let roots1 = try consumer.settleWindow(keeping: emitted)
            let committedDrafts = min(accepted, emitted - 1)
            head.assistant.finalizeRound(requestState: state, confirmedInputTokens: 1 + committedDrafts,
                committedDraftTokens: drafts[0..., 0 ..< committedDrafts],
                committedTargetHidden: targetHidden[0..., 0 ..< committedDrafts, 0...])
            let carryHidden = targetHidden[0..., (emitted - 1) ..< emitted, 0...]
            eval(roots0 + roots1 + [carryHidden])
            try checked()
            try producer.confirmSettled(check: checked)
            try consumer.confirmSettled(check: checked)
            self.carry = (tokens[emitted - 1], carryHidden)
            let settled = DispatchTime.now().uptimeNanoseconds

            statistics.rounds += 1
            statistics.emittedTokens += emitted
            for position in 0..<min(accepted + 1, depth) { statistics.examinedByPosition[position] += 1 }
            for position in 0..<accepted { statistics.acceptedByPosition[position] += 1 }
            statistics.buildNanoseconds += built - started
            statistics.evaluateNanoseconds += evaluated - built
            statistics.settleNanoseconds += settled - evaluated
            return Emitted(tokens: tokens, payloadSHA256: digests, logits: logits[0..., 0 ..< emitted, 0...],
                round: true)
        }
    }

    /// One ordinary decode frame through both stages, as the plain phase-split
    /// path runs it.
    private func plainStep(producer: QwenLayerStageSession, consumer: QwenLayerStageSession,
                           lastToken: Int, offset: Int, check: () throws -> Void) throws -> Emitted {
        guard case .hidden(let produced) = try producer.decode(lastToken, offset: offset, check: check) else {
            throw ProbeError("Producer stage did not return a residual")
        }
        var incoming = produced
        if !produced.hasOwnedCompactStorage { incoming = try produced.ownedCopy(check: check) }
        guard case .logits(let row) = try consumer.decode(lastToken, offset: offset, incoming: incoming, check: check) else {
            throw ProbeError("Consumer stage did not return target logits")
        }
        let token = try QwenLayerStageGenerationSelection.token(row, request: request, check: check)
        statistics.emittedTokens += 1
        return Emitted(tokens: [token], payloadSHA256: [produced.payloadSHA256], logits: row, round: false)
    }

    /// Releases the head's request state. Idempotent.
    func release() {
        guard !released else { return }
        released = true
        carry = nil; promptFrontier = nil
        head.assistant.releaseRequestState(state)
    }

    deinit { release() }
}
