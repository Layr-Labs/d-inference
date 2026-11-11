import Foundation
import Testing

@testable import ProviderCore

/// The exact artifacts whose 4-bit (`balanced`) checkpoints moved restored
/// answers off the cold ones save native checkpoints by default, so a cache
/// hit continues the cold prefill. The operator's per-model setting and the
/// process switch still select a profile; the global setting, which a saved
/// provider.toml spells out as `balanced`, does not.
struct NativeCheckpointDefaultTests {
    /// Each exact artifact ID with the `model_type` its config declares.
    static let nativeByDefault: [(id: String, type: String)] = [
        ("gemma-4-26b-qat-4bit", "gemma4"),
        ("gpt-oss-20b", "gpt_oss"),
        ("glm-5.3-flash", "glm5_next"),
        (GLM5NextLocalQualification.modelID, "glm5_next"),
        ("ternary-bonsai-2-27b", "prism_hadamard_qwen35"),
        ("EigenLabs/Ternary-Bonsai-2-27B-MLX-2bit", "prism_hadamard_qwen35"),
        (EngineV2SupportedModels.bonsai2ModelID, "prism_hadamard_qwen35"),
        (Bonsai9BModelPolicy.eigenModelID, "prism_hadamard_qwen35"),
        (Bonsai9BModelPolicy.modelID, "prism_hadamard_qwen35"),
    ]

    /// nil when the settings are refused.
    private func precision(
        _ id: String, type: String?, global: String = "balanced", byModel: [String: String] = [:],
        environment: [String: String] = [:]
    ) -> EngineV2KVQuantizationSelection? {
        try? PrefixCachePolicy.checkpointPrecision(
            modelId: id, modelType: type, global: global, byModel: byModel, environment: environment)
    }

    @Test func lossyArtifactsDefaultToNative() {
        for model in Self.nativeByDefault {
            #expect(PrefixCachePolicy.defaultsToNativeCheckpoints(modelId: model.id), "\(model.id)")
            for global in ["balanced", "", "k4v4", "k8v4", "k8v8", "native"] {
                #expect(precision(model.id, type: model.type, global: global) == .native,
                        "\(model.id) global \(global)")
            }
            #expect(precision(model.id, type: model.type, byModel: ["another-model": "balanced"]) == .native)
        }
    }

    /// The operator's own choice for the model wins, in the shared order:
    /// the switch, then the per-model entry.
    @Test func operatorChoicesStillWin() {
        let key = EngineV2KVQuantizationPolicy.checkpointEnvironmentKey
        for model in Self.nativeByDefault {
            #expect(precision(model.id, type: model.type, byModel: [model.id: "balanced"]) == .balanced)
            #expect(precision(model.id, type: model.type, global: "native", byModel: [model.id: "k8v8"]) == .k8v8)
            #expect(precision(model.id, type: model.type, environment: [key: "balanced"]) == .balanced)
            #expect(precision(model.id, type: model.type, byModel: [model.id: "balanced"],
                              environment: [key: "native"]) == .native)
            #expect(precision(model.id, type: model.type, byModel: [model.id: "bogus"]) == nil)
        }
    }

    /// Other builds, aliases and families keep the global setting and the
    /// SDK's defaults: only the exact qualified artifacts change.
    @Test func otherModelsKeepTheirCheckpointDefault() {
        for (id, type) in [("qwen3.5-35b-a3b", "qwen3_5_moe"), ("EigenLabs/Qwen3.8-27B-4bit-mtp", "qwen3_5"),
                           ("gemma-4-26b", "gemma4"), ("gemma-4-26b-8bit", "gemma4"),
                           ("openai/gpt-oss-20b", "gpt_oss"), ("gpt-oss-120b", "gpt_oss"),
                           ("ternary-bonsai-2-27b-future", "prism_hadamard_qwen35")] {
            #expect(!PrefixCachePolicy.defaultsToNativeCheckpoints(modelId: id), "\(id)")
            #expect(precision(id, type: type) == .balanced, "\(id)")
            #expect(precision(id, type: type, global: "k8v8") == .k8v8, "\(id)")
            #expect(precision(id, type: type, global: "native") == .native, "\(id)")
        }
    }
}
