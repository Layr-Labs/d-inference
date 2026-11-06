import Foundation
import MLX
import MLXNN

struct Gemma4TargetWidthCohortReport: Encodable {
    let schema = "gemma4_target_width_qualification_result_v1"
    let benchmarkJob: Gemma4BenchmarkJob
    let ordinaryInputScopeSHA256: String, scopeSHA256: String, planSHA256: String
    let sourceLoad: Gemma4ForwardLoadReceipt
    let referenceRequestID: String, referenceRequestSHA256: String
    let referenceSelectedTokenIDs: [Int], referenceSelectedTokenIDsSHA256: String
    let modes: [Gemma4TargetWidthIsolationMode]
    let denseProjection: Gemma4MTPDenseProjection.Summary?
    let samples: [Gemma4TargetWidthIsolationEvidence]
    let resources: Gemma4BenchmarkResourceReceipt
    let targetResources: Gemma4MTPRemoteTargetReceipt
    let files: [Gemma4ShortFile]
    let diagnosticRequests = 4, referenceRequests = 1, comparisonRequests = 3
    let checkpointFrontier = 132, rowsPerRequest = 6, stateComponentsPerRequest = 90
    let allActualTargetArgmaxMatchReference: Bool
    let nativeExecuted = true, modelReleased = true
    let assistantLoaded = false, assistantForwardExecuted = false
    let sameBuildReferenceCreated = true, targetVerificationEnabled = true
    let numericalComparisonPerformed = false, targetBatchNumericsQualified = false
    let performanceMeasurement = false, performanceQualified = false
    let runtimeServingEnabled = false, encryptedRDMAEstablished = false
    let physicalProcessOrLeaseRetirementEstablished = false
}

/// Private diagnostic over the original full-target loader, resource owner and
/// request states. The target-only additive ledger includes conservative unused
/// sender reserves; it loads no assistant and constructs no Collective.
enum Gemma4TargetWidthRuntime {
    static let modes: [Gemma4TargetWidthIsolationMode] = [
        .ordinary, .verificationOne, .verificationThreeKeepThree, .verificationThreeKeepOne
    ]

    static func validate(_ input: Gemma4BenchmarkInput) throws {
        guard input.job.mode == "full", input.job.rank == nil,
              input.job.promptCount == 128, input.job.chunkSize == 64,
              input.job.outputCount == 16, input.job.captureEvidence,
              input.job.prefill == .serial, input.job.dtype == .bfloat16,
              input.requests.count == 4,
              input.requests.allSatisfy({ $0.promptCount == 128 && $0.chunkSize == 64
                  && $0.outputCount == 16 && $0.finalCommittedTokens == 143 }) else {
            throw ProbeError("Target width qualification requires ordinary full P128/C64/O16 BF16 capture input")
        }
    }

