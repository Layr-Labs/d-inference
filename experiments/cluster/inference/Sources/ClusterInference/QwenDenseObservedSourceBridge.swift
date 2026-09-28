import Foundation
import MLX
import MLXNN

/// Project actual descriptors and constructor parameters once. No array read,
/// evaluation, parameter mutation, payload materialization or environment read.
func observedQwenDenseSource(_ prepared: PreparedQwenCheckpoint,
                             model: Module) -> [QwenDenseObservedSourceTensor] {
    let parameters = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
    return prepared.canonical.keys.sorted().map { name in
        let tensor = prepared.canonical[name]!
        let dtype: String
        switch tensor.dtype {
        case .uint32: dtype = "U32"
        case .float16: dtype = "F16"
        case .bfloat16: dtype = "BF16"
        case .float32: dtype = "F32"
        default: dtype = "unsupported"
        }
        return .init(canonical: .init(name: name, shape: tensor.shape,
            sourceDType: dtype, byteCount: tensor.byteCount), sourcePartCount: tensor.parts.count,
            preparedExpectedShape: prepared.expectedShapes[name],
            constructorParameterIsPacked: parameters[name].map { $0.dtype == .uint32 })
    }
}

/// An unwired registered compact metadata seam. prepareQwenLayerStageModel's
/// existing actual-constructor coverage, quantization and inert checks remain
/// mandatory. This function grants no resource or materialization permission.
func validateObservedQwenDenseStage(_ inventory: QwenStagePreparedInventory,
    source: QwenDenseSourceReadPlan, profile: QwenRegisteredDenseModelProfile,
    requirement: QwenDenseStorageRequirement, plan: QwenLayerStagePlan, stageIndex: Int
) throws {
    try QwenDenseObservedStageValidation.validateRegistered(source: source, profile: profile,
        requirement: requirement, plan: plan, stageIndex: stageIndex,
        active: inventory.active, inert: inventory.inert, summary: inventory.summary)
}
