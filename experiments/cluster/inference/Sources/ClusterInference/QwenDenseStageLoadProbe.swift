import Foundation
import MLX
import MLXLLM

struct QwenDenseStageLoadReport: Encodable {
    let kind = "qwen_dense_stage_load_report", schemaVersion = 1, completed = true
    let model: QwenRegisteredDenseModel, stageIndex: Int
    let profileFingerprint: String, arithmeticEnvironment: QwenLongPrefillArithmeticEnvironment.Receipt
    let load: QwenLayerStageLoadReceipt, budget: QwenDenseStageLoadBudget
    let initialResources: QwenDenseStageLoadOSObservation
    let loadingResources: [QwenDenseStageLoadResourceDecision]
    let releasedResources: QwenDenseStageLoadOSObservation
    let memory: [QwenStageMemoryObservation], runtime: QwenDenseStageLoadRuntimeObservation
    let selectedStagePayloadMaterialized = true, selectedParametersEvaluated = true
    let selectedStageModelsLoaded = 1, fullCheckpointVerificationPasses = 1
    let allConstructorModelsReleased = true, verifiedFileOwnerReleased = true, cacheClearCompleted = true
    let actualLocalResourceAdmissionPerformed = true, parentProcessFencingIndependentlyRequired = true
    let fullModelWeightsLoaded = false, forwardExecuted = false, requestStateCreated = false
    let tensorValuesIndependentlyCompared = false, numericalParityEstablished = false
    let providerEligibilityEstablished = false, forwardExecutionAuthorized = false
    let wholeProcessMemorySafetyEstablished = false, throughputMeasurementValid = false
}

/// The only return is completed CPU evidence after the selected model and all
/// verified file owners have left scope. External deadline/fencing remains required.
func runQwenDenseStageLoadProbe(directory: URL, selection: QwenDenseStageLoadSelection,
    check: () throws -> Void
) throws -> QwenDenseStageLoadReport {
    // Actual OS observation before hashing or any model/native construction.
    let initial = try QwenDenseStageLoadResources.requireInitial()
    try check()
    weak var retiredFiles: VerifiedCheckpoint?
    do {
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try check(); try nativeError.check() }
            do {
                try checked()
                guard !_qwen35MTPEnabled else { throw ProbeError("Selected-stage load requires MTP disabled") }
                let runtime = QwenDenseStageLoadRuntimeObservation()
                try checked()
                let result = try autoreleasepool {
                    let admission = selection.metadata
                    let checkpoint = try VerifiedCheckpoint(directory: directory,
                        configurationData: admission.configuration,
                        expectedAggregateSHA256: admission.specification.artifactSHA256,
                        maximumPayloadBytes: admission.specification.manifestBytes,
                        expectedManifestSHA256: admission.specification.manifestSHA256)
                    retiredFiles = checkpoint
                    try checked()
                    let source = try prepareQwenDenseConstructorSource(checkpoint: checkpoint, admission: admission, check: checked)
                    let loaded = try materializeQwenDenseSelectedStage(source, selection: selection, check: checked)
                    try checkpoint.checkUnchanged(); try checked()
                    return (source.profile.fingerprint, loaded)
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                guard retiredFiles == nil else { throw ProbeError("Selected-stage load retained verified file owner") }
                Memory.clearCache(); try checked()
                let released = try QwenDenseStageLoadResources.requireInitial()
                try checked()
                return QwenDenseStageLoadReport(model: selection.metadata.specification.model,
                    stageIndex: selection.stageIndex, profileFingerprint: result.0,
                    arithmeticEnvironment: selection.metadata.arithmetic, load: result.1.receipt, budget: result.1.budget,
                    initialResources: initial, loadingResources: result.1.resources, releasedResources: released,
                    memory: result.1.memory + [QwenStageMemoryObservation("selected_stage_released_cache_cleared")], runtime: runtime)
            } catch {
                let primary = error
                do { try nativeError.check() }
                catch { throw ProbeError("Native selected-stage failure (\(error)); accompanying Swift failure: \(primary)") }
                throw primary
            }
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
        if retiredFiles != nil { cleanup.append("verified file owner remained retained") }
        if !cleanup.isEmpty { throw ProbeError("Selected-stage load failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))") }
        throw primary
    }
}
