import Foundation
import MLX
import MLXNN

enum InferenceModelFamily: String, Codable { case qwen35, gemma4 }

func modelParameterLayout(_ model: Module) -> String {
    let entries = model.parameters().flattened().map { path, value in "\(path):\(value.dtype):\(value.shape)" }
    return sha256(Data(entries.sorted().joined(separator: "\n").utf8))
}
