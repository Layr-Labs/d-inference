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
/// whose transforms depend on its history (logit bias, penalties) decodes one
/// token per step.
///
/// One instance per request, used only by the native executor that selects.
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

    /// The tokens one speculative round committed. The next `sample`
    /// reconfigures from the confirmed history, as the product's does.
    func commitRound(_ tokens: [Int]) {
        selected += tokens
        sampler.mtpRoundDidCommit(requestIDs: [stream])
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
