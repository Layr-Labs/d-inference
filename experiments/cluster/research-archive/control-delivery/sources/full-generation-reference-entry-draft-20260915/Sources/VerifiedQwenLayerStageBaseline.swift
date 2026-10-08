import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Draft matched, unpartitioned baseline for the sequential layer-stage check.
/// The caller supplies already-retained configuration bytes and an artifact pin;
/// no Options/loadModel branch, file-by-path weight reopen or precision wrapper
/// is involved. Use only in the serialized diagnostic process (MTP is disabled
/// before construction), and release the baseline before loading either stage.
func loadVerifiedQwenLayerStageBaseline(directory: URL, originalConfiguration: Data,
    expectedAggregateSHA256: String, hooks: VerifiedQwenDiagnosticLoadHooks? = nil
) throws -> LoadedModel {
    guard originalConfiguration.count <= 1_048_576,
          let root = try JSONSerialization.jsonObject(with: originalConfiguration) as? [String: Any],
          let type = root["model_type"] as? String,
          ["qwen3_5", "qwen3_5_text"].contains(type) else {
        throw ProbeError("Layer-stage baseline requires bounded retained dense Qwen configuration")
    }
    let nested = root["text_config"] != nil
    guard !nested || (type == "qwen3_5" && root["text_config"] is [String: Any]) else {
        throw ProbeError("Layer-stage baseline has an unsupported nested text configuration")
    }
    let text = root["text_config"] as? [String: Any] ?? root
    // Same model/configuration scope as the pure stage planner. No compact
    // construction configuration is substituted into this baseline.
    try QwenStageMetadata.validate(text: text, root: root, nested: nested)
    let layers = try QwenStageMetadata.integer(text, "num_hidden_layers", limit: 128)
    let hidden = try QwenStageMetadata.integer(text, "hidden_size", limit: 8192)
    let vocabulary = try QwenStageMetadata.integer(text, "vocab_size", limit: 262144)
    let interval = try QwenStageMetadata.integer(text, "full_attention_interval", limit: 128)
    guard vocabulary > 3, interval > 1, layers >= interval else {
        throw ProbeError("Layer-stage baseline requires a nonempty hybrid dense Qwen model")
    }
    let layerTypes = (0..<layers).map { ($0 + 1) % interval == 0 ? "full_attention" : "linear_attention" }
    guard text["layer_types"] == nil || text["layer_types"] as? [String] == layerTypes else {
        throw ProbeError("Baseline layer types disagree with the public dense Qwen constructor")
    }
    let namespace = type == "qwen3_5" ? "language_model." : ""
    let inventory = QwenStageMetadata.moduleInventory(namespace: namespace, layerTypes: layerTypes, text: text)
    _ = try QwenStageMetadata.policy(root: root, modules: inventory.modules,
        inputWidths: inventory.inputWidths, namespace: namespace)
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: originalConfiguration)
    guard let policy = base.perLayerQuantization else {
        throw ProbeError("Verified layer-stage baseline requires the retained quantization policy")
    }
    return try MLX.withError { nativeError in
        func checked() throws { try nativeError.check(); try hooks?.check(); try nativeError.check() }
        do {
            try checked()
            _qwen35MTPEnabled = false
            let model = try constructQwenModel(originalConfiguration)
            try checked()
            let receipt = try loadVerifiedQwenDiagnostic(model: model, directory: directory,
                originalConfiguration: originalConfiguration, policy: policy,
                expectedAggregateSHA256: expectedAggregateSHA256, hooks: hooks)
            try checked()
            return try finishVerifiedQwenLayerStageBaseline(model: model,
                originalConfiguration: originalConfiguration, receipt: receipt,
                expectedAggregateSHA256: expectedAggregateSHA256, label: directory.lastPathComponent,
                layers: layers, hidden: hidden, vocabulary: vocabulary, namespace: namespace,
                check: checked)
        } catch { try nativeError.check(); throw error }
    }
}
