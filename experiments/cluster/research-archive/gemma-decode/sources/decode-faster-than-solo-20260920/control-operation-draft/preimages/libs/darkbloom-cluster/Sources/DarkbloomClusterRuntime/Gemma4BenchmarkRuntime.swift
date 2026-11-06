import Foundation
import MLX
import MLXLMCommon
import MLXNN

struct Gemma4BenchmarkExecution: Encodable {
    let schema = "gemma4_resident_benchmark_result_v1"
    let job: Gemma4BenchmarkJob
    let scopeSHA256: String, planSHA256: String
    let sourceLoad: Gemma4ForwardLoadReceipt
    let loadStartedNanoseconds: UInt64, loadCompletedNanoseconds: UInt64, probeCompletedNanoseconds: UInt64
    let samples: [Gemma4BenchmarkSample]
    let resources: Gemma4BenchmarkResourceReceipt
    let files: [Gemma4ShortFile]
    let modelReleased = true, nativeExecuted = true, measuredRequests = 3, warmupRequests = 1
    let runtimeServingEnabled = false, encryptedRDMAEstablished = false
    let numericalComparisonPerformed = false, physicalProcessOrLeaseRetirementEstablished = false
}

enum Gemma4BenchmarkRuntime {
    static func execute(_ input: Gemma4BenchmarkInput, deadline: UInt64, group: Collective?,
                        sidecars: Gemma4BenchmarkSidecars, guardMetrics: Gemma4BenchmarkGuardMetrics,
                        check: (Gemma4BenchmarkGuardObservation?) throws -> Void) throws -> Data {
        weak var releasedModel: Module?
        return try withoutActuallyEscaping(check) { borrowedCheck in
            try MLX.withError { native in
                func scopedOuterCheck(_ observation: Gemma4BenchmarkGuardObservation?) throws {
                    try guardMetrics.measure(.outerNativeFault) { try native.check() }
                    try borrowedCheck(observation)
                    try guardMetrics.measure(.outerNativeFault) { try native.check() }
                }
                func outerCheck() throws { try scopedOuterCheck(nil) }
                do {
                    let environment = ProcessInfo.processInfo.environment
                    _ = try QwenLongPrefillArithmeticEnvironment.admit(environment)
                    for name in ["MLX_QUANTIZED_CONSTANT_CACHE", "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT",
                        "MLX_GATHER_QMM_EXPERT_SLICES", "MLX_COMPILED_DECODE",
                        "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL", "DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS",
                        "DARKBLOOM_GEMMA4_PREFILL_TAIL_MIN_CHUNK", "DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY"] {
                        guard environment[name] == nil else { throw ProbeError("Gemma benchmark requires ordinary default " + name) }
                    }
                    try QwenResidentAllocatorPolicy.disableFreedBufferCache.configure(
                        setCacheLimit: { Memory.cacheLimit = $0 }, check: outerCheck)
                    Memory.clearCache(); try outerCheck()
                    let owner = try Gemma4BenchmarkResourceOwner(plan: input.plan, target: input.job.target,
                        requests: input.requests, residualDType: input.job.dtype,
                        captureEvidence: input.job.captureEvidence, prefillPolicy: input.job.prefill, deadline: deadline, guardMetrics: guardMetrics)
                    func checked() throws {
                        try guardMetrics.measure(.logicalGuard) {
                            let observation = Gemma4BenchmarkGuardObservation(mode: .combined, deadline: deadline)
                            defer { observation.close() }
                            try scopedOuterCheck(observation)
                            try owner.check(observation: observation)
                            try scopedOuterCheck(observation)
                            try observation.finish(deadline: deadline)
                        }
                    }
                    var releaseWire: Gemma4BenchmarkWire?
                    let loadStarted = DispatchTime.now().uptimeNanoseconds
                    var loadCompleted: UInt64 = 0, probeCompleted: UInt64 = 0
                    let execution: (Gemma4ForwardLoadReceipt, [Gemma4BenchmarkSample]) = try autoreleasepool {
                        let first = try input.iteration(0)
                        let firstWire = try group.map { try Gemma4BenchmarkWire(input: first, group: $0, guardMetrics: guardMetrics) }
                        releaseWire = firstWire
                        try firstWire?.checkpoint("begin", check: checked)
                        let source = try Gemma4RegisteredSource.prepare(
                            directory: URL(fileURLWithPath: input.job.modelDirectory, isDirectory: true),
                            artifact: input.artifact, cut: input.job.cut, check: checked)
                        try owner.construction(source.selection(input.job.target)); try checked()
                        let prepared = try Gemma4PreparedForwardModel.prepare(source: source, target: input.job.target, check: checked)
                        releasedModel = prepared.model.module
                        try owner.prepared(prepared)
                        let loaded = try materializeRegisteredGemma4(prepared, beforeTensor: owner.beforeTensor,
                            afterTensor: owner.afterTensor, check: checked)
                        try owner.loaded(loaded.receipt); try checked()
                        loadCompleted = DispatchTime.now().uptimeNanoseconds
                        let incoming: ((CBv2NativeKVTypeProbe.Phase, Int) throws -> MLXArray)?
                        let outgoing: ((CBv2NativeKVTypeProbe.Phase, MLXArray) throws -> Void)?
                        if input.job.rank == 1 {
                            incoming = { phase, count in try firstWire!.receiveProbe(phase: phase, count: count, check: checked) }
                        } else { incoming = nil }
                        if input.job.rank == 0 {
                            outgoing = { phase, array in try firstWire!.sendProbe(array, phase: phase, check: checked) }
                        } else { outgoing = nil }
                        let probe = try loaded.probe(incomingDType: input.job.rank == 1 ? input.job.dtype : nil,
                            incoming: incoming, observeIngress: outgoing, check: checked)
                        try owner.probeCompleted(); try checked()
                        probeCompleted = DispatchTime.now().uptimeNanoseconds
                        var samples: [Gemma4BenchmarkSample] = []
                        for ordinal in input.requests.indices {
                            let requestInput = try input.iteration(ordinal)
                            let wire: Gemma4BenchmarkWire? = ordinal == 0 ? firstWire : try group.map { try Gemma4BenchmarkWire(input: requestInput, group: $0, guardMetrics: guardMetrics) }
                            releaseWire = wire
                            if ordinal > 0 { try wire?.checkpoint("begin", check: checked) }
                            try owner.beginRequest(requestInput.request)
                            weak var releasedSession: Gemma4OwnedForwardSession?
                            let sample = try autoreleasepool {
                                let session = try Gemma4OwnedForwardSession(loaded: loaded, request: requestInput.request,
                                    probe: probe, residualDType: input.job.dtype, admitGeometry: owner.request, check: checked)
                                releasedSession = session
                                do {
                                    let sample = try Gemma4BenchmarkDriver.execute(requestInput, session: session,
                                        sidecars: sidecars, wire: wire, guardMetrics: guardMetrics, check: checked)
                                    try owner.retiredRequest(session)
                                    return sample
                                } catch {
                                    let primary = error
                                    do { try session.cancel() }
                                    catch { throw ProbeError("Gemma resident request failed (\(primary)); cleanup failed (\(error))") }
                                    throw primary
                                }
                            }
                            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                            guard releasedSession == nil else { throw ProbeError("Gemma request owner escaped its iteration") }
                            samples.append(sample)
                        }
                        guard samples.count == 4, Set(samples.map(\.selectedTokenIDsSHA256)).count == 1 else {
                            throw ProbeError("Gemma fresh resident requests did not reproduce identical token results")
                        }
                        return (loaded.receipt, samples)
                    }
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                    guard releasedModel == nil else { throw ProbeError("Gemma resident model escaped its cohort") }
                    Memory.clearCache(); try checked()
                    try releaseWire?.checkpoint("model-released", tokenIDs: execution.1.last!.selectedTokenIDs, check: checked)
                    releaseWire = nil
                    let receipt = try owner.completed()
                    return try canonicalJSONData(Gemma4BenchmarkExecution(job: input.job, scopeSHA256: input.scopeSHA256,
                        planSHA256: input.plan.fingerprint, sourceLoad: execution.0,
                        loadStartedNanoseconds: loadStarted, loadCompletedNanoseconds: loadCompleted,
                        probeCompletedNanoseconds: probeCompleted, samples: execution.1, resources: receipt, files: sidecars.files))
                } catch {
                    let primary = error
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache()
                    try native.check()
                    guard releasedModel == nil else { throw ProbeError("Gemma resident failed (\(primary)); model remains retained") }
                    throw primary
                }
            }
        }
    }
}
