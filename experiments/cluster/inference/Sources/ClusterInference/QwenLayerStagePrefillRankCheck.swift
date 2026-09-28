import Foundation
import MLX
import MLXNN

struct QwenLayerStagePrefillRankReady: Encodable {
    let kind = "qwen_layer_stage_prefill_rank_ready", schemaVersion = 1
    let epoch: String, rank: Int
    let worldSize = 2, transport = "loopback-test", backend = "ring"
    let flow = QwenLayerStagePrefillMeasurementFlow.name
    let envelopeVersion = QwenLayerStagePrefillMeasurementFlow.version
    let modelsReadyAgreementValidated = true, freshRequestStateCreated = false
    let agreementFingerprint: String
    let agreement: QwenLayerStagePrefillStartAgreement.Descriptor
}

struct QwenLayerStagePrefillRankReport: Encodable {
    let kind = "qwen_layer_stage_prefill_rank_report", schemaVersion = 1
    let epoch: String, rank: Int
    let worldSize = 2, transport = "loopback-test", backend = "ring"
    let flow = QwenLayerStagePrefillMeasurementFlow.name
    let envelopeVersion = QwenLayerStagePrefillMeasurementFlow.version
    let completed = true, correctnessOnly = true, throughputMeasurementValid = false
    let modelForwardCompared = false, physicalTransferQualified = false
    let agreementFingerprint: String
    let agreement: QwenLayerStagePrefillStartAgreement.Descriptor
    let sourceLoad: QwenLayerStageLoadReceipt
    let request: QwenLayerStageRecordedRequest
    let execution: QwenLayerStagePrefillRankRequestResult
    let allRequestStateRetired = true, modelReleased = true
    let conservativeStateAndBoundaryBytes: Int
    let memory: [QwenStageMemoryObservation]
}

/// One loaded stage per process. Source and prepared-input agreement precedes
/// the request owner's clock. Parent comparison qualifies the final CPU evidence;
/// loopback timings describe this bounded diagnostic, not cluster performance.
func runQwenLayerStagePrefillRankCheck(options: Options,
    inputs: QwenLayerStageComparisonAdmission.Inputs, check: () throws -> Void
) throws -> QwenLayerStagePrefillRankReport {
    try QwenLayerStagePrefillRankAdmission.validateOptions(options)
    let collective = try Collective(transport: options.transport)
    let request = try QwenLayerStageRecordedRequest(request: .init(
        requestID: QwenLayerStageRankAdmission.requestID(epoch: options.epoch!),
        promptCount: inputs.prompt.count, chunkSize: options.chunkSize, outputCount: 1),
        vocabularySize: inputs.vocabularySize, prompt: inputs.prompt, teacher: [])
    var memory = [QwenStageMemoryObservation("before_stage_load")]
    weak var stageModel: Module?
    let result = try autoreleasepool {
        let loaded = try loadVerifiedQwenLayerStage(directory: options.modelDirectory!,
            originalConfiguration: inputs.configurationData, plan: inputs.plan, stageIndex: collective.rank,
            expectedAggregateSHA256: options.expectedArtifactAggregateSHA256!)
        stageModel = loaded.model
        try check()
        let agreement = try prefillRankAgreement(loaded: loaded, inputs: inputs, request: request, options: options)
        let transfer = try QwenLayerStagePrefillTransport(collective: collective, agreement: agreement, admittedRank: collective.rank)
        memory.append(QwenStageMemoryObservation("stage_loaded_no_request_state"))
        do {
            try requireQwenLayerStagePrefillRankReadiness(agreement, collective: collective, check: check)
            try emitJSON(QwenLayerStagePrefillRankReady(epoch: options.epoch!, rank: collective.rank,
                agreementFingerprint: agreement.fingerprint, agreement: agreement.descriptor))
            let execution = try runQwenLayerStagePrefillRankRequest(loaded: loaded, plan: inputs.plan,
                agreement: agreement, transport: transfer, check: check)
            guard transfer.isComplete, !transfer.isFailed else { throw ProbeError("Prefill rank transport did not complete its post-stop release") }
            memory.append(QwenStageMemoryObservation("stage_request_retired_weights_resident"))
            return (loaded.receipt, agreement, execution)
        } catch { transfer.retire(); throw error }
    }
    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
    guard stageModel == nil else { throw ProbeError("Prefill rank retained its loaded model after request retirement") }
    Memory.clearCache(); try check()
    memory.append(QwenStageMemoryObservation("stage_model_released_cache_cleared"))
    return .init(epoch: options.epoch!, rank: collective.rank,
        agreementFingerprint: result.1.fingerprint, agreement: result.1.descriptor,
        sourceLoad: result.0, request: request, execution: result.2,
        conservativeStateAndBoundaryBytes: inputs.conservativeStateAndBoundaryBytes, memory: memory)
}

private func prefillRankAgreement(loaded: LoadedQwenLayerStage,
    inputs: QwenLayerStageComparisonAdmission.Inputs, request: QwenLayerStageRecordedRequest,
    options: Options) throws -> QwenLayerStagePrefillStartAgreement {
    guard let root = try JSONSerialization.jsonObject(with: inputs.configurationData) as? [String: Any] else {
        throw ProbeError("Prefill rank configuration is not an object")
    }
    let text = root["text_config"] as? [String: Any] ?? root
    let hidden = try QwenStageMetadata.integer(text, "hidden_size", limit: 8192)
    let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: loaded.receipt.sourceConfigurationSHA256,
        artifactAggregateSHA256: loaded.receipt.verifiedAggregateSHA256,
        storageCommitmentSHA256: loaded.receipt.storageCommitmentSHA256,
        planFingerprint: inputs.plan.fingerprint, producerStageFingerprint: inputs.plan.stages[0].fingerprint)
    return try .init(epoch: options.epoch!, request: request, sourceIdentity: source,
        consumerStageFingerprint: inputs.plan.stages[1].fingerprint,
        producerConstructionConfigurationSHA256: sha256(inputs.plan.stages[0].constructionConfiguration),
        consumerConstructionConfigurationSHA256: sha256(inputs.plan.stages[1].constructionConfiguration),
        bf16ConversionEnabled: loaded.receipt.bf16ConversionEnabled, hiddenSize: hidden,
        nativeDType: String(describing: loaded.activationDType), logitsDType: options.stageLogitsDType!,
        schedulingPolicy: options.stagePrefillPolicy!)
}
