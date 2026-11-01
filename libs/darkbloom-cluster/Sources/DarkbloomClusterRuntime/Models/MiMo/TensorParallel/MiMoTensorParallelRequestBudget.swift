import Foundation

/// What one request costs one MiMo tensor-parallel rank, from the plan's
/// per-rank geometry: a conservative charge, not a measured one (no hardware
/// has measured a MiMo tensor-parallel rank). Each buffer is rounded up to
/// the allocator's bound.
///
/// - Paged KV (`MiMoV26IndependentHistoryCache`, 64-token BF16 pages): a
///   full layer holds the whole context at this rank's KV heads and widths;
///   a sliding layer at most its window plus a chunk, charged twice (a chunk's
///   append rewrites the kept rows into new pages while the old ones live).
///   One layer's gathered history (attention reads the pages concatenated),
///   twice.
/// - Activations of one chunk: the residual and its FP32 partial, this
///   rank's query, key and value rows and attention output, its experts'
///   gate/up rows for every selected expert, and the full layers' attention
///   scores over the context at this rank's query heads (FP32), as if
///   materialized.
/// - The head: this rank's logits and the gathered whole row, FP32, twice.
struct MiMoTensorParallelRequestBudget: Equatable, Sendable {
    static let pageTokens = 64
    let plan: MiMoTensorParallelPlan
    let slidingWindow: Int

    init(plan: MiMoTensorParallelPlan, slidingWindow: Int) throws {
        guard slidingWindow > 0 else { throw ProbeError("MiMo tensor-parallel request budget needs a sliding window") }
        self.plan = plan; self.slidingWindow = slidingWindow
    }

    /// This rank's paged KV bytes for `contextTokens` (chunks of `chunk`).
    func historyBytes(contextTokens: Int, chunk: Int,
                      allocationBound: (Int) throws -> Int = QwenResidentResourceEnvironment.allocationBound) throws -> Int {
        typealias Bytes = QwenLongPrefillCheckedBytes
        guard contextTokens > 0, chunk > 0 else { throw ProbeError("MiMo tensor-parallel request budget needs a context") }
        var total = 0, widest = 0
        for layer in 0 ..< plan.layerCount {
            let rowBytes = try Bytes.product([plan.kvHeads(layer: layer) / plan.size,
                plan.headDim(layer: layer) + plan.valueHeadDim(layer: layer), 2])
            let rows = plan.slidingLayers[layer] ? min(contextTokens, slidingWindow - 1 + chunk) : contextTokens
            let pages = (rows + Self.pageTokens - 1) / Self.pageTokens
            let paged = try allocationBound(try Bytes.product([pages, Self.pageTokens, rowBytes]))
            total = try Bytes.sum([total, try Bytes.product([paged, plan.slidingLayers[layer] ? 2 : 1])])
            widest = max(widest, try allocationBound(try Bytes.product([rows, rowBytes])))
        }
        return try Bytes.sum([total, try Bytes.product([widest, 2])])
    }

    /// One chunk's activations and the head's rows on this rank.
    func workspaceBytes(contextTokens: Int, chunk: Int,
                        allocationBound: (Int) throws -> Int = QwenResidentResourceEnvironment.allocationBound) throws -> Int {
        typealias Bytes = QwenLongPrefillCheckedBytes
        let hidden = plan.hiddenSize
        let queries = (0 ..< plan.layerCount).map { plan.queryHeads(layer: $0) / plan.size }.max() ?? 0
        let width = (0 ..< plan.layerCount).map { plan.headDim(layer: $0) + plan.valueHeadDim(layer: $0) }.max() ?? 0
        let perToken = try Bytes.sum([
            try Bytes.product([hidden, 4, 4]),                              // residual, normed, two FP32 partials
            try Bytes.product([queries, width, 2, 2]),                       // q/k/v rows and attention output
            try Bytes.product([plan.expertsPerToken, plan.expertWidth / plan.size, 2, 4]),  // gate/up, FP32 combine
            try Bytes.product([plan.denseWidth / plan.size, 2, 2]),          // the dense layer's gate/up
        ])
        let scores = try Bytes.product([chunk, contextTokens, queries, 4])
        let head = try Bytes.product([plan.vocabularySize, 4, 2 + plan.size])
        return try Bytes.sum([try allocationBound(try Bytes.product([chunk, perToken])), try allocationBound(scores),
                              try allocationBound(head)])
    }

    func bytes(contextTokens: Int, chunk: Int,
               allocationBound: (Int) throws -> Int = QwenResidentResourceEnvironment.allocationBound) throws -> Int {
        try QwenLongPrefillCheckedBytes.sum([
            try historyBytes(contextTokens: contextTokens, chunk: chunk, allocationBound: allocationBound),
            try workspaceBytes(contextTokens: contextTokens, chunk: chunk, allocationBound: allocationBound)])
    }
}
