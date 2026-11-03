import DarkbloomClusterPlacement
import Foundation

/// What a MiMo tensor-parallel rank holds beside its weights, as its LOAD and
/// request gates charge it (`MiMoTensorParallelResidentRuntime`) and the
/// planner quotes it (`ClusterTensorParallelFamilyPlan.requestAllowance`), from
/// the plan's per-rank geometry. A conservative charge, not a measured one: no
/// hardware has measured a MiMo tensor-parallel rank. Every array is charged at
/// the allocator's bound.
///
/// Per request (`requestBytes`, what a reservation charges at its own context):
/// - Paged KV (`MiMoV26IndependentHistoryCache`, 64-token BF16 pages) at this
///   rank's KV heads and widths: a full layer holds the whole context; a
///   sliding layer at most its window plus a chunk, charged twice (a chunk's
///   append rewrites the kept rows into new pages while the old ones live).
/// - Every layer's gathered history at once, and the widest again: attention
///   reads a layer's pages concatenated, and a decode step's 100-operation
///   command buffers (`MiMoTensorParallelDecoding.decodeCommandBuffers`) keep
///   the whole step in flight.
/// - One chunk's activations: the residual and its normed rows, this rank's
///   query, key and value rows and attention output, its selected experts'
///   gate/up rows and layer 0's dense ones.
/// - The chunk's FP32 partials: the attention and feed-forward rows, the sum's
///   output, and the 8 selected experts' rows before the local combine.
/// - The full layers' attention scores at this rank's query heads (FP32), as
///   if materialized: one chunk against the context, and never less than
///   every full layer's decode row at once (the step in flight).
/// - The head: this rank's logits, the gathered whole row and the top-k (FP32).
///
/// Once per rank (`rankBytes`): the conservative activation floor until
/// hardware measures one for a MiMo tensor-parallel rank (5.5 GiB, the
/// provider's default reserve, as GLM's and Gemma's ranks keep), the
/// freed-buffer cache a ready rank keeps, and eight sealed frames of a chunk's
/// partial (`ClusterTensorParallelRequestAllowance`).
struct MiMoTensorParallelRequestBudget: Equatable, Sendable {
    static let pageTokens = 64
    /// `UnifiedMemoryCap.defaultActivationReserveBytes`: 5.5 GiB. A measured
    /// constant replaces it once a pair measures a rank's peak.
    static let activationFloorBytes = 11 * 1024 * 1024 * 1024 / 2
    /// The freed-buffer cache a ready rank keeps, as GLM tensor parallel keeps
    /// it (serving at zero halved GLM's throughput). Charged under every
    /// allocator policy: the planner does not know which one a rank runs.
    static let freedBufferCacheBytes = 4 << 30

    let contextTokens: Int
    let chunkTokens: Int
    let historyBytes: Int
    let activationBytes: Int
    let partialBytes: Int
    let scoreBytes: Int
    let headBytes: Int
    let allowance: ClusterTensorParallelRequestAllowance

    /// What one request of `contextTokens` reserves on a rank.
    var requestBytes: Int { historyBytes + activationBytes + partialBytes + scoreBytes + headBytes }
    /// What a rank holds once beside every request it serves.
    var rankBytes: Int { Self.activationFloorBytes + Self.freedBufferCacheBytes + allowance.collectiveScratchBytes }

    static func derive(plan: MiMoTensorParallelPlan, slidingWindow: Int, contextTokens: Int, chunkTokens: Int,
                       allocationBound: (Int) throws -> Int) throws -> Self {
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        guard slidingWindow > 0, contextTokens > 0, chunkTokens > 0 else {
            throw ProbeError("MiMo tensor-parallel request budget needs a window, a context and a chunk")
        }
        let chunk = min(contextTokens, chunkTokens)
        func bound(_ logical: Int, count: Int = 1) throws -> Int {
            let allocated = try allocationBound(logical)
            guard logical > 0, allocated >= logical, count >= 0 else {
                throw ProbeError("MiMo tensor-parallel request allocator bound is invalid")
            }
            return try product([allocated, count])
        }
        var pages = 0, gathered = 0, widest = 0, fullLayers = 0
        for layer in 0 ..< plan.layerCount {
            let sliding = plan.slidingLayers[layer]
            let rowBytes = try product([plan.kvHeads(layer: layer) / plan.size,
                                        plan.headDim(layer: layer) + plan.valueHeadDim(layer: layer), 2])
            let rows = sliding ? min(contextTokens, slidingWindow - 1 + chunk) : contextTokens
            let paged = try bound(product([(rows + pageTokens - 1) / pageTokens, pageTokens, rowBytes]))
            let view = try bound(product([rows, rowBytes]))
            pages = try sum([pages, product([paged, sliding ? 2 : 1])])
            gathered = try sum([gathered, view])
            widest = max(widest, view)
            if !sliding { fullLayers += 1 }
        }
        let hidden = plan.hiddenSize
        let queries = (0 ..< plan.layerCount).map { plan.queryHeads(layer: $0) / plan.size }.max() ?? 0
        let width = (0 ..< plan.layerCount).map { plan.headDim(layer: $0) + plan.valueHeadDim(layer: $0) }.max() ?? 0
        let perToken = try sum([
            product([hidden, 2, 2]),                                         // residual and normed rows
            product([queries, width, 2, 2]),                                 // q/k/v rows and attention output
            product([plan.expertsPerToken, plan.expertWidth / plan.size, 2, 4]),  // selected experts' gate/up
            product([plan.denseWidth / plan.size, 2, 2]),                    // layer 0's gate/up
        ])
        let row = try product([chunk, hidden, 4])
        // The attention and feed-forward partials and the sum's output; the selected experts' rows.
        let partials = try sum([bound(row, count: 3), bound(product([row, plan.expertsPerToken]))])
        let scores = fullLayers == 0 ? 0
            : try bound(product([max(chunk, fullLayers), contextTokens, queries, 4]))
        let head = try bound(product([plan.vocabularySize, 4]), count: 2 + plan.size)
        let history = try sum([pages, gathered, widest])
        let activations = try bound(product([chunk, perToken]))
        let payload = try product([chunk, plan.partialBytesPerToken])
        let frame = try sum([payload, QwenTensorParallelSealCodec.frameOverhead])
        let request = try sum([history, activations, partials, scores, head])
        let allowance = try ClusterTensorParallelRequestAllowance(maximumContextTokens: contextTokens,
            maximumChunkTokens: chunk,
            requestBytesExcludingCollectives: sum([request, activationFloorBytes, freedBufferCacheBytes]),
            maximumCollectivePayloadBytes: payload, maximumCollectiveFrameBytes: frame, allocationBound: allocationBound)
        return .init(contextTokens: contextTokens, chunkTokens: chunk, historyBytes: history, activationBytes: activations,
            partialBytes: partials, scoreBytes: scores, headBytes: head, allowance: allowance)
    }
}
