import Foundation

/// The named request state of one GPT-OSS stage, in bytes, from registered
/// geometry alone. A ledger of what a request is known to allocate; it is not
/// a whole-process peak and grants nothing.
///
/// A full-attention layer keeps keys and values `[1, heads, tokens, width]` in
/// the activation dtype; the class's growing cache extends them in steps of
/// 256 tokens (a prompt chunk extends by the chunk rounded up to a step) and
/// holds the old and the new buffer while it does. A sliding-window layer
/// keeps at most the window plus the chunk just appended, the same way. There
/// is no recurrent state. A stage also holds one residual chunk coming or
/// going, and stage 1 one vocabulary row. The workspace term is the largest
/// transient a forward is known to build: one full-attention layer's score
/// matrix for a chunk against the whole history, in float32.
struct GPTOSSRequestStateBudget: Encodable, Equatable {
    static let activationBytes = 2, growthStep = 256
    let fullAttentionLayers: Int, slidingLayers: Int
    let fullAttentionStateBytes: Int, slidingStateBytes: Int
    let boundaryBytes: Int, rowBytes: Int, workspaceBytes: Int
    let reservedBytes: Int

    static func estimate(specification spec: GPTOSSRegisteredSpecification, layers: [GPTOSSLayerStagePlan.Layer],
                         rank: Int, maximumTokens: Int, chunkSize: Int, bound: (Int) throws -> Int) throws -> Self {
        guard (0...1).contains(rank), !layers.isEmpty, layers.count < spec.layers,
              (1...GPTOSSRegisteredSpecification.maximumContextTokens).contains(maximumTokens),
              (1...GPTOSSRegisteredSpecification.maximumChunkTokens).contains(chunkSize) else {
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
        func pair(_ tokens: Int) throws -> Int {
            // Keys and values, each held twice while the cache grows or reorders.
            try allowance(try product([spec.keyValueHeads, tokens, spec.headDimension, activationBytes]), 4)
        }
        let fullState = full == 0 ? 0 : try product([try pair(capacity), full])
        let slidingState = sliding == 0 ? 0 : try product([try pair(window), sliding])
        let boundary = try allowance(try product([chunkSize, spec.hidden, activationBytes]), 2)
        let row = rank == 1 ? try allowance(try product([spec.vocabulary, 4]), 2) : 0
        let workspace = full == 0 ? 0 : try allowance(try product([spec.queryHeads, chunkSize, capacity, 4]), 1)
        return .init(fullAttentionLayers: full, slidingLayers: sliding, fullAttentionStateBytes: fullState,
            slidingStateBytes: slidingState, boundaryBytes: boundary, rowBytes: row, workspaceBytes: workspace,
            reservedBytes: try sum([fullState, slidingState, boundary, row, workspace]))
    }
}
