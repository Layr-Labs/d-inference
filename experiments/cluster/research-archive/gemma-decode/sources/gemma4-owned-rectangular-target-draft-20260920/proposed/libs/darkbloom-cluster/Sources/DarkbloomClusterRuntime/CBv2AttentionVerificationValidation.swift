import MLX
import MLXLMCommon

extension CBv2OwnedRequestState {
    /// Pending chronology is different from the ordinary committed window.
    /// Validate scalar/shape metadata, never snapshot/copy the entire KV here.
    func validatePendingAttention(_ plan: CBv2AttentionVerificationPlan, frontier: Int) throws {
        guard geometry.attentionLayout == plan.layout, geometry.recurrent.layers.isEmpty,
              recurrent.spec.layers.isEmpty, recurrent.materializedByteCount == 0,
              recurrent.confirmedStateSnapshot() == nil, committedTokens == plan.base,
              frontier == plan.base + plan.steps, rows.count == plan.layout.layers.count,
              geometry.caches.count == rows.count, backend.bytesCapacity == plan.backendCapacityBytes,
              backend.bytesInUse <= plan.backendCapacityBytes,
              backend.bytesReserved <= plan.backendCapacityBytes else {
            throw ProbeError("Pending attention state exceeded its separately admitted transaction")
        }
        for index in rows.indices {
            guard let row = rows[index], let source = row as? any CBv2ContiguousKVMetadataProviding,
                  geometry.caches[index].rows.count == 1, geometry.caches[index].rows[0] === row,
                  geometry.caches[index].positionOffsets.shape == [1],
                  geometry.caches[index].positionOffsets.dtype == .int32,
                  geometry.caches[index].positionOffsets.asArray(Int32.self) == [Int32(frontier)] else {
                throw ProbeError("Pending attention cache lost row identity or device frontier")
            }
            let value = source.cbv2ContiguousMetadata, layer = plan.layout.layers[index]
            guard value.absoluteOffset == frontier, value.window == layer.window,
                  let keys = value.keys, let values = value.values else { throw ProbeError("Pending attention lacks storage") }
            let slots = keys.shape.count == 4 ? keys.shape[2] : -1
            func requirePair(_ k: CBv2ContiguousKVMetadata.Tensor, _ v: CBv2ContiguousKVMetadata.Tensor,
                             count: Int) throws {
                guard count >= 0, k.shape == [1, layer.kvHeads, count, layer.headDimension], v.shape == k.shape,
                      String(describing: k.dtype) == layer.element.rawValue, v.dtype == k.dtype,
                      k.bytes == (try LayerAttentionStateLayout.bytes(layer, tokens: count, elementBytes: layer.element.bytes) / 2),
                      v.bytes == k.bytes else { throw ProbeError("Pending attention tensor differs from observed layout") }
            }
            if let window = layer.window {
                guard slots == window, value.speculativeWritePending, value.stagedBaseOffset == plan.base,
                      value.retainedStart == max(0, plan.base - window),
                      value.retainedCount == frontier - max(0, plan.base - window),
                      let stagedK = value.stagedKeys, let stagedV = value.stagedValues,
                      let chunkK = value.retainedChunkKeys, let chunkV = value.retainedChunkValues else {
                    throw ProbeError("Pending window chronology or staged backing differs")
                }
                try requirePair(stagedK, stagedV, count: plan.steps)
                try requirePair(chunkK, chunkV, count: min(plan.base, window - 1) + plan.steps)
            } else {
                guard (frontier...plan.layout.maximumTokens).contains(slots), !value.speculativeWritePending,
                      value.retainedStart == 0, value.retainedCount == frontier,
                      value.stagedBaseOffset == nil, value.stagedKeys == nil, value.stagedValues == nil,
                      value.retainedChunkKeys == nil, value.retainedChunkValues == nil else {
                    throw ProbeError("Pending full-attention prefix differs")
                }
            }
            try requirePair(keys, values, count: slots)
        }
    }
}
