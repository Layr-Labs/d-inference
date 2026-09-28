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

