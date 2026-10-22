#if CBV2_WINDOW_STATE_FIXTURE
import Foundation
import MLX
import MLXLMCommon

/// Fixed synthetic attention inputs, with no registered model or weight receipt.
enum WindowedStateFixtureModel {
    static let maximumTokens = 32, maximumChunk = 7, window = 4
    static let globals = [5, 6]
    static let kinds: [CBv2LayerKind] = [
        .init(attention: .full, headDim: 32, kvHeads: 1, queryHeads: 2, modelLayerIndex: 0),
        .init(attention: .slidingWindow(window), headDim: 64, kvHeads: 2, queryHeads: 4, modelLayerIndex: 1),
    ]
    static let dtypes: [DType] = [.bfloat16, .float32]

    static func value(position: Int, head: Int, dimension: Int, values: Bool, constant: Bool) -> Float {
        // These small integers and halves are exactly representable in BF16.
        Float((constant ? 0 : position) * 2 + head + (values ? 1 : 0)) + Float(dimension % 2) * 0.5
    }

    static func tensor(kind: CBv2LayerKind, start: Int, count: Int, dtype: DType,
                       values: Bool, constant: Bool = false) -> MLXArray {
        let data = (0..<kind.kvHeads).flatMap { head in
            (start..<(start + count)).flatMap { position in
                (0..<kind.headDim).map { dimension in
                    value(position: position, head: head, dimension: dimension, values: values, constant: constant)
                }
            }
        }
        return MLXArray(data).reshaped([1, kind.kvHeads, count, kind.headDim]).asType(dtype)
    }

    static func forward(caches: [any CBv2AttendingLayerCache], count: Int,
                        dtypes: [DType] = WindowedStateFixtureModel.dtypes, constant: Bool = false) throws -> MLXArray {
        guard caches.count == kinds.count, dtypes.count == kinds.count else { throw ProbeError("Fixture cache coverage differs") }
        var result = MLXArray(Float(0))
        for (index, cache) in caches.enumerated() {
            let kind = kinds[index], start = Int(cache.positionOffsets.item(Int32.self))
            guard cache.kind == kind, (0...maximumTokens).contains(start), count > 0,
                  count <= maximumChunk, start <= maximumTokens - count else { throw ProbeError("Fixture forward exceeds fixed geometry") }
            let keys = tensor(kind: kind, start: start, count: count, dtype: dtypes[index], values: false, constant: constant)
            let values = tensor(kind: kind, start: start, count: count, dtype: dtypes[index], values: true, constant: constant)
            let queries = MLXArray.zeros([1, kind.queryHeads, count, kind.headDim], dtype: dtypes[index])
            result = result + cache.updateAndAttend(queries: queries, keys: keys, values: values,
                scale: 1, sinks: nil).sum().asType(.float32)
        }
        return result
    }

    static func geometry(check: () throws -> Void) throws -> CBv2RequestGeometry {
        try check()
        let caches: [any CBv2AttendingLayerCache] = kinds.enumerated().map { CBv2LayerCache(layerIndex: $0.offset, kind: $0.element) }
        let observed = try CBv2NativeKVTypeProbe.run(layerKinds: kinds, caches: caches) { _, count, bound in
            try check()
            return try forward(caches: bound, count: count)
        }
        try check()
        guard observed.layerDTypes == dtypes, observed.observations.count == 4,
              caches.allSatisfy({ $0.rows.isEmpty }) else { throw ProbeError("Fixture actual prefill2/decode1 probe differs") }
        return try .init(attentionKinds: kinds, caches: caches, observed: observed,
            globalLayerIndices: globals, maximumTokens: maximumTokens, maximumChunkTokens: maximumChunk)
    }
}
#endif
