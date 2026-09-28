import Foundation
import MLX
import MLXNN

struct QwenLayerStagePrefillReport: Encodable {
    let kind = "qwen_layer_stage_prefill_report", schemaVersion = 1
    let correctnessOnly = true, throughputMeasurementValid = false
    let baselineModelReleasedBeforeStageLoading = true, stageModelsReleasedAfterComparison = true
    let conservativeStateAndBoundaryBytes: Int
    let stageLoads: [QwenLayerStageLoadReceipt]
    let comparison: QwenLayerStagePrefillComparisonResult
    let memory: [QwenStageMemoryObservation]
}

/// Separately captured full-model reference followed by stage computation that
/// observes state/logits only after the entire prompt. There is no timer here.
func runQwenLayerStagePrefillCheck(options: Options,
    inputs: QwenLayerStageComparisonAdmission.Inputs, check: () throws -> Void
) throws -> QwenLayerStagePrefillReport {
    try QwenLayerStagePrefillAdmission.validateOptions(options)
    let request = try QwenLayerStageRecordedRequest(request: .init(requestID: UUID(),
        promptCount: inputs.prompt.count, chunkSize: options.chunkSize, outputCount: 1),
        vocabularySize: inputs.vocabularySize, prompt: inputs.prompt, teacher: [])
    var memory = [QwenStageMemoryObservation("before_baseline_load")]
    weak var baselineModel: Module?
    let baseline = try autoreleasepool {
        let loaded = try loadVerifiedQwenLayerStageBaseline(directory: options.modelDirectory!,
            originalConfiguration: inputs.configurationData,
            expectedAggregateSHA256: options.expectedArtifactAggregateSHA256!)
        baselineModel = loaded.model
        try check()
        return try recordQwenLayerStageBaseline(loaded: loaded, plan: inputs.plan, request: request, check: check)
    }
    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
    guard baselineModel == nil else { throw ProbeError("Prefill control retained its reference model before stage loading") }
    Memory.clearCache(); try check()
    memory.append(QwenStageMemoryObservation("baseline_released_cache_cleared"))
    try emitJSON(QwenLayerStageBaselineCheckpoint(baseline: baseline, memory: memory))
    weak var firstModel: Module?
    weak var secondModel: Module?
    let result = try autoreleasepool {
        let first = try loadVerifiedQwenLayerStage(directory: options.modelDirectory!,
            originalConfiguration: inputs.configurationData, plan: inputs.plan, stageIndex: 0,
            expectedAggregateSHA256: options.expectedArtifactAggregateSHA256!)
        firstModel = first.model; try check()
        let second = try loadVerifiedQwenLayerStage(directory: options.modelDirectory!,
            originalConfiguration: inputs.configurationData, plan: inputs.plan, stageIndex: 1,
            expectedAggregateSHA256: options.expectedArtifactAggregateSHA256!)
        secondModel = second.model; try check()
        memory.append(QwenStageMemoryObservation("both_stages_loaded"))
        let comparison = try compareQwenLayerStagePrefillCompute(baseline: baseline,
            stages: [first, second], plan: inputs.plan, check: check)
        memory.append(QwenStageMemoryObservation("stage_requests_retired"))
        return ([first.receipt, second.receipt], comparison)
    }
    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
    guard firstModel == nil, secondModel == nil else { throw ProbeError("Prefill control retained a stage model after comparison") }
    Memory.clearCache(); try check()
    memory.append(QwenStageMemoryObservation("stage_models_released_cache_cleared"))
    return .init(conservativeStateAndBoundaryBytes: inputs.conservativeStateAndBoundaryBytes,
        stageLoads: result.0, comparison: result.1, memory: memory)
}
