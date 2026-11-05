import Foundation
import MLX
@_spi(GemmaEncoder) import MLXLLM
import MLXLMCommon
import MLXNN

/// A speculative verify window of one Gemma 4 request: the last committed
/// token and the drafts, `[1, T]`, through the whole model (or one rank's
/// shard) in one forward, with every row equal byte for byte to the plain
/// decode step that would compute the same position:
///
/// - every affine projection keeps its singleton (M=1) reduction per row
///   (`Gemma4PrefillProjectionScope`, the registered prompt policy; under
///   `MLX_QMV_BATCH_INVARIANT=1` two to seven rows would take `qmv_wide`);
/// - each token's experts run alone (`isExpertPrefill`: the per-token route
///   the batch decode lanes take), and a rank packs every row's expert
///   partials into the layer's one collective, whose sum is element-wise;
/// - each provisional query attends the exact prefix it may see through the
///   canonical one-query dispatch (`CBv2OwnedRequestState.beginWindow` scopes
///   the paged host's serial rectangular verification);
/// - no prompt-tail narrowing: every row is projected through the head, one
///   row at a time, then the softcap.
///
/// The same per-layer composition as the product's trunk for this geometry
/// (no per-layer inputs, no shared keys and values, cache-owned masks), as
/// `Gemma4LayerStageModel` restates it; the tests compare each window row
/// with the product's own decode step.
enum Gemma4VerifyWindow {
    struct Output {
        /// `[T, head rows]` FP32 (softcapped), one row a window position.
        let logits: MLXArray
        /// `[1, T, H]`: the residual after the last layer, before the final
        /// norm (what the assistant reads as the target's hidden).
        let hidden: MLXArray
        /// This forward's new key and value rows of the last sliding and the
        /// last full-attention layer, `[1, local KV heads, T, D]`.
        let sliding: (keys: MLXArray, values: MLXArray)
        let full: (keys: MLXArray, values: MLXArray)
    }

    /// The layers the assistant shares keys and values with: the model's last
    /// sliding-window and last full-attention layer.
    static func sourceLayers(_ configuration: Gemma4TextConfiguration) throws -> (sliding: Int, full: Int) {
        guard let sliding = configuration.layerTypes.lastIndex(of: Gemma4StageGeometry.slidingKind),
              let full = configuration.layerTypes.lastIndex(of: Gemma4StageGeometry.fullKind),
              configuration.numKvSharedLayers == 0 else {
            throw ProbeError("Gemma verify window needs a sliding and a full-attention layer of its own")
        }
        return (sliding, full)
    }

    /// The window's graph over `caches` (one CBv2 cache a layer, already
    /// inside the request's speculative window), not evaluated.
    static func forward(text: Gemma4TextModel, tokens: MLXArray, caches: [KVCache]) throws -> Output {
        let configuration = text.configuration
        let (slidingLayer, fullLayer) = try sourceLayers(configuration)
        let inner = text.model
        guard tokens.ndim == 2, tokens.dim(0) == 1, tokens.dim(1) >= 1, caches.count == inner.layers.count,
              configuration.hiddenSizePerLayerInput == 0 else {
            throw ProbeError("Gemma verify window takes [1, T] tokens and one cache a layer")
        }
        // A one-row window is a decode step and takes the step's own routes.
        let perToken = tokens.dim(1) > 1
        return Gemma4PrefillProjectionScope.withPrefillFrame(tokens: tokens, enabled: true) {
            var hidden = inner.embedTokens(tokens) * inner.embedScale
            var sliding: (MLXArray, MLXArray)?, full: (MLXArray, MLXArray)?
            for (index, layer) in inner.layers.enumerated() {
                let (out, kv, _) = layer(hidden, mask: nil, cache: caches[index], perLayerInput: nil, sharedKV: nil,
                    positionOffset: nil, v2SharedSource: nil, outputTailRows: nil, useLastQueryPrefill: false,
                    isExpertPrefill: perToken)
                hidden = out
                if index == slidingLayer { sliding = kv }
                if index == fullLayer { full = kv }
            }
            let normed = inner.norm(hidden)
            var logits = head(text, normed)
            if configuration.finalLogitSoftcapping > 0 {
                logits = Gemma4StagePromptPolicy.logitSoftcap(logits, MLXArray(configuration.finalLogitSoftcapping))
            }
            return Output(logits: logits, hidden: hidden, sliding: (sliding!.0, sliding!.1), full: (full!.0, full!.1))
        }
    }

