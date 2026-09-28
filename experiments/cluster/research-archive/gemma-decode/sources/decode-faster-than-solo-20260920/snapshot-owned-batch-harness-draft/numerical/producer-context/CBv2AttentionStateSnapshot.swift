import Foundation
import MLX
import MLXLMCommon

extension CBv2OwnedStateSnapshot {
    static func captureAttention(geometry: CBv2RequestGeometry, layout: LayerAttentionStateLayout,
        rows: [CBv2SequenceKV?], recurrent: CBv2RecurrentRequestState, committedTokens: Int,
        globalLayerIndices: [Int], includeBytes: Bool, check: () throws -> Void) throws -> Self {
        guard committedTokens > 0, rows.count == layout.layers.count,
              globalLayerIndices == layout.layers.map(\.globalIndex),
              recurrent.spec.layers.isEmpty, geometry.recurrent.layers.isEmpty, !recurrent.isReleased,
              recurrent.materializedByteCount == 0, recurrent.confirmedStateSnapshot() == nil else {
            throw ProbeError("Attention snapshot lacks exact mapping/frontier or empty recurrent ownership")
        }
        var entries: [Entry] = []
        func append(_ array: MLXArray, local: Int, component: String, range: Range<Int>?) throws {
            try check()
            let bytes = array.asData().data
            try check()
            guard bytes.count == array.nbytes else { throw ProbeError("Attention snapshot logical bytes differ") }
            entries.append(.init(localLayerIndex: local, globalLayerIndex: globalLayerIndices[local],
                component: component, shape: array.shape, dtype: String(describing: array.dtype),
                byteCount: bytes.count, sha256: sha256(bytes), bytes: includeBytes ? bytes : nil,
                logicalRange: range))
        }
        for index in rows.indices {
            guard let row = rows[index], let source = row as? any CBv2ContiguousKVMetadataProviding,
                  geometry.caches[index].rows.count == 1, geometry.caches[index].rows[0] === row else {
                throw ProbeError("Attention snapshot does not own its exact row")
            }
            try layout.validate(source.cbv2ContiguousMetadata, layer: index, frontier: committedTokens)
            let range = try layout.range(layer: index, frontier: committedTokens), layer = layout.layers[index]
            // Explicit diagnostic boundary: snapshot is chronological, including
            // wrapped rings. No borrowed view survives the synchronous CPU copy.
            try check()
            let snapshot = row.snapshot()
            guard snapshot.offset == committedTokens,
                  snapshot.keys.shape == [1, layer.kvHeads, range.count, layer.headDimension],
                  snapshot.values.shape == snapshot.keys.shape,
                  String(describing: snapshot.keys.dtype) == layer.element.rawValue,
                  snapshot.values.dtype == snapshot.keys.dtype else { throw ProbeError("Attention temporal snapshot geometry differs") }
            try append(snapshot.keys, local: index, component: "kv.keys", range: range)
            try append(snapshot.values, local: index, component: "kv.values", range: range)
            let position = geometry.caches[index].positionOffsets
            guard position.shape == [1], position.dtype == .int32,
                  position.asArray(Int32.self) == [Int32(committedTokens)] else { throw ProbeError("Attention snapshot position differs") }
            try append(position, local: index, component: "kv.position_offsets", range: nil)
        }
        entries.sort { ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component) }
        let fingerprint = sha256(Data((["cbv2-owned-attention-state-v2", layout.fingerprint,
            "tokens=\(committedTokens)"] + entries.map(\.identity)).joined(separator: "\n").utf8))
        return .init(committedTokens: committedTokens, entries: entries, fingerprint: fingerprint)
    }
}
