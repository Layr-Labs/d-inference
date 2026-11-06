import Foundation
import MLX
import MLXLLM

/// One verified descriptor owner and one pair load. The shared immutable
/// reference admission binds the intended recorded history, not a passed baseline.
/// This support emits no output and provides no model or arbitrary continuation.
func runQwenDenseShortPairLoadSupport(directory: URL, admission: QwenDenseShortReferenceAdmission,
    check: () throws -> Void
) throws -> QwenDenseShortPairLoadReport {
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
                    let loaded = try materializeQwenDenseShortPair(prepared, admission: admission, check: checked)
                    try checkpoint.checkUnchanged(); try checked()
                    return loaded
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                guard retiredFiles == nil else { throw ProbeError("Short pair retained its verified file owner") }
                Memory.clearCache(); try checked()
                let released = try QwenDenseStageLoadResources.requireInitial(); try checked()
                return QwenDenseShortPairLoadReport(model: admission.metadata.specification.model,
                    referenceAdmissionFingerprint: admission.fingerprint, recordedRequestFingerprint: admission.request.fingerprint,
                    loads: result.loads, budget: result.budget, initialResources: initial, releasedResources: released,
                    loadingResources: result.resources, memory: result.memory
                        + [QwenStageMemoryObservation("short_pair_released_cache_cleared")], runtime: runtime)
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
