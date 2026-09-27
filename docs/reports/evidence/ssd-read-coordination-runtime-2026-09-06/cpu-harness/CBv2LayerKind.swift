public struct CBv2LayerKind: Sendable, Equatable {
    public enum Attention: Sendable, Equatable {
        case full
        /// Sliding-window attention with the given window (in tokens).
        case slidingWindow(Int)
    }
    public var attention: Attention
    /// Layer index whose K/V this layer reuses (Gemma-4 cross-layer KV
    /// sharing). A shared layer owns NO storage; it borrows (K, V) and the
    /// position offset from the source layer at attention time.
    public var sharesKVWithLayer: Int?
    /// Multi-token prompt attention is bidirectional within the current
    /// chunk. Cached prefix columns retain their established visibility;
    /// decode remains unchanged because no future keys exist yet.
    public var isBidirectional: Bool
    /// Learned per-head attention sinks (GPT-OSS). Sinks are a kernel
    /// parameter (folded into the softmax denominator), never KV state.
    /// A backend that cannot honor sinks MUST be statically ineligible for
    /// models with `hasSinks == true` (it must throw at engine build).
    public var hasSinks: Bool
    public var headDim: Int
    public var kvHeads: Int
    public var queryHeads: Int
    /// Original transformer-layer index when the CBv2 storage layout is a
    /// compact subset of the model layers (for example, hybrid recurrent +
    /// full-attention trunks). nil preserves the historical identity mapping:
    /// storage index == model layer index.
    public var modelLayerIndex: Int?

    public init(
        attention: Attention, sharesKVWithLayer: Int? = nil, hasSinks: Bool = false,
        isBidirectional: Bool = false,
        headDim: Int, kvHeads: Int, queryHeads: Int, modelLayerIndex: Int? = nil
    ) {
        self.attention = attention
        self.sharesKVWithLayer = sharesKVWithLayer
        self.hasSinks = hasSinks
        self.isBidirectional = isBidirectional
        self.headDim = headDim
        self.kvHeads = kvHeads
        self.queryHeads = queryHeads
        self.modelLayerIndex = modelLayerIndex
    }
}

