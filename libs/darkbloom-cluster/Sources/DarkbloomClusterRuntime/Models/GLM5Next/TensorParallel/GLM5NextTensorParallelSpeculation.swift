import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Greedy speculative decode for GLM tensor parallel with the model's own
/// NextN (MTP) layer, which every rank holds whole (replicated: its drafts
/// need no sums, and the head it shares with the stage is replicated too).
///
/// A round proposes up to `depth` tokens from the NextN layer (step 0 plus
/// index-shared continuations, `GLM5NextMTP.primeAndPropose`), verifies the
/// last committed token and the proposals in ONE stage forward
/// (`GLM5NextTextStage.prepareVerification`, a `[1, 1 + depth]` window whose
/// layer sums are the ordinary decode step's, `depth + 1` rows wide), and
/// keeps the longest prefix of proposals equal to the target's greedy tokens
/// plus the target's next token. Every KDA layer adopts the state it captured
/// after the last kept token and every DSA history drops the rest, so a
/// rejected proposal costs no replay. The NextN history is fed only verified
/// pairs (target token, preceding target hidden row), never a proposal.
///
/// Both ranks propose and verify from identical inputs, so they agree; they
/// still check it. Each round carries one small sum in which every rank puts
/// its own slot: the target's greedy token at each window position, its
/// proposals and its stop flag. The ranks' tokens and proposals must be
/// equal (a difference means diverged state and ends the request); a stop
/// flag on either rank ends both after the same round.
///
/// The output is the target's greedy tokens, computed by `[1, T]` windows
/// instead of one-token steps. MLX runs every multi-row quantized projection
/// (and the head) as `qmv_wide`, a one-row one as `qmv`, with a different K
/// order, so each window rounds differently from a one-token step and the
/// histories carry that forward: a long decode drifts from one-token greedy
/// decode and can pick a different token after tens to hundreds of tokens
/// (measured: first difference at 104 tokens at depths 1 and 2), not only at
/// a near-tie. Ranks never differ; a one-token window is bitwise a step.
final class GLM5NextTensorParallelSpeculation {
    /// Bound into the load agreement beside the depth.
    static let agreementName = "glm5-next-tp-mtp-v1"

    let mtp: GLM5NextMTP
    let depth: Int
    let rank: Int
    let ranks: Int
    /// The round's agreement sum (the sealed all-sum; the identity with no peer).
    private let agree: (MLXArray) -> MLXArray
    /// History rows primed per call: one prompt chunk's rows in pieces of at
    /// most this many, the request charge's bound for NextN history work.
    private let primeRows: Int
    let state: GLM5NextMTPState
    /// The verified shifted pairs (tokens `[1, n]`, target hidden `[1, n, H]`)
    /// the next round primes before it proposes.
    private var pending: (tokens: MLXArray, hidden: MLXArray)?
    /// False keeps only the target's first token of every round (each
    /// proposal rejected): one-token greedy decode computed in verification
    /// windows. A diagnostic: it separates the window arithmetic from the
    /// acceptance and rollback path.
    var acceptsProposals = true
    /// Per round, when set: host seconds building the graph, encoding it
    /// (`asyncEval` returning) and then waiting for the result. A wait near
    /// zero means the round is host-bound; a long wait, GPU-bound.
    var recordsPhases = false
    private(set) var phases: [(build: Double, encode: Double, wait: Double)] = []
    private(set) var rounds = 0
    private(set) var proposedTokens = 0
    private(set) var acceptedTokens = 0

    init(mtp: GLM5NextMTP, depth: Int, rank: Int, ranks: Int, primeRows: Int,
         agree: @escaping (MLXArray) -> MLXArray) throws {
        guard (1...GLM5NextMTP.maximumProposalDepth).contains(depth),
              depth + 1 <= GLM5NextTextStage.maximumVerificationTokens,
              depth == 1 || mtp.configuration.indexShareForMTPIteration,
              (1...2).contains(ranks), (0..<ranks).contains(rank), primeRows > 0 else {
            throw ProbeError("GLM speculative decode depth, ranks or priming bound is unsupported")
        }
        self.mtp = mtp; self.depth = depth; self.rank = rank; self.ranks = ranks
        self.primeRows = primeRows; self.agree = agree
        state = try mtp.newRequestState()
    }

