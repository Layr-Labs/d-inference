// Copyright © 2026 Eigen Labs.
//
// Model-specific EOS-token policy — scheduler-free home (v0.7.5).
//
// Re-homed unchanged from `BatchScheduler.effectiveEOSTokenIds` so the v2
// slot builder no longer needs a `BatchScheduler` just to resolve stop
// tokens. The `BatchScheduler` static forwards here (one implementation,
// two call surfaces) until the legacy scheduler is deleted.

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
