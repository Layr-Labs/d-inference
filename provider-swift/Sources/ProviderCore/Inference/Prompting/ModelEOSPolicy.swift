// Copyright © 2026 Eigen Labs.
//
// Model-specific EOS-token policy — scheduler-free home (v0.7.5).
//
// Re-homed from the retired `BatchScheduler.effectiveEOSTokenIds` so EngineV2
// slot construction has one scheduler-independent stop-token policy.

import Foundation
import MLXLMCommon

public enum ModelEOSPolicy {
    /// The artifact's own EOS ids exactly as the model loader gives a
    /// single-Mac slot (`LLMModelFactory` / `VLMModelFactory`, read into the
    /// container's `ModelConfiguration.eosTokenIds`): config.json's top-level
    /// `eos_token_id`, replaced by generation_config.json's when that file
    /// names one. A model served without a loaded container (a cluster pair)
    /// resolves its stop set from the same files by the same rule. Nil when
    /// config.json is absent or not a model configuration.
    public static func artifactEOSTokenIds(modelDirectory: URL) -> Set<Int>? {
        guard let data = try? Data(contentsOf: modelDirectory.appendingPathComponent("config.json")),
              let configuration = try? JSONDecoder.json5().decode(BaseConfiguration.self, from: data)
        else { return nil }
        var ids = Set(configuration.eosTokenIds?.values ?? [])
        if let generation = try? Data(contentsOf: modelDirectory.appendingPathComponent("generation_config.json")),
           let file = try? JSONDecoder.json5().decode(GenerationConfigFile.self, from: generation),
           let values = file.eosTokenIds?.values {
            ids = Set(values)
        }
        return ids
    }

    /// Return model-specific EOS tokens at the engine boundary. Most models
    /// keep the loader-provided set; GPT-OSS/Harmony adds its
    /// generation-config action stops via `GPTOSSHarmonyTemplateFix`.
    public static func effectiveEOSTokenIds(
        modelId: String,
        modelType: String? = nil,
        base: Set<Int>,
        tokenToId: (String) -> Int?
    ) -> Set<Int> {
        let context = ChatTemplateFixContext(modelId: modelId, modelType: modelType)
        return ChatTemplateFixes.extraEOSTokenIds(
            context: context,
            base: base,
            tokenToId: tokenToId
        )
    }
}
