import Foundation

/// One definition for the currently admitted resident adapter and its metadata.
/// Describing these limits does not allocate a model or admit a request.
enum QwenResidentAdapterDefinition {
    static let profileID = "registered_qwen35_9b_greedy_generation_v1"
    static let maximumLifetimeNanoseconds: UInt64 = 300_000_000_000
    static let maximumRequests = 16
    static let supportedCuts = [4, 8, 12, 16]

    static func profile(specification: QwenDenseRegisteredSpecification) throws -> QwenLayerStageGenerationProfile {
        guard specification.model == .qwen35NineB else { throw ProbeError("Unsupported resident model") }
        return try .init(identifier: profileID, vocabularySize: 248_320,
            hiddenSize: specification.hidden, activationDType: "bfloat16", maximumPromptTokens: 8192,
            maximumChunkTokens: 512, maximumOutputTokens: 128, maximumContextTokens: 8320)
    }
}
