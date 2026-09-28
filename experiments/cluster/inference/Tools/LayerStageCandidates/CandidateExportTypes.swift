import Foundation

struct QwenCandidateExportState: Encodable {
    let layer: QwenLayerStagePlan.Layer
    let components: [String]
}

struct QwenCandidateExportStage: Encodable {
    let stageIndex: Int
    let sourceLayerRange: [Int]
    let stageFingerprint: String
    let constructionConfigurationSHA256: String
    let parameters: [QwenLayerStagePlan.Parameter]
    let state: [QwenCandidateExportState]
    let activeModuleRoots: [String]
    let inertModules: [QwenLayerStagePlan.InertModule]
    let parameterCount: Int
    let stateLayerCount: Int
    let computeCostStatus = "unknown"
}

struct QwenCandidateExportCandidate: Encodable {
    let cut: Int
    let planFingerprint: String
    let stages: [QwenCandidateExportStage]
    let excludedCanonicalSourceNames: [String]
    let computeCostStatus = "unknown"
}

struct QwenCandidateExportCatalog: Encodable {
    let kind = "qwen_layer_stage_candidate_catalog"
    let schemaVersion = 1
    let adapter = "qwen35-dense-layer-stage-catalog-v1"
    let sourceConfigurationSHA256: String
    let canonicalNamesRawSHA256: String
    let canonicalNamesSHA256: String
    let canonicalNamesEncoding = "sorted_unique_strings_json_without_escaping_slashes_v1"
    let canonicalNameCount: Int
    let candidates: [QwenCandidateExportCandidate]
    let metadataOnly = true
    let canonicalNameCoverageChecked = true
    let actualSanitizerVerified = false
    let sourceDescriptorsVerified = false
    let modelConstructed = false
    let checkpointWeightsRead = false
    let modelPayloadsVerified = false
    let allocationMeasured = false
    let runtimeEligibilityEstablished = false
    let performanceQualified = false
    let computeCostStatus = "unknown"
}
