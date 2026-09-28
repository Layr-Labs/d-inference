import Foundation
import MLX
import MLXNN

/// The only strong full-model owner after loading. No model, Module, MLXArray,
/// session or state owner crosses this file's callback/return boundaries.
private final class QwenLongPrefillResidentSoloOwner {
    private var loaded: LoadedModel?
    private weak var model: Module?
    private let lifecycle: QwenLayerStageResidentLifecycle

    init(loaded: LoadedModel, maximumRequests: Int) throws {
        self.loaded = loaded; self.model = loaded.model
        self.lifecycle = try .init(maximumRequests: maximumRequests)
    }

    func request(_ admission: QwenRegistered9BLongPrefillReferenceAdmission,
        check: () throws -> Void
    ) throws -> QwenLongPrefillSoloRequestResult {
        let id = admission.request.request.requestID
        // Solo has no wire epoch. Use its same unique request UUID solely in
        // the shared CPU lifecycle's second identity slot, never as wire proof.
        return try lifecycle.withRequest(identity: .init(requestID: id, epoch: id,
            recordedRequestFingerprint: admission.request.fingerprint)) {
            try autoreleasepool {
                guard let loaded else { throw ProbeError("Resident solo weights have been released") }
                return try runQwenLongPrefillSoloRequest(loaded: loaded, admission: admission, check: check)
            }
        }
    }

    func release() throws {
        try lifecycle.withModelRelease {
            try MLX.withError { error in
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                try error.check()
                loaded = nil
                guard model == nil else { throw ProbeError("Resident full model remained retained after request scopes") }
                Memory.clearCache()
                try error.check()
            }
        }
    }
}

/// Internal owner for a worker which already performed process arithmetic,
/// actual OS/resource and deadline admission. No CLI or resource gate is added.
/// The request timer, source checks, native forward and retirement are unchanged.
func runQwenLongPrefillResidentSoloCohort(options: Options,
    requests: [QwenRegistered9BLongPrefillReferenceAdmission], warmupCount: Int,
    onModelReady: (QwenLongPrefillResidentSoloReady) throws -> Void,
    beforeRequest: (QwenLongPrefillResidentRequestStep) throws -> Void,
    onRequestResult: (QwenLongPrefillResidentRequestStep, QwenLongPrefillSoloRequestResult) throws -> Void,
    check: () throws -> Void
) throws -> QwenLongPrefillResidentSoloReport {
    let steps = try QwenLongPrefillResidentSoloAdmission.validate(
        options: options, requests: requests, warmupCount: warmupCount)
    let first = requests[0]
    var owner: QwenLongPrefillResidentSoloOwner?
    weak var model: Module?
    var releaseAttempted = false
    var memory = [QwenStageMemoryObservation("before_resident_full_model_load")]
    do {
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            try checked()
            let (source, receipt) = try autoreleasepool {
                let loaded = try loadVerifiedQwenLayerStageBaseline(directory: options.modelDirectory!,
                    originalConfiguration: first.configuration,
                    expectedAggregateSHA256: first.resource.expectedArtifactAggregateSHA256)
                model = loaded.model
                let admitted = try admitQwenLongPrefillReferenceSource(loaded: loaded, admission: first)
                owner = try .init(loaded: loaded, maximumRequests: requests.count)
                try checked()
                return admitted
            }
            memory.append(QwenStageMemoryObservation("resident_full_model_loaded_no_request_state"))
            try checked()
            try onModelReady(.init(source: source, sourceLoad: receipt,
                arithmeticEnvironment: first.arithmetic,
                arithmeticEnvironmentSHA256: first.arithmeticEnvironmentSHA256,
                resourceAdmission: first.resource, requestCount: requests.count, warmupCount: warmupCount))
            try checked()
            let results = try runQwenLongPrefillResidentSteps(steps: steps,
                beforeRequest: beforeRequest,
                request: { step in
                    let result = try owner!.request(requests[step.ordinal], check: checked)
                    memory.append(QwenStageMemoryObservation("resident_solo_request_\(step.ordinal)_retired_weights_resident"))
                    return result
                }, onRequestResult: onRequestResult, check: checked)
            releaseAttempted = true
            try owner!.release(); owner = nil
            guard model == nil else { throw ProbeError("Resident solo cohort did not release its full model") }
            try checked()
            memory.append(QwenStageMemoryObservation("resident_full_model_released_cache_cleared"))
            return .init(sourceLoad: receipt, arithmeticEnvironment: first.arithmetic,
                arithmeticEnvironmentSHA256: first.arithmeticEnvironmentSHA256,
                resourceAdmission: first.resource, warmupCount: warmupCount,
                requests: zip(steps, results).map { .init(step: $0.0, execution: $0.1) }, memory: memory)
        }
    } catch {
        let primary = error
        var cleanup: [String] = []
        if let owner, !releaseAttempted {
            releaseAttempted = true
            do { try owner.release() } catch { cleanup.append(String(describing: error)) }
        }
        owner = nil
        do {
            try MLX.withError { error in
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                Memory.clearCache(); try error.check()
            }
        } catch { cleanup.append(String(describing: error)) }
        if model != nil { cleanup.append("resident full model remained retained") }
        if !cleanup.isEmpty {
            throw ProbeError("Resident solo cohort failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))")
        }
        throw primary
    }
}
