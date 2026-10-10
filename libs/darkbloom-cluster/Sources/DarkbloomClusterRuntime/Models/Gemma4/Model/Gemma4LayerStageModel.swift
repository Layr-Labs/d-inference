import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// `model.{embed_tokens, layers, norm}` with local layer indices: the artifact's
/// own tensor names for the layers a stage holds.
final class Gemma4StageTrunk: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: [Gemma4DecoderLayer]
    /// Present only on the rank that produces logits.
    @ModuleInfo(key: "norm") var norm: RMSNorm?

    init(configuration: Gemma4TextConfiguration, sourceLayerRange: Range<Int>, ownsFinalOutput: Bool,
         fuseWeightedUnsort: Bool) {
        _embedTokens.wrappedValue = Embedding(embeddingCount: configuration.vocabSize,
                                               dimensions: configuration.hiddenSize)
        // The product's own decoder layer, at its index in the whole model.
        _layers.wrappedValue = sourceLayerRange.map {
            Gemma4DecoderLayer(configuration, layerIdx: $0, fuseWeightedUnsort: fuseWeightedUnsort)
        }
        if ownsFinalOutput {
            _norm.wrappedValue = RMSNorm(dimensions: configuration.hiddenSize, eps: configuration.rmsNormEps)
        }
        super.init()
    }
}

final class Gemma4StageLanguageModel: Module {
    @ModuleInfo(key: "model") var model: Gemma4StageTrunk

    init(_ trunk: Gemma4StageTrunk) {
        _model.wrappedValue = trunk
        super.init()
    }
}

/// One rank's contiguous layers of a registered Gemma 4 26B, composed from the
/// product's decoder layers with the original configuration. Rank 0 owns the
/// token lookup; rank 1 owns the final norm and the tied output head. Both hold
/// the embedding, which serves a different purpose on each.
///
/// It is not a complete language model: only a stage session may drive it, and
/// only through `layerStageForward`.
final class Gemma4LayerStageModel: Module, LanguageModel {
    @ModuleInfo(key: "language_model") var languageModel: Gemma4StageLanguageModel
    let configuration: Gemma4TextConfiguration
    let rank: Int
    let sourceLayerRange: Range<Int>
    /// Resolved by the product's own model for this configuration and process.
    let fuseWeightedUnsort: Bool
    private let embedScale: Float

    var ownsFinalOutput: Bool { rank == 1 }
    var trunk: Gemma4StageTrunk { languageModel.model }

    init(configuration: Gemma4TextConfiguration, rank: Int, sourceLayerRange: Range<Int>,
         fuseWeightedUnsort: Bool) throws {
        let count = Gemma4StageGeometry.layerCount
        guard configuration.numHiddenLayers == count, configuration.layerTypes.count == count,
              configuration.numKvSharedLayers == 0, configuration.hiddenSizePerLayerInput == 0,
              configuration.tieWordEmbeddings, configuration.enableMoeBlock,
              configuration.hiddenSize == Gemma4StageGeometry.hiddenSize,
              configuration.vocabSize == Gemma4StageGeometry.vocabularySize,
              (0...1).contains(rank), !sourceLayerRange.isEmpty,
              rank == 0 ? sourceLayerRange.lowerBound == 0 && sourceLayerRange.upperBound < count
                        : sourceLayerRange.lowerBound > 0 && sourceLayerRange.upperBound == count else {
            throw ProbeError("Gemma stage requires the registered text geometry and a valid rank range")
        }
        self.configuration = configuration; self.rank = rank; self.sourceLayerRange = sourceLayerRange
        self.fuseWeightedUnsort = fuseWeightedUnsort
        embedScale = Float(configuration.hiddenSize).squareRoot()
        _languageModel.wrappedValue = Gemma4StageLanguageModel(Gemma4StageTrunk(
            configuration: configuration, sourceLayerRange: sourceLayerRange,
            ownsFinalOutput: rank == 1, fuseWeightedUnsort: fuseWeightedUnsort))
        super.init()
    }