    /// Roots a caller's fence must evaluate with the graph that built them.
    func evaluationTargets() throws -> [MLXArray] { try mtp.evaluationTargets(state: state) }

    // MARK: - Prompt

    /// Primes the NextN history of prompt positions `start ..< end` from the
    /// chunk's target hidden rows `[1, end - start, H]`: position p pairs
    /// `prompt[p + 1]` with row p. The last prompt position waits for the
    /// first generated token (`begin`). History only: no proposal is needed.
    func primePrompt(_ prompt: [Int], from start: Int, to end: Int, hidden: MLXArray) throws {
        let paired = min(end, prompt.count - 1)
        guard start >= 0, start <= paired, end <= prompt.count,
              hidden.ndim == 3, hidden.dim(0) == 1, hidden.dim(1) == end - start else {
            throw ProbeError("GLM speculative prompt priming geometry")
        }
        var position = start
        while position < paired {
            let next = min(paired, position + primeRows)
            try mtp.primeHistory(
                shiftedTokens: MLXArray(prompt[(position + 1)...next].map(Int32.init), [1, next - position]),
                targetHidden: hidden[0..., (position - start) ..< (next - start), 0...],
                at: state.committedInputCount, state: state)
            position = next
        }
    }

    /// A prompt prefix's NextN history, kept beside the stage cache it matches.
    func checkpoint() throws -> GLM5NextMTPCheckpoint { try mtp.capture(state: state) }

    /// Restores a prefix's history; nil (an entry stored without one) starts
    /// the history at the restored boundary: proposals are then weaker, never
    /// wrong.
    func restore(_ checkpoint: GLM5NextMTPCheckpoint?) throws {
        guard let checkpoint else { return }
        try mtp.restore(checkpoint, into: state)
    }

    // MARK: - Decode

    /// The first generated token (both ranks agreed it) and the last prompt
    /// row's target hidden `[1, 1, H]` are the first round's verified pair.
    func begin(carry: Int, lastHidden: MLXArray) throws {
        guard pending == nil, lastHidden.ndim == 3, lastHidden.dim(1) == 1 else {
            throw ProbeError("GLM speculative decode began twice or without its hidden row")
        }
        pending = (MLXArray([Int32(carry)], [1, 1]), lastHidden)
    }

    struct Round: Equatable {
        /// The agreed new tokens: the accepted proposals, then the target's next token.
        let tokens: [Int]
        /// Every rank's stop flag, in rank order (0: continue; otherwise tokens to keep).
        let stops: [Float]
    }

    /// Reads a round's evaluated agreement: `ranks` slots of `2 * window + 2`
    /// values, each the target's greedy token at the `window + 1` positions,
    /// the `window` proposals and the stop flag. Every rank's tokens and
    /// proposals must be equal (only the stop flags may differ). Keeps the
    /// longest prefix of proposals equal to the targets, then the target
    /// after it.
    static func decide(_ values: [Float], ranks: Int, window: Int) throws -> Round {
        let width = 2 * window + 2
        guard window >= 0, ranks > 0, values.count == ranks * width else {
            throw ProbeError("GLM speculative agreement has a wrong shape")
        }
        let slots = (0..<ranks).map { Array(values[($0 * width) ..< (($0 + 1) * width)]) }
        guard slots.allSatisfy({ $0.dropLast() == slots[0].dropLast() }) else {
            throw ProbeError("GLM tensor-parallel ranks verified different tokens")
        }
        let target = slots[0][0...window].map { Int($0) }
        let draft = slots[0][(window + 1) ..< (2 * window + 1)].map { Int($0) }
        var accepted = 0
        while accepted < window, draft[accepted] == target[accepted] { accepted += 1 }
        return Round(tokens: Array(target[0...accepted]), stops: slots.map { $0[width - 1] })
    }

