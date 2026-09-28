import Foundation

enum QwenDenseShortFusionLedger {
    static func append(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
                       scope: QwenDenseShortLedgerScope, expectedBytes: Int,
                       builder: inout QwenDenseShortAllowanceBuilder,
                       bound: (Int) throws -> Int) throws {
        let tensors = Dictionary(uniqueKeysWithValues: profile.canonicalTensors.map { ($0.name, $0) })
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        var logicalBytes: [Int] = []
        for layer in 0..<plan.layers where (layer + 1) % plan.interval != 0 {
            let stage = layer < plan.stages[0].sourceRange.upperBound ? 0 : 1
            let owner = scope == .fullReference ? "full" : "stage\(stage)"
            for suffix in ["weight", "scales", "biases"] {
                let parts = try ["in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a"].map { projection in
                    let name = "language_model.model.layers.\(layer).linear_attn.\(projection).\(suffix)"
                    guard let tensor = tensors[name] else {
                        throw QwenDenseProfileError("Missing registered GDN fusion source tensor")
                    }
                    return tensor
                }
                let dtype = suffix == "weight" ? "U32" : "BF16"
                guard let first = parts.first, first.shape.count == 2,
                      parts.allSatisfy({ $0.sourceDType == dtype && $0.shape.count == 2 &&
                          $0.shape[1] == first.shape[1] }) else {
                    throw QwenDenseProfileError("GDN fusion source shape or dtype differs")
                }
                let shape = [try sum(parts.map { $0.shape[0] }), first.shape[1]]
                let width = suffix == "weight" ? 4 : 2
                let bytes = try product(shape + [width])
                guard bytes == (try sum(parts.map(\.byteCount))) else {
                    throw QwenDenseProfileError("Fused allocation does not conserve source bytes")
                }
                logicalBytes.append(bytes)
                // All banks are allowed concurrently with old parameter/cache
                // storage. This does not claim a permanent duplicate model.
                try builder.append(category: "fusion", owner: owner,
                    name: "layer\(layer).fused_\(suffix)", shape: shape,
                    elementBytes: width, instances: 1, bound: bound)
            }
        }
        guard try sum(logicalBytes) == expectedBytes else {
            throw QwenDenseProfileError("Short fusion arrays differ from registered storage identity")
        }
    }
}
