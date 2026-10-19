import DarkbloomClusterProtocol
import Foundation

/// The request bounds of one registered model, as the runtime derives them:
/// the worker protocol's bounds cut to the context the model declares in its
/// pinned configuration (`QwenResidentContextLimits` in the runtime). This
/// tool links no runtime, so the declared contexts repeat the runtime's
/// closed catalog; the worker's own capability profile is compared with the
/// request before anything is launched and is the authority.
///
/// A model with no declared context here keeps the earlier fixed reservation
/// (8,192 prompt, 128 output, 8,320 context) until its row is added.
public struct QualificationLimits: Equatable, Sendable {
    public static let chunkTokens = 512
    public let maximumPromptTokens: Int
    public let maximumOutputTokens: Int
    public let maximumContextTokens: Int
    public let maximumChunkTokens: Int

    public init(maximumPromptTokens: Int, maximumOutputTokens: Int, maximumContextTokens: Int, maximumChunkTokens: Int) {
        self.maximumPromptTokens = maximumPromptTokens; self.maximumOutputTokens = maximumOutputTokens
        self.maximumContextTokens = maximumContextTokens; self.maximumChunkTokens = maximumChunkTokens
    }

    /// The earlier fixed profile every model had before its limits were derived.
    public static let reservation = QualificationLimits(maximumPromptTokens: 8192, maximumOutputTokens: 128,
        maximumContextTokens: 8320, maximumChunkTokens: 512)

    /// `max_position_embeddings` of each registered model's pinned configuration.
    public static let declaredContextTokens: [String: Int] = [
        "registered_qwen35_9b": 262_144,
        "registered_qwen38_27b": 262_144,
        "registered_qwen35_35b_a3b": 262_144,
        "registered_qwen36_35b_a3b": 262_144,
        "registered_ternary_bonsai_2_27b": 262_144,
        "registered_nemotron35_lightning": 262_144,
        "registered_gemma4_26b_qat_4bit": 262_144,
        "registered_gemma4_26b": 262_144,
        "registered_gemma4_26b_8bit": 262_144,
        "registered_gpt_oss_20b": 131_072,
        "registered_mimo_v26_flash_mopd": 1_048_576,
        "registered_glm53_flash": 1_048_576,
    ]

    /// The runtime's derivation: protocol bounds, cut to the declared context;
    /// prompt and output each leave room for one token of the other.
    public static func derived(declaredContextTokens declared: Int) -> QualificationLimits {
        let context = min(ClusterWorkerLimits.contextTokens, max(2, declared))
        let prompt = min(ClusterWorkerLimits.promptTokens, context - 1)
        return .init(maximumPromptTokens: prompt, maximumOutputTokens: min(ClusterWorkerLimits.outputTokens, context - 1),
            maximumContextTokens: context, maximumChunkTokens: min(chunkTokens, prompt))
    }

    public static func forModel(_ modelID: String) -> QualificationLimits {
        declaredContextTokens[modelID].map(derived(declaredContextTokens:)) ?? reservation
    }

    /// Nil when the request fits; otherwise the sentence naming the bound it exceeds.
    public func refusal(promptTokens: Int, outputTokens: Int, chunkTokens: Int) -> String? {
        if !(1...maximumPromptTokens).contains(promptTokens) { return "prompt must have 1...\(maximumPromptTokens) tokens" }
        if !(1...maximumChunkTokens).contains(chunkTokens) { return "chunk size must be 1...\(maximumChunkTokens)" }
        if !(1...maximumOutputTokens).contains(outputTokens) { return "output count must be 1...\(maximumOutputTokens)" }
        if promptTokens > maximumContextTokens - outputTokens {
            return "prompt plus output exceeds \(maximumContextTokens) tokens"
        }
        return nil
    }
}

extension QualificationRequest {
    /// The request bounds of the model this request names.
    public var limits: QualificationLimits { QualificationLimits.forModel(modelID) }
}
