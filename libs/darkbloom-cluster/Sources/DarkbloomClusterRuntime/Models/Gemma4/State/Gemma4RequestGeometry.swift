import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon

extension CBv2RequestGeometry {
    /// A Gemma stage's request state: one attention row per local layer and no
    /// recurrent state. A full-attention layer keeps every committed token; a
    /// sliding layer keeps a ring of its window. Kinds are already keyed by the
    /// stage's own storage index.
    init(gemma4StageKinds kinds: [CBv2LayerKind], kvDType: DType, maximumTokens: Int) throws {
        try self.init(gemma4Kinds: kinds, layerLimit: Gemma4StageGeometry.layerCount, kvDType: kvDType,
            maximumTokens: maximumTokens, slidingWindow: Gemma4StageGeometry.slidingWindow,
            queryHeads: Gemma4StageGeometry.queryHeads,
            full: (Gemma4StageGeometry.fullKVHeads, Gemma4StageGeometry.fullHeadDimension),
            sliding: (Gemma4StageGeometry.slidingKVHeads, Gemma4StageGeometry.slidingHeadDimension))
    }

    /// One tensor-parallel rank's request state over every layer of the
    /// model `plan` splits (`ranks` = the plan's size): each layer keeps this
    /// rank's own KV heads (26B: 4 of 8 sliding, 1 of 2 full) at the plan's
    /// head widths. `ranks` 1 is the whole model's (the oracle's).
    init(gemma4TensorParallelKinds kinds: [CBv2LayerKind], plan: Gemma4TensorParallelPlan, ranks: Int,
         slidingWindow: Int, kvDType: DType, maximumTokens: Int) throws {
        guard [1, plan.size].contains(ranks), kinds.count == plan.layerCount,
              zip(kinds, plan.layerKinds).allSatisfy({ kind, planned in
                  if case .full = kind.attention { return planned == .full }
                  return planned == .sliding
              }) else {
            throw ProbeError("Gemma tensor-parallel state needs one row per layer of the plan, of the plan's kind")
        }
        try self.init(gemma4Kinds: kinds, layerLimit: plan.layerCount, kvDType: kvDType, maximumTokens: maximumTokens,
            slidingWindow: slidingWindow, queryHeads: plan.queryHeads / ranks,
            full: (plan.fullKVHeads / ranks, plan.fullHeadDim),
            sliding: (plan.slidingKVHeads / ranks, plan.slidingHeadDim))
    }

    private init(gemma4Kinds kinds: [CBv2LayerKind], layerLimit: Int, kvDType: DType, maximumTokens: Int,
                 slidingWindow: Int, queryHeads: Int, full: (kvHeads: Int, headDim: Int),
                 sliding: (kvHeads: Int, headDim: Int)) throws {
        // Any context the wire carries: the profile holds a request to the
        // model's own, and its host's bound to the longest the rank serves.
        guard !kinds.isEmpty, kinds.count <= layerLimit,
              (1...ClusterWorkerLimits.wireContextTokens).contains(maximumTokens), [.float16, .bfloat16, .float32].contains(kvDType),
              kinds.enumerated().allSatisfy({ $0.element.modelLayerIndex == $0.offset }) else {
            throw ProbeError("Gemma stage state requires bounded tokens, a native dtype and local layer indices")
        }
        var capacity = 0
        for kind in kinds {
            let tokens: Int
            switch kind.attention {
            case .full:
                guard kind.kvHeads == full.kvHeads, kind.headDim == full.headDim else {
                    throw ProbeError("Gemma full-attention state geometry differs")
                }
                tokens = maximumTokens
            case .slidingWindow(let window):
                guard window == slidingWindow, kind.kvHeads == sliding.kvHeads, kind.headDim == sliding.headDim else {
                    throw ProbeError("Gemma sliding-attention state geometry differs")
                }
                // The ring is allocated whole at the first write.
                tokens = window
            }
            guard kind.sharesKVWithLayer == nil, !kind.hasSinks, !kind.isBidirectional,
                  kind.valueHeadDim == kind.headDim, kind.queryHeads == queryHeads else {
                throw ProbeError("Unsupported Gemma attention cache geometry")
            }
            // Keys and values, each `[1, kvHeads, tokens, headDim]`.
            capacity = try QwenLongPrefillCheckedBytes.sum([capacity,
                QwenLongPrefillCheckedBytes.product([2, tokens, kind.kvHeads, kind.headDim, kvDType.size])])
        }
        self.kinds = kinds
        caches = kinds.enumerated().map { CBv2LayerCache(layerIndex: $0.offset, kind: $0.element) }
        recurrent = CBv2RecurrentStateSpec(layers: [])
        self.kvDType = kvDType
        kvCapacityBytes = capacity
        // Every Gemma layer owns attention state.
        layerCount = kinds.count
    }

    /// This geometry on a stage's KV host (its batch lanes): the host's caches
    /// and backend, which were built for exactly these layers.
    init(gemma4Stage geometry: CBv2RequestGeometry, host: CBv2StageKVHost, maximumTokens: Int) throws {
        guard host.layerKinds == geometry.kinds, host.caches.count == geometry.kinds.count,
              host.kvDType == geometry.kvDType, maximumTokens <= host.maximumTokensPerRequest else {
            throw ProbeError("Stage KV host differs from this Gemma stage's layers or request bound")
        }
        kinds = geometry.kinds; caches = host.caches; recurrent = geometry.recurrent
        kvDType = geometry.kvDType; kvCapacityBytes = geometry.kvCapacityBytes
        layerCount = geometry.layerCount; self.host = host
    }
}
