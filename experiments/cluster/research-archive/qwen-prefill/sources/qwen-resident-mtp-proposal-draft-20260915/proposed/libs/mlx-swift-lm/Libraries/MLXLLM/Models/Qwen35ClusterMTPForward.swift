import MLX
import MLXLMCommon
import MLXNN

/// Explicit residual-ingress capture. The ordinary token/prefill methods do not
/// call this SPI. The caller owns the target caches and evaluates both outputs
/// in the same transaction before admitting hidden rows as committed history.
@_spi(Cluster) public enum Qwen35ClusterMTPForward {
    public enum Output { case prefillEvaluation, prefillLastLogits, decodeLastLogits }
    private enum Failure: Error { case invalidInput, incompatibleCache }

    public static func forward(target model: any LanguageModel, tokens: MLXArray,
        residual: MLXArray, caches: [any KVCache],
        recurrentState: [CBv2RecurrentStateEvaluation], output: Output
    ) throws -> (value: MLXArray, preNormHidden: MLXArray) {
        let target = try Qwen35InlineMTPAssistant.qwen35TextTarget(model)
        guard tokens.ndim == 2, tokens.dim(0) == 1, tokens.dim(1) > 0,
              tokens.dtype == .int32, residual.shape == [1, tokens.dim(1), target.configuration.hiddenSize],
              [.float16, .bfloat16, .float32].contains(residual.dtype), recurrentState.count == 1 else {
            throw Failure.invalidInput
        }
        if case .decodeLastLogits = output, tokens.dim(1) != 1 { throw Failure.invalidInput }
        let attending = try caches.map { cache -> any CBv2AttendingLayerCache in
            guard let value = cache as? any CBv2AttendingLayerCache else { throw Failure.incompatibleCache }
            return value
        }
        // Exactly one call to the existing residual-ingress trunk. No token
        // embedding lookup, target KV replay, or recurrent capture is added.
        let hidden = target.model.cbv2Forward(tokens, inputEmbeddings: residual,
            caches: attending, recurrentState: recurrentState, positionIds: nil)
        let value: MLXArray
        switch output {
        case .prefillEvaluation:
            value = hidden[0..., -1, 0 ..< 1]
        case .prefillLastLogits:
            let last = target.model.norm(hidden[0..., -1, 0...])
            value = target.lmHead.map { $0(last) } ?? target.model.embedTokens.asLinear(last)
        case .decodeLastLogits:
            // Preserve the ordinary embeddingForward decode projection shape.
            let normalized = target.model.norm(hidden)
            let logits = target.lmHead.map { $0(normalized) } ?? target.model.embedTokens.asLinear(normalized)
            value = logits[0..., -1, 0...]
        }
        return (value, hidden)
    }
}
