import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon

/// The single-Mac product's own sampler for one request, on the rank that
/// selects its tokens (the tail rank of a pipeline, the decoding rank of a
/// phase split, with or without the speculative head).
///
/// It is the product's code, not a copy: `CBv2DefaultSampler` (the logits
/// pipeline: logit bias, repetition / frequency / presence penalties,
/// temperature, top-k / top-p / min-p; then the keyed Gumbel-max draw, or one
/// argmax when the row is greedy). Its random stream is keyed on
/// `(seed, stream, output index)`, as the product keys a row on
/// `(seed, requestID, step)`; the provider passes the product's request
/// identity as `stream` and resolves an omitted seed exactly as the product's
/// engine does. So, given the same logits, a token here is bit for bit the
/// token the product would draw for the same request at the same index.
///
/// Speculative rounds use the product's target-prefix pre-sampling
/// (`mtpVerifySample`): each verify column is a genuine keyed target sample at
/// its own output index, a draft is kept while it equals that sample, and the
/// sample at the first mismatch (or the bonus column) is committed. Like the
/// product, only the stateless transforms are verified that way; a request
/// whose transforms depend on its history (logit bias, penalties) replays the
/// step path itself over a round's proposals instead (`propose`, `verifyRound`).
/// Proposals can be drawn the same way from a draft head's logits (`draft`),
/// which changes how many are kept and never a token.
///
/// One instance per request, used only by the native executor that selects
/// (and, in tensor parallel, by every rank to propose).
final class QwenStageTokenSampler {
    let wire: ClusterWorkerSampling
    private let parameters: CBv2SamplingParams
    private let stream: CBv2RequestID
    private let promptTokens: [Int]
    private let sampler: CBv2DefaultSampler
    /// The tokens this rank selected for the request, in order: the penalty
    /// history and the next output index.
    private(set) var selected: [Int] = []

    init(_ state: QwenStageSamplingState) {
        let wire = state.wire
        self.wire = wire; promptTokens = state.promptTokens
        parameters = CBv2SamplingParams(temperature: wire.temperature, topP: wire.topP, topK: wire.topK,
            minP: wire.minP, repetitionPenalty: wire.repetitionPenalty,
            repetitionContextSize: wire.repetitionContextSize, frequencyPenalty: wire.frequencyPenalty,
            presencePenalty: wire.presencePenalty, seed: wire.seed,
            logitBias: Dictionary(uniqueKeysWithValues: wire.logitBias.map { ($0.tokenID, $0.bias) }),
            topLogprobs: 0)
        stream = CBv2RequestID(wire.stream)
        // The seed is always resolved by the provider; the fallback is never used.
        sampler = CBv2DefaultSampler(fallbackSeed: wire.seed)
    }

    /// Speculative decoding may verify this request's drafts.
    var admitsSpeculativeVerification: Bool { wire.admitsSpeculativeVerification }

    /// The next output index this rank will select.
    var nextOutputIndex: Int { selected.count }

    /// Graph only: one token `[1]` (int32) from a selected row `[1, V]`, drawn
    /// at output index `nextOutputIndex`. Follow with `commit`.
    func sample(_ logits: MLXArray) -> MLXArray {
        sampler.sample(logits: logits, params: [parameters], requestIDs: [stream], stepIndex: selected.count,
            pendingSampledTokens: nil,
            rowContext: { [parameters, stream, promptTokens, selected] in
                [CBv2SamplerRow(id: stream, params: parameters, promptTokens: promptTokens, outputTokens: selected)]
            })
    }

    /// The token `sample` produced, read back.
    func commit(_ token: Int) { selected.append(token) }

    /// Graph only: the keyed target sample at every column of a verify window
    /// `[1, W, V]`, column j at output index `nextOutputIndex + j`. Nil when the
    /// request's transforms depend on its history.
    func verify(_ logits: MLXArray) -> MLXArray? {
        guard admitsSpeculativeVerification else { return nil }
        return sampler.mtpVerifySample(logits: logits, params: [parameters], requestIDs: [stream],
            stepBases: [selected.count])
    }

    /// Graph only: coupled proposals from a draft head's logits `[R, 1, V]`
    /// for output index `nextOutputIndex + offset`
    /// (`CBv2DefaultSampler.mtpCoupledProposal`): each row runs the keyed
    /// exponential race `verify` runs at that index (the same temperature,
    /// the same noise) over that row of draft logits, sort-free (a winner the
    /// filters would drop gives way to the row's mode). Returns `[R, 1]`. The
    /// target keeps a proposal exactly when its own draw at the index is the
    /// same token, which a draft distribution close to the target's makes
    /// likely (the shared noise couples the two draws); no committed token
    /// depends on it. Nil when the request's transforms depend on its history.
    func draft(_ logits: MLXArray, offset: Int) -> MLXArray? {
        guard admitsSpeculativeVerification, logits.ndim == 3, logits.dim(1) == 1 else { return nil }
        let rows = logits.dim(0)
        return sampler.mtpCoupledProposal(logits: logits, params: Array(repeating: parameters, count: rows),
            requestIDs: Array(repeating: stream, count: rows),
            stepBases: Array(repeating: selected.count + offset, count: rows))
    }

    /// The tokens one speculative round committed. The next `sample`
    /// reconfigures from the confirmed history, as the product's does, and
    /// the next `propose` begins the next round.
    func commitRound(_ tokens: [Int]) {
        selected += tokens
        round = nil
        sampler.mtpRoundDidCommit(requestIDs: [stream])
    }

