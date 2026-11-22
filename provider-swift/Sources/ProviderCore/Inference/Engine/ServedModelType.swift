// Copyright © 2026 Eigen Labs.

/// The `model_type`s (config.json) the provider serves: every type
/// `EngineV2SupportedModels` admits, by its type or by its listed model ids.
///
/// A closed list of engine architectures, not a model catalog. Published
/// manifests decide which builds are served, so a case never carries a model
/// id, a revision or a repository.
///
/// A rule that must answer for every served type switches over this enum
/// without a `default:`, so a new case fails to build until the rule decides
/// it (`EngineV2SupportedModels.isSupported(modelType:)`,
/// `GenerationLoopGuardPolicy.decision(_:)`, `ToolCallExposure.Family`). A raw
/// value is the type as config.json declares it; each caller keeps its own
/// rule for letter case and surrounding whitespace, and `init(normalizing:)`
/// is the supported set's.
enum ServedModelType: String, CaseIterable, Sendable {
    case gptOSS = "gpt_oss"
    case gemma4
    case gemma4Text = "gemma4_text"
    case diffusionGemma = "diffusion_gemma"
    case qwen35 = "qwen3_5"
    case qwen35MoE = "qwen3_5_moe"
    case qwen3VLMoE = "qwen3_vl_moe"
    case qwen4Exp = "qwen4_exp"
    case qwen4ExpText = "qwen4_exp_text"
    case prismHadamardQwen35 = "prism_hadamard_qwen35"
    case flint
    case mimoV2 = "mimo_v2"
    case glm5Next = "glm5_next"
    case nemotronH = "nemotron_h"
    case nemotronHOmni = "nemotron_h_omni"
}

extension ServedModelType {
    /// The served type `modelType` names once lowercased and without
    /// surrounding whitespace: how the supported set admits a type
    /// (`EngineV2SupportedModels.isSupported(modelType:)`). A rule that must
    /// answer for every string the engine can serve reads the type through
    /// this, so it cannot disagree with the supported set about which strings
    /// name a served type.
    init?(normalizing modelType: String?) {
        guard let raw = EngineV2SupportedModels.normalized(modelType) else { return nil }
        self.init(rawValue: raw)
    }
}
