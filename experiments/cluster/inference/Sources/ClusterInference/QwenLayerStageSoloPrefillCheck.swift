import Foundation
import MLX
import MLXNN

struct QwenLayerStageSoloPrefillReady: Encodable {
    let kind = "qwen_layer_stage_solo_prefill_ready", schemaVersion = 1
    let verifiedModelLoaded = true, freshRequestStateCreated = false
    let referenceFileSHA256: String, baselineEvidenceFingerprint: String
    let request: QwenLayerStageRecordedRequest
    let source: QwenLayerStageSoloPrefillReference.Source
}

struct QwenLayerStageSoloPrefillReport: Encodable {
    let kind = "qwen_layer_stage_solo_prefill_report", schemaVersion = 1
    let completed = true, correctnessOnly = true, throughputMeasurementValid = false
    let interprocessTransportUsed = false, physicalTransferQualified = false
    let allRequestStateRetired = true, modelReleased = true
    let conservativeStateAndBoundaryBytes: Int
    let execution: QwenLayerStageSoloPrefillResult
    let memory: [QwenStageMemoryObservation]
}

/// A full-model request with the same prompt microchunks as the stage driver.
/// Load/readiness precede the clock; only a pinned CPU reference is present.
func runQwenLayerStageSoloPrefillCheck(options: Options,
    inputs: QwenLayerStageSoloPrefillCLIAdmission.Inputs, check: () throws -> Void
) throws -> QwenLayerStageSoloPrefillReport {
    try QwenLayerStageSoloPrefillCLIAdmission.validateOptions(options)
    var memory = [QwenStageMemoryObservation("before_solo_model_load")]
    weak var model: Module?
    let result = try autoreleasepool {
        let loaded = try loadVerifiedQwenLayerStageBaseline(directory: options.modelDirectory!,
            originalConfiguration: inputs.comparison.configurationData,
            expectedAggregateSHA256: options.expectedArtifactAggregateSHA256!)
        model = loaded.model
        try check()
        let source = try admitQwenLayerStageSoloPrefill(loaded: loaded, plan: inputs.comparison.plan,
            request: inputs.request, reference: inputs.reference)
        memory.append(QwenStageMemoryObservation("solo_model_loaded_no_request_state"))
        try emitJSON(QwenLayerStageSoloPrefillReady(referenceFileSHA256: inputs.reference.fileSHA256,
            baselineEvidenceFingerprint: inputs.reference.descriptor.baselineEvidenceFingerprint,
            request: inputs.request, source: source))
        let result = try runQwenLayerStageSoloPrefillRequest(loaded: loaded, plan: inputs.comparison.plan,
            request: inputs.request, reference: inputs.reference, check: check)
        memory.append(QwenStageMemoryObservation("solo_request_retired_weights_resident"))
        return result
    }
    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
    guard model == nil else { throw ProbeError("Solo prefill retained its model after request retirement") }
    Memory.clearCache(); try check()
    memory.append(QwenStageMemoryObservation("solo_model_released_cache_cleared"))
    return .init(conservativeStateAndBoundaryBytes: inputs.comparison.conservativeStateAndBoundaryBytes,
        execution: result, memory: memory)
}
