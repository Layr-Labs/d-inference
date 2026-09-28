import Foundation
import MLX
import MLXNN

struct QwenLongPrefillPairReferenceCheckpoint: Encodable {
    let kind = "qwen_long_prefill_pair_reference_checkpoint", schemaVersion = 1
    let baselineModelReleasedBeforeStageLoading = true
    let reference: QwenLongPrefillReferenceEvidence
    let memory: [QwenStageMemoryObservation]
}

struct QwenLongPrefillPairReport: Encodable {
    let kind = "qwen_long_prefill_pair_report", schemaVersion = 1
    let correctnessOnly = true, throughputMeasurementValid = false
    let interprocessTransportUsed = false, physicalTransferQualified = false
    let baselineModelReleasedBeforeStageLoading = true, stageModelsReleased = true
    let allRequestStateRetired = true
    let stageLoads: [QwenLayerStageLoadReceipt]
    let comparison: QwenLongPrefillPairResult
    let memory: [QwenStageMemoryObservation]
}

/// The explicit long pair CLI's correctness driver. The baseline request
/// and its model retire before either stage loads. All successful results are
/// CPU evidence; the error path preserves cleanup errors and retains no models.
func runQwenLongPrefillPairCheck(directory: URL,
    local: QwenRegistered9BLongPrefillReferenceAdmission, stageCut: Int? = nil, check: () throws -> Void
) throws -> QwenLongPrefillPairReport {
    try QwenLongPrefillStageCut.validateBinding(stageCut, plan: local.plan)
    var memory = [QwenStageMemoryObservation("before_baseline_load")]
    let reference = try produceQwenRegistered9BLongPrefillReference(directory: directory,
        admission: local, check: check)
    memory.append(QwenStageMemoryObservation("baseline_released_cache_cleared"))
    try emitJSON(QwenLongPrefillPairReferenceCheckpoint(reference: reference, memory: memory))
    weak var firstModel: Module?
    weak var secondModel: Module?
    do {
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            let result = try autoreleasepool {
                let first = try loadVerifiedQwenLayerStage(directory: directory,
                    originalConfiguration: local.configuration, plan: local.plan, stageIndex: 0,
                    expectedAggregateSHA256: local.resource.expectedArtifactAggregateSHA256)
                firstModel = first.model; try checked()
                let second = try loadVerifiedQwenLayerStage(directory: directory,
                    originalConfiguration: local.configuration, plan: local.plan, stageIndex: 1,
                    expectedAggregateSHA256: local.resource.expectedArtifactAggregateSHA256)
                secondModel = second.model; try checked()
                memory.append(QwenStageMemoryObservation("both_stages_loaded"))
                let comparison = try compareQwenLongPrefillPair(reference: reference,
                    stages: [first, second], local: local, check: checked)
                memory.append(QwenStageMemoryObservation("stage_requests_retired_weights_resident"))
                return ([first.receipt, second.receipt], comparison)
            }
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
            guard firstModel == nil, secondModel == nil else {
                throw ProbeError("Long pair retained stage models after request retirement")
            }
            Memory.clearCache(); try checked()
            memory.append(QwenStageMemoryObservation("stage_models_released_cache_cleared"))
            return .init(stageLoads: result.0, comparison: result.1, memory: memory)
        }
    } catch {
        let primary = error
        var cleanup: [String] = []
        do {
            try MLX.withError { error in
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                Memory.clearCache(); try error.check()
            }
        } catch { cleanup.append(String(describing: error)) }
        if firstModel != nil || secondModel != nil { cleanup.append("stage model remained retained") }
        if !cleanup.isEmpty {
            throw ProbeError("Long pair check failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))")
        }
        throw primary
    }
}
