import Foundation

/// Identity of one serialized layer-stage session. Verbatim from PR 1226's
/// QwenLayerStageSession.swift (head 78397f4c); the session class itself is
/// NOT staged in this slice (it needs the resident loading web and shows
/// mlx-swift-lm API drift — see the staging handoff, slice 13). Split into
/// its own file so the wire/result contracts compile without the executor.
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
