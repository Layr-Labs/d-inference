import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Local adapter over the existing target/auxiliary owners. No Collective,
/// second device owner, lease, unchecked loader or alternate request state.
enum Gemma4LocalMTPRuntime {
    static func execute(_ local: Gemma4LocalMTPInput, deadline: UInt64,
        sidecars: Gemma4BenchmarkSidecars, guardMetrics: Gemma4BenchmarkGuardMetrics,
        check: (Gemma4BenchmarkGuardObservation?) throws -> Void
    ) throws -> Data {
        let input = local.benchmark
        weak var releasedModel: Module?
        weak var releasedAssistant: Module?
        return try withoutActuallyEscaping(check) { borrowedCheck in
            try MLX.withError { native in
                func outer(_ observation: Gemma4BenchmarkGuardObservation?) throws {
                    try guardMetrics.measure(.outerNativeFault) { try native.check() }
                    try borrowedCheck(observation)
                    try guardMetrics.measure(.outerNativeFault) { try native.check() }
                }
                func fresh() throws { try outer(nil) }
                var auxiliary: Gemma4MTPAuxiliaryOwner?
                do {
                    let environment = ProcessInfo.processInfo.environment
                    _ = try QwenLongPrefillArithmeticEnvironment.admit(environment)
                    for name in ["MLX_QUANTIZED_CONSTANT_CACHE", "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT",
                        "MLX_GATHER_QMM_EXPERT_SLICES", "MLX_COMPILED_DECODE",
                        "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL", "DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS",
                        "DARKBLOOM_GEMMA4_PREFILL_TAIL_MIN_CHUNK", "DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY"] {
                        guard environment[name] == nil else { throw ProbeError("Local MTP requires ordinary default " + name) }
                    }
                    try QwenResidentAllocatorPolicy.disableFreedBufferCache.configure(
                        setCacheLimit: { Memory.cacheLimit = $0 }, check: fresh)
                    Memory.clearCache(); try fresh()
                    let owner = try Gemma4BenchmarkResourceOwner(plan: input.plan, target: .fullReference,
                        requests: input.requests, residualDType: input.job.dtype,
                        captureEvidence: local.job.captureEvidence, prefillPolicy: .serial,
                        deadline: deadline, guardMetrics: guardMetrics)
                    let budget = try Gemma4MTPAuxiliaryBudget(artifact: local.assistant, placement: .localTarget,
                        requestSHA256: owner.budget.requestSHA256,
                        maximumFrontier: input.requests[0].finalCommittedTokens,
                        serialTargetHead: local.denseProjectionEnabled,
                        bound: QwenResidentResourceEnvironment.allocationBound)
                    let admitted = try Gemma4MTPAuxiliaryOwner(budget: budget, deadline: deadline)
                    auxiliary = admitted
                    try owner.attachMTPAuxiliary(admitted)
                    func checked() throws {
                        try guardMetrics.measure(.logicalGuard) {
                            let observation = Gemma4BenchmarkGuardObservation(mode: .combined, deadline: deadline)
                            defer { observation.close() }
                            try outer(observation); try owner.check(observation: observation)
                            try outer(observation); try observation.finish(deadline: deadline)
                        }
                    }
                    try checked()
                    let loadStarted = DispatchTime.now().uptimeNanoseconds
                    var targetLoaded: UInt64 = 0, assistantLoaded: UInt64 = 0, probeCompleted: UInt64 = 0
                    let execution: (Gemma4ForwardLoadReceipt, Gemma4AssistantLoadReceipt, [Gemma4LocalMTPCohortSample], Gemma4MTPDenseProjection.Summary?) = try autoreleasepool {
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
                        targetLoaded = DispatchTime.now().uptimeNanoseconds
                        let probe = try loaded.probe(incomingDType: nil, incoming: nil, observeIngress: nil, check: checked)
                        try owner.probeCompleted(); try checked()
                        probeCompleted = DispatchTime.now().uptimeNanoseconds
                        let assistant = try loadRegisteredGemma4Assistant(
                            directory: URL(fileURLWithPath: local.job.assistantModelDirectory, isDirectory: true),
                            artifact: local.assistant, auxiliary: admitted, check: checked)
                        releasedAssistant = assistant.model
                        defer { assistant.model.unbind() }
                        try checked(); assistantLoaded = DispatchTime.now().uptimeNanoseconds
                        let denseProjection: Gemma4MTPDenseProjection?
                        if local.denseProjectionEnabled {
                            guard case .full(let full) = loaded.model else { throw ProbeError("Dense local MTP requires the existing full target") }
                            denseProjection = try Gemma4MTPDenseProjection(model: full, resources: admitted)
                        } else { denseProjection = nil }
                        var samples: [Gemma4LocalMTPCohortSample] = []
                        for ordinal in input.requests.indices {
                            let request = try local.iteration(ordinal)
                            try owner.beginRequest(request.request)
                            weak var releasedSession: Gemma4OwnedForwardSession?
                            let sample = try autoreleasepool {
                                let session = try Gemma4OwnedForwardSession(loaded: loaded, request: request.request,
                                    probe: probe, residualDType: input.job.dtype, admitGeometry: owner.request, check: checked)
                                releasedSession = session
                                do {
                                    let binding = try session.shortDiagnosticBinding()
                                    let recorder = Gemma4LocalMTPEvidence(input: request,
                                        captureEvidence: local.job.captureEvidence,
                                        qualifyConditioning: local.qualifyConditioning && ordinal == 0)
                                    let generation = try Gemma4LocalMTPDriver.execute(input: request, session: session,
                                        assistant: assistant.model, maximumDraftTokens: local.job.maximumDraftTokens,
                                        denseProjection: denseProjection,
                                        admitVerification: { plan in
                                            try admitted.admitVerification(plan); try checked()
                                        }, requireGrant: { count, capture in
                                            try checked(); try admitted.requireGrant(count: count, capture: capture); try checked()
                                        }, observeVerifiedWindow: recorder.observe,
                                        beforeFinish: { current, selected in
                                            try recorder.finish(session: current, selected: selected, assistant: assistant.model,
                                                auxiliary: admitted, sidecars: sidecars, check: checked)
                                        }, check: checked)
                                    guard let evidence = recorder.result, session.isClosed, !session.isFailed else {
                                        throw ProbeError("Local MTP request omitted evidence callback or retirement")
                                    }
                                    try owner.retiredRequest(session)
                                    return Gemma4LocalMTPCohortSample(requestID: request.request.requestID.uuidString.lowercased(),
                                        scopeSHA256: request.scopeSHA256,
                                        selectedTokenIDsSHA256: qwenGenerationTokenHash(generation.selectedTokenIDs),
                                        binding: binding, generation: generation, evidence: evidence)
                                } catch {
                                    let primary = error
                                    do { try session.cancel() }
                                    catch { throw ProbeError("Local MTP failed (\(primary)); request cleanup failed (\(error))") }
                                    throw primary
                                }
                            }
                            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                            guard releasedSession == nil else { throw ProbeError("Local MTP request owner escaped its iteration") }
                            samples.append(sample)
                        }
                        guard samples.count == 4, Set(samples.map(\.selectedTokenIDsSHA256)).count == 1,
                              samples.filter({ $0.evidence.conditioning != nil }).count == (local.qualifyConditioning ? 1 : 0) else {
                            throw ProbeError("Fresh local MTP requests differ or conditioning qualification is missing")
                        }
                        return (loaded.receipt, assistant.receipt, samples, denseProjection?.summary)
                    }
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                    guard releasedModel == nil, releasedAssistant == nil else {
                        throw ProbeError("Local MTP target or assistant escaped its cohort")
                    }
                    Memory.clearCache(); try checked()
                    let auxiliaryReceipt = try admitted.completedAfterNativeFence(check: checked)
                    let receipt = try owner.completed()
                    return try canonicalJSONData(Gemma4LocalMTPCohortReport(configuration: local.job,
                        benchmarkJob: input.job, scopeSHA256: local.scopeSHA256,
                        ordinaryInputScopeSHA256: input.scopeSHA256, planSHA256: input.plan.fingerprint,
                        sourceLoad: execution.0, assistantLoad: execution.1,
                        loadStartedNanoseconds: loadStarted, targetLoadCompletedNanoseconds: targetLoaded,
                        assistantLoadCompletedNanoseconds: assistantLoaded, probeCompletedNanoseconds: probeCompleted,
                        samples: execution.2, resources: receipt, auxiliaryResources: auxiliaryReceipt, files: sidecars.files,
                        conditioningQualificationRequested: local.qualifyConditioning,
                        conditioningQualificationPassed: local.qualifyConditioning, denseProjection: execution.3))
                } catch {
                    let primary = error
                    auxiliary?.poison()
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache()
                    try native.check()
                    guard releasedModel == nil, releasedAssistant == nil else {
                        throw ProbeError("Local MTP failed (\(primary)); model remains retained")
                    }
                    throw primary
                }
            }
        }
    }
}
