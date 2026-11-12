import Foundation
import MLX

enum Gemma4RemoteMTPRuntime {
    static func execute(_ input: Gemma4RemoteMTPInput, deadline: UInt64, group: Collective,
                        sidecars: Gemma4BenchmarkSidecars, guardMetrics: Gemma4BenchmarkGuardMetrics,
                        check: (Gemma4BenchmarkGuardObservation?) throws -> Void) throws -> Data {
        try Gemma4RemoteMTPNativeLifetime.requireAvailable()
        let lifetime = Gemma4RemoteMTPNativeLifetime(); lifetime.group = group
        return try withoutActuallyEscaping(check) { borrowed in
            try MLX.withError { native in
                func outer(_ observation: Gemma4BenchmarkGuardObservation?) throws {
                    try native.check(); try borrowed(observation); try native.check()
                }
                func fresh() throws { try outer(nil) }
                do {
                    let env = ProcessInfo.processInfo.environment
                    _ = try QwenLongPrefillArithmeticEnvironment.admit(env)
                    for key in ["MLX_QUANTIZED_CONSTANT_CACHE","MLX_GEMMA4_FUSED_WEIGHTED_UNSORT",
                        "MLX_GATHER_QMM_EXPERT_SLICES","MLX_COMPILED_DECODE",
                        "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL","DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS",
                        "DARKBLOOM_GEMMA4_PREFILL_TAIL_MIN_CHUNK","DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY"] {
                        guard env[key] == nil else { throw ProbeError("Remote MTP requires ordinary default "+key) }
                    }
                    try QwenResidentAllocatorPolicy.disableFreedBufferCache.configure(setCacheLimit:{Memory.cacheLimit=$0},check:fresh)
                    Memory.clearCache(); try fresh()
                    let controlOperations = Gemma4MTPControlOperation(metrics:guardMetrics)
                    let control = try Gemma4RemoteMTPCohortControl(group:group,input:input,controlOperations:controlOperations)
                    let report: Data
                    if input.job.rank == 1 {
                        report = try Gemma4RemoteMTPTargetRuntime.execute(input,deadline:deadline,group:group,control:control,
                            lifetime:lifetime,sidecars:sidecars,guardMetrics:guardMetrics,check:outer)
                    } else {
                        report = try Gemma4RemoteMTPAssistantRuntime.execute(input,deadline:deadline,group:group,control:control,
                            lifetime:lifetime,check:outer)
                    }
                    try Gemma4MTPPullNativeFence.join(check:fresh)
                    guard lifetime.model == nil, lifetime.assistant == nil, lifetime.embedding == nil,
                          lifetime.session == nil, lifetime.target == nil, lifetime.service == nil else {
                        throw ProbeError("Remote MTP native roots escaped successful cohort retirement")
                    }
                    lifetime.clearAfterSuccessfulFence()
                    guard var result = try JSONSerialization.jsonObject(with:report) as? [String:Any] else {
                        throw ProbeError("Remote MTP control report is not an object")
                    }
                    if input.snapshotPolicy == .ownedBatch {
                        result["snapshotTransferPolicy"] = input.snapshotPolicy.rawValue
                    }
                    guard var controlMetrics = try JSONSerialization.jsonObject(with:
                        canonicalJSONData(controlOperations.counters.snapshot())) as? [String:Any] else {
                        throw ProbeError("Remote MTP control counters are not an object")
                    }
                    if input.snapshotPolicy == .ownedBatch {
                        // Control entry/exit counters and fences are unchanged;
                        // the complete cohort now explicitly includes the new
                        // snapshot completion/check chronology. Old readers fail.
                        controlMetrics["schema"] = "gemma4_remote_control_resource_counters_owned_snapshot_v1"
                        controlMetrics["policy"] = Gemma4MTPPullSnapshotPolicy.batchObservationPolicy
                        controlMetrics["snapshotResourceCadenceChanged"] = true
                        controlMetrics["nativeCompletionFencesChanged"] = true
                        result["controlResourceObservationPolicy"] = Gemma4MTPPullSnapshotPolicy.batchObservationPolicy
                    } else { result["controlResourceObservationPolicy"] = Gemma4MTPControlCounters.policy }
                    result["controlResourceMetrics"] = controlMetrics
                    return try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.withoutEscapingSlashes])
                } catch {
                    // Keep the original group and current model/request/protocol
                    // roots until this failed bounded process exits. No success
                    // report, retry, lease release or unbounded registry follows.
                    lifetime.retainFailedUntilProcessExit()
                    throw error
                }
            }
        }
    }
}
