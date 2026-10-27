import Foundation
import MLX
import MLXLMCommon
import MLXNN

struct Gemma4ResidentLoadedStage {
    let loaded: LoadedQwenLayerStage
    let specification: Gemma4RegisteredSpecification
}

/// Loads this rank's stage of a registered Gemma artifact from this Mac's own
/// verified files. The source, both stages' inventories and the allocation
/// limits are checked before the first tensor is read, and the tensors then go
/// through the same materializer and ordered memory gate as every other
/// registered stage.
///
/// `constructed` receives the stage's model as soon as it exists, before any
/// tensor is read, so a caller's weak reference answers for a load that fails part-way.
func loadGemma4ResidentStage(_ admission: Gemma4ResidentAdmission, check: () throws -> Void,
                            constructed: (Module) -> Void = { _ in }) throws -> Gemma4ResidentLoadedStage {
    let local = try prepareGemma4ResidentSource(admission, check: check)
    let source = local.metadata, plan = admission.plan, index = admission.configuration.rank
    let other = try withRandomState(MLXRandom.RandomState(seed: 7)) {
        try inspectOtherGemma4LayerStage(source: source, stage: plan.stages[1 - index], check: check)
    }
    return try autoreleasepool {
        try withRandomState(MLXRandom.RandomState(seed: 7)) {
            let value = try prepareGemma4LayerStageModel(source: source, stage: plan.stages[index], check: check)
            constructed(value.model)
            let commitment = try gemma4LayerStageStorageCommitment(source: source.source,
                originalConfiguration: admission.configBytes, plan: plan,
                inventories: [other, value.inventory].sorted { $0.summary.stageIndex < $1.summary.stageIndex })
            let gate = try QwenResidentLoadGate(inventory: value.inventory)
            let loaded = try materializeVerifiedQwenLayerStage(source: source.source, payload: local.payload,
                plan: plan, stageIndex: index, model: value.model, inventory: value.inventory,
                commitment: commitment, gate: gate,
                check: { try check(); try gate.observe(); try check() },
                beforeTensor: { try check(); try gate.beforeRead($0); try check() })
            try gate.finish(); try check()
            return .init(loaded: loaded, specification: source.specification)
        }
    }
}
