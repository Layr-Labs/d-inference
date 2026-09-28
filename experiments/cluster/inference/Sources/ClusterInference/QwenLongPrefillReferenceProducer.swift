import Foundation
import MLX
import MLXNN

/// Source-only producer draft. Call in an exclusive diagnostic process after
/// early environment and independent OS resource admission. A hard external
/// deadline remains necessary if native work stalls. No Options/CLI is involved.
func produceQwenRegistered9BLongPrefillReference(directory: URL,
    admission: QwenRegistered9BLongPrefillReferenceAdmission, check: () throws -> Void
) throws -> QwenLongPrefillReferenceEvidence {
    weak var model: Module?
    do {
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            try checked()
            let result = try autoreleasepool {
                let loaded = try loadVerifiedQwenLayerStageBaseline(directory: directory,
                    originalConfiguration: admission.configuration,
                    expectedAggregateSHA256: admission.resource.expectedArtifactAggregateSHA256)
                model = loaded.model
                try checked()
                return try runQwenLongPrefillReferenceRequest(loaded: loaded, admission: admission, check: checked)
            }
            // Result contains only CPU values/private copied Data. Synchronize
            // after its request closed and the full LoadedModel scope ended.
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
            guard model == nil else { throw ProbeError("Long reference retained its full model after retirement") }
            Memory.clearCache(); try checked()
            return try QwenLongPrefillReferenceEvidence(admission: admission, execution: result)
        }
    } catch {
        let primary = error
        var cleanup: [String] = []
        // The request owner handles cancellation. This outer scope also covers
        // partial load/constructor/late CPU-evidence failures without calling a
        // throwing deadline callback during cleanup or losing the primary error.
        do {
            try MLX.withError { cleanupError in
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try cleanupError.check()
                Memory.clearCache(); try cleanupError.check()
            }
        } catch { cleanup.append(String(describing: error)) }
        if model != nil { cleanup.append("full model remained retained after failed producer scope") }
        if !cleanup.isEmpty {
            throw ProbeError("Long reference producer failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))")
        }
        throw primary
    }
}