    static func execute(_ input: Gemma4BenchmarkInput, denseProjectionEnabled: Bool = false,
        packedHeadEnabled: Bool = false, deadline: UInt64,
        sidecars: Gemma4BenchmarkSidecars, guardMetrics: Gemma4BenchmarkGuardMetrics,
        check: (Gemma4BenchmarkGuardObservation?) throws -> Void
    ) throws -> Data {
        try validate(input)
        guard !packedHeadEnabled || denseProjectionEnabled else { throw ProbeError("Packed head requires explicit dense scope") }
        weak var releasedModel: Module?
        return try withoutActuallyEscaping(check) { borrowedCheck in
            try MLX.withError { native in
                func outer(_ observation: Gemma4BenchmarkGuardObservation?) throws {
                    try guardMetrics.measure(.outerNativeFault) { try native.check() }
                    try borrowedCheck(observation)
                    try guardMetrics.measure(.outerNativeFault) { try native.check() }
                }
                func fresh() throws { try outer(nil) }
                var attached: Gemma4MTPRemoteTargetResources?
                do {
                    let environment = ProcessInfo.processInfo.environment
                    _ = try QwenLongPrefillArithmeticEnvironment.admit(environment)
                    for name in ["MLX_QUANTIZED_CONSTANT_CACHE", "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT",
                        "MLX_GATHER_QMM_EXPERT_SLICES", "MLX_COMPILED_DECODE",
                        "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL", "DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS",
                        "DARKBLOOM_GEMMA4_PREFILL_TAIL_MIN_CHUNK", "DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY"] {
                        guard environment[name] == nil else {
                            throw ProbeError("Target width qualification requires ordinary default " + name)
                        }
                    }
                    try QwenResidentAllocatorPolicy.disableFreedBufferCache.configure(
                        setCacheLimit: { Memory.cacheLimit = $0 }, check: fresh)
                    Memory.clearCache(); try fresh()
                    let owner = try Gemma4BenchmarkResourceOwner(plan: input.plan, target: .fullReference,
                        requests: input.requests, residualDType: input.job.dtype,
                        captureEvidence: true, prefillPolicy: .serial,
                        deadline: deadline, guardMetrics: guardMetrics)
                    let budget = try Gemma4MTPRemoteTargetBudget(requestSHA256: owner.budget.requestSHA256,
                        maximumFrontier: input.requests[0].finalCommittedTokens,
                        serialTargetHead: denseProjectionEnabled, bound: QwenResidentResourceEnvironment.allocationBound)
                    let extra = try Gemma4MTPRemoteTargetResources(budget: budget, deadline: deadline)
                    attached = extra
                    // Attaches and checks the SUMMED original target + extra
                    // inequalities before constructing any target model/state.
                    try owner.attachRemoteMTPResources(extra)
                    func checked() throws {
                        try guardMetrics.measure(.logicalGuard) {
                            let observation = Gemma4BenchmarkGuardObservation(mode: .combined, deadline: deadline)
                            defer { observation.close() }
                            try outer(observation); try owner.check(observation: observation)
                            try outer(observation); try observation.finish(deadline: deadline)
                        }
                    }
                    try checked()
                    var projectionSummary: Gemma4MTPDenseProjection.Summary?
                    let execution: (Gemma4ForwardLoadReceipt, [Gemma4TargetWidthIsolationEvidence]) = try autoreleasepool {
                        let source = try Gemma4RegisteredSource.prepare(
                            directory: URL(fileURLWithPath: input.job.modelDirectory, isDirectory: true),
                            artifact: input.artifact, cut: input.job.cut, check: checked)
                        try owner.construction(source.selection(.fullReference)); try checked()
                        let prepared = try Gemma4PreparedForwardModel.prepare(source: source, target: .fullReference, check: checked)
                        releasedModel = prepared.model.module
                        try owner.prepared(prepared)
                        let loaded = try materializeRegisteredGemma4(prepared, beforeTensor: owner.beforeTensor,
                            afterTensor: owner.afterTensor, check: checked)
                        try owner.loaded(loaded.receipt); try checked()
                        let probe = try loaded.probe(incomingDType: nil, incoming: nil, observeIngress: nil, check: checked)
                        try owner.probeCompleted(); try checked()
                        let denseProjection: Gemma4MTPDenseProjection?
                        if denseProjectionEnabled {
                            guard case .full(let full) = loaded.model else { throw ProbeError("Dense scope requires full target") }
                            denseProjection = try Gemma4MTPDenseProjection(model: full, resources: extra,
                                headPolicy: packedHeadEnabled ? .packedM1 : .serialM1)
                        } else { denseProjection = nil }
                        projectionSummary = denseProjection?.summary
                        var samples: [Gemma4TargetWidthIsolationEvidence] = []
                        var reference: [Int]?
                        for ordinal in input.requests.indices {
                            let request = try input.iteration(ordinal)
                            try owner.beginRequest(request.request)
                            weak var releasedSession: Gemma4OwnedForwardSession?
                            let sample = try autoreleasepool {
                                let session = try Gemma4OwnedForwardSession(loaded: loaded, request: request.request,
                                    probe: probe, residualDType: input.job.dtype, admitGeometry: owner.request, check: checked)
                                releasedSession = session
                                do {
                                    let result = try Gemma4TargetWidthIsolation.execute(input: request, session: session,
                                        mode: modes[ordinal], expectedGreedyIDs: reference, sidecars: sidecars,
                                        denseProjection: denseProjection,
                                        admitVerification: { plan in
                                            try extra.admitVerification(plan)
                                            // The new revision is admitted on a
                                            // fresh summed observation before the
                                            // state API creates staging arrays.
                                            try checked()
                                        }, check: checked)
                                    guard session.isClosed, !session.isFailed else {
                                        throw ProbeError("Target width request did not retire its original state")
                                    }
                                    try owner.retiredRequest(session)
                                    return result
                                } catch {
                                    let primary = error
                                    do { try session.cancel() }
                                    catch {
                                        try native.check()
                                        throw ProbeError("Target width failed (\(primary)); request cleanup failed (\(error))")
                                    }
                                    try native.check(); throw primary
                                }
                            }
                            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                            guard releasedSession == nil else {
                                throw ProbeError("Target width request owner escaped its fresh iteration")
                            }
                            if ordinal == 0 {
                                guard sample.referenceGeneratedInThisSession, !sample.teacherForcedInputs,
                                      sample.actualTargetArgmax.count == 16 else {
                                    throw ProbeError("Target width reference is not actual same-build ordinary output")
                                }
                                reference = sample.actualTargetArgmax
                            } else {
                                guard let reference, sample.expectedGreedyIDs == reference,
                                      sample.forcedInputSequence == Array(reference.prefix(15)),
                                      !sample.referenceGeneratedInThisSession, sample.teacherForcedInputs else {
                                    throw ProbeError("Target width variant did not consume its actual ordinary token packet")
                                }
                            }
                            samples.append(sample)
                        }
                        guard samples.count == 4, samples.map(\.mode) == modes,
                              sidecars.files.count == 384 else {
                            throw ProbeError("Target width cohort mode or exact sidecar count differs")
                        }
                        return (loaded.receipt, samples)
                    }
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                    guard releasedModel == nil else { throw ProbeError("Target width full model escaped its cohort") }
                    Memory.clearCache(); try checked()
                    let targetReceipt = try extra.receipt(), receipt = try owner.completed()
                    let reference = execution.1[0]
                    let tokenHash = qwenGenerationTokenHash(reference.actualTargetArgmax)
                    let scope = sha256(Data((["gemma4_target_width_qualification_v1", input.scopeSHA256,
                        "reference=" + reference.requestSHA256, "tokens=" + tokenHash,
                        "checkpoint=132", "assistant=false", "performance=false"]
                        + modes.map(\.rawValue)
                        + (projectionSummary.map { [$0.policy] } ?? [])).joined(separator: "\n").utf8))
                    return try canonicalJSONData(Gemma4TargetWidthCohortReport(benchmarkJob: input.job,
                        ordinaryInputScopeSHA256: input.scopeSHA256, scopeSHA256: scope,
                        planSHA256: input.plan.fingerprint, sourceLoad: execution.0,
                        referenceRequestID: reference.requestID, referenceRequestSHA256: reference.requestSHA256,
                        referenceSelectedTokenIDs: reference.actualTargetArgmax, referenceSelectedTokenIDsSHA256: tokenHash,
                        modes: modes, denseProjection: projectionSummary, samples: execution.1, resources: receipt, targetResources: targetReceipt,
                        files: sidecars.files,
                        allActualTargetArgmaxMatchReference: execution.1.allSatisfy(\.allArgmaxMatchReference)))
                } catch {
                    let primary = error
                    attached?.poison()
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache()
                    try native.check()
                    guard releasedModel == nil else {
                        throw ProbeError("Target width failed (\(primary)); model remains retained")
                    }
                    throw primary
                }
            }
        }
    }
}
