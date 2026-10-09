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
    // The artifact's own configuration of a Prism Hadamard pack: the SDK's
    // product class, which checks the pack's declaration. A stage of that pack
    // is declared as the dense model below and receives its packed modules
    // from the stage loader.
    if object["model_type"] as? String == QwenPrismStageConfiguration.rootModelType {
        return try PrismHadamardQwen35TextModel(configurationData: data)
    }
    if object["model_type"] as? String == "qwen3_5" {
        return Qwen35Model(try JSONDecoder().decode(Qwen35Configuration.self, from: data))
    }
    return Qwen35TextModel(try JSONDecoder().decode(Qwen35TextConfiguration.self, from: data))
}

