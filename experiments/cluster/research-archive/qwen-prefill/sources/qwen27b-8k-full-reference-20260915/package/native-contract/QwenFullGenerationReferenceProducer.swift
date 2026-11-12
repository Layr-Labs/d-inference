import Foundation
import MLX
import MLXNN

struct QwenFullGenerationReferenceReport: Encodable {
    let kind = "qwen_full_generation_reference_report"
    let schemaVersion = 1
    let completed = true
    let modelReleased = true
    let allRequestStateRetired = true
    let verifiedFullModelLoads = 1
    let freshFullModelRequests = 1
    let correctnessOnly = true
    let throughputMeasurementValid = false
    let physicalTransferQualified = false
    let candidateNumericalComparisonPerformed = false
    let execution: QwenGenerationReferenceResult
    let resources: QwenFullGenerationReferenceResourceReceipt
    let memory: [QwenStageMemoryObservation]
    let runtime: QwenDenseStageLoadRuntimeObservation
}

/// Existing full loader and scoped model ownership, with explicit per-tensor
/// resource callbacks. Request math/capture/retirement is the frozen reference.
func produceQwenFullGenerationReference(directory: URL, preflight: QwenFullGenerationReferencePreflight,
    resources: QwenFullGenerationReferenceResources
) throws -> QwenFullGenerationReferenceReport {
    weak var model: Module?
    let before = QwenStageMemoryObservation("before_full_generation_load")
    do {
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try resources.check(); try nativeError.check() }
            do {
                try checked()
                let result = try autoreleasepool {
                    let loaded = try loadQwenRegisteredGenerationReferenceBaseline(directory: directory,
                        preflight: preflight, resources: resources, check: checked)
                    model = loaded.model
                    guard let receipt = loaded.verifiedDiagnosticLoad else { throw ProbeError("Full generation model lacks its verified load receipt") }
                    try resources.modelLoaded(receipt)
                    try checked()
                    return try runQwenGenerationReference(loaded: loaded, admission: preflight.admission,
                        admitResources: resources.admitRequest, check: checked)
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                guard model == nil else { throw ProbeError("Full generation model remained retained after request retirement") }
                Memory.clearCache(); try checked()
                return .init(execution: result, resources: try resources.completedReceipt(),
                    memory: [before, QwenStageMemoryObservation("full_generation_model_released_cache_cleared")],
                    runtime: QwenDenseStageLoadRuntimeObservation())
            } catch { try nativeError.check(); throw error }
        }
    } catch {
        let primary = error
        var cleanup: [String] = []
        do {
            try MLX.withError { nativeError in
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                Memory.clearCache(); try nativeError.check()
            }
        } catch { cleanup.append(String(describing: error)) }
        if model != nil { cleanup.append("full model remained retained after failed generation scope") }
        if !cleanup.isEmpty {
            throw ProbeError("Full generation reference failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))")
        }
        throw primary
    }
}
