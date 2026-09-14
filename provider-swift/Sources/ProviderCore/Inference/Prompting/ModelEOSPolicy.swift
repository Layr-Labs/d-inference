// Copyright © 2026 Eigen Labs.
//
// Model-specific EOS-token policy — scheduler-free home (v0.7.5).
//
// Re-homed from the retired `BatchScheduler.effectiveEOSTokenIds` so EngineV2
// slot construction has one scheduler-independent stop-token policy.

import Foundation

public enum ModelEOSPolicy {
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
