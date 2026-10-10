import DarkbloomClusterProtocol
import Foundation

/// One definition for the currently admitted resident adapter and its metadata.
/// Describing these limits does not allocate a model or admit a request.
enum QwenResidentAdapterDefinition {
    static let profileID = "registered_qwen35_9b_greedy_generation_v1"
    /// The adapter's own ceiling (`ClusterRuntimeAdapter.maximumLifetimeSeconds`).
    /// An owner asks for a lifetime sized to its requests; this only bounds it.
    static let maximumLifetimeNanoseconds = UInt64(ClusterRuntimeAdapter.qwen35Dense.maximumLifetimeSeconds) * 1_000_000_000
    static let maximumRequests = 16
    static let supportedCuts = [4, 8, 12, 16]
    static let supportedPrefillSchedules: [ClusterPrefillSchedule] = [.serial, .oneChunkLookahead]

    static func profile(specification: QwenDenseRegisteredSpecification) throws -> QwenLayerStageGenerationProfile {
        // The model's own closed row names its profile; the 9B row is `Self.profileID`.
        let profileID = try QwenResidentModelDefinition(model: specification.model).profileID
        // Prompt, output and context follow from the protocol and the model's
        // declared context, not from a table (`QwenResidentContextLimits`).
        let limits = try QwenResidentContextLimits(specification: specification)
        return try .init(identifier: profileID, vocabularySize: 248_320,
            hiddenSize: specification.hidden, activationDType: "bfloat16",
            maximumPromptTokens: limits.maximumPromptTokens, maximumChunkTokens: limits.maximumChunkTokens,
            maximumOutputTokens: limits.maximumOutputTokens, maximumContextTokens: limits.maximumContextTokens)
    }
}
