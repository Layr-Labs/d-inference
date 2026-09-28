import Foundation
import MLX
import MLXLLM

private struct QwenDenseShortPairReleased {
    let loading: QwenDenseShortPairLoadResult
    let comparison: QwenLayerStageRecordedComparison?
    let initial: QwenDenseStageLoadOSObservation, released: QwenDenseStageLoadOSObservation
    let memory: [QwenStageMemoryObservation], runtime: QwenDenseStageLoadRuntimeObservation
}

private func runQwenDenseShortPairOwner(directory: URL, admission: QwenDenseShortReferenceAdmission,
    baseline: QwenLayerStageBaselineEvidence?, check: () throws -> Void
) throws -> QwenDenseShortPairReleased {
    if let baseline { try QwenDenseShortParityBinding.requireBaseline(baseline, admission: admission) }
    let initial = try QwenDenseStageLoadResources.requireInitial()
    let arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(ProcessInfo.processInfo.environment)
    guard try canonicalJSONData(arithmetic) == canonicalJSONData(admission.metadata.arithmetic) else {
        throw ProbeError("Short pair arithmetic environment changed after admission")
    }
    try check()
    weak var retiredFiles: VerifiedCheckpoint?
    do {
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try check(); try nativeError.check() }
            do {
                try checked()
                guard !_qwen35MTPEnabled else { throw ProbeError("Short pair requires MTP disabled") }
                let runtime = QwenDenseStageLoadRuntimeObservation(); try checked()
                let result = try autoreleasepool {
                    let metadata = admission.metadata
                    let checkpoint = try VerifiedCheckpoint(directory: directory,
                        configurationData: metadata.configuration,
                        expectedAggregateSHA256: metadata.specification.artifactSHA256,
                        maximumPayloadBytes: metadata.specification.manifestBytes,
                        expectedManifestSHA256: metadata.specification.manifestSHA256)
                    retiredFiles = checkpoint; try checked()
                    let prepared = try prepareQwenDenseConstructorSource(checkpoint: checkpoint, admission: metadata, check: checked)
                    let loading: QwenDenseShortPairLoadResult
                    let comparison: QwenLayerStageRecordedComparison?
                    if let baseline {
                        let value = try materializeQwenDenseShortPairComparison(prepared, admission: admission,
                            baseline: baseline, check: checked)
                        loading = value.loading; comparison = value.comparison
                    } else {
                        loading = try materializeQwenDenseShortPair(prepared, admission: admission, check: checked)
                        comparison = nil
                    }
                    try checkpoint.checkUnchanged(); try checked()
                    return (loading, comparison)
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                guard retiredFiles == nil else { throw ProbeError("Short pair retained its verified file owner") }
                Memory.clearCache(); try checked()
                let released = try QwenDenseStageLoadResources.requireInitial(); try checked()
                return QwenDenseShortPairReleased(loading: result.0, comparison: result.1,
                    initial: initial, released: released,
                    memory: result.0.memory + [QwenStageMemoryObservation("short_pair_released_cache_cleared")], runtime: runtime)
            } catch {
                let primary = error
                do { try nativeError.check() }
                catch { throw ProbeError("Native short pair failure (\(error)); accompanying Swift failure: \(primary)") }
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
        if !cleanup.isEmpty { throw ProbeError("Short pair load failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))") }
        throw primary
    }
}

/// Existing loading-only entry; shared admission does not claim a passed baseline.
func runQwenDenseShortPairLoadSupport(directory: URL, admission: QwenDenseShortReferenceAdmission,
    check: () throws -> Void
) throws -> QwenDenseShortPairLoadReport {
    let value = try runQwenDenseShortPairOwner(directory: directory, admission: admission, baseline: nil, check: check)
    let result = value.loading
    return QwenDenseShortPairLoadReport(model: admission.metadata.specification.model,
        referenceAdmissionFingerprint: admission.fingerprint, recordedRequestFingerprint: admission.request.fingerprint,
        loads: result.loads, budget: result.budget, initialResources: value.initial, releasedResources: value.released,
        loadingResources: result.resources, memory: value.memory, runtime: value.runtime)
}

/// The baseline is CPU-only and already released; neither native owner escapes.
func compareQwenDenseShortPair(directory: URL, admission: QwenDenseShortReferenceAdmission,
    baseline: QwenLayerStageBaselineEvidence, check: () throws -> Void
) throws -> QwenDenseShortPairComparisonReport {
    let value = try runQwenDenseShortPairOwner(directory: directory, admission: admission,
        baseline: baseline, check: check)
    guard let comparison = value.comparison else { throw ProbeError("Short pair returned no comparison") }
    return .init(loading: value.loading, comparison: comparison,
        initialResources: value.initial, releasedResources: value.released, memory: value.memory, runtime: value.runtime)
}
