import Foundation
import MLX
import MLXNN

enum QwenPartitionKind: String, Codable { case ffn, full }

/// An explicit model adapter. Transport and tensor IO do not infer layer semantics.
struct QwenPartitionPlan {
    let kind: QwenPartitionKind
    let attentionOutputPrecision: AttentionOutputPrecision
    let originalConfiguration: Data
    let constructionConfiguration: Data
    let fingerprint: String
    let layers: Int
    let interval: Int
    let hidden: Int
    /// Dense FFN width, or routed expert width for MoE.
    let intermediate: Int
    let isMoE: Bool
    private let sparse: QwenMoEPartition?
    private let attention: QwenAttentionPartition?
    private let recurrent: QwenGDNPartition?

    init(configuration: Data, kind: QwenPartitionKind,
         attentionOutputPrecision: AttentionOutputPrecision = .native) throws {
        guard var root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
            throw ProbeError("Invalid partition configuration")
        }
        if root["text_config"] != nil && !(root["text_config"] is [String: Any]) {
            throw ProbeError("Qwen text_config must be an object")
        }
        var text = root["text_config"] as? [String: Any] ?? root
        let hidden = try qwenPartitionInteger(text, "hidden_size")
        let layers = try qwenPartitionInteger(text, "num_hidden_layers")
        let interval = try qwenPartitionInteger(text, "full_attention_interval")
        let experts = try text["num_experts"] == nil ? 0
            : qwenPartitionInteger(text, "num_experts", allowZero: true)
        let sparse = try experts > 0 ? QwenMoEPartition(text: text) : nil
        let intermediate = try sparse?.intermediate ?? qwenPartitionInteger(text, "intermediate_size")
        guard hidden % 64 == 0, intermediate % 128 == 0 else {
            throw ProbeError("Qwen two-rank FFNs require whole W4/G64 groups")
        }
        if let declared = text["layer_types"] {
            let expected = (0..<layers).map { ($0 + 1) % interval == 0 ? "full_attention" : "linear_attention" }
            guard let types = declared as? [String], types == expected else {
                throw ProbeError("Qwen layer_types disagrees with full_attention_interval")
            }
        }
        self.sparse = sparse; self.isMoE = sparse != nil
        self.kind = kind; self.originalConfiguration = configuration
        self.attentionOutputPrecision = attentionOutputPrecision
        self.hidden = hidden; self.intermediate = intermediate
        self.layers = layers; self.interval = interval
        if kind == .full {
            attention = try QwenAttentionPartition(text: text)
            recurrent = try QwenGDNPartition(text: text)
        } else { attention = nil; recurrent = nil }
        if let sparse {
            for (key, value) in sparse.configurationUpdates { text[key] = value }
        } else { text["intermediate_size"] = intermediate / 2 }
        for (key, value) in (attention?.configurationUpdates ?? [:]) { text[key] = value }
        for (key, value) in (recurrent?.configurationUpdates ?? [:]) { text[key] = value }
        if root["text_config"] != nil { root["text_config"] = text } else { root = text }
        constructionConfiguration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        fingerprint = sha256(try JSONSerialization.data(withJSONObject: [
            "adapter": isMoE ? "qwen35-moe-two-rank-v2" : "qwen35-dense-two-rank-v2", "kind": kind.rawValue,
            "attentionOutputPrecision": attentionOutputPrecision.rawValue,
            "sourceConfigurationSHA256": sha256(configuration),
            "constructionConfigurationSHA256": sha256(constructionConfiguration),
        ], options: [.sortedKeys]))
    }

    func selection(name: String, shape: [Int], rank: Int) throws -> TensorSelection {
        guard (0..<2).contains(rank) else { throw ProbeError("Invalid partition rank") }
        guard let marker = name.range(of: ".layers.") else { return .all }
        let pieces = name[marker.upperBound...].split(separator: ".").map(String.init)
        guard pieces.count >= 3, let layer = Int(pieces[0]), (0..<layers).contains(layer) else {
            throw ProbeError("Unknown model layer tensor: \(name)")
        }
        let relative = pieces.dropFirst(2).joined(separator: ".")
        switch pieces[1] {
        case "mlp":
            if let sparse { return try sparse.selection(relativeName: relative, shape: shape, rank: rank) }
            return try ffnSelection(relative, shape: shape, rank: rank)
        case "self_attn":
            guard (layer + 1) % interval == 0 else { throw ProbeError("Attention layer/config mismatch") }
            return try attention?.selection(relativeName: relative, shape: shape, rank: rank) ?? .all
        case "linear_attn":
            guard (layer + 1) % interval != 0 else { throw ProbeError("Recurrent layer/config mismatch") }
            return try recurrent?.selection(relativeName: relative, shape: shape, rank: rank) ?? .all
        case "input_layernorm", "post_attention_layernorm":
            guard relative == "weight", shape == [hidden] else { throw ProbeError("Qwen layer norm shape mismatch") }
            return .all
        default: throw ProbeError("Unqualified Qwen layer tensor: \(name)")
        }
    }

    private func ffnSelection(_ name: String, shape: [Int], rank: Int) throws -> TensorSelection {
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count == 2, ["weight", "scales", "biases"].contains(parts[1]) else {
            throw ProbeError("Unqualified dense FFN tensor: \(name)")
        }
        let divisor = parts[1] == "weight" ? 8 : 64
        let axis: Int, expected: [Int]
        switch parts[0] {
        case "gate_proj", "up_proj": axis = 0; expected = [intermediate, hidden / divisor]
        case "down_proj": axis = 1; expected = [hidden, intermediate / divisor]
        default: throw ProbeError("Unknown dense FFN projection")
        }
        guard shape == expected else { throw ProbeError("FFN W4/G64 shape mismatch: \(name)") }
        let width = shape[axis] / 2
        return .axis(axis, [(rank * width)..<((rank + 1) * width)])
    }

    func reductionPaths(in model: Module) throws -> [String] {
        var paths: [String] = []
        var boundaries = Set<String>()
        for (path, module) in model.namedModules() {
            guard let marker = path.range(of: ".layers.") else { continue }
            let parts = path[marker.upperBound...].split(separator: ".").map(String.init)
            let relative = parts.dropFirst().joined(separator: ".")
            let ffnBoundary = relative == (isMoE ? "mlp" : "mlp.down_proj")
            let attentionBoundary = kind == .full && ["self_attn.o_proj", "linear_attn.out_proj"].contains(relative)
            guard ffnBoundary || attentionBoundary else { continue }
            guard let first = parts.first, let layer = Int(first), (0..<layers).contains(layer),
                (ffnBoundary && isMoE ? module is UnaryLayer : module is QuantizedLinear) else {
                throw ProbeError("Unsupported Qwen reduction boundary: \(path)")
            }
            if attentionBoundary {
                let expected = (layer + 1) % interval == 0 ? "self_attn.o_proj" : "linear_attn.out_proj"
                guard relative == expected else { throw ProbeError("Qwen reduction attention topology mismatch") }
            }
            guard boundaries.insert("\(layer).\(ffnBoundary ? "ffn" : "attention")").inserted else {
                throw ProbeError("Duplicate Qwen reduction boundary: \(path)")
            }
            paths.append(path)
        }
        guard paths.count == layers * (kind == .full ? 2 : 1) else {
            throw ProbeError("Partition reduction boundaries do not match the model topology")
        }
        return paths.sorted()
    }
}
