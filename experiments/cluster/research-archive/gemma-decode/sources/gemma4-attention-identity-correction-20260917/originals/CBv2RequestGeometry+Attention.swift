import Foundation
import MLX
import MLXLMCommon

extension CBv2RequestGeometry {
    /// Shared non-recurrent construction from actual two-phase native probe
    /// observations. This validates state geometry, not model eligibility.
    init(attentionKinds kinds: [CBv2LayerKind], caches: [any CBv2AttendingLayerCache],
         observed: CBv2NativeKVTypeProbe.Result, globalLayerIndices: [Int],
         maximumTokens: Int, maximumChunkTokens: Int) throws {
        guard (1...128).contains(kinds.count), kinds.count == caches.count, kinds.count == globalLayerIndices.count,
              observed.layerDTypes.count == kinds.count, observed.observations.count == kinds.count * 2,
              Set(caches.map { ObjectIdentifier($0) }).count == caches.count else {
            throw ProbeError("Attention geometry requires complete distinct caches and native observations")
        }
        var layers: [LayerAttentionStateLayout.Layer] = []
        for (index, kind) in kinds.enumerated() {
            guard kind.modelLayerIndex == index, kind.sharesKVWithLayer == nil,
                  !kind.hasSinks, !kind.isBidirectional, kind.queryHeads > 0, kind.kvHeads > 0,
                  kind.queryHeads % kind.kvHeads == 0, kind.headDim > 0,
                  caches[index].kind == kind, caches[index].layerIndex == index,
                  caches[index].rows.isEmpty, caches[index] is any KVCache,
                  let element = LayerAttentionStateLayout.Element(rawValue: String(describing: observed.layerDTypes[index])) else {
                throw ProbeError("Attention geometry needs ordinary independent observed storage owners")
            }
            for (phase, count) in [(CBv2NativeKVTypeProbe.Phase.prefill, 2), (.decode, 1)] {
                let values = observed.observations.filter { $0.storageIndex == index && $0.phase == phase }
                guard values.count == 1, let value = values.first, value.modelLayerIndex == index,
                      value.keysDType == observed.layerDTypes[index], value.valuesDType == value.keysDType,
                      value.keysShape == [1, kind.kvHeads, count, kind.headDim], value.valuesShape == value.keysShape else {
                    throw ProbeError("Attention native probe shape/type/phase coverage differs")
                }
            }
            let window: Int?
            switch kind.attention { case .full: window = nil; case .slidingWindow(let value): window = value }
            layers.append(.init(globalIndex: globalLayerIndices[index], kvHeads: kind.kvHeads,
                headDimension: kind.headDim, window: window, element: element))
        }
        let layout = try LayerAttentionStateLayout(layers: layers, maximumTokens: maximumTokens,
            maximumChunkTokens: maximumChunkTokens)
        self.kinds = kinds; self.caches = caches; recurrent = .init(layers: [])
        kvDType = observed.layerDTypes.max(by: { $0.size < $1.size })!
        kvCapacityBytes = layout.conservativeKVCapacityBytes; attentionLayout = layout
    }

    /// Exact Gemma descriptor join. No compact decoder rewrite, shared KV,
    /// payload admission, model construction or execution authorization here.
    init(gemmaStage descriptor: Gemma4StageConstructionDescriptor,
         caches: [any CBv2AttendingLayerCache], observed: CBv2NativeKVTypeProbe.Result,
         maximumTokens: Int, maximumChunkTokens: Int) throws {
        let text = try Gemma4TextMetadata.decode(descriptor.originalConfiguration)
        guard sha256(descriptor.originalConfiguration) == descriptor.sourceConfigurationSHA256,
              caches.count == descriptor.layers.count else { throw ProbeError("Gemma state descriptor/configuration differs") }
        for (index, layer) in descriptor.layers.enumerated() {
            let kind = caches[index].kind, full = layer.kind == .full
            guard layer.localIndex == index, layer.globalIndex == descriptor.sourceLayerStart + index,
                  text.layerKinds.indices.contains(layer.globalIndex),
                  text.layerKinds[layer.globalIndex] == layer.kind,
                  kind.attention == (full ? .full : .slidingWindow(text.slidingWindow)),
                  kind.kvHeads == (full ? text.fullKVHeads : text.slidingKVHeads),
                  kind.headDim == (full ? text.fullHeadDimension : text.slidingHeadDimension),
                  kind.queryHeads == text.queryHeads else { throw ProbeError("Gemma native local/global KV geometry differs") }
        }
        try self.init(attentionKinds: caches.map(\.kind), caches: caches, observed: observed,
            globalLayerIndices: descriptor.layers.map(\.globalIndex),
            maximumTokens: maximumTokens, maximumChunkTokens: maximumChunkTokens)
    }
}
