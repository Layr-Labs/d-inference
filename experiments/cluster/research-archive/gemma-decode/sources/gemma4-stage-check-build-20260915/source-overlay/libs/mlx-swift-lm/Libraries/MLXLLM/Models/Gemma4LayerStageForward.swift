import MLX
import MLXLMCommon

public enum Gemma4LayerStagePhase: Sendable, Equatable { case prefill, decode }

/// Actual graph metadata returned by the existing decoder after projection,
/// normalization and rotary application. Contains no K/V array aliases.
public struct Gemma4LayerStageKVObservation: Sendable {
    public let localLayerIndex: Int
    public let globalLayerIndex: Int
    public let keysDType: DType
    public let valuesDType: DType
    public let keysShape: [Int]
    public let valuesShape: [Int]
}

public struct Gemma4LayerStageOutput {
    public let residual: MLXArray
    public let kvObservations: [Gemma4LayerStageKVObservation]

    /// Call before committing the existing request state. The expected types
    /// must come from separately admitted native observation, not packed weights.
    public func requireKVDTypes(_ expected: [DType]) throws {
        guard expected.count == kvObservations.count,
            zip(expected, kvObservations).allSatisfy({
                $0.0 == $0.1.keysDType && $0.0 == $0.1.valuesDType
            }) else { throw Gemma4LayerStageError.invalidNativeKV }
    }
}

extension Gemma4LayerStage {
    /// Rank0 alone performs lookup/scaling. Rank1's embedding replica serves
    /// the tied head; accepting a residual never applies this scale again.
    public func inputResidual(tokens: [Int32]) throws -> MLXArray {
        guard layout.rank == 0 else { throw Gemma4LayerStageError.wrongResponsibility }
        guard (1...512).contains(tokens.count),
            tokens.allSatisfy({ $0 >= 0 && Int($0) < configuration.vocabSize }),
            loadedEmbeddingOutputDType != nil
        else { throw Gemma4LayerStageError.invalidInput }
        let input = MLXArray(tokens).reshaped([1, tokens.count])
        return languageModel.model.embedTokens(input) * Float(configuration.hiddenSize).squareRoot()
    }

    /// Reuses caller-owned CBv2 caches. The caller must poison/retire the whole
    /// request on any throw; earlier layers may already have advanced. This
    /// method supplies no independent request owner, rollback or admission.
    public func forwardResidual(
        _ residual: MLXArray, caches: [any CBv2AttendingLayerCache],
        phase: Gemma4LayerStagePhase
    ) throws -> Gemma4LayerStageOutput {
        guard residual.ndim == 3, residual.dim(0) == 1,
            residual.dim(2) == configuration.hiddenSize,
            (1...512).contains(residual.dim(1)),
            phase == .prefill || residual.dim(1) == 1,
            loadedEmbeddingOutputDType != nil,
            [.float16, .bfloat16, .float32].contains(residual.dtype)
        else { throw Gemma4LayerStageError.invalidInput }
        let legacyCaches = caches.compactMap { $0 as? KVCache }
        guard caches.count == layout.layerKinds.count,
            legacyCaches.count == caches.count,
            zip(caches, layout.layerKinds).allSatisfy({
                $0.0.kind == $0.1 && $0.0.rows.count == 1
            }),
            Set(caches.map { ObjectIdentifier($0.rows[0]) }).count == caches.count,
            Set(caches.map { $0.rows[0].absoluteOffset }).count == 1
        else { throw Gemma4LayerStageError.invalidCache }

        let inputLength = residual.dim(1)
        var hidden = residual
        var observations: [Gemma4LayerStageKVObservation] = []
        for (local, layer) in languageModel.model.layers.enumerated() {
            let global = layout.sourceLayerRange.lowerBound + local
            let policy = gemma4LayerPrefillPolicy(
                configuration, globalLayerIndex: global,
                finalOutputLayerIndex: configuration.numHiddenLayers - 1,
                ownsFinalOutput: layout.ownsFinalOutput,
                schedulePrefill: phase == .prefill, isCBv2: true,
                batchSize: hidden.dim(0), sequenceLength: hidden.dim(1),
                inputSequenceLength: inputLength,
                hasLastQueryCache: caches[local] is any CBv2LastQueryPrefillLayerCache)
            let (output, kv, _) = layer(
                hidden, cache: legacyCaches[local], outputTailRows: policy.outputTailRows,
                useLastQueryPrefill: policy.useLastQuery,
                isExpertPrefill: policy.expertPrefill)
            let kind = layout.layerKinds[local]
            let shape = [1, kind.kvHeads, inputLength, kind.headDim]
            guard kv.0.shape == shape, kv.1.shape == shape,
                kv.0.dtype == kv.1.dtype,
                [.float16, .bfloat16, .float32].contains(kv.0.dtype)
            else { throw Gemma4LayerStageError.invalidNativeKV }
            observations.append(Gemma4LayerStageKVObservation(
                localLayerIndex: local, globalLayerIndex: global,
                keysDType: kv.0.dtype, valuesDType: kv.1.dtype,
                keysShape: kv.0.shape, valuesShape: kv.1.shape))
            hidden = output
            if policy.submitIntermediate {
                asyncEval(hidden)
                CBv2StepProfiler.recordEvent("v2.gemma4.prefill.chunk_eval")
            }
        }
        return Gemma4LayerStageOutput(residual: hidden, kvObservations: observations)
    }

    /// Preserve ordinary CBv2 norm-before-final-row selection and softcap.
    /// Exactly one rank1 embedding object supplies the tied output projection.
    public func finalLogits(_ residual: MLXArray) throws -> MLXArray {
        guard layout.ownsFinalOutput, let norm = languageModel.model.norm else {
            throw Gemma4LayerStageError.wrongResponsibility
        }
        guard residual.ndim == 3, residual.dim(0) == 1,
            (1...512).contains(residual.dim(1)), residual.dim(2) == configuration.hiddenSize,
            loadedEmbeddingOutputDType != nil,
            [.float16, .bfloat16, .float32].contains(residual.dtype)
        else { throw Gemma4LayerStageError.invalidInput }
        let normalized = norm(residual)
        let logits = languageModel.model.embedTokens.asLinear(normalized[0..., -1, 0...])
        return gemma4CompiledLogitSoftcap(logits, MLXArray(configuration.finalLogitSoftcapping))
    }
}
