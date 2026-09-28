import Foundation
import MLX
import MLXNN

struct QwenLayerStageLookaheadReady: Encodable {
    let kind = "qwen_layer_stage_lookahead_ready", schemaVersion = 1
    let epoch: String, rank: Int
    let worldSize = 2, transport = "loopback-test", backend = "ring"
    let flow = QwenLayerStageLookaheadWireEnvelope.flow
    let envelopeVersion = QwenLayerStageLookaheadWireEnvelope.version
}

struct QwenLayerStageLookaheadReport: Encodable {
    let kind = "qwen_layer_stage_lookahead_report", schemaVersion = 1
    let epoch: String, rank: Int
    let worldSize = 2, transport = "loopback-test", backend = "ring"
    let flow = QwenLayerStageLookaheadWireEnvelope.flow
    let envelopeVersion = QwenLayerStageLookaheadWireEnvelope.version
    let completed = true, correctnessOnly = true, throughputMeasurementValid = false
    let modelForwardCompared = false, physicalTransferQualified = false
    let sourceLoad: QwenLayerStageLoadReceipt
    let request: QwenLayerStageRecordedRequest
    let execution: QwenLayerStageLookaheadRequestResult
    let allRequestStateRetired = true, modelReleased = true
    let conservativeStateAndBoundaryBytes: Int
    let memory: [QwenStageMemoryObservation]
}

/// One actual stage per process, v2 prompt-only lookahead, immutable teacher
/// continuation. Parent validates CPU evidence against the separate baseline.
func runQwenLayerStageLookaheadCheck(options: Options,
    inputs: QwenLayerStageComparisonAdmission.Inputs, check: () throws -> Void
) throws -> QwenLayerStageLookaheadReport {
    try QwenLayerStageLookaheadAdmission.validateOptions(options)
    let collective = try Collective(transport: options.transport)
    let request = try QwenLayerStageRecordedRequest(request: .init(
        requestID: QwenLayerStageRankAdmission.requestID(epoch: options.epoch!),
        promptCount: inputs.prompt.count, chunkSize: options.chunkSize, outputCount: options.decodeCount),
        vocabularySize: inputs.vocabularySize, prompt: inputs.prompt, teacher: inputs.teacher)
    let transfer = QwenLayerStageLookaheadTransport(collective: collective)
    var memory = [QwenStageMemoryObservation("before_stage_load")]
    weak var stageModel: Module?
    let result = try autoreleasepool {
        let loaded = try loadVerifiedQwenLayerStage(directory: options.modelDirectory!,
            originalConfiguration: inputs.configurationData, plan: inputs.plan, stageIndex: collective.rank,
            expectedAggregateSHA256: options.expectedArtifactAggregateSHA256!)
        stageModel = loaded.model
        try check()
        let context = try QwenLayerStageLookaheadContext(loaded: loaded, plan: inputs.plan, request: request)
        memory.append(QwenStageMemoryObservation("stage_loaded_request_admitted"))
        do {
            try emitJSON(QwenLayerStageLookaheadReady(epoch: options.epoch!, rank: collective.rank))
            let execution = try runQwenLayerStageLookaheadRequest(context: context, transport: transfer,
                request: request, check: check)
            try check()
            guard context.isClosed, !context.isFailed, !transfer.isFailed, !transfer.hasPendingConsumption else {
                throw ProbeError("Lookahead rank did not retire its completed request and final acknowledgement")
            }
            memory.append(QwenStageMemoryObservation("stage_request_retired_weights_resident"))
            return (loaded.receipt, execution)
        } catch {
            let primary = error
            transfer.retire()
            do { try context.cancel() }
            catch { throw ProbeError("Lookahead rank failed (\(primary)); cleanup also failed (\(error))") }
            throw primary
        }
    }
    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
    guard stageModel == nil else { throw ProbeError("Lookahead rank retained its model after retirement") }
    Memory.clearCache(); try check()
    memory.append(QwenStageMemoryObservation("stage_model_released_cache_cleared"))
    return .init(epoch: options.epoch!, rank: collective.rank, sourceLoad: result.0,
        request: request, execution: result.1,
        conservativeStateAndBoundaryBytes: inputs.conservativeStateAndBoundaryBytes, memory: memory)
}
