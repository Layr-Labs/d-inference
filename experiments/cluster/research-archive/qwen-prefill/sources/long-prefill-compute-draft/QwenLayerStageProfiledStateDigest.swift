import Foundation

extension QwenLayerStageProfiledStateDigest {
    /// Reuse the real committed snapshot, but independently check its exact
    /// registered per-component shapes/dtypes and local-to-global layer map.
    /// The common baseline namespace intentionally omits local compact indices.
    init(snapshot: CBv2OwnedStateSnapshot, admission: QwenLayerStageProfiledComputeAdmission) throws {
        let stage = admission.local.plan.stages[admission.stageIndex]
        let geometry = admission.local.resource.geometry
        let product = QwenLongPrefillCheckedBytes.product
        let channels = try QwenLongPrefillCheckedBytes.sum([
            product([2, geometry.linearKeyHeads, geometry.linearKeyDimension]),
            product([geometry.linearValueHeads, geometry.linearValueDimension]),
        ])
        var expected: [String: (local: Int, shape: [Int], dtype: String, bytes: Int)] = [:]
        func append(_ layer: QwenLayerStagePlan.Layer, _ component: String,
                    _ shape: [Int], _ dtype: String, _ size: Int) throws {
            let key = "\(layer.globalIndex)|\(component)"
            guard expected[key] == nil else { throw ProbeError("Profiled state metadata repeats a global component") }
            expected[key] = (layer.localIndex, shape, dtype, try product(shape + [size]))
        }
        for layer in stage.layers {
            switch layer.kind {
            case "full_attention":
                let shape = [1, geometry.kvHeads, 8192, geometry.headDimension]
                try append(layer, "kv.keys", shape, "bfloat16", 2)
                try append(layer, "kv.values", shape, "bfloat16", 2)
                try append(layer, "kv.position_offsets", [1], "int32", 4)
            case "linear_attention":
                try append(layer, "conv", [1, geometry.convolutionKernel - 1, channels], "bfloat16", 2)
                try append(layer, "ssm", [1, geometry.linearValueHeads, geometry.linearValueDimension,
                    geometry.linearKeyDimension], "float32", 4)
            default: throw ProbeError("Profiled state metadata has an unsupported layer kind")
            }
        }
        guard snapshot.committedTokens == 8192, expected.count == 36, snapshot.entries.count == expected.count,
              Set(snapshot.entries.map { "\($0.globalLayerIndex)|\($0.component)" }) == Set(expected.keys) else {
            throw ProbeError("Profiled state snapshot lacks the full disjoint local-stage component set")
        }
        for entry in snapshot.entries {
            guard let value = expected["\(entry.globalLayerIndex)|\(entry.component)"],
                  entry.localLayerIndex == value.local, entry.shape == value.shape,
                  entry.dtype == value.dtype, entry.byteCount == value.bytes,
                  entry.bytes == nil, qwenStageWireIsSHA256(entry.sha256) else {
                throw ProbeError("Profiled final native state differs in global/local geometry, dtype, bytes or digest")
            }
        }
        let entries = snapshot.entries.map {
            QwenRecordedState.Entry(globalLayerIndex: $0.globalLayerIndex, component: $0.component,
                shape: $0.shape, dtype: $0.dtype, byteCount: $0.byteCount, sha256: $0.sha256)
        }.sorted { ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component) }
        let bytes = try QwenLongPrefillCheckedBytes.sum(entries.map(\.byteCount))
        let fingerprint = sha256(Data((["cbv2-owned-state-v1", "tokens=8192"]
            + entries.map(\.identity)).joined(separator: "\n").utf8))
        guard fingerprint == snapshot.fingerprint,
              bytes == (try QwenLongPrefillCheckedBytes.sum(expected.values.map { $0.bytes })) else {
            throw ProbeError("Profiled state digest changed the native snapshot namespace or logical byte total")
        }
        self.committedTokens = 8192; self.entries = entries
        self.logicalByteCount = bytes; self.fingerprint = fingerprint
    }
}
