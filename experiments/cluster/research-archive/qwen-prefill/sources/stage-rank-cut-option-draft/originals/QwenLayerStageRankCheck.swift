import Foundation
import MLX
import MLXNN

struct QwenLayerStageRankReady: Encodable {
    let kind = "qwen_layer_stage_rank_ready", schemaVersion = 1
    let epoch: String, rank: Int
    let worldSize = 2, transport = "loopback-test", backend = "ring"
}

struct QwenLayerStageRankReport: Encodable {
    let kind = "qwen_layer_stage_rank_report", schemaVersion = 1
    let epoch: String, rank: Int
    let worldSize = 2, transport = "loopback-test", backend = "ring"
    let completed = true, correctnessOnly = true, throughputMeasurementValid = false
    let modelForwardCompared = false, physicalTransferQualified = false
    let sourceLoad: QwenLayerStageLoadReceipt
    let request: QwenLayerStageRecordedRequest
    let frames: [QwenLayerStageRankFrameCompletion]
    let allRequestStateRetired = true, modelReleased = true
    let conservativeStateAndBoundaryBytes: Int
    let memory: [QwenStageMemoryObservation]
}

/// Each process owns one verified stage; CPU evidence is compared by its parent
/// to a separately recorded baseline. Nothing here makes a TPS or parity claim.
func runQwenLayerStageRankCheck(options: Options,
    inputs: QwenLayerStageComparisonAdmission.Inputs, check: () throws -> Void
) throws -> QwenLayerStageRankReport {
    try QwenLayerStageRankAdmission.validateOptions(options)
    let collective = try Collective(transport: options.transport)
    let request = try QwenLayerStageRecordedRequest(request: .init(
        requestID: QwenLayerStageRankAdmission.requestID(epoch: options.epoch!),
        promptCount: inputs.prompt.count, chunkSize: options.chunkSize, outputCount: options.decodeCount),
        vocabularySize: inputs.vocabularySize, prompt: inputs.prompt, teacher: inputs.teacher)
    let transfer = QwenLayerStageBoundaryTransport(collective: collective)
    var memory = [QwenStageMemoryObservation("before_stage_load")]
    weak var stageModel: Module?
    let result = try autoreleasepool {
        let loaded = try loadVerifiedQwenLayerStage(directory: options.modelDirectory!,
            originalConfiguration: inputs.configurationData, plan: inputs.plan, stageIndex: collective.rank,
            expectedAggregateSHA256: options.expectedArtifactAggregateSHA256!)
        stageModel = loaded.model
        try check()
        let session = try QwenLayerStageRankSession(stage: loaded, plan: inputs.plan,
            request: request, transport: transfer)
        memory.append(QwenStageMemoryObservation("stage_loaded_request_admitted"))
        do {
            try emitJSON(QwenLayerStageRankReady(epoch: options.epoch!, rank: collective.rank))
            var frames: [QwenLayerStageRankFrameCompletion] = []
            for _ in request.steps {
                frames.append(try session.runNextFrame(observe: { _ in }, check: check))
            }
            try session.close(); try check()
            guard session.isClosed, !session.isFailed, session.completedFrames == request.steps.count else {
                throw ProbeError("Layer-stage rank did not complete and retire every frame")
            }
            memory.append(QwenStageMemoryObservation("stage_request_retired_weights_resident"))
            return (loaded.receipt, frames)
        } catch {
            let primary = error
            do { try session.cancel() }
            catch { throw ProbeError("Layer-stage rank failed (\(primary)); cleanup also failed (\(error))") }
            throw primary
        }
    }
    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
    guard stageModel == nil else { throw ProbeError("Layer-stage rank retained its model after retirement") }
    Memory.clearCache(); try check()
    memory.append(QwenStageMemoryObservation("stage_model_released_cache_cleared"))
    return .init(epoch: options.epoch!, rank: collective.rank, sourceLoad: result.0,
        request: request, frames: result.1, conservativeStateAndBoundaryBytes: inputs.conservativeStateAndBoundaryBytes,
        memory: memory)
}