    /// One round after the committed token `last` (not yet in `cache`):
    /// proposes `window` tokens (0...depth; 0 only verifies `last`), verifies
    /// them, agrees, and commits the kept prefix to `cache`. Both ranks must
    /// call it with the same `last` and `window`, which callers derive from
    /// agreed tokens only. Evaluates the round (one host read).
    /// `whileRunning` runs once the round is submitted and before its result
    /// is read (the caller hands the last round's tokens to its owner then);
    /// what it does cannot change this round.
    func round(stage: GLM5NextTextStage, cache: GLM5NextTextStageCache, last: Int, window: Int,
               stop: Float, whileRunning: () throws -> Void = {}) throws -> Round {
        guard let verified = pending, (0...depth).contains(window) else {
            throw ProbeError("GLM speculative round without its verified pairs or beyond its depth")
        }
        pending = nil
        let started = DispatchTime.now().uptimeNanoseconds
        // Priming the verified pairs is never skipped: it keeps the NextN
        // history in step with the target even when no proposal is used.
        let proposals = try mtp.primeAndPropose(shiftedTokens: verified.tokens, targetHidden: verified.hidden,
            at: state.committedInputCount, state: state, depth: max(1, window))
        let drafts = window > 0 ? proposals[0..., ..<window] : nil
        let input = concatenated([MLXArray([Int32(last)], [1, 1])] + (drafts.map { [$0] } ?? []), axis: 1)
        let candidate = try stage.prepareVerification(tokens: input, cache: cache)
        guard case .final(let output) = candidate.output else {
            throw ProbeError("GLM speculative verification produced no logits")
        }
        // Slot: the target's greedy token at each of the 1 + window positions,
        // the proposals, the stop flag. Token IDs are exact in float32.
        let width = 2 * window + 2
        let targets = argMax(output.logits[0].asType(.float32), axis: -1)
        var slot = [targets.asType(.float32)]
        if let drafts { slot.append(drafts.reshaped(-1).asType(.float32)) }
        slot.append(MLXArray([stop]))
        let local = concatenated(slot, axis: 0)
        let empty = MLXArray.zeros([width], dtype: .float32)
        let agreed = agree(concatenated((0..<ranks).map { $0 == rank ? local : empty }, axis: 0))
        var decided: Round?
        try candidate.commit(afterEvaluating: { roots in
            try MLX.withError { error in
                let all = roots + [agreed] + (try evaluationTargets())
                let built = DispatchTime.now().uptimeNanoseconds
                asyncEval(all)
                let encoded = DispatchTime.now().uptimeNanoseconds
                try whileRunning()
                eval(all)
                if recordsPhases {
                    let done = DispatchTime.now().uptimeNanoseconds
                    phases.append((Double(built - started) / 1e9, Double(encoded - built) / 1e9,
                        Double(done - encoded) / 1e9))
                }
                try error.check()
            }
        }, keeping: { _ in
            var round = try Self.decide(agreed.asArray(Float.self), ranks: ranks, window: window)
            if !acceptsProposals { round = Round(tokens: [round.tokens[0]], stops: round.stops) }
            decided = round
            return round.tokens.count
        })
        guard let decided else { throw ProbeError("GLM speculative round decided nothing") }
        let kept = decided.tokens.count
        // The next round's verified pairs: each kept target token with the
        // hidden row that predicted it.
        pending = (MLXArray(decided.tokens.map(Int32.init), [1, kept]), output.hidden[0..., ..<kept, 0...])
        rounds += 1; proposedTokens += window; acceptedTokens += kept - 1
        return decided
    }
}
