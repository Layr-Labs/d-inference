import MLX
import MLXLMCommon
import MLXNN

@_spi(ExpertParallel)
public enum Gemma4ExpertParallelError: Error {
    case invalidPartition, invalidInput, invalidCache, invalidExpertOutput, invalidNativeKV
}

/// Returns unweighted [tokens, global top-k slots, hidden] in the router's
/// original slot order. The SDK retains the actual weights and applies the
/// unchanged weightedExpertSum itself. No callback or request state is stored.
@_spi(ExpertParallel)
public typealias Gemma4ExpertUnweightedOperation =
    (Int, MLXArray, MLXArray, MLXArray, SwitchGLU) throws -> MLXArray

/// Both ranks retain the same full decoder topology. Only the sparse banks'
/// expert axis differs. Construction is native work requiring the existing
/// caller's load gate; this class creates no owner, stream, group, or permit.
@_spi(ExpertParallel)
public final class Gemma4ExpertParallelModel: Module {
    public let configuration: Gemma4TextConfiguration
    public let globalExpertIDs: [Int]
    public let layerKinds: [CBv2LayerKind]
    @ModuleInfo(key: "language_model") private var languageModel: Gemma4ExpertLanguageModel

    public init(originalConfiguration: Gemma4Configuration, globalExpertIDs: [Int]) throws {
        // Reuse the exact registered decoder/configuration validator. Its
        // temporary metadata layout allocates no model or native arrays.
        _ = try Gemma4LayerStageLayout(originalConfiguration: originalConfiguration,
            rank: 0, sourceLayerRange: 0..<1)
        let config = originalConfiguration.textConfig
        guard !globalExpertIDs.isEmpty, globalExpertIDs.count < 128,
              globalExpertIDs == globalExpertIDs.sorted(),
              Set(globalExpertIDs).count == globalExpertIDs.count,
              globalExpertIDs.allSatisfy({ (0..<128).contains($0) }) else {
            throw Gemma4ExpertParallelError.invalidPartition
        }
        self.configuration = config; self.globalExpertIDs = globalExpertIDs
        self.layerKinds = config.cbv2LayerKinds
        self._languageModel.wrappedValue = try Gemma4ExpertLanguageModel(
            configuration: config, localExpertCount: globalExpertIDs.count)
        super.init()
    }

    public var loadedEmbeddingOutputDType: DType? {
        guard let value = languageModel.model.embedTokens as? QuantizedEmbedding,
              value.mode == .affine, value.bits == 4, value.groupSize == 64,
              let biases = value.biases, value.scales.dtype == biases.dtype,
              value.weight.dtype == .uint32,
              [.float16, .bfloat16, .float32].contains(value.scales.dtype) else { return nil }
        return value.scales.dtype
    }

    /// Graph construction over existing CBv2 rows; exactly the stage policy and
    /// original decoder operation order. The owning session poisons/retires on
    /// any throw, including a collective failure after a prior layer's KV write.
    public func forward(tokens: [Int32], caches: [any CBv2AttendingLayerCache],
                        phase: Gemma4LayerStagePhase,
                        expertOperation: Gemma4ExpertUnweightedOperation) throws -> Gemma4LayerStageOutput {
        guard (1...128).contains(tokens.count), phase == .prefill || tokens.count == 1,
              tokens.allSatisfy({ $0 >= 0 && Int($0) < configuration.vocabSize }),
              loadedEmbeddingOutputDType != nil else { throw Gemma4ExpertParallelError.invalidInput }
        let legacy = caches.compactMap { $0 as? KVCache }
        guard caches.count == layerKinds.count, legacy.count == caches.count,
              zip(caches, layerKinds).allSatisfy({ $0.0.kind == $0.1 && $0.0.rows.count == 1 }),
              Set(caches.map { ObjectIdentifier($0.rows[0]) }).count == caches.count,
              Set(caches.map { $0.rows[0].absoluteOffset }).count == 1 else {
            throw Gemma4ExpertParallelError.invalidCache
        }
        let input = MLXArray(tokens).reshaped([1, tokens.count])
        var hidden = languageModel.model.embedTokens(input) * Float(configuration.hiddenSize).squareRoot()
        var observations: [Gemma4LayerStageKVObservation] = []
        for (index, layer) in languageModel.model.layers.enumerated() {
            let policy = gemma4LayerPrefillPolicy(configuration, globalLayerIndex: index,
                finalOutputLayerIndex: configuration.numHiddenLayers - 1, ownsFinalOutput: true,
                schedulePrefill: phase == .prefill, isCBv2: true,
                batchSize: hidden.dim(0), sequenceLength: hidden.dim(1), inputSequenceLength: tokens.count,
                hasLastQueryCache: caches[index] is any CBv2LastQueryPrefillLayerCache)
            let (output, kv, _) = try layer.callAsExpertParallel(hidden, cache: legacy[index],
                outputTailRows: policy.outputTailRows, useLastQueryPrefill: policy.useLastQuery,
                isExpertPrefill: policy.expertPrefill, expertOperation: expertOperation)
            let kind = layerKinds[index]
            let shape = [1, kind.kvHeads, tokens.count, kind.headDim]
            guard kv.0.shape == shape, kv.1.shape == shape, kv.0.dtype == kv.1.dtype,
                  [.float16, .bfloat16, .float32].contains(kv.0.dtype) else {
                throw Gemma4ExpertParallelError.invalidNativeKV
            }
            observations.append(.init(localLayerIndex: index, globalLayerIndex: index,
                keysDType: kv.0.dtype, valuesDType: kv.1.dtype, keysShape: kv.0.shape, valuesShape: kv.1.shape))
            hidden = output
            if policy.submitIntermediate {
                asyncEval(hidden)
                CBv2StepProfiler.recordEvent("v2.gemma4.prefill.chunk_eval")
            }
        }
        return .init(residual: hidden, kvObservations: observations)
    }

    public func finalLogits(_ residual: MLXArray) throws -> MLXArray {
        guard residual.ndim == 3, residual.dim(0) == 1, (1...128).contains(residual.dim(1)),
              residual.dim(2) == configuration.hiddenSize, loadedEmbeddingOutputDType != nil,
              [.float16, .bfloat16, .float32].contains(residual.dtype) else {
            throw Gemma4ExpertParallelError.invalidInput
        }
        let normalized = languageModel.model.norm(residual)
        let logits = languageModel.model.embedTokens.asLinear(normalized[0..., -1, 0...])
        return gemma4CompiledLogitSoftcap(logits, MLXArray(configuration.finalLogitSoftcapping))
    }
}

private final class Gemma4ExpertLanguageModel: Module {
    @ModuleInfo(key: "model") var model: Gemma4ExpertTrunk
    init(configuration: Gemma4TextConfiguration, localExpertCount: Int) throws {
        self._model.wrappedValue = try Gemma4ExpertTrunk(configuration: configuration,
            localExpertCount: localExpertCount)
        super.init()
    }
}

private final class Gemma4ExpertTrunk: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: [Gemma4DecoderLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm
    init(configuration: Gemma4TextConfiguration, localExpertCount: Int) throws {
        self._embedTokens.wrappedValue = Embedding(embeddingCount: configuration.vocabSize,
            dimensions: configuration.hiddenSize)
        self._layers.wrappedValue = try (0..<configuration.numHiddenLayers).map {
            try Gemma4DecoderLayer(expertParallelConfiguration: configuration,
                layerIdx: $0, localExpertCount: localExpertCount)
        }
        self._norm.wrappedValue = RMSNorm(dimensions: configuration.hiddenSize, eps: configuration.rmsNormEps)
        super.init()
    }
}
