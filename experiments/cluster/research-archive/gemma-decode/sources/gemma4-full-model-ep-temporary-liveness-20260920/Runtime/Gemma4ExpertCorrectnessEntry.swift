import Darwin
import Foundation
import MLX

/// Private correctness SPI. Same canonical outer native gate/315-second parent
/// fence is mandatory; this function supplies no physical ownership proof.
@_spi(ClusterTesting) public enum GemmaExpertFullCorrectness {
    public static func run(arguments: [String]) throws -> Data {
        guard arguments.count == 2, ["--describe","--check-arguments","--execute","--check-local"].contains(arguments[0]) else {
            throw ProbeError("Use --describe|--check-arguments|--check-local|--execute with one exact Gemma EP job")
        }
        let job = try Gemma4ExpertCorrectnessJob.read(URL(fileURLWithPath: arguments[1]))
        let input = try Gemma4ExpertCorrectnessInput(job: job)
        if arguments[0] == "--check-local" { return try Gemma4ExpertExecutionChecks.run(input: input) }
        let expected = try input.description()
        if arguments[0] != "--execute" { return try canonicalJSONData(expected) }
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(
            UInt64(job.timeoutSeconds) * 1_000_000_000)
        guard !overflow else { throw ProbeError("Gemma EP deadline overflow") }
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(UInt32(job.timeoutSeconds))
        defer { alarm(0) }
        weak var releasedGroup: Collective?
        return try MLX.withError { native in
            func outerCheck() throws {
                try native.check()
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProbeError("Gemma EP deadline expired") }
                try QwenResidentResourceEnvironment.require()
                let os = try QwenDenseStageLoadResources.requireInitial()
                guard os.pressureLevel == 1 else { throw ProbeError("Gemma EP requires pressure level1") }
                try native.check()
            }
            do {
                try outerCheck()
                let environment = ProcessInfo.processInfo.environment
                _ = try QwenLongPrefillArithmeticEnvironment.admit(environment)
                for name in ["MLX_QUANTIZED_CONSTANT_CACHE", "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT",
                    "MLX_GATHER_QMM_EXPERT_SLICES", "MLX_COMPILED_DECODE",
                    "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL", "DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS",
                    "DARKBLOOM_GEMMA4_PREFILL_TAIL_MIN_CHUNK", "DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY"] {
                    guard environment[name] == nil else { throw ProbeError("Gemma EP requires original arithmetic default " + name) }
                }
                try QwenResidentAllocatorPolicy.disableFreedBufferCache.configure(
                    setCacheLimit: { Memory.cacheLimit = $0 }, check: outerCheck)
                Memory.clearCache(); try outerCheck()
                // The same existing operational owner admits the complete
                // model/state/transport ledger BEFORE any Collective is made.
                let temporaryPolicy: Gemma4ExpertTemporaryPolicy? = input.partition == nil ? nil : .adjacentSynchronousV1
                let owner = try Gemma4ShortResourceOwner(plan: input.plan, target: input.target,
                    request: input.request, residualDType: .bfloat16, deadline: deadline,
                    expertTemporaryPolicy: temporaryPolicy)
                func checked() throws { try outerCheck(); try owner.check(); try outerCheck() }
                try checked()
                let result: Data = try autoreleasepool {
                    let group: Collective? = job.rank == nil ? nil : try Collective(transport: .jaccl)
                    releasedGroup = group; try checked()
                    let wire = try group.map { try Gemma4ExpertWire(input: input, group: $0) }
                    let sidecars = try Gemma4ShortSidecars(directory: job.outputDirectory)
                    let probeOperation: Gemma4ExpertCollectiveOperation?
                    let requestOperation: Gemma4ExpertCollectiveOperation?
                    if let partition = input.partition, let wire {
                        probeOperation = try .init(partition: partition, binding: input.binding(purpose: .probe), exchange: wire, temporaryPolicy: temporaryPolicy)
                        requestOperation = try .init(partition: partition, binding: input.binding(purpose: .request), exchange: wire, temporaryPolicy: temporaryPolicy)
                    } else { probeOperation = nil; requestOperation = nil }
                    do {
                        try wire?.checkpoint("begin", check: checked)
                        let executionData = try withRegisteredGemma4Forward(
                            directory: URL(fileURLWithPath: job.modelDirectory, isDirectory: true), artifact: input.artifact,
                            cut: Gemma4ShortResourceBudget.candidateCut, target: input.target,
                            request: input.request, residualDType: .bfloat16,
                            admitConstruction: owner.construction, admitPrepared: owner.prepared,
                            beforeTensor: owner.beforeTensor, afterTensor: owner.afterTensor,
                            admitLoadedProbe: owner.loaded, admitRequest: owner.request,
                            probeExpertOperation: probeOperation, requestExpertOperation: requestOperation,
                            check: checked, body: { session in
                                try Gemma4ExpertCorrectnessDriver.run(input, session: session,
                                    sidecars: sidecars, wire: wire, check: checked)
                            })
                        guard let execution = try JSONSerialization.jsonObject(with: executionData) as? [String: Any],
                              let selected = execution["selectedTokenIDs"] as? [Int], selected.count == 2 else {
                            throw ProbeError("Gemma EP execution metadata lacks exact token retirement")
                        }
                        // withRegisteredGemma4Forward already proved actual
                        // model weak release and cache clearing before this ACK.
                        try checked(); try wire?.checkpoint("model-released", selected: selected, check: checked)
                        guard wire?.complete ?? true else { throw ProbeError("Gemma EP exchange lifecycle incomplete") }
                        try probeOperation?.requireTemporaryWindowComplete()
                        try requestOperation?.requireTemporaryWindowComplete()
                        let encoded = try Gemma4ExpertCorrectnessReport.intermediate(input: input,
                            expected: expected, execution: execution, observations: wire?.observations ?? [],
                            sentTensorBytes: wire?.sentTensorBytes ?? 0, receivedTensorBytes: wire?.receivedTensorBytes ?? 0,
                            controlRecordsSent:wire?.controlRecordsSent ?? 0,
                            controlRecordsReceived:wire?.controlRecordsReceived ?? 0)
                        try checked(); return encoded
                    } catch { wire?.poison(); throw error }
                }
                // Owner remains live throughout group release and final report
                // encoding, with exactly the same full additive resource terms.
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                guard releasedGroup == nil else { throw ProbeError("Gemma EP Collective escaped its original bounded scope") }
                Memory.clearCache(); try checked()
                guard Memory.cacheMemory == 0 else { throw ProbeError("Gemma EP freed-buffer cache did not retire") }
                let resources = try owner.completed()
                let encoded = try Gemma4ExpertCorrectnessReport.finish(result, resources: resources,
                    collectiveCreated: job.rank != nil, cacheBytes: Memory.cacheMemory)
                try checked(); return encoded
            } catch {
                // Same original native-fault precedence and retirement path.
                // The physical owner still proves process/group/journal release.
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache()
                try native.check(); throw error
            }
        }
    }
}
