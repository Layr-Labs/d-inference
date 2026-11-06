import Foundation

struct QwenLayerStageSessionIdentity: Codable, Equatable {
    let stageIndex: Int
    let requestFingerprint: String
    let artifactAggregateSHA256: String
    let storageCommitmentSHA256: String
    let bf16ConversionEnabled: Bool
    let sourceConfigurationSHA256: String
    let constructionConfigurationSHA256: String
    let planFingerprint: String
    let stageFingerprint: String
    let activationDType: String
}
