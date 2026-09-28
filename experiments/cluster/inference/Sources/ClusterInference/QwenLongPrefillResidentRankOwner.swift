import Foundation
import MLX
import MLXNN

/// Only this file can construct or access the resident owner. No model, array,
/// Module or mutable Loaded stage crosses its request or release interfaces.
private final class QwenLongPrefillResidentRankOwner {
    private var loaded: LoadedQwenLayerStage?
    private weak var model: Module?
    private let lifecycle: QwenLayerStageResidentLifecycle
    private let collective: Collective

    init(loaded: LoadedQwenLayerStage, collective: Collective, maximumRequests: Int) throws {
        self.loaded = loaded; self.model = loaded.model; self.collective = collective
        self.lifecycle = try .init(maximumRequests: maximumRequests)
    }

    func request(_ request: QwenLongPrefillResidentRankRequest, options: Options,
                 ordinal: Int, excludedWarmup: Bool, check: () throws -> Void
    ) throws -> QwenLongPrefillResidentRankRequestReport {
        try lifecycle.withRequest(identity: request.identity) {
            // The gate returns to idle only after this entire scope returns.
            try autoreleasepool {
                guard let loaded else { throw ProbeError("Resident weights have been released") }
                var current = options
                current.epoch = request.epoch
                current.longPromptSHA256 = request.local.promptFileSHA256
                let agreement = try qwenLongPrefillRankAgreement(loaded: loaded, local: request.local, options: current)
                let execution = try runQwenLongPrefillRankRequest(loaded: loaded, local: request.local,
                    agreement: agreement, collective: collective, onReady: {}, check: check)
                return .init(ordinal: ordinal, excludedWarmup: excludedWarmup, epoch: request.epoch,
                    request: request.local.request, promptFileSHA256: request.local.promptFileSHA256,
                    agreement: agreement.descriptor, execution: execution)
            }
        }
    }

    func release() throws {
        try lifecycle.withModelRelease {
            try MLX.withError { error in
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                try error.check()
                loaded = nil
                guard model == nil else { throw ProbeError("Resident stage remained retained after all request scopes") }
                Memory.clearCache()
                try error.check()
            }
        }
    }
}

/// Resident cohort seam. The entry owner remains
/// responsible for early arithmetic and actual OS resource admission/deadlines.
/// One-shot modes, forward kernels, request retirement and wire loops are reused
/// unchanged. Each next readiness exchange is also the peer retirement barrier.
func runQwenLongPrefillResidentRankCohort(options: Options,
    requests: [QwenLongPrefillResidentRankRequest], warmupCount: Int,
    jacclConfiguration: QwenResidentJACCLConfiguration? = nil,
    onModelReady: (QwenLongPrefillResidentRankReady) throws -> Void,
    beforeRequest: (QwenLongPrefillResidentRequestStep) throws -> Void,
    onRequestResult: (QwenLongPrefillResidentRequestStep, QwenLongPrefillResidentRankRequestReport) throws -> Void,
    check: () throws -> Void
) throws -> QwenLongPrefillResidentRankReport {
    let cohortAgreement = try QwenLongPrefillResidentCohortAgreement(
        options: options, requests: requests, warmupCount: warmupCount,
        jacclConfiguration: jacclConfiguration)
    let first = requests[0].local
    let steps = requests.enumerated().map { ordinal, request in
        QwenLongPrefillResidentRequestStep(ordinal: ordinal, excludedWarmup: ordinal < warmupCount,
            requestID: request.local.request.request.requestID,
            recordedRequestFingerprint: request.local.request.fingerprint,
            promptFileSHA256: request.local.promptFileSHA256)
    }
    try QwenLongPrefillResidentRequestStep.validate(steps)
    try jacclConfiguration?.requireUnchanged(environment: ProcessInfo.processInfo.environment,
        read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
    try check()
    let collective = try Collective(transport: options.transport)
    try jacclConfiguration?.requireUnchanged(environment: ProcessInfo.processInfo.environment,
        read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
    try jacclConfiguration?.requireInitialized(rank: collective.rank, worldSize: collective.size,
                                              transport: collective.transport)
    try check()
    var owner: QwenLongPrefillResidentRankOwner?
    weak var model: Module?
    var releaseAttempted = false
    var memory = [QwenStageMemoryObservation("before_resident_stage_load")]
    do {
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            let cohortReadiness = try requireQwenLongPrefillResidentCohortReadiness(
                cohortAgreement, collective: collective, check: checked)
            let receipt = try autoreleasepool {
                let loaded = try loadVerifiedQwenLayerStage(directory: options.modelDirectory!,
                    originalConfiguration: first.configuration, plan: first.plan, stageIndex: collective.rank,
                    expectedAggregateSHA256: first.resource.expectedArtifactAggregateSHA256)
                model = loaded.model
                owner = try .init(loaded: loaded, collective: collective, maximumRequests: requests.count)
                try checked()
                return loaded.receipt
            }
            memory.append(QwenStageMemoryObservation("resident_stage_loaded_no_request_state"))
            try checked()
            try onModelReady(.init(rank: collective.rank, transport: collective.transportLabel,
                jacclConfiguration: jacclConfiguration?.receipt, cohortAgreement: cohortAgreement.descriptor,
                cohortReadiness: cohortReadiness, sourceLoad: receipt, arithmeticEnvironment: first.arithmetic,
                arithmeticEnvironmentSHA256: first.arithmeticEnvironmentSHA256, resourceAdmission: first.resource,
                requestCount: requests.count, warmupCount: warmupCount))
            try checked()
            let results = try runQwenLongPrefillResidentSteps(steps: steps,
                beforeRequest: beforeRequest,
                request: { step in
                    let result = try owner!.request(requests[step.ordinal], options: options,
                        ordinal: step.ordinal, excludedWarmup: step.excludedWarmup, check: checked)
                    memory.append(QwenStageMemoryObservation("resident_request_\(step.ordinal)_retired_weights_resident"))
                    return result
                }, onRequestResult: onRequestResult, check: checked)
            releaseAttempted = true
            try owner!.release(); owner = nil
            guard model == nil else { throw ProbeError("Resident cohort did not release its stage") }
            try checked()
            memory.append(QwenStageMemoryObservation("resident_stage_released_cache_cleared"))
            return .init(rank: collective.rank, transport: collective.transportLabel,
                jacclConfiguration: jacclConfiguration?.receipt, cohortAgreement: cohortAgreement.descriptor,
                cohortReadiness: cohortReadiness, sourceLoad: receipt, arithmeticEnvironment: first.arithmetic,
                arithmeticEnvironmentSHA256: first.arithmeticEnvironmentSHA256, resourceAdmission: first.resource,
                warmupCount: warmupCount, requests: results, memory: memory)
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
        if model != nil { cleanup.append("resident stage remained retained") }
        if !cleanup.isEmpty {
            throw ProbeError("Resident cohort failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))")
        }
        throw primary
    }
}
