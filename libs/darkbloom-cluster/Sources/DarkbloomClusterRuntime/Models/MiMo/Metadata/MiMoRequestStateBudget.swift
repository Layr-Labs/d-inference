import Foundation

/// The named request state of one MiMo stage, in bytes, from registered
/// geometry alone. A ledger of what a request is known to allocate; it is not
/// a whole-process peak and grants nothing.
///
/// A full-attention layer keeps keys `[1, heads, tokens, keyWidth]` and values
/// `[1, heads, tokens, valueWidth]` in the activation dtype; the class's
/// growing cache extends them in steps of 256 tokens and holds the old and the
/// new buffer while it does. A sliding-window layer keeps at most the window
/// plus the chunk just appended, the same way. A stage also holds one residual
/// chunk coming or going, and stage 1 one vocabulary row. The workspace term
/// is the largest transient a forward is known to build: one full-attention
/// layer's score matrix for a chunk against the whole history, in float32.
struct MiMoRequestStateBudget: Encodable, Equatable {
    static let activationBytes = 2, growthStep = 256
    let fullAttentionLayers: Int, slidingLayers: Int
    let fullAttentionStateBytes: Int, slidingStateBytes: Int
    let boundaryBytes: Int, rowBytes: Int, workspaceBytes: Int
    /// A phase split's moving state: the producer's state, held a second time
    /// while it is exported, sent and adopted. Zero otherwise.
    var handoffBytes = 0
    let reservedBytes: Int

    init(fullAttentionLayers: Int, slidingLayers: Int, fullAttentionStateBytes: Int, slidingStateBytes: Int,
         boundaryBytes: Int, rowBytes: Int, workspaceBytes: Int, handoffBytes: Int = 0, reservedBytes: Int) {
        self.fullAttentionLayers = fullAttentionLayers; self.slidingLayers = slidingLayers
        self.fullAttentionStateBytes = fullAttentionStateBytes; self.slidingStateBytes = slidingStateBytes
        self.boundaryBytes = boundaryBytes; self.rowBytes = rowBytes; self.workspaceBytes = workspaceBytes
        self.handoffBytes = handoffBytes; self.reservedBytes = reservedBytes
    }

    /// The same budget with a phase split's moving state charged on top.
    func adding(handoffBytes extra: Int) throws -> Self {
        guard extra >= 0, handoffBytes == 0 else { throw MiMoProfileError("MiMo hand-off charge is invalid") }
        return .init(fullAttentionLayers: fullAttentionLayers, slidingLayers: slidingLayers,
            fullAttentionStateBytes: fullAttentionStateBytes, slidingStateBytes: slidingStateBytes,
            boundaryBytes: boundaryBytes, rowBytes: rowBytes, workspaceBytes: workspaceBytes, handoffBytes: extra,
            reservedBytes: try QwenLongPrefillCheckedBytes.sum([reservedBytes, extra]))
    }

    static func estimate(specification spec: MiMoRegisteredSpecification, layers: Range<Int>, rank: Int,
                         maximumTokens: Int, chunkSize: Int, bound: (Int) throws -> Int) throws -> Self {
        let limits = try spec.contextLimits()
        guard (0...1).contains(rank), !layers.isEmpty, layers.lowerBound >= 0, layers.upperBound <= spec.layers,
              (1...limits.maximumContextTokens).contains(maximumTokens),
              (1...limits.maximumChunkTokens).contains(chunkSize) else {
            throw MiMoProfileError("MiMo request state is outside the registered request scope")
        }
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        func allowance(_ bytes: Int, _ count: Int) throws -> Int {
            let rounded = try bound(bytes)
            guard bytes > 0, rounded >= bytes else { throw MiMoProfileError("MiMo allocator bound is invalid") }
            return try product([rounded, count])
        }
        let full = layers.filter(spec.fullAttentionLayers.contains).count, sliding = layers.count - full
        let capacity = (maximumTokens + growthStep - 1) / growthStep * growthStep
        let window = spec.slidingWindow + chunkSize
        func pair(_ heads: Int, _ tokens: Int) throws -> Int {
            // Keys and values, each held twice while the cache grows.
            try sum([allowance(try product([heads, tokens, spec.keyWidth, activationBytes]), 2),
                     allowance(try product([heads, tokens, spec.valueWidth, activationBytes]), 2)])
        }
        let fullState = full == 0 ? 0 : try product([try pair(spec.fullKeyValueHeads, capacity), full])
        let slidingState = sliding == 0 ? 0 : try product([try pair(spec.slidingKeyValueHeads, window), sliding])
        let boundary = try allowance(try product([chunkSize, spec.hidden, activationBytes]), 2)
        let row = rank == 1 ? try allowance(try product([spec.vocabulary, 4]), 2) : 0
        // 64 query heads; the registered attention geometry fixes it.
        let workspace = full == 0 ? 0 : try allowance(try product([64, chunkSize, capacity, 4]), 1)
        return .init(fullAttentionLayers: full, slidingLayers: sliding, fullAttentionStateBytes: fullState,
            slidingStateBytes: slidingState, boundaryBytes: boundary, rowBytes: row, workspaceBytes: workspace,
            reservedBytes: try sum([fullState, slidingState, boundary, row, workspace]))
    }
}
