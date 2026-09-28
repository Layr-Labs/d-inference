import Foundation
import MLX
import MLXLLM

/// Native metadata probe only. The caller must provide independent external
/// process/resource fencing. Alarm/deadline cannot make backend allocation safe.
func runQwenDenseConstructorProbe(directory: URL, admission: QwenDenseConstructorAdmission,
    check: () throws -> Void
) throws -> QwenDenseConstructorReport {
    weak var retiredFiles: VerifiedCheckpoint?
    do {
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try check(); try nativeError.check() }
            do {
                try checked()
                guard !_qwen35MTPEnabled else { throw ProbeError("Constructor probe requires MTP disabled") }
                let result = try autoreleasepool {
                    let checkpoint = try VerifiedCheckpoint(directory: directory,
                        configurationData: admission.configuration,
                        expectedAggregateSHA256: admission.specification.artifactSHA256,
                        maximumPayloadBytes: admission.specification.manifestBytes,
                        expectedManifestSHA256: admission.specification.manifestSHA256)
                    retiredFiles = checkpoint
                    try checked()
                    let prepared = try prepareQwenDenseConstructorSource(checkpoint: checkpoint,
                        admission: admission, check: checked)
                    let stages = try inspectQwenDenseConstructorStages(prepared, admission: admission, check: checked)
                    try checkpoint.checkUnchanged(); try checked()
                    return QwenDenseConstructorReport(model: prepared.profile.model, scope: admission.scope,
                        profileFingerprint: prepared.profile.fingerprint, planSHA256: admission.plan.fingerprint,
                        configurationSHA256: checkpoint.configurationSHA256,
                        manifestSHA256: admission.specification.manifestSHA256, verifiedAggregateSHA256: checkpoint.aggregate,
                        canonicalInventorySHA256: prepared.profile.canonicalInventorySHA256,
                        sourceTensorCount: prepared.source.tensors.count, sourceTensorBytes: prepared.source.sourceBytes,
                        largestSourceTensorBytes: prepared.source.largestSourceBytes,
                        sourceTensors: prepared.source.tensors,
                        sourceTensorManifestSHA256: prepared.source.sourceTensorManifestSHA256,
                        expectedSourceParameterLayoutSHA256: prepared.source.sourceParameterLayoutSHA256,
                        arithmeticEnvironment: admission.arithmetic, fullConstructor: prepared.constructor, stages: stages)
                }
                // Synchronization does not eval the discarded parameter graphs. It
                // fences existing native cleanup work; no tensor values are read.
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                guard retiredFiles == nil else { throw ProbeError("Constructor probe retained verified file owner") }
                Memory.clearCache(); try checked()
                return result
            } catch {
                let primary = error
                do { try nativeError.check() }
                catch { throw ProbeError("Native constructor failure (\(error)); accompanying Swift failure: \(primary)") }
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
        if !cleanup.isEmpty {
            throw ProbeError("Constructor probe failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))")
        }
        throw primary
    }
}
