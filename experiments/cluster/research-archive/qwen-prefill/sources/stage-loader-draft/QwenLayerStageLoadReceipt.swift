import Foundation
import MLX
import MLXLMCommon

/// Draft contract: a compact stage is not a complete LanguageModel. Only the
/// stage session may consume it, after checking the expected ingress below.
enum QwenLayerStageInputKind: String, Codable { case tokens, residual }

struct LoadedQwenLayerStage {
    let model: any LanguageModel
    let plan: QwenLayerStagePlan
    let stageIndex: Int
    let receipt: QwenLayerStageLoadReceipt
    let activationDType: DType
    let vocabularySize: Int

    var configurationData: Data { plan.stages[stageIndex].constructionConfiguration }
    var layerCount: Int { plan.stages[stageIndex].layers.count }
    var inputKind: QwenLayerStageInputKind { stageIndex == 0 ? .tokens : .residual }

    /// A caller must invoke this before choosing a public model entry point.
    /// Stage 0 exports pre-final-norm hidden; stage 1 accepts that residual.
    /// Ordinary token-to-logit generation is unsupported for either stage.
    func requireInputKind(_ kind: QwenLayerStageInputKind) throws {
        guard kind == inputKind else { throw ProbeError("Wrong layer-stage consumer path") }
    }
}

struct QwenStageSourceTensor: Codable {
    let sourceName: String
    /// PreparedQwenCheckpoint has already sanitized this name. The original
    /// storage is bound by the verified file, exact descriptor offset and size.
    let canonicalPartName: String
    let file: String
    let offset: Int
    let shape: [Int]
    let sourceDType: String
    let loadedDType: String
    let byteCount: Int
}

struct QwenStageActiveTensor: Codable {
    let sourceName: String
    let localName: String
    let shape: [Int]
    let sourceDType: String
    let loadedDType: String
    let byteCount: Int
}

struct QwenStageInertParameter: Codable {
    let localName: String
    let shape: [Int]
    let dtype: String
    let byteCount: Int
}

struct QwenStageInertModule: Codable {
    let path: String
    /// "module-replacement" or "parameter-only-replacement". The pinned final
    /// RMSNorm is a plain let child, so Module.update cannot replace its object.
    let replacementKind: String
    let responsibility: String
    let parameters: [QwenStageInertParameter]
}

struct QwenStageStorageSummary: Codable {
    let stageIndex: Int
    let constructionConfigurationSHA256: String
    let stagePlanSHA256: String
    let activeMappingSHA256: String
    let activeParameterLayoutSHA256: String
    let parameterLayoutSHA256: String
    let loadedTensorBytes: Int
    let activeTensorCount: Int
    /// Declared bytes of explicit inert parameters, not measured allocation/RSS.
    let inertTensorBytes: Int
    let inertTensorCount: Int
}

/// Common across independently loaded stages. Descriptor bytes are conserved
/// exactly; inactive placeholders are accounted separately, never as source.
struct QwenLayerStageStorageCommitment: Codable {
    let schemaVersion: Int
    let verifiedAggregateSHA256: String
    let sourceConfigurationSHA256: String
    let planSHA256: String
    let sourceTensorManifestSHA256: String
    let sourceModelTensorBytes: Int
    let largestSourceTensorBytes: Int
    let sourceTensorCount: Int
    let canonicalTensorCount: Int
    let bf16ConversionEnabled: Bool
    let stages: [QwenStageStorageSummary]
}

struct QwenLayerStageLoadReceipt: Codable {
    let schemaVersion: Int
    let stageIndex: Int
    let verifiedAggregateSHA256: String
    let sourceConfigurationSHA256: String
    let constructionConfigurationSHA256: String
    let planSHA256: String
    let stagePlanSHA256: String
    let sourceTensorManifestSHA256: String
    let sourceParameterLayoutSHA256: String
    let parameterLayoutSHA256: String
    let activeParameterLayoutSHA256: String
    let activeMappingSHA256: String
    let embeddingActivationDType: String
    let bf16ConversionEnabled: Bool
    let sourceModelTensorBytes: Int
    let loadedTensorBytes: Int
    let largestHostTensorBytes: Int
    let activeTensors: [QwenStageActiveTensor]
    let inertModules: [QwenStageInertModule]
    let inertTensorBytes: Int
    let storageCommitment: QwenLayerStageStorageCommitment
    let storageCommitmentSHA256: String
}
