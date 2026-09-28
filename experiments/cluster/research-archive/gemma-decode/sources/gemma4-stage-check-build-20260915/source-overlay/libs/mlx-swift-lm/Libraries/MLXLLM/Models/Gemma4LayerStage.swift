import MLX
import MLXLMCommon
import MLXNN

/// Selected-layer module for a separately verified Gemma text Plan. Construct
/// under the caller's native error/resource/deadline guard: SwitchGLU performs
/// an activation probe. This initializer is not metadata-only work.
public final class Gemma4LayerStage: Module {
    public let layout: Gemma4LayerStageLayout
    public let configuration: Gemma4TextConfiguration
    public let weightedExpertUnsortEffective: Bool

    @ModuleInfo(key: "language_model") var languageModel: Gemma4StageLanguageModel

    public init(
        originalConfiguration: Gemma4Configuration,
        rank: Int, sourceLayerRange: Range<Int>
    ) throws {
        let layout = try Gemma4LayerStageLayout(
            originalConfiguration: originalConfiguration,
            rank: rank, sourceLayerRange: sourceLayerRange)
        let config = originalConfiguration.textConfig
        let fuseWeightedUnsort = gemma4ShouldFuseWeightedUnsort(config)
        self.layout = layout
        self.configuration = config
        self.weightedExpertUnsortEffective = fuseWeightedUnsort
        self._languageModel.wrappedValue = Gemma4StageLanguageModel(
            configuration: config, layout: layout,
            fuseWeightedUnsort: fuseWeightedUnsort)
        super.init()
    }

    /// The actual loaded embedding's output type, never its packed U32 weight
    /// type. This does not attest native K/V types after normalization/RoPE.
    public var loadedEmbeddingOutputDType: DType? {
        let embedding = languageModel.model.embedTokens
        guard let quantized = embedding as? QuantizedEmbedding,
            quantized.mode == .affine, quantized.bits == 4, quantized.groupSize == 64,
            let biases = quantized.biases, quantized.scales.dtype == biases.dtype,
            quantized.weight.dtype == .uint32,
            [.float16, .bfloat16, .float32].contains(quantized.scales.dtype)
        else { return nil }
        return quantized.scales.dtype
    }
}

/// Wrapper keys match the selected descriptor destinations exactly. Both ranks
/// own one embedding; only rank1 owns the final norm. No separate head exists.
final class Gemma4StageLanguageModel: Module {
    @ModuleInfo(key: "model") var model: Gemma4StageTrunk

    init(configuration: Gemma4TextConfiguration, layout: Gemma4LayerStageLayout,
         fuseWeightedUnsort: Bool) {
        self._model.wrappedValue = Gemma4StageTrunk(
            configuration: configuration, layout: layout,
            fuseWeightedUnsort: fuseWeightedUnsort)
        super.init()
    }
}

final class Gemma4StageTrunk: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: [Gemma4DecoderLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm?

    init(configuration: Gemma4TextConfiguration, layout: Gemma4LayerStageLayout,
         fuseWeightedUnsort: Bool) {
        self._embedTokens.wrappedValue = Embedding(
            embeddingCount: configuration.vocabSize, dimensions: configuration.hiddenSize)
        self._layers.wrappedValue = layout.sourceLayerRange.map { global in
            Gemma4DecoderLayer(configuration, layerIdx: global,
                fuseWeightedUnsort: fuseWeightedUnsort)
        }
        if layout.ownsFinalOutput {
            self._norm.wrappedValue = RMSNorm(
                dimensions: configuration.hiddenSize, eps: configuration.rmsNormEps)
        }
        super.init()
    }
}
