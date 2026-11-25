import Foundation
import MLX
import MLXNN
@_spi(ClusterBenchmark) import MLXLLM
@_spi(ClusterBenchmark) import MLXLMCommon

struct QwenResidentSoloKernelEligibility: Encodable {
    let gatedDeltaLayers: Int
    let fusedProjectionLayers: Int
    let warmupDispatch: QwenGatedDeltaWarmupObservation
    let configuredQueryBlockSize: Int
    let queryBlockDispatchIndependentlyCounted = false
    let measuredRequestDispatchObservationEnabled = false
    let optimizedAgainstAllPossibleSoloPolicies = false

    init(model: Module, warmup: QwenGatedDeltaWarmupObservation, scope: QwenResidentSoloModelScope) throws {
        let counts = qwen35BenchmarkFusedProjectionCounts(model)
        let block = cbv2BenchmarkConfiguredQueryBlockSize()
        try scope.requireWarmup(gatedDeltaLayers: counts.gatedDeltaLayers,
            fusedLayers: counts.fusedLayers, queryBlock: block,
            nativePrefillCalls: warmup.nativePrefillCalls, nativeDecodeCalls: warmup.nativeDecodeCalls,
            fallbackCalls: warmup.operationsFallbackCalls, invalidGeometryCalls: warmup.invalidGeometryCalls)
        gatedDeltaLayers = counts.gatedDeltaLayers; fusedProjectionLayers = counts.fusedLayers
        warmupDispatch = warmup; configuredQueryBlockSize = block
    }
}

struct QwenResidentSoloCohortRequest: Encodable {
    let ordinal: Int
    let isWarmup: Bool
    let execution: QwenResidentSoloRequestResult
}

struct QwenResidentSoloCohortReport: Encodable {
    let kind = "qwen_resident_solo_generation_report"
    let schemaVersion = 1
    let completed = true
    let verifiedFullModelLoads = 1
    let warmupCount = 1
    let measuredCount: Int
    let freshRequestsAdmitted: Int
    let modelReleased = true
    let allRequestStateRetired = true
    let prefixReuse = false
    let mtpEnabled = false
    let allocatorPolicy = "disable_freed_buffer_cache_v1"
    let unusedDiagnosticAllowanceStillReserved = true
    let independentNumericalComparisonPerformed = false
    let physicalOrPerformanceQualificationEstablished = false
    let externalTTFTMeasured = false
    let source: QwenLongPrefillReferenceSource
    let sourceLoad: VerifiedQwenDiagnosticReceipt
    let expectedTokenFileSHA256: String
    let kernelEligibility: QwenResidentSoloKernelEligibility
    let requests: [QwenResidentSoloCohortRequest]
    let resources: QwenFullGenerationReferenceResourceReceipt
    let memory: [QwenStageMemoryObservation]
    let runtime: QwenDenseStageLoadRuntimeObservation
}

/// Owns exactly one full model and reuses the existing serialized lifecycle.
/// Only CPU result values can escape the request body/autorelease scope.
private final class QwenResidentSoloModelOwner {
    private var loaded: LoadedModel?
    private weak var model: Module?
    private let lifecycle: QwenLayerStageResidentLifecycle
    private let scope: QwenResidentSoloModelScope

    init(loaded: LoadedModel, scope: QwenResidentSoloModelScope, maximumRequests: Int) throws {
        self.scope = scope
        lifecycle = try QwenLayerStageResidentLifecycle(maximumRequests: maximumRequests)
        self.loaded = loaded; model = loaded.model
    }

    func request(_ admission: QwenGenerationReferenceAdmission, expected: [Int],
                 admitResources: () throws -> Void, check: () throws -> Void) throws -> QwenResidentSoloRequestResult {
        let id = admission.request.requestID
        return try lifecycle.withRequest(identity: .init(requestID: id, epoch: id,
            recordedRequestFingerprint: admission.request.fingerprint)) {
            try autoreleasepool {
                guard let loaded else { throw ProbeError("Resident solo full model was released") }
                return try runQwenResidentSoloRequest(loaded: loaded, admission: admission,
                    expectedTokenIDs: expected, admitResources: admitResources, check: check)
            }
        }
    }

    func eligibility(_ warmup: QwenGatedDeltaWarmupObservation) throws -> QwenResidentSoloKernelEligibility {
        guard let loaded else { throw ProbeError("Solo eligibility lacks its resident model") }
        return try .init(model: loaded.model, warmup: warmup, scope: scope)
    }

    func release() throws {
        try lifecycle.withModelRelease {
            try MLX.withError { fault in
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try fault.check()
                loaded = nil
                guard model == nil else { throw ProbeError("Resident solo model remained retained after request scopes") }
                Memory.clearCache(); try fault.check()
            }
        }
    }
}

