import Foundation
import MLX
import MLXNN

struct QwenStageMemoryObservation: Encodable {
    let phase: String
    let activeMLXBytes: Int
    let cachedMLXBytes: Int
    let peakMLXBytesSinceProcessStart: Int

    init(_ phase: String) {
        self.phase = phase
        activeMLXBytes = Memory.activeMemory; cachedMLXBytes = Memory.cacheMemory
        peakMLXBytesSinceProcessStart = Memory.peakMemory
    }
}

struct QwenLayerStageBaselineCheckpoint: Encodable {
    let kind = "qwen_layer_stage_baseline_checkpoint"
    let baselineModelReleasedBeforeStageLoading = true
    let baseline: QwenLayerStageBaselineEvidence
    let memory: [QwenStageMemoryObservation]
}

struct QwenLayerStageComparisonReport: Encodable {
    let kind = "qwen_layer_stage_comparison_report"
    let correctnessOnly = true
    let throughputMeasurementValid = false
    let baselineModelReleasedBeforeStageLoading = true
    let stageModelsReleasedAfterComparison = true
    let conservativeStateAndBoundaryBytes: Int
    let stageLoads: [QwenLayerStageLoadReceipt]
    let comparison: QwenLayerStageRecordedComparison
    let memory: [QwenStageMemoryObservation]
}

/// Only CPU evidence crosses the baseline/stage residency boundary. Emit the
/// completed baseline first so a later load/forward mismatch preserves its data.
func runQwenLayerStageComparison(options: Options, inputs: QwenLayerStageComparisonAdmission.Inputs,
    check: () throws -> Void
) throws -> QwenLayerStageComparisonReport {
    try QwenLayerStageComparisonAdmission.validateOptions(options)
    try QwenLayerStageComparisonAdmission.validatePlanBinding(options, inputs: inputs)
    let request = try QwenLayerStageRecordedRequest(request: .init(requestID: UUID(),
        promptCount: inputs.prompt.count, chunkSize: options.chunkSize, outputCount: options.decodeCount),
        vocabularySize: inputs.vocabularySize, prompt: inputs.prompt, teacher: inputs.teacher)
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
    guard baselineModel == nil else { throw ProbeError("Full baseline model remained retained before stage loading") }
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
        let comparison = try compareQwenLayerStageRecordedRequest(baseline: baseline,
            stages: [first, second], plan: inputs.plan, check: check)
        memory.append(QwenStageMemoryObservation("stage_requests_retired"))
        return ([first.receipt, second.receipt], comparison)
    }
    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
    guard firstModel == nil, secondModel == nil else { throw ProbeError("Stage model remained retained after comparison") }
    Memory.clearCache(); try check()
    memory.append(QwenStageMemoryObservation("stage_models_released_cache_cleared"))
    return .init(conservativeStateAndBoundaryBytes: inputs.conservativeStateAndBoundaryBytes,
        stageLoads: result.0, comparison: result.1, memory: memory)
}
