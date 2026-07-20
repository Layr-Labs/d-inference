// Copyright © 2026 Eigen Labs.
//
// Shared inference value types (extracted from the deleted
// `BatchSchedulerTypes.swift` when the legacy engine was removed —
// v0.7.5 one-engine).
//
// `GenerationEvent` is the stream vocabulary between the v2 bridge and
// everything downstream (tool-call parsing, SSE framing, error→status
// mapping, billing extraction). `TokenizerHandle` is the type-erased
// tokenizer reference every slot carries. `ModelArchitecture` is the
// config.json parse consumed by `KVEstimation` (the pre-load estimate)
// and `SlotSizingSnapshot` (context window / fallback rate).

import Foundation
import MLXLMCommon

/// Events emitted for a single inference request.
public enum GenerationEvent: Sendable {
    case chunk(String)
    /// Terminal usage. `finishReason` is the OpenAI wire value ("stop",
    /// "length") when the engine reported one; nil maps to "stop"
    /// downstream. Threaded end-to-end (`CBv2FinishReason.length`) so a
    /// max_tokens truncation reaches clients as `finish_reason: "length"`
    /// instead of being flattened to "stop".
    case info(
        promptTokens: Int, completionTokens: Int, tokensPerSecond: Double,
        finishReason: String?)
    case error(String)
}

/// Model-architecture fields read from `config.json`, used by
/// `KVEstimation.computeKVBytesPerToken` to size the pre-load estimate.
/// All values are post-clamp; see `KVEstimation.parseModelArchitecture`.
public struct ModelArchitecture: Sendable {
    let numLayers: Int?
    let kvHeads: Int?
    let headDim: Int?
    let numKvSharedLayers: Int
    let globalHeadDim: Int?
    let numGlobalKvHeads: Int?
    let slidingWindowPattern: Int?
    let layerTypes: [String]?
    let maxContextLength: Int?
    /// MoE: total routed experts (`num_local_experts`). nil ⇒ dense model.
    let numLocalExperts: Int?
    /// MoE: experts activated per token (`num_experts_per_tok`). nil ⇒ dense.
    let numExpertsPerTok: Int?
    /// Transformer residual width (`hidden_size`).
    let hiddenSize: Int?
    /// MLP / per-expert inner width (`intermediate_size`).
    let intermediateSize: Int?

    init(
        numLayers: Int?,
        kvHeads: Int?,
        headDim: Int?,
        numKvSharedLayers: Int,
        globalHeadDim: Int?,
        numGlobalKvHeads: Int?,
        slidingWindowPattern: Int?,
        layerTypes: [String]?,
        maxContextLength: Int?,
        numLocalExperts: Int? = nil,
        numExpertsPerTok: Int? = nil,
        hiddenSize: Int? = nil,
        intermediateSize: Int? = nil
    ) {
        self.numLayers = numLayers
        self.kvHeads = kvHeads
        self.headDim = headDim
        self.numKvSharedLayers = numKvSharedLayers
        self.globalHeadDim = globalHeadDim
        self.numGlobalKvHeads = numGlobalKvHeads
        self.slidingWindowPattern = slidingWindowPattern
        self.layerTypes = layerTypes
        self.maxContextLength = maxContextLength
        self.numLocalExperts = numLocalExperts
        self.numExpertsPerTok = numExpertsPerTok
        self.hiddenSize = hiddenSize
        self.intermediateSize = intermediateSize
    }

    static let empty = ModelArchitecture(
        numLayers: nil,
        kvHeads: nil,
        headDim: nil,
        numKvSharedLayers: 0,
        globalHeadDim: nil,
        numGlobalKvHeads: nil,
        slidingWindowPattern: nil,
        layerTypes: nil,
        maxContextLength: nil
    )
}

/// Type-erased wrapper around the loaded model's tokenizer.
///
/// Wraps the tokenizer in a class so holders can keep an `Optional`
/// reference without copying the underlying tokenizer state every load.
public final class TokenizerHandle: @unchecked Sendable {
    public let inner: any MLXLMCommon.Tokenizer
    private let toolConstraintLock = NSLock()
    private var gemmaVocabularies: [[Int]: GemmaTokenVocabulary] = [:]

    public init(_ inner: any MLXLMCommon.Tokenizer) { self.inner = inner }

    func gemmaVocabulary(
        stopTokenIDs: Set<Int>
    ) throws -> GemmaTokenVocabulary {
        let key = stopTokenIDs.sorted()
        toolConstraintLock.lock()
        defer { toolConstraintLock.unlock() }
        if let cached = gemmaVocabularies[key] {
            return cached
        }

        let built = try GemmaTokenVocabulary(
            tokenizer: inner, stopTokenIDs: stopTokenIDs)
        gemmaVocabularies[key] = built
        return built
    }
}
