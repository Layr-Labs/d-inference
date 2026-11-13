import DarkbloomClusterPlacement
import Foundation

/// What a Gemma 4 tensor-parallel rank holds beside its weights, as its LOAD
/// and request gates charge it (`Gemma4TensorParallelResidentRuntime`) and the
/// planner quotes it (`ClusterTensorParallelFamilyPlan.requestAllowance`).
/// Every array is charged at the allocator's bound.
///
/// Per request (`requestBytes`, what each reservation or lane charges at its
/// own context): this rank's own KV heads of every layer (`Gemma4StateBudget`
/// at two ranks), the attention transient over its own 8 query heads
/// (`Gemma4PrefillTransient`), the FP32 partials (the attention row; the
/// dense row and the 8 selected experts' rows, and the packed copy of them
/// the collective carries), three float32 rows of the whole vocabulary (the
/// row a sampled step gathers, the split head's half, the top-k) and its
/// prompt-prefix capture at its deepest boundary (`prefixCaptureBytes`: its
/// own heads' full rows for its prompt, the memory plan's longest in the LOAD
/// quote, and one sliding window of every sliding layer).
///
/// The transient and the partials are priced at one prompt chunk, or at one
/// decode row on every layer where that is more: a decode step is submitted
/// layer by layer (`Gemma4TensorParallelModel.decodeLayerStride`) in
/// 100-operation command buffers (`Gemma4TensorParallelModel.decodeCommandBuffers`),
/// so several layers' temporaries are alive at once. Only requests shorter
/// than a step's layers pay more; the LOAD quote's 512-token chunk covers a step.
///
/// Once per rank (`rankBytes`): the conservative activation floor until
/// hardware measures one for a Gemma tensor-parallel rank (5.5 GiB, the
/// provider's default reserve, as `GLM5NextServingResources` charges GLM's),
/// the freed-buffer cache the ready rank keeps and eight sealed frames of the
/// largest collective (`ClusterTensorParallelRequestAllowance`). No prefill is
/// micro-batched, so prefill adds no buffer beyond these.
///
/// The prompt-prefix memory tier is not charged: as the pipeline's, its
/// budget is half the room the load measures beside this charge
/// (`QwenStagePrefixCache.budget(roomBytes:)`), and its entries give way
/// before a reservation, a lane or a running request is refused for memory.
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
    /// The request's prompt-prefix capture at its deepest boundary.
    let prefixCaptureBytes: Int
    let allowance: ClusterTensorParallelRequestAllowance

    /// What one request of `contextTokens` reserves on a rank.
    var requestBytes: Int { stateBytes + transientBytes + partialBytes + logitsBytes + prefixCaptureBytes }
    /// What a rank holds once beside every request it serves.
    var rankBytes: Int { Self.activationFloorBytes + Self.freedBufferCacheBytes + allowance.collectiveScratchBytes }
    /// What each lane after the first adds: its whole request charge, as `reserveLane` admits every lane. The layout
    /// states it (`ClusterTensorParallelFamilyPlan.laneBytes`), so the planner prices a saved width as LOAD reserves it.
    var laneBytes: Int { requestBytes }

    /// What a rank's LOAD gate reserves beside its shard for `lanes` requests at once: the allowance (one request and
    /// the rank's reserve) and `laneBytes` for each lane after the first. The allowance is `requestBytes` and
    /// `rankBytes`, so this is every lane's request and the rank's reserve once: what the prompt-prefix memory tier is
    /// measured beside too.
    func reservedBytes(lanes: Int) throws -> Int {
        guard (1...QwenBatchWire.maximumLanes).contains(lanes) else {
            throw ProbeError("Gemma tensor-parallel lanes are 1...\(QwenBatchWire.maximumLanes)")
        }
        return try QwenLongPrefillCheckedBytes.sum([allowance.reservedBytes,
            QwenLongPrefillCheckedBytes.product([laneBytes, lanes - 1])])
    }

    /// One prefix capture of a prompt of `promptTokens` at the allocator's
    /// bound: this rank's full-attention rows (keys and values, every token)
    /// and one window of every sliding layer, its own heads.
    static func prefixCaptureBytes(promptTokens: Int, allocationBound: (Int) throws -> Int) throws -> Int {
        typealias G = Gemma4StageGeometry
        let product = QwenLongPrefillCheckedBytes.product
        guard promptTokens > 0 else { return 0 }
        let layers = (0 ..< G.layerCount).map(G.isFullAttention(globalLayerIndex:))
        let full = layers.filter { $0 }.count, sliding = layers.count - full
        func bound(_ logical: Int, count: Int) throws -> Int {
            let allocated = try allocationBound(logical)
            guard logical > 0, allocated >= logical else { throw ProbeError("Gemma tensor-parallel prefix allocator bound is invalid") }
            return try product([allocated, count])
        }
        let rows = try product([promptTokens, G.fullKVHeads / ranks, G.fullHeadDimension, 2])
        let window = try product([min(promptTokens, G.slidingWindow), G.slidingKVHeads / ranks, G.slidingHeadDimension, 2])
        return try QwenLongPrefillCheckedBytes.sum([bound(rows, count: 2 * full), bound(window, count: 2 * sliding)])
    }

    /// `promptTokens`: the prompt whose capture is charged (a request's own,
    /// or the memory plan's longest in the LOAD quote), at most `contextTokens - 1`;
    /// nil: `contextTokens - 1`. `keepsPrefixes` false charges no prefix
    /// capture (the load's cache off, or the request's).
    static func derive(contextTokens: Int, chunkTokens: Int, promptTokens: Int? = nil, keepsPrefixes: Bool = true,
                       allocationBound: (Int) throws -> Int) throws -> Self {
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
        let prompt = min(promptTokens ?? contextTokens - 1, contextTokens - 1)
        let capture = keepsPrefixes ? try prefixCaptureBytes(promptTokens: max(1, prompt), allocationBound: allocationBound) : 0
        let b = try Gemma4StateBudget.estimate(maximumTokens: contextTokens, chunkSize: chunk, ranks: ranks)
        let layers = b.fullLayers + b.slidingLayers
        let state = try sum([bound(b.fullKVBytes, count: 2 * b.fullLayers), bound(b.ringKVBytes, count: 2 * b.slidingLayers),
            bound(b.slidingViewKVBytes, count: 2 * b.slidingLayers), bound(4, count: layers),
            bound(b.largestSingleHostStateComponentBytes), bound(b.boundaryBytes, count: 2)])
        let kinds = (0..<G.layerCount).map(G.isFullAttention(globalLayerIndex:))
        let transientLogical = try Gemma4PrefillTransient.bytes(fullAttention: kinds, queryHeads: G.queryHeads / ranks,
            chunkTokens: chunk, contextTokens: contextTokens, decodeRows: 1, decodeFullAttention: kinds)
        // A chunk's rows, or a decode step's one row on every layer.
        let rows = max(chunk, G.layerCount)
        let row = try product([rows, G.hiddenSize, 4])
        // The attention partial, the dense partial, the selected experts' rows and their packed copy.
        let partials = try sum([bound(row, count: 2), bound(product([row, G.expertsPerToken])),
                                bound(product([rows, maximumPartialBytesPerToken]))])
        let logits = try bound(product([G.vocabularySize, 4]), count: 3)
        let payload = try product([chunk, maximumPartialBytesPerToken])
        let frame = try sum([payload, QwenTensorParallelSealCodec.frameOverhead])
        let request = try sum([state, bound(transientLogical), partials, logits, capture])
        let allowance = try ClusterTensorParallelRequestAllowance(maximumContextTokens: contextTokens,
            maximumChunkTokens: chunk,
            requestBytesExcludingCollectives: sum([request, activationFloorBytes, freedBufferCacheBytes]),
            maximumCollectivePayloadBytes: payload, maximumCollectiveFrameBytes: frame, allocationBound: allocationBound)
        return .init(contextTokens: contextTokens, chunkTokens: chunk, stateBytes: state,
            transientBytes: try bound(transientLogical), partialBytes: partials, logitsBytes: logits,
            prefixCaptureBytes: capture, allowance: allowance)
    }
}
