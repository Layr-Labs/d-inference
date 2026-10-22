import Foundation
import MLX
import MLXNN

func runQwenLongPrefillSoloCheck(options: Options,
    admission: QwenRegistered9BLongPrefillReferenceAdmission, phaseCapture: QwenPrefillPhaseCapture? = nil, check: () throws -> Void
) throws -> QwenLongPrefillSoloReport {
    _ = try QwenLongPrefillSoloCLI.referenceOptions(options)
    var memory = [QwenStageMemoryObservation("before_full_model_load")]
    weak var model: Module?
    do {
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            let execution = try autoreleasepool {
                let loaded = try loadVerifiedQwenLayerStageBaseline(directory: options.modelDirectory!,
                    originalConfiguration: admission.configuration,
                    expectedAggregateSHA256: admission.resource.expectedArtifactAggregateSHA256)
                model = loaded.model; try checked()
                let phaseRecorder: QwenPrefillPhaseRecorder?
                if let phaseCapture {
                    phaseRecorder = try phaseCapture.makeRecorder(identity: .init(
                        requestFingerprint: admission.request.fingerprint,
                        profile: admission.request.request.profile.rawValue, role: .solo))
                } else { phaseRecorder = nil }
                let result = try runQwenLongPrefillSoloRequest(loaded: loaded, admission: admission,
                    onReady: {
                        memory.append(QwenStageMemoryObservation("full_model_loaded_no_request_state"))
                        try emitJSON(QwenLongPrefillSoloReady(profile: admission.request.request.profile,
                            profileFingerprint: admission.request.request.profile.fingerprint,
                            promptFileSHA256: admission.promptFileSHA256,
                            arithmeticEnvironmentSHA256: admission.arithmeticEnvironmentSHA256,
                            recordedRequestFingerprint: admission.request.fingerprint))
                    }, phaseRecorder: phaseRecorder, check: checked)
                memory.append(QwenStageMemoryObservation("full_request_retired_weights_resident"))
                return result
            }
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
            guard model == nil else { throw ProbeError("Long solo retained its full model after request retirement") }
            Memory.clearCache(); try checked()
            memory.append(QwenStageMemoryObservation("full_model_released_cache_cleared"))
            return .init(profile: admission.request.request.profile,
                profileFingerprint: admission.request.request.profile.fingerprint,
                promptFileSHA256: admission.promptFileSHA256, promptTokenIDsSHA256: admission.promptTokenIDsSHA256,
                arithmeticEnvironment: admission.arithmetic,
                arithmeticEnvironmentSHA256: admission.arithmeticEnvironmentSHA256,
                resourceAdmission: admission.resource, execution: execution, memory: memory)
        }
    } catch {
        phaseCapture?.fail()
        let primary = error
        var cleanup: [String] = []
        do {
            try MLX.withError { error in
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                Memory.clearCache(); try error.check()
            }
        } catch { cleanup.append(String(describing: error)) }
        if model != nil { cleanup.append("full model remained retained") }
        if !cleanup.isEmpty {
            throw ProbeError("Long solo failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))")
        }
        throw primary
    }
}
