import Foundation
import MLX

/// The three pieces of the product's Gemma 4 trunk that are private to it and
/// that a stage needs, restated. The product model class runs all thirty layers
/// or none, so a stage composes the product's own decoder layers and must make
/// these decisions itself. Each is checked against the product by comparison
/// (the staged reference against the serving engine), not by sharing code.
///
/// Source: `Gemma4Text.swift` at the pinned mlx-swift-lm revision
/// (`forwardTrunk`, `gemma4UseLastQueryPrefill`, `gemma4CompiledLogitSoftcap`).
enum Gemma4StagePromptPolicy {
    /// The defaults the arithmetic contract binds; see `Gemma4ArithmeticEnvironment`.
    static let tailRows = Gemma4ArithmeticEnvironment.finalLayerTailRows
    static let tailMinimumChunk = Gemma4ArithmeticEnvironment.finalLayerTailMinimumChunk
    static let lastQueryEnabled = Gemma4ArithmeticEnvironment.finalLayerLastQuery

    struct Decision: Equatable {
        /// Rows the layer keeps after attention; nil keeps the whole chunk.
        let outputTailRows: Int?
        /// Project and attend the query of the last row only.
        let useLastQuery: Bool
    }

    /// Only the model's last layer narrows, only on a prompt chunk, and only on
    /// the rank that owns the final output: every earlier layer's rows feed the
    /// next layer's keys and values, and rank 0's rows are the residual it sends.
    static func decide(globalLayerIndex: Int, prefill: Bool, ownsFinalOutput: Bool,
                       batchSize: Int, sequenceLength: Int, cacheSupportsLastQuery: Bool) -> Decision {
        let last = Gemma4StageGeometry.layerCount - 1
        let finalPromptLayer = prefill && ownsFinalOutput && globalLayerIndex == last
            && batchSize > 0 && sequenceLength >= tailMinimumChunk
        let tail: Int? = finalPromptLayer && tailRows > 0 ? min(tailRows, sequenceLength) : nil
        // The registered geometry's last layer is full attention and owns its
        // keys and values, which is what makes one query equivalent.
        let lastQuery = lastQueryEnabled && cacheSupportsLastQuery && tail == 1
            && globalLayerIndex == last && batchSize > 0 && sequenceLength > 1
            && Gemma4StageGeometry.isFullAttention(globalLayerIndex: last)
        return .init(outputTailRows: tail, useLastQuery: lastQuery)
    }

    /// `tanh(x / cap) * cap` as one compiled function, as the product compiles
    /// it. The cap is an untyped (float32) array, so the logits are float32.
    static let logitSoftcap: @Sendable (MLXArray, MLXArray) -> MLXArray = compile(shapeless: true) {
        (x: MLXArray, cap: MLXArray) -> MLXArray in tanh(x / cap) * cap
    }
}
