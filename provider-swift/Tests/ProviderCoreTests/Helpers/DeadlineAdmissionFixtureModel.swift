import MLX
import MLXLMCommon

/// Tiny deterministic tensors exercise the real scheduler and deadline verdict
/// without model weights or performance measurements.
final class DeadlineAdmissionFixtureModel: CBv2SteppableModel {
    let kinds = [CBv2LayerKind(attention: .full, headDim: 1, kvHeads: 1, queryHeads: 1)]

    func forward(tokens: MLXArray, caches: [CBv2AttendingLayerCache]) -> MLXArray {
        let batch = tokens.dim(0), length = tokens.dim(1)
        let kv = MLXArray.ones([batch, 1, length, 1], dtype: .float32)
        for cache in caches {
            _ = cache.updateAndAttend(queries: kv, keys: kv, values: kv, scale: 1, sinks: nil)
        }
        return broadcast(MLXArray([Float(0), 1]).reshaped([1, 1, 2]), to: [batch, length, 2])
    }
}
