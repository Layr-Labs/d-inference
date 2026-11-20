import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

func constructQwenModel(_ data: Data) throws -> any LanguageModel {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProbeError("Model configuration must be an object")
    }
    if object["model_type"] as? String == "qwen3_5_moe" {
        return Qwen35MoEModel(try JSONDecoder().decode(Qwen35Configuration.self, from: data))
    }
    if object["model_type"] as? String == "qwen3_5" {
        return Qwen35Model(try JSONDecoder().decode(Qwen35Configuration.self, from: data))
    }
    return Qwen35TextModel(try JSONDecoder().decode(Qwen35TextConfiguration.self, from: data))
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