    // A stage is driven by frames; the whole-model entry points do not exist.
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        throw ProbeError("A Gemma layer stage is not a complete language model")
    }

    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }

    /// The activation dtype of the loaded embedding: what the residual and every
    /// layer's keys and values are computed in.
    var activationDType: DType? { (trunk.embedTokens as? QuantizedEmbedding)?.scales.dtype }
}

extension Gemma4LayerStageModel: CBv2CompleteCheckpointKVTypeProviding {
    var cbv2CompleteCheckpointKVDTypes: [DType]? {
        activationDType.map { Array(repeating: $0, count: sourceLayerRange.count) }
    }
}

extension Gemma4LayerStageModel: LayerStageFrameForwarding {
    func layerStageRequestGeometry(maximumTokens: Int) throws -> CBv2RequestGeometry {
        guard let dtype = activationDType else { throw ProbeError("Gemma stage embedding is not loaded") }
        // The product's own derivation, then this stage's slice of it with the
        // stage's storage index as the layer index its state is keyed by.
        let all = configuration.cbv2LayerKinds
        guard all.count == Gemma4StageGeometry.layerCount else { throw ProbeError("Gemma layer kinds differ") }
        let kinds = sourceLayerRange.enumerated().map { local, global -> CBv2LayerKind in
            var kind = all[global]; kind.modelLayerIndex = local
            return kind
        }
        return try CBv2RequestGeometry(gemma4StageKinds: kinds, kvDType: dtype, maximumTokens: maximumTokens)
    }

    func layerStageForward(tokens: MLXArray, residual: MLXArray?,
                           caches: [any CBv2AttendingLayerCache], frame: QwenLayerStageFrame) -> MLXArray {
        precondition(caches.count == trunk.layers.count, "Gemma stage needs one cache per local layer")
        precondition((residual == nil) == (rank == 0), "Gemma stage ingress differs from its rank")
        let prefill = frame.phase == .prefill
        var hidden = residual ?? trunk.embedTokens(tokens) * embedScale
        for (local, layer) in trunk.layers.enumerated() {
            let cache = caches[local]
            let decision = Gemma4StagePromptPolicy.decide(
                globalLayerIndex: sourceLayerRange.lowerBound + local, prefill: prefill,
                ownsFinalOutput: ownsFinalOutput, batchSize: hidden.dim(0), sequenceLength: hidden.dim(1),
                cacheSupportsLastQuery: cache is any CBv2LastQueryPrefillLayerCache)
            // No per-layer input and no shared keys/values in this geometry; the
            // layer cache owns attention and masking, as in the product's trunk.
            hidden = layer(hidden, mask: nil, cache: cache as? KVCache, perLayerInput: nil, sharedKV: nil,
                positionOffset: nil, v2SharedSource: nil, outputTailRows: decision.outputTailRows,
                useLastQueryPrefill: decision.useLastQuery, isExpertPrefill: prefill).0
        }
        guard ownsFinalOutput, let norm = trunk.norm else { return hidden }
        let normed = norm(hidden)
        if prefill {
            // The product's prompt forward: nothing is projected for a chunk
            // whose logits nobody reads, and one row for the chunk that ends the prompt.
            return frame.finalPromptChunk ? logits(normed[0..., -1, 0...]) : normed[0..., -1, 0 ..< 1]
        }
        return logits(normed)[0..., -1, 0...]
    }

    /// The tied embedding as the output projection, then the final-logit softcap.
    private func logits(_ hidden: MLXArray) -> MLXArray {
        let projected = trunk.embedTokens.asLinear(hidden)
        guard configuration.finalLogitSoftcapping > 0 else { return projected }
        return Gemma4StagePromptPolicy.logitSoftcap(projected, MLXArray(configuration.finalLogitSoftcapping))
    }
}
