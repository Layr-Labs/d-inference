import Foundation

/// Actual full-baseline finishing inputs from already admitted raw metadata.
struct QwenDenseShortBaselineGeometry {
    let hidden: Int, namespace: String
    init(configuration: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              let type = root["model_type"] as? String,
              ["qwen3_5", "qwen3_5_text"].contains(type) else {
            throw ProbeError("Short baseline finishing requires the admitted dense Qwen constructor")
        }
        let text = root["text_config"] as? [String: Any] ?? root
        hidden = try QwenStageMetadata.integer(text, "hidden_size", limit: 8192)
        namespace = type == "qwen3_5" ? "language_model." : ""
    }
}
