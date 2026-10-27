import Foundation
import MLXLLM
import MLXLMCommon

/// Staged metadata checks, not executed. Call with the exact retained 26B config.
/// This entry deliberately allocates no model or MLXArray and performs no I/O.
func checkGemmaAttentionPartition(configuration: Data) throws {
    guard let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
          let text = root["text_config"] as? [String: Any] else {
        throw ProbeError("Expected the exact wrapped Gemma26B metadata fixture")
    }
    func decoded(_ value: [String: Any]) throws -> Gemma4TextConfiguration {
        try JSONDecoder().decode(Gemma4TextConfiguration.self,
            from: JSONSerialization.data(withJSONObject: value))
    }
    func require(_ condition: Bool) throws {
        guard condition else { throw ProbeError("Gemma attention metadata check failed") }
    }
    func refuse(_ operation: () throws -> Void) throws {
        do { try operation() } catch is ProbeError { return }
        throw ProbeError("Gemma attention metadata check accepted a refused case")
    }
    func policy(bits: Int = 4, group: Int = 64) throws -> BaseConfiguration.Quantization {
        try JSONDecoder().decode(BaseConfiguration.Quantization.self,
            from: Data("{\"bits\":\(bits),\"group_size\":\(group),\"mode\":\"affine\"}".utf8))
    }
    let plan = try GemmaAttentionPartition(config: decoded(text))
    try require(plan.configurationUpdates == ["num_attention_heads": 8,
        "num_key_value_heads": 4, "num_global_key_value_heads": 1,
        "head_dim": 256, "global_head_dim": 512])
    let w4 = try policy(), w8 = try policy(bits: 8)
    func selected(_ layer: Int, _ name: String, _ shape: [Int], _ rank: Int,
                  _ quantization: BaseConfiguration.Quantization? = nil) throws -> TensorSelection {
        try plan.selection(layer: layer, relativeName: name, shape: shape,
                           rank: rank, quantization: quantization)
    }
    // Hand-assembled global stored shapes, not computed by the selection helper.
    let cases: [(Int, String, [Int], Int, Range<Int>)] = [
        (0, "q_proj.weight", [4096, 352], 0, 0..<2048),
        (0, "k_proj.scales", [2048, 44], 0, 0..<1024),
        (0, "v_proj.biases", [2048, 44], 0, 0..<1024),
        (0, "o_proj.weight", [2816, 512], 1, 0..<256),
        (0, "o_proj.scales", [2816, 64], 1, 0..<32),
        (5, "q_proj.weight", [8192, 352], 0, 0..<4096),
        (5, "k_proj.weight", [1024, 352], 0, 0..<512),
        (5, "o_proj.biases", [2816, 128], 1, 0..<64),
    ]
    for (layer, name, shape, axis, first) in cases {
        try require(selected(layer, name, shape, 0, w4) == .axis(axis, [first]))
        try require(selected(layer, name, shape, 1, w4)
            == .axis(axis, [first.upperBound..<shape[axis]]))
    }
    try require(selected(0, "q_norm.weight", [256], 1) == .all)
    try require(selected(5, "k_norm.weight", [512], 0) == .all)
    try require(selected(0, "q_proj.weight", [4096, 704], 0, w8) == .axis(0, [0..<2048]))
    try require(selected(5, "o_proj.weight", [2816, 2048], 1, w8) == .axis(1, [1024..<2048]))
    try refuse { _ = try selected(0, "q_proj.weight", [8192, 352], 0, w4) } // Qwen layout
    try refuse { _ = try selected(5, "v_proj.weight", [1024, 352], 0, w4) } // K=V
    try refuse { _ = try selected(0, "q_norm.weight", [512], 0) }
    try refuse { _ = try selected(0, "q_proj.weight", [4096, 352], 2, w4) }
    try refuse { _ = try selected(30, "q_proj.weight", [4096, 352], 0, w4) }
    try refuse { _ = try selected(0, "q_proj.bias", [4096], 0, w4) }
    try refuse { _ = try selected(0, "q_proj.weight", [4096, 352], 0) }
    try refuse { _ = try selected(0, "q_proj.weight", [4096, 352], 0, policy(bits: 2)) }
    try refuse { _ = try selected(0, "q_proj.weight", [4096, 352], 0, policy(group: 32)) }
    for (field, value) in [("num_global_key_value_heads", 1), ("num_kv_shared_layers", 1),
                           ("head_dim", 258), ("num_attention_heads", 15)] {
        var changed = text; changed[field] = value
        try refuse { _ = try GemmaAttentionPartition(config: decoded(changed)) }
    }
}
