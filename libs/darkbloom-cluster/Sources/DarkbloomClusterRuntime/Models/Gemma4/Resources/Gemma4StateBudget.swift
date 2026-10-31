import DarkbloomClusterProtocol
import Foundation

/// The named storage of one request on the registered Gemma 4 26B geometry, in
/// logical bytes. Either rank is charged the whole model's state, as the
/// registered Qwen allowance charges it: a conservative ledger of named arrays,
/// not a whole-process peak.
struct Gemma4StateBudget: Equatable {
    let maximumTokens: Int, chunkSize: Int
    let fullLayers: Int, slidingLayers: Int
    /// Keys or values of one full-attention layer at the request's capacity.
    let fullKVBytes: Int
    /// Keys or values of one sliding layer's ring, allocated whole at first write.
    let ringKVBytes: Int
    /// Keys or values one sliding layer attends over during a prompt chunk: the
    /// history the ring is about to overwrite, then the chunk.
    let slidingViewKVBytes: Int
    /// One chunk of residual rows.
    let boundaryBytes: Int
    /// One vocabulary row of float32 logits.
    let logitsBytes: Int
    let largestSingleHostStateComponentBytes: Int
    let stateAndBoundaryBytes: Int

    static func estimate(maximumTokens: Int, chunkSize: Int) throws -> Self {
        guard (1...ClusterWorkerLimits.contextTokens).contains(maximumTokens), (1...512).contains(chunkSize) else {
            throw ProbeError("Gemma state budget requires bounded tokens and chunk")
        }
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        let layers = Gemma4StageGeometry.layerCount
        let full = layers / Gemma4StageGeometry.fullAttentionInterval, sliding = layers - full
        let elementBytes = 2
        let fullKV = try product([maximumTokens, Gemma4StageGeometry.fullKVHeads,
                                  Gemma4StageGeometry.fullHeadDimension, elementBytes])
        let slidingRow = try product([Gemma4StageGeometry.slidingKVHeads,
                                      Gemma4StageGeometry.slidingHeadDimension, elementBytes])
        let ring = try product([Gemma4StageGeometry.slidingWindow, slidingRow])
        let view = try product([Gemma4StageGeometry.slidingWindow - 1 + chunkSize, slidingRow])
        let boundary = try product([chunkSize, Gemma4StageGeometry.hiddenSize, elementBytes])
        let logits = try product([Gemma4StageGeometry.vocabularySize, 4])
        let total = try sum([product([2, full, fullKV]), product([2, sliding, ring]),
            product([2, sliding, view]), product([4, layers]), max(fullKV, ring),
            product([2, boundary]), product([2, logits])])
        return .init(maximumTokens: maximumTokens, chunkSize: chunkSize, fullLayers: full, slidingLayers: sliding,
            fullKVBytes: fullKV, ringKVBytes: ring, slidingViewKVBytes: view, boundaryBytes: boundary,
            logitsBytes: logits, largestSingleHostStateComponentBytes: max(fullKV, ring),
            stateAndBoundaryBytes: total)
    }
}

/// Byte ceilings of the registered Gemma resident scope. A ceiling is a refusal
/// bound, not a memory grant or a fit on any Mac; the live gates stay in force.
struct Gemma4ResidentResourceCeilings: Equatable {
    /// The resident profile's largest request: 8,192 prompt plus 128 output
    /// tokens, prefilled in chunks of at most 512.
    static let maximumContextTokens = 8320
    static let maximumChunkTokens = 512
    /// The ledger at that request, recomputed from the geometry and required to
    /// equal this independently pinned integer.
    static let pinnedMaximumNamedStateBytes = 719_380_600

    /// Largest manifest payload the verified loader will hash for this model:
    /// the registered manifest total itself.
    let maximumManifestPayloadBytes: Int
    /// The ledger at the model's largest request (`Gemma4ResidentAdapterDefinition.contextLimits`),
    /// from the geometry with the formula every request is charged by.
    let namedStateByteCeiling: Int
    /// The ledger at the earlier reservation's largest request, required to
    /// equal the independently pinned integer as a check of the formula.
    let maximumNamedStateBytes: Int

    init(specification: Gemma4RegisteredSpecification) throws {
        maximumManifestPayloadBytes = specification.manifestBytes
        maximumNamedStateBytes = try Gemma4StateBudget.estimate(maximumTokens: Self.maximumContextTokens,
            chunkSize: Self.maximumChunkTokens).stateAndBoundaryBytes
        guard specification.manifestBytes > 0, maximumNamedStateBytes == Self.pinnedMaximumNamedStateBytes else {
            throw ProbeError("Registered Gemma ceilings differ from the model's own byte vector")
        }
        let limits = try Gemma4ResidentAdapterDefinition.contextLimits()
        namedStateByteCeiling = try Gemma4StateBudget.estimate(maximumTokens: limits.maximumContextTokens,
            chunkSize: limits.maximumChunkTokens).stateAndBoundaryBytes
    }
}

/// The attention transient of one prefill frame on a Gemma stage (the owner's
/// planner prices it beside the KV, oMLX U#3651). Both head dimensions (512 on
/// a full layer, 256 on a sliding one) take MLX's unfused path, so a frame
/// materializes float32 scores beside a float32 output: over the whole context
/// on a full layer, over the window and the frame on a sliding one. Layers run
/// one after another, so the stage's transient is its largest layer's.
enum Gemma4PrefillTransient {
    static func bytes(layers: [QwenLayerStagePlan.Layer], chunkTokens: Int, contextTokens: Int) throws -> Int {
        typealias G = Gemma4StageGeometry
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        let queries = min(chunkTokens, contextTokens)
        var largest = 0
        for layer in layers {
            let full = layer.kind == G.fullKind
            let width = full ? G.fullHeadDimension : G.slidingHeadDimension
            let keys = full ? contextTokens : min(contextTokens, G.slidingWindow - 1 + chunkTokens)
            let value = try sum([product([G.queryHeads, queries, keys, 4]), product([G.queryHeads, queries, width, 4])])
            largest = max(largest, value)
        }
        return largest
    }
}
