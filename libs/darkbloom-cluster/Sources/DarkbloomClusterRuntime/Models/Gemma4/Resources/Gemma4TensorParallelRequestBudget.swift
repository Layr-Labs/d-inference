import DarkbloomClusterPlacement
import Foundation

/// What a Gemma 4 tensor-parallel rank holds beside its weights, as its LOAD
/// and request gates charge it (`Gemma4TensorParallelResidentRuntime`) and the
/// planner quotes it (`ClusterTensorParallelFamilyPlan.requestAllowance`).
/// Every array is charged at the allocator's bound.
///
/// Per request (`requestBytes`, what each reservation or lane charges at its
/// own context): this rank's own KV heads of every layer (`Gemma4StateBudget`
/// at two ranks), one prompt chunk's attention transient over its own 8 query
/// heads (`Gemma4PrefillTransient`), the chunk's FP32 partials (the attention
/// row; the dense row and the 8 selected experts' rows, and the packed copy
/// of them the collective carries) and three float32 rows of the whole
/// vocabulary (the row a sampled step gathers, the split head's half, the
/// top-k).
///
/// Once per rank (`rankBytes`): the conservative activation floor until
/// hardware measures one for a Gemma tensor-parallel rank (5.5 GiB, the
/// provider's default reserve, as `GLM5NextServingResources` charges GLM's),
/// the freed-buffer cache the ready rank keeps, and eight sealed frames of the
/// largest collective (`ClusterTensorParallelRequestAllowance`). The decode
/// steps' 100-operation command buffers (`Gemma4TensorParallelModel.decodeCommandBuffers`)
/// bound only how a step is submitted, and no prefill is micro-batched: neither
/// adds a buffer beyond these.
struct Gemma4TensorParallelRequestBudget: Equatable {
    static let ranks = 2
    /// `UnifiedMemoryCap.defaultActivationReserveBytes`: 5.5 GiB. A measured
    /// constant replaces it once a pair measures a rank's peak.
    static let activationFloorBytes = 11 * 1024 * 1024 * 1024 / 2
    /// `Gemma4TensorParallelResidentRuntime.freedBufferCacheBytes`: half the
    /// allocator headroom, as Qwen tensor parallel keeps.
    static var freedBufferCacheBytes: Int {
        QwenTensorParallelLaunch.freedBufferCacheBytes(allocatorHeadroomBytes: QwenDenseStageLoadPolicy.allocatorHeadroomBytes)
    }
    /// FP32 bytes per token of the largest collective: the dense and 8 expert rows.
    static let maximumPartialBytesPerToken = (Gemma4StageGeometry.expertsPerToken + 1) * Gemma4StageGeometry.hiddenSize * 4

    let contextTokens: Int
    let chunkTokens: Int
    let stateBytes: Int
    let transientBytes: Int
    let partialBytes: Int
    let logitsBytes: Int
    let allowance: ClusterTensorParallelRequestAllowance

    /// What one request of `contextTokens` reserves on a rank.
    var requestBytes: Int { stateBytes + transientBytes + partialBytes + logitsBytes }
    /// What a rank holds once beside every request it serves.
    var rankBytes: Int { Self.activationFloorBytes + Self.freedBufferCacheBytes + allowance.collectiveScratchBytes }

    static func derive(contextTokens: Int, chunkTokens: Int, allocationBound: (Int) throws -> Int) throws -> Self {
        typealias G = Gemma4StageGeometry
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        let chunk = min(contextTokens, chunkTokens)
        func bound(_ logical: Int, count: Int = 1) throws -> Int {
            let allocated = try allocationBound(logical)
            guard logical > 0, allocated >= logical, count >= 0 else {
                throw ProbeError("Gemma tensor-parallel request allocator bound is invalid")
            }
            return try product([allocated, count])
        }
        let b = try Gemma4StateBudget.estimate(maximumTokens: contextTokens, chunkSize: chunk, ranks: ranks)
        let layers = b.fullLayers + b.slidingLayers
        let state = try sum([bound(b.fullKVBytes, count: 2 * b.fullLayers), bound(b.ringKVBytes, count: 2 * b.slidingLayers),
            bound(b.slidingViewKVBytes, count: 2 * b.slidingLayers), bound(4, count: layers),
            bound(b.largestSingleHostStateComponentBytes), bound(b.boundaryBytes, count: 2)])
        let transientLogical = try Gemma4PrefillTransient.bytes(
            fullAttention: (0..<G.layerCount).map(G.isFullAttention(globalLayerIndex:)),
            queryHeads: G.queryHeads / ranks, chunkTokens: chunk, contextTokens: contextTokens)
        let row = try product([chunk, G.hiddenSize, 4])
        // The attention partial, the dense partial, the selected experts' rows and their packed copy.
        let partials = try sum([bound(row, count: 2), bound(product([row, G.expertsPerToken])),
                                bound(product([chunk, maximumPartialBytesPerToken]))])
        let logits = try bound(product([G.vocabularySize, 4]), count: 3)
        let payload = try product([chunk, maximumPartialBytesPerToken])
        let frame = try sum([payload, QwenTensorParallelSealCodec.frameOverhead])
        let request = try sum([state, bound(transientLogical), partials, logits])
        let allowance = try ClusterTensorParallelRequestAllowance(maximumContextTokens: contextTokens,
            maximumChunkTokens: chunk,
            requestBytesExcludingCollectives: sum([request, activationFloorBytes, freedBufferCacheBytes]),
            maximumCollectivePayloadBytes: payload, maximumCollectiveFrameBytes: frame, allocationBound: allocationBound)
        return .init(contextTokens: contextTokens, chunkTokens: chunk, stateBytes: state,
            transientBytes: try bound(transientLogical), partialBytes: partials, logitsBytes: logits, allowance: allowance)
    }
}
