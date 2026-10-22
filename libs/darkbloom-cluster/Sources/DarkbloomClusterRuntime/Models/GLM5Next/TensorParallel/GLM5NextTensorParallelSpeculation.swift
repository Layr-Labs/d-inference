import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Speculative decode for GLM tensor parallel with the model's own
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
/// A sampled request keeps the product's target-prefix pre-sampling instead
/// of the argmax: rank 0 draws the keyed target sample at every window column
/// at its own output index (`QwenStageTokenSampler.verify`; with logit bias or
/// penalties, the step path replayed over the proposals before the column,
/// `QwenStageTokenSampler.verifyRound`), a proposal is kept while it equals
/// that sample, and the sample at the first mismatch is the round's last
/// token. Each committed token is the draw the one-token sampled path makes
/// at that index from the same logits; rank 1 puts its argmax (only so its
/// slot depends on the window, like rank 0's) and adopts rank 0's draws.
///
/// Its proposals are coupled to those draws: every rank draws proposal j
/// from the NextN logits with the request's own sampler and the keyed noise
/// of window column j's output index (`QwenStageTokenSampler.propose`,
/// which also replays logit bias and penalties over the proposals). The
/// argmax is kept only as often as the target draws it; a coupled proposal
/// from a draft distribution close to the target's is the target's own
/// draw: kept with probability between `(1 - TV) / (1 + TV)` and `1 - TV`
/// (TV: the two filtered distributions' total variation distance; equal
/// distributions always agree). No committed token depends on how a
/// proposal is chosen: column j's draw is a function of the committed prefix,
/// the logits and the noise, never of the proposal at j, and a column is
/// only reached through proposals equal to the committed tokens.
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
/// Where rounds end follows the proposals, so which window column computes a
/// given index (and with it that rounding) depends on how proposals are
/// chosen, greedy or coupled, exactly as on the NextN history they come from.
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
    /// Proposals made and kept at each proposal position.
    private(set) var proposedByPosition: [Int]
    private(set) var acceptedByPosition: [Int]

    /// Diagnostic for a sampled request on rank 0: scores other proposal
    /// rules on every verified round's first proposal. Window column 0's
    /// draw does not depend on any proposal, so each rule is scored against
    /// the very draw the round kept or rejected its own first proposal by.
    /// `rules` maps the first step's NextN logits `[1, 1, V]` to one token
    /// per rule `[R]`; it is called inside `round` (before the caller commits
    /// the round's tokens to its sampler) and evaluated after the round's
    /// result is read, while the next round is built. It never changes a
    /// proposal or a token.
    struct DraftProbe {
        let names: [String]
        let rules: (MLXArray) -> MLXArray
    }
    var draftProbe: DraftProbe?
    /// The current round's first-step NextN logits, while the probe needs them.
    private var probeLogits: MLXArray?
    private var probeHits: MLXArray?
    private(set) var probedRounds = 0

    /// `historyTokens`: the most columns the NextN history grows to (the
    /// request's charged length, `GLM5NextDSACache.capacityLimit`); nil is the
    /// cache's own doubling.
    init(mtp: GLM5NextMTP, depth: Int, rank: Int, ranks: Int, primeRows: Int, historyTokens: Int? = nil,
         agree: @escaping (MLXArray) -> MLXArray) throws {
        guard (1...GLM5NextMTP.maximumProposalDepth).contains(depth),
              depth + 1 <= GLM5NextTextStage.maximumVerificationTokens,
              depth == 1 || mtp.configuration.indexShareForMTPIteration,
              (1...2).contains(ranks), (0..<ranks).contains(rank), primeRows > 0 else {
            throw ProbeError("GLM speculative decode depth, ranks or priming bound is unsupported")
        }
        self.mtp = mtp; self.depth = depth; self.rank = rank; self.ranks = ranks
        self.primeRows = primeRows; self.agree = agree
        proposedByPosition = Array(repeating: 0, count: depth)
        acceptedByPosition = Array(repeating: 0, count: depth)
        let state = try mtp.newRequestState()
        state.historyCapacityLimit = historyTokens
        self.state = state
    }

    /// The draft probe's kept counts per rule, as `name:count` (one host
    /// read); nil without a probe or a probed round.
    func draftProbeHits() -> String? {
        guard let draftProbe, let probeHits, probedRounds > 0 else { return nil }
        let hits = probeHits.asArray(Int32.self)
        return zip(draftProbe.names, hits).map { "\($0):\($1)" }.joined(separator: ",")
    }

    /// Roots a caller's fence must evaluate with the graph that built them.
    func evaluationTargets() throws -> [MLXArray] { try mtp.evaluationTargets(state: state) }

    // MARK: - Prompt

    /// Primes the NextN history of prompt positions `start ..< end` from the
    /// chunk's target hidden rows `[1, end - start, H]`: position p pairs
    /// `prompt[p + 1]` with row p. The last prompt position waits for the
    /// first generated token (`begin`). History only: no proposal is needed.
    /// `inputs`, when given, returns the target's input embeddings
    /// `[1, n, H]` for prompt positions `lower ..< upper` where they are not
    /// token embeddings (image or video features), nil where they are: those
    /// rows are primed with what the target was fed.
    func primePrompt(_ prompt: [Int], from start: Int, to end: Int, hidden: MLXArray,
                     inputs: ((_ lower: Int, _ upper: Int) throws -> MLXArray?)? = nil) throws {
        let paired = min(end, prompt.count - 1)
        guard start >= 0, start <= paired, end <= prompt.count,
              hidden.ndim == 3, hidden.dim(0) == 1, hidden.dim(1) == end - start else {
            throw ProbeError("GLM speculative prompt priming geometry")
        }
        var position = start
        while position < paired {
            let next = min(paired, position + primeRows)
            let rows = hidden[0..., (position - start) ..< (next - start), 0...]
            if let embedded = try inputs?(position + 1, next + 1) {
                try mtp.primeHistory(shiftedEmbeddings: embedded, targetHidden: rows,
                    at: state.committedInputCount, state: state)
            } else {
                try mtp.primeHistory(
                    shiftedTokens: MLXArray(prompt[(position + 1)...next].map(Int32.init), [1, next - position]),
                    targetHidden: rows, at: state.committedInputCount, state: state)
            }
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
    /// values, each the target's token at the `window + 1` positions, the
    /// `window` proposals and the stop flag. Every rank's tokens and
    /// proposals must be equal (only the stop flags may differ); `sampled`
    /// takes rank 0's tokens (its draws) and checks the proposals only. Keeps
    /// the longest prefix of proposals equal to the targets, then the target
    /// after it.
    static func decide(_ values: [Float], ranks: Int, window: Int, sampled: Bool = false) throws -> Round {
        let width = 2 * window + 2
        guard window >= 0, ranks > 0, values.count == ranks * width else {
            throw ProbeError("GLM speculative agreement has a wrong shape")
        }
        let slots = (0..<ranks).map { Array(values[($0 * width) ..< (($0 + 1) * width)]) }
        let compared = sampled ? (window + 1) ..< (2 * window + 1) : 0 ..< (width - 1)
        guard slots.allSatisfy({ $0[compared] == slots[0][compared] }) else {
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
    /// what it does cannot change this round. `draw`, for a sampled request,
    /// gives this rank's target token at every column of the window's logits
    /// `[1, 1 + window, V]` (rank 0 its keyed samples); nil takes the argmax.
    /// Every rank's slot must be computed from the logits: the agreement sum
    /// is ordered after the window's layer sums only by that dependency.
    /// `propose`, for a sampled request, gives proposal j from step j's NextN
    /// logits `[1, 1, V]`, the same on every rank (the coupled draw at window
    /// column j's output index); nil takes the argmax. It must hold no
    /// collective: the proposals precede the window and its sums on every rank.
    func round(stage: GLM5NextTextStage, cache: GLM5NextTextStageCache, last: Int, window: Int,
               stop: Float, draw: ((MLXArray) -> MLXArray)? = nil,
               propose: GLM5NextMTP.ProposalSelection? = nil,
               whileRunning: () throws -> Void = {}) throws -> Round {
        guard let verified = pending, (0...depth).contains(window) else {
            throw ProbeError("GLM speculative round without its verified pairs or beyond its depth")
        }
        pending = nil
        let started = DispatchTime.now().uptimeNanoseconds
        let drafts = try prepareProposals(verified, window: window, propose: propose)
        let input = concatenated([MLXArray([Int32(last)], [1, 1])] + (drafts.map { [$0] } ?? []), axis: 1)
        let candidate = try stage.prepareVerification(tokens: input, cache: cache)
        guard case .final(let output) = candidate.output else {
            throw ProbeError("GLM speculative verification produced no logits")
        }
        // Slot: the target's token at each of the 1 + window positions, the
        // proposals, the stop flag. Token IDs are exact in float32.
        let width = 2 * window + 2
        let targets = draw?(output.logits).reshaped(-1) ?? argMax(output.logits[0].asType(.float32), axis: -1)
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
            var round = try Self.decide(agreed.asArray(Float.self), ranks: ranks, window: window, sampled: draw != nil)
            if !acceptsProposals { round = Round(tokens: [round.tokens[0]], stops: round.stops) }
            decided = round
            return round.tokens.count
        })
        guard let decided else { throw ProbeError("GLM speculative round decided nothing") }
        let kept = decided.tokens.count
        // The next round's verified pairs: each kept target token with the
        // hidden row that predicted it.
        pending = (MLXArray(decided.tokens.map(Int32.init), [1, kept]), output.hidden[0..., ..<kept, 0...])
        record(decided, window: window)
        return decided
    }

    /// Graph only: primes the verified pairs (never skipped: it keeps the
    /// NextN history in step with the target even when no proposal is used)
    /// and proposes a round's `window` tokens with `propose` (nil: the
    /// argmax), `[1, window]`; nil for a window of 0. Keeps the first step's
    /// NextN logits for the draft probe.
    private func prepareProposals(_ verified: (tokens: MLXArray, hidden: MLXArray), window: Int,
                                  propose: GLM5NextMTP.ProposalSelection?) throws -> MLXArray? {
        probeLogits = nil
        let select: GLM5NextMTP.ProposalSelection? = propose.map { propose in
            { [unowned self, probing = draftProbe != nil && window > 0] logits, step in
                if probing, step == 0 { probeLogits = logits }
                return propose(logits, step)
            }
        }
        let proposals = try mtp.primeAndPropose(shiftedTokens: verified.tokens, targetHidden: verified.hidden,
            at: state.committedInputCount, state: state, depth: max(1, window), select: select)
        return window > 0 ? proposals[0..., ..<window] : nil
    }

    /// Counts a decided round of `window` proposals and scores the draft
    /// probe's rules against its first token: enqueued now, run while the
    /// next round is built, read once (`draftProbeHits`).
    private func record(_ decided: Round, window: Int) {
        let kept = decided.tokens.count
        rounds += 1; proposedTokens += window; acceptedTokens += kept - 1
        for position in 0 ..< window { proposedByPosition[position] += 1 }
        for position in 0 ..< (kept - 1) { acceptedByPosition[position] += 1 }
        if let draftProbe, let probeLogits {
            let hits = (draftProbe.rules(probeLogits).reshaped(-1).asType(.int32)
                .== MLXArray(Int32(decided.tokens[0]))).asType(.int32)
            let total = probeHits.map { $0 + hits } ?? hits
            asyncEval(total)
            probeHits = total; probedRounds += 1
        }
        probeLogits = nil
    }
}

// MARK: - Several requests per round

extension GLM5NextTensorParallelSpeculation {
    /// One request of `rounds`: `round`'s arguments for that request.
    struct Lane {
        let speculation: GLM5NextTensorParallelSpeculation
        let cache: GLM5NextTextStageCache
        let last: Int
        let window: Int
        let stop: Float
        var draw: ((MLXArray) -> MLXArray)?
        /// `round`'s `propose`.
        var propose: GLM5NextMTP.ProposalSelection?
    }

    /// Each lane's part of a multi-lane agreement, lane after lane: the
    /// `ranks` slots of `2 * window + 2` values its own round carries.
    static func segments(windows: [Int], ranks: Int) -> [Range<Int>] {
        var start = 0
        return windows.map { window in
            let width = ranks * (2 * window + 2)
            defer { start += width }
            return start ..< start + width
        }
    }

    /// `round` for several requests at once. Every lane primes and proposes
    /// from its own NextN state (a sampled lane with its own sampler's
    /// coupled proposals, `propose`, which hold no collective); ONE stage
    /// forward then verifies every lane's window over its own cache
    /// (`GLM5NextTextStage.prepareVerificationRows`: each lane's logits,
    /// hidden rows and cache are bitwise those of its own
    /// `prepareVerification`); ONE agreement sum
    /// carries every lane's slots, each laid out as its own round's; and each
    /// lane commits its own kept prefix. A lane's tokens, cache and NextN
    /// history are therefore exactly those of its own `round`. Both ranks
    /// must pass the same lanes in the same order with the same `last` and
    /// `window`, derived from agreed tokens only. Evaluates the round (one
    /// host read); `whileRunning` as in `round`.
    /// Host seconds of one `rounds` call, for measurement (`timing`).
    struct RoundsTiming {
        /// Every lane's NextN priming and proposals built (and, with
        /// `evaluatesProposals`, evaluated: `proposalWait`).
        var proposals = 0.0
        var proposalWait = 0.0
        /// The rows forward built (`prepareVerificationRows`).
        var forward = 0.0
        /// Slots and the agreement sum built.
        var agreement = 0.0
        /// `asyncEval` returning (encoding), then waiting for the GPU.
        var encode = 0.0
        var wait = 0.0
        var total: Double { proposals + proposalWait + forward + agreement + encode + wait }
    }

    static func rounds(stage: GLM5NextTextStage, lanes: [Lane], whileRunning: () throws -> Void = {},
                       evaluatesProposals: Bool = false, timing: ((RoundsTiming) -> Void)? = nil)
        throws -> [Round]
    {
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        func seconds(_ from: UInt64, _ to: UInt64) -> Double { Double(to - from) / 1e9 }
        var times = RoundsTiming()
        guard let first = lanes.first?.speculation,
              Set(lanes.map { ObjectIdentifier($0.speculation) }).count == lanes.count,
              lanes.allSatisfy({ $0.speculation.rank == first.rank && $0.speculation.ranks == first.ranks
                  && $0.speculation.pending != nil && (0...$0.speculation.depth).contains($0.window) }) else {
            throw ProbeError("GLM speculative rounds need distinct lanes with verified pairs, within their depth")
        }
        let (rank, ranks) = (first.rank, first.ranks)
        let started = DispatchTime.now().uptimeNanoseconds
        var inputs: [GLM5NextTextStageLane] = []
        var drafts: [MLXArray?] = []
        for lane in lanes {
            let speculation = lane.speculation
            let verified = speculation.pending!
            speculation.pending = nil
            // Each lane's own priming and proposals (as in `round`): its own
            // NextN state and, for a sampled lane, its own sampler's round.
            let draft = try speculation.prepareProposals(verified, window: lane.window, propose: lane.propose)
            drafts.append(draft)
            inputs.append(.init(tokens: concatenated([MLXArray([Int32(lane.last)], [1, 1])] + (draft.map { [$0] } ?? []),
                axis: 1), cache: lane.cache))
        }
        let proposed = now()
        times.proposals = seconds(started, proposed)
        var forwardStart = proposed
        if evaluatesProposals {
            // Measurement only: the proposals' graphs alone, before the forward.
            eval(drafts.compactMap { $0 } + (try lanes.flatMap { try $0.speculation.evaluationTargets() }))
            forwardStart = now()
            times.proposalWait = seconds(proposed, forwardStart)
        }
        let candidate = try stage.prepareVerificationRows(inputs)
        let forwardBuilt = now()
        times.forward = seconds(forwardStart, forwardBuilt)
        let outputs = try candidate.outputs.map { output -> GLM5NextTextOutput in
            guard case .final(let value) = output else { throw ProbeError("GLM speculative verification produced no logits") }
            return value
        }
        // Each lane's slots exactly as its own round lays them out.
        var slots: [MLXArray] = []
        for (lane, (output, draft)) in zip(lanes, zip(outputs, drafts)) {
            let width = 2 * lane.window + 2
            let targets = lane.draw?(output.logits).reshaped(-1) ?? argMax(output.logits[0].asType(.float32), axis: -1)
            var slot = [targets.asType(.float32)]
            if let draft { slot.append(draft.reshaped(-1).asType(.float32)) }
            slot.append(MLXArray([lane.stop]))
            let local = concatenated(slot, axis: 0)
            let empty = MLXArray.zeros([width], dtype: .float32)
            slots += (0..<ranks).map { $0 == rank ? local : empty }
        }
        // The agreement sum must follow the forward's layer sums on every
        // rank (the ranks pair their sums in order): the explicit dependency
        // holds whatever each lane's `draw` computes from its logits.
        let agreed = first.agree(depends(input: concatenated(slots, axis: 0),
            dependencies: outputs.map(\.logits)))
        let segments = Self.segments(windows: lanes.map(\.window), ranks: ranks)
        var decided: [Round] = []
        try candidate.commit(afterEvaluating: { roots in
            try MLX.withError { error in
                let all = roots + [agreed] + (try lanes.flatMap { try $0.speculation.evaluationTargets() })
                let built = DispatchTime.now().uptimeNanoseconds
                times.agreement = seconds(forwardBuilt, built)
                asyncEval(all)
                let encoded = DispatchTime.now().uptimeNanoseconds
                try whileRunning()
                eval(all)
                let done = DispatchTime.now().uptimeNanoseconds
                times.encode = seconds(built, encoded)
                times.wait = seconds(encoded, done)
                for lane in lanes where lane.speculation.recordsPhases {
                    lane.speculation.phases.append((Double(built - started) / 1e9, Double(encoded - built) / 1e9,
                        Double(done - encoded) / 1e9))
                }
                try error.check()
            }
        }, keeping: { _ in
            let values = agreed.asArray(Float.self)
            decided = try zip(lanes, segments).map { lane, segment in
                var round = try Self.decide(Array(values[segment]), ranks: ranks, window: lane.window,
                    sampled: lane.draw != nil)
                if !lane.speculation.acceptsProposals { round = Round(tokens: [round.tokens[0]], stops: round.stops) }
                return round
            }
            return decided.map(\.tokens.count)
        })
        guard decided.count == lanes.count else { throw ProbeError("GLM speculative rounds decided nothing") }
        for ((lane, round), output) in zip(zip(lanes, decided), outputs) {
            let speculation = lane.speculation
            let kept = round.tokens.count
            // The next round's verified pairs, as `round` keeps them.
            speculation.pending = (MLXArray(round.tokens.map(Int32.init), [1, kept]), output.hidden[0..., ..<kept, 0...])
            speculation.record(round, window: lane.window)
        }
        timing?(times)
        return decided
    }
}
