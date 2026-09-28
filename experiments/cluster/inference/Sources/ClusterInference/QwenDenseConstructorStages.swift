import Foundation
import MLX
import MLXNN

func inspectQwenDenseConstructorStages(_ prepared: QwenDenseConstructorSource,
    admission: QwenDenseConstructorAdmission, check: () throws -> Void
) throws -> [QwenDenseConstructorStage] {
    var result: [QwenDenseConstructorStage] = []
    for stage in admission.plan.stages {
        weak var retired: Module?
        let observation = try {
            do {
                return try autoreleasepool {
                    try withRandomState(MLXRandom.RandomState(seed: 7)) {
                        let value = try prepareQwenLayerStageModel(source: prepared.source, stage: stage, check: check)
                        retired = value.model
                        // This validator covers prepared expectations, not installed active weights.
                        try validateObservedQwenDenseStage(value.inventory, source: prepared.validation,
                            profile: prepared.profile, requirement: prepared.requirement,
                            plan: admission.plan, stageIndex: stage.index)
                        let actual = try observeQwenDenseConstructor(value.model, role: "stage\(stage.index)",
                            layerCount: stage.layers.count, configuration: stage.constructionConfiguration)
                        try check()
                        return QwenDenseConstructorStage(constructor: actual,
                            expectedActiveTensors: value.inventory.active, installedLazyInertModules: value.inventory.inert,
                            expectedPostLoadSummary: value.inventory.summary)
                    }
                }
            } catch {
                let primary = error
                guard retired == nil else {
                    throw ProbeError("Constructor metadata failure (\(primary)); model remained retained")
                }
                throw primary
            }
        }()
        guard retired == nil else { throw ProbeError("Compact constructor probe model remained retained") }
        try check()
        result.append(observation)
    }
    return result
}