    /// The tied head over this model's vocabulary rows, each window row a
    /// singleton product: the rows as the batch of a broadcast weight, so
    /// MLX keeps M=1 per row (the kernel a one-token step's head takes).
    static func head(_ text: Gemma4TextModel, _ normed: MLXArray) -> MLXArray {
        let rows = text.headVocabularyRange
        let count = normed.dim(1), width = normed.dim(2)
        let vectors = normed.reshaped([count, 1, width])
        let embedding = text.model.embedTokens
        guard type(of: embedding) == QuantizedEmbedding.self, let packed = embedding as? QuantizedEmbedding,
              packed.mode == .affine else {
            let weight = embedding.weight[rows]
            return concatenated((0 ..< count).map { matmul(vectors[$0], weight.T) }, axis: 0)
        }
        let whole = rows == 0 ..< packed.weight.dim(0)
        let weight = whole ? packed.weight : packed.weight[rows]
        let scales = whole ? packed.scales : packed.scales[rows]
        let biases = packed.biases.map { whole ? $0 : $0[rows] }
        return quantizedMM(vectors, weight.expandedDimensions(axis: 0),
            scales: scales.expandedDimensions(axis: 0), biases: biases?.expandedDimensions(axis: 0),
            transpose: true, groupSize: packed.groupSize, bits: packed.bits)
            .reshaped([count, rows.count])
    }
}

extension Gemma4TensorParallelPagedSession {
    /// Builds a verify window of `tokens` (`[1, T]` int32: the last committed
    /// token, then the drafts) at the committed frontier, inside the request's
    /// speculative window: nothing commits until `settleWindow`. Returns the
    /// window's outputs and the roots to evaluate with them.
    func beginWindow(_ tokens: MLXArray) throws -> (output: Gemma4VerifyWindow.Output, roots: [MLXArray]) {
        let count = tokens.ndim == 2 ? tokens.dim(1) : 0
        guard !retired, state.committedTokens >= promptCount, tokens.ndim == 2, tokens.dim(0) == 1,
              tokens.dtype == .int32, (1 ... 8).contains(count),
              pagesCover(writing: count) || reservePages(writing: count) else {
            throw ProbeError("Gemma tensor-parallel verify window differs from its request or pages")
        }
        var output: Gemma4VerifyWindow.Output?
        let text = model.textModel
        let built = try state.beginWindow(tokenCount: count) { caches, _ in
            let result = try Gemma4VerifyWindow.forward(text: text, tokens: tokens,
                caches: caches.map { $0 as! any KVCache })
            output = result
            return [result.logits, result.hidden, result.sliding.keys, result.sliding.values,
                    result.full.keys, result.full.values]
        }
        guard let output, output.logits.shape == [count, model.vocabularyRange.count],
              output.logits.dtype == .float32, output.hidden.shape == [1, count, model.plan.hiddenSize] else {
            throw ProbeError("Gemma tensor-parallel verify window output contract differs")
        }
        return (output, built.outputs + built.roots)
    }

    /// After the window's roots were evaluated.
    func confirmWindow(check: () throws -> Void) throws { try state.confirmWindow(check: check) }

    /// Keeps the window's first `kept` positions and rolls back the rest;
    /// returns the roots to evaluate before `confirmSettled`.
    func settleWindow(keeping kept: Int) throws -> [MLXArray] { try state.settleWindow(keeping: kept) }

    func confirmSettled(check: () throws -> Void) throws { try state.confirmSettled(check: check) }
}