func produceQwenResidentSoloCohort(directory: URL, preflight: QwenResidentSoloPreflight,
    resources: QwenFullGenerationReferenceResources,
    publishLoaded: (QwenResidentSoloModelLoaded) throws -> Void,
    publishRetired: (QwenResidentSoloRequestRetired) throws -> Void) throws -> QwenResidentSoloCohortReport {
    let scope = try QwenResidentSoloModelScope(definition: preflight.first.admission.source.definition)
    var owner: QwenResidentSoloModelOwner?
    weak var model: Module?
    var releaseAttempted = false
    var memory = [QwenStageMemoryObservation("before_resident_solo_load")]
    do {
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try resources.check(); try nativeError.check() }
            do {
                try checked()
                let (source, receipt) = try autoreleasepool {
                    let loaded = try loadQwenRegisteredGenerationReferenceBaseline(directory: directory,
                        preflight: preflight.first, resources: resources, check: checked)
                    model = loaded.model
                    let admitted = try admitQwenRegisteredGenerationReferenceSource(
                        loaded: loaded, admission: preflight.first.admission.source)
                    try resources.modelLoaded(admitted.1)
                    owner = try QwenResidentSoloModelOwner(loaded: loaded, scope: scope, maximumRequests: preflight.requests.count)
                    try checked()
                    return admitted
                }
                memory.append(QwenStageMemoryObservation("resident_solo_loaded_no_request_state"))
                try publishLoaded(.init(preflight: preflight, source: source, sourceLoad: receipt))
                var results: [QwenResidentSoloCohortRequest] = []
                var eligibility: QwenResidentSoloKernelEligibility?
                var requestAdmissions = 0
                for (ordinal, admission) in preflight.requests.enumerated() {
                    try checked()
                    let now = DispatchTime.now().uptimeNanoseconds
                    let addition = now.addingReportingOverflow(120_000_000_000)
                    guard !addition.overflow else { throw ProbeError("Solo request deadline overflow") }
                    let deadline = min(resources.deadline, addition.partialValue)
                    func requestCheck() throws {
                        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProbeError("Resident solo request deadline expired") }
                        try checked()
                        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProbeError("Solo request expired during resource check") }
                    }
                    func request() throws -> QwenResidentSoloRequestResult {
                        guard let owner, requestAdmissions == ordinal else { throw ProbeError("Solo admission order differs") }
                        return try owner.request(admission, expected: preflight.expectedTokenIDs,
                            admitResources: {
                                // The inherited ledger is admitted once for the bounded serial
                                // cohort. Every request has already passed the exact same-geometry
                                // preflight; its live check is repeated before any fresh state.
                                if ordinal == 0 { try resources.admitRequest(preflight.first.admission.requirements) }
                                try requestCheck()
                                requestAdmissions += 1
                            }, check: requestCheck)
                    }
                    let result: QwenResidentSoloRequestResult
                    if ordinal == 0 {
                        let observed = try withQwenGatedDeltaWarmupObservation(request, profile: scope.warmupProfile)
                        result = observed.0
                        guard let owner else { throw ProbeError("Warmup owner disappeared") }
                        eligibility = try owner.eligibility(observed.1)
                    } else {
                        guard eligibility != nil else { throw ProbeError("Measured request lacks warmup kernel eligibility") }
                        result = try request()
                    }
                    try requestCheck()
                    let retired = QwenResidentSoloCohortRequest(ordinal: ordinal, isWarmup: ordinal == 0, execution: result)
                    results.append(retired)
                    memory.append(QwenStageMemoryObservation("resident_solo_request_\(ordinal)_retired"))
                    guard let eligibility else { throw ProbeError("Retired request lacks warmup eligibility") }
                    // CPU-only publication follows request/autorelease/lifecycle retirement.
                    // Its I/O is outside every request timing interval and before the next request.
                    try publishRetired(.init(preflight: preflight, request: retired, kernelEligibility: eligibility))
                }
                guard requestAdmissions == preflight.requests.count, results.count == preflight.requests.count,
                      let eligibility, let owned = owner else {
                    throw ProbeError("Resident solo cohort ended before all configured retired requests")
                }
                releaseAttempted = true; try owned.release(); owner = nil
                guard model == nil else { throw ProbeError("Resident solo did not release its full model") }
                try checked()
                memory.append(QwenStageMemoryObservation("resident_solo_model_released"))
                return .init(measuredCount: preflight.measuredCount, freshRequestsAdmitted: requestAdmissions,
                    source: source, sourceLoad: receipt,
                    expectedTokenFileSHA256: preflight.expectedTokenFileSHA256, kernelEligibility: eligibility,
                    requests: results, resources: try resources.completedReceipt(), memory: memory,
                    runtime: QwenDenseStageLoadRuntimeObservation())
            } catch { try nativeError.check(); throw error }
        }
    } catch {
        let primary = error
        var cleanup: [String] = []
        if let owner, !releaseAttempted {
            releaseAttempted = true
            do { try owner.release() } catch { cleanup.append(String(describing: error)) }
        }
        owner = nil
        do { try MLX.withError { fault in
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache(); try fault.check()
        } } catch { cleanup.append(String(describing: error)) }
        if model != nil { cleanup.append("resident solo full model remains retained") }
        if !cleanup.isEmpty { throw ProbeError("Resident solo cohort failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))") }
        throw primary
    }
}
