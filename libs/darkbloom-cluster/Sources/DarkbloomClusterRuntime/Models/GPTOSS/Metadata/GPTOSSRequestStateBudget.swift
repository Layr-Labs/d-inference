import Foundation

/// The named request state of one GPT-OSS stage, in bytes, from registered
/// geometry alone. A ledger of what a request is known to allocate; it is not
/// a whole-process peak and grants nothing.
///
/// A full-attention layer keeps keys and values `[1, heads, tokens, width]` in
/// native BF16 dtype, charged conservatively at four bytes per element, in
/// demand-grown 64-token pages. The full
/// history charges each page allocation separately, its gathered attention
/// view and partial-page copies, never less than the previous contiguous
/// allowance. Sliding layers also charge old/repacked pages and partial-page
/// versions together. Allocator bounds apply per buffer, not to an aggregate
/// of many independently allocated pages. There
/// is no recurrent state. A stage also holds one residual chunk coming or
/// going, and stage 1 one vocabulary row. The workspace term is the largest
/// transient a forward is known to build: one full-attention layer's score
/// matrix for a chunk against the whole history, in float32.
struct GPTOSSRequestStateBudget: Encodable, Equatable {
    static let activationBytes = 4, growthStep = 256
    let fullAttentionLayers: Int, slidingLayers: Int
    let fullAttentionStateBytes: Int, slidingStateBytes: Int
    let boundaryBytes: Int, rowBytes: Int, workspaceBytes: Int
    let reservedBytes: Int

    static func estimate(specification spec: GPTOSSRegisteredSpecification, layers: [GPTOSSLayerStagePlan.Layer],
                         rank: Int, maximumTokens: Int, chunkSize: Int, bound: (Int) throws -> Int) throws -> Self {
        let limits = try spec.contextLimits()
        guard (0...1).contains(rank), !layers.isEmpty, layers.count < spec.layers,
              (1...limits.maximumContextTokens).contains(maximumTokens),
              (1...limits.maximumChunkTokens).contains(chunkSize) else {
            throw GPTOSSProfileError("GPT-OSS request state is outside the registered request scope")
        }
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        func allowance(_ bytes: Int, _ count: Int) throws -> Int {
            let rounded = try bound(bytes)
            guard bytes > 0, rounded >= bytes else { throw GPTOSSProfileError("GPT-OSS allocator bound is invalid") }
            return try product([rounded, count])
        }
        func steps(_ tokens: Int) -> Int { (tokens + growthStep - 1) / growthStep * growthStep }
        let full = layers.filter { $0.kind == GPTOSSRegisteredSpecification.fullAttention }.count
        let sliding = layers.count - full
        // The growing cache can overshoot the frontier by one rounded chunk.
        let capacity = steps(maximumTokens) + steps(chunkSize)
        let window = spec.slidingWindow + chunkSize
        func pair(_ tokens: Int, copies: Int = 4) throws -> Int {
            try allowance(try product([spec.keyValueHeads, tokens, spec.headDimension, activationBytes]), copies)
        }
        func paged(_ tokens: Int, pageCopies: Int) throws -> Int {
            let pageTokens = GPTOSSPagedKVLayout.pageTokens
            let pages = (tokens + pageTokens - 1) / pageTokens
            let pageBytes = try product([spec.keyValueHeads, pageTokens, spec.headDimension, activationBytes])
            // One extra page covers a partial-tail rewrite. Sliding repacking
            // can keep old/new pages and an intermediate partial page version.
            return try sum([try allowance(pageBytes, product([pages + 1, pageCopies])),
                try pair(tokens, copies: 2)])
        }
        let fullPerLayer = try max(pair(capacity), paged(maximumTokens, pageCopies: 2))
        let slidingPerLayer = try max(pair(window), paged(window, pageCopies: 6))
        let fullState = try product([fullPerLayer, full])
        let slidingState = try product([slidingPerLayer, sliding])
        let boundary = try allowance(try product([chunkSize, spec.hidden, activationBytes]), 2)
        let row = rank == 1 ? try allowance(try product([spec.vocabulary, 4]), 2) : 0
        let workspace = full == 0 ? 0 : try allowance(try product([spec.queryHeads, chunkSize, capacity, 4]), 1)
        return .init(fullAttentionLayers: full, slidingLayers: sliding, fullAttentionStateBytes: fullState,
            slidingStateBytes: slidingState, boundaryBytes: boundary, rowBytes: row, workspaceBytes: workspace,
            reservedBytes: try sum([fullState, slidingState, boundary, row, workspace]))
    }
}