    /// Graph only: proposal `step` of the current speculative round `[1]`
    /// int32 from draft logits `[1, 1, V]`; step 0 begins a round at output
    /// index `nextOutputIndex` (steps come in order). `sharpness` scales a
    /// stateless request's draft logits first (1: the target's own race;
    /// infinity: the draft's argmax, the proposal before coupling); a request
    /// with bias or penalties draws as its target does unless it is infinite.
    func propose(_ logits: MLXArray, step: Int, sharpness: Float = 1) -> MLXArray {
        if step == 0 { round = SpeculativeRound(self) }
        guard let round else { preconditionFailure("A speculative round's proposals begin at step 0") }
        return round.propose(logits, step: step, sharpness: sharpness)
    }

    /// Graph only: the target's draw at every column of the current round's
    /// verify window `[1, W, V]`, column j at index `nextOutputIndex + j`, as
    /// `[1, W]` (once per round, after its first `W - 1` proposals).
    func verifyRound(_ window: MLXArray) -> MLXArray {
        let current = round ?? SpeculativeRound(self)
        round = current
        return current.verify(window)
    }

    /// The round between its first proposal and `commitRound`.
    private var round: SpeculativeRound?

    /// A round's proposals and the target's draws at every window column,
    /// each keyed at the output index it is for.
    ///
    /// Stateless transforms use `draft` and `verify` (the product's
    /// target-prefix sampling). A request whose transforms depend on its
    /// history (logit bias, penalties) replays the step path's own pipeline
    /// and draw (`LogitsPipelineV2`, `SamplerV2`) configured from this rank's
    /// history: proposal j and window column j are processed with the
    /// history plus proposals `0 ..< j` and drawn at index
    /// `nextOutputIndex + j`. A column's draw is committed only when those
    /// proposals were kept, that is when they are the committed tokens; it is
    /// then the step the plain path makes at that index (the pipeline's state
    /// is a function of the history, whether rebuilt or advanced token by
    /// token, as the product's reconfiguration relies on).
    private final class SpeculativeRound {
        private unowned let owner: QwenStageTokenSampler
        private let base: Int
        private var proposals: [MLXArray] = []
        private var proposing: Replay?
        private var verified = false

        init(_ owner: QwenStageTokenSampler) {
            self.owner = owner; base = owner.selected.count
        }

        func propose(_ logits: MLXArray, step: Int, sharpness: Float) -> MLXArray {
            precondition(step == proposals.count && owner.selected.count == base && logits.ndim == 3)
            let greedy = argMax(logits[0..., -1, 0...], axis: -1)
            let token: MLXArray
            if sharpness == .infinity {
                token = greedy.reshaped(1).asType(.int32)
            } else if owner.admitsSpeculativeVerification {
                let scaled = sharpness == 1 ? logits : logits.asType(.float32) * sharpness
                token = (owner.draft(scaled, offset: step) ?? greedy).reshaped(1).asType(.int32)
            } else {
                let replay = proposing ?? owner.replay(vocabulary: logits.dim(-1))
                proposing = replay
                token = replay.draw(logits[0..., -1, 0...])
                replay.advance(token)
            }
            proposals.append(token)
            return token
        }

        func verify(_ window: MLXArray) -> MLXArray {
            precondition(!verified && owner.selected.count == base && window.ndim == 3
                && (owner.admitsSpeculativeVerification || window.dim(1) <= proposals.count + 1))
            verified = true
            if owner.admitsSpeculativeVerification { return owner.verify(window) ?? argMax(window, axis: -1) }
            let replay = owner.replay(vocabulary: window.dim(-1))
            var draws: [MLXArray] = []
            for column in 0 ..< window.dim(1) {
                draws.append(replay.draw(window[0..., column, 0...]))
                if column + 1 < window.dim(1) { replay.advance(proposals[column]) }
            }
            return concatenated(draws, axis: 0).reshaped(1, -1)
        }
    }

    /// The step path's transform pipeline and keyed draw for this request,
    /// configured at `nextOutputIndex` from this rank's history.
    private final class Replay {
        private let pipeline: LogitsPipelineV2
        private let draws: SamplerV2

        init(vocabulary: Int, row: CBv2SamplerRow, fallbackSeed: UInt64) {
            pipeline = LogitsPipelineV2(vocabSize: vocabulary)
            draws = SamplerV2(fallbackSeed: fallbackSeed)
            pipeline.setRows([row]); draws.setRows([row])
        }

        /// The draw `[1]` int32 at the current index from one row `[1, V]`.
        func draw(_ logits: MLXArray) -> MLXArray {
            draws.sample(from: pipeline.process(logits).sampling).asType(.int32)
        }

        /// Takes `token` `[1]` as the current index's token and moves to the next.
        func advance(_ token: MLXArray) {
            pipeline.commit(sampledTokens: token); draws.commit()
        }
    }

    private func replay(vocabulary: Int) -> Replay {
        Replay(vocabulary: vocabulary,
            row: CBv2SamplerRow(id: stream, params: parameters, promptTokens: promptTokens, outputTokens: selected),
            fallbackSeed: wire.seed)
    }
}

extension QwenLayerStageGenerationRequest {
    /// The selecting rank's sampler for a sampled request; nil for greedy
    /// text. Created on first use and shared by every copy of the request.
    var sampler: QwenStageTokenSampler? {
        guard let sampling else { return nil }
        if let existing = sampling.tokenSampler as? QwenStageTokenSampler { return existing }
        let created = QwenStageTokenSampler(sampling)
        sampling.tokenSampler = created
        return created
    }
}
