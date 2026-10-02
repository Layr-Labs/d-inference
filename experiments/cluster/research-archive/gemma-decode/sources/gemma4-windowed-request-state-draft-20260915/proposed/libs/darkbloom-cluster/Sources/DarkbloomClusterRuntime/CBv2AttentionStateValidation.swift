import MLX
import MLXLMCommon

extension CBv2OwnedRequestState {
    /// Healthy validation reads only small scalar/shape/type metadata and the
    /// one-element device position. Never call row.snapshot() in this path.
    func validateAttentionState(_ layout: LayerAttentionStateLayout, after count: Int) throws {
        guard geometry.recurrent.layers.isEmpty, recurrent.spec.layers.isEmpty,
              recurrent.materializedByteCount == 0, recurrent.confirmedStateSnapshot() == nil,
              rows.count == layout.layers.count, geometry.caches.count == rows.count,
              count > 0 else { throw ProbeError("Attention-only state has unexpected recurrent or row ownership") }
        for index in rows.indices {
            guard let row = rows[index], let source = row as? any CBv2ContiguousKVMetadataProviding,
                  geometry.caches[index].rows.count == 1, geometry.caches[index].rows[0] === row,
                  geometry.caches[index].positionOffsets.shape == [1],
                  geometry.caches[index].positionOffsets.dtype == .int32,
                  geometry.caches[index].positionOffsets.asArray(Int32.self) == [Int32(count)] else {
                throw ProbeError("Attention cache lost its owned row or absolute device position")
            }
            try layout.validate(source.cbv2ContiguousMetadata, layer: index, frontier: count)
        }
        guard backend.bytesInUse <= layout.conservativeKVCapacityBytes,
              backend.bytesReserved <= layout.conservativeKVCapacityBytes else {
            throw ProbeError("Attention KV exceeds its conservative admitted capacity")
        }
    }
}

extension LayerAttentionStateLayout {
    func validate(_ value: CBv2ContiguousKVMetadata, layer index: Int, frontier: Int) throws {
        let expected = try range(layer: index, frontier: frontier), layer = layers[index]
        guard !value.speculativeWritePending, value.absoluteOffset == frontier,
              value.retainedStart == expected.lowerBound, value.retainedCount == expected.count,
              value.window == layer.window, let keys = value.keys, let values = value.values else {
            throw ProbeError("Attention logical chronology/window differs from committed frontier")
        }
        let slots = keys.shape.count == 4 ? keys.shape[2] : -1
        guard (layer.window.map { slots == $0 } ?? ((frontier...maximumTokens).contains(slots))),
              keys.shape == [1, layer.kvHeads, slots, layer.headDimension], values.shape == keys.shape,
              String(describing: keys.dtype) == layer.element.rawValue, values.dtype == keys.dtype,
              keys.bytes == (try Self.bytes(layer, tokens: slots, elementBytes: layer.element.bytes) / 2),
              values.bytes == keys.bytes else { throw ProbeError("Attention physical geometry/type differs from observation") }
        if let window = layer.window {
            guard (value.retainedChunkKeys == nil) == (value.retainedChunkValues == nil) else {
                throw ProbeError("Attention retained chunk views are asymmetric")
            }
            if let k = value.retainedChunkKeys, let v = value.retainedChunkValues {
                let tokens = k.shape.count == 4 ? k.shape[2] : -1
                guard (1...(window - 1 + maximumChunkTokens)).contains(tokens),
                      k.shape == [1, layer.kvHeads, tokens, layer.headDimension], v.shape == k.shape,
                      k.dtype == keys.dtype, v.dtype == values.dtype,
                      k.bytes == (try Self.bytes(layer, tokens: tokens, elementBytes: layer.element.bytes) / 2),
                      v.bytes == k.bytes else { throw ProbeError("Attention retained chunk exceeds bounded window geometry") }
            }
        } else if value.retainedChunkKeys != nil || value.retainedChunkValues != nil {
            throw ProbeError("Full attention unexpectedly retains window chunk views")
        }
    }
}
