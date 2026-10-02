import Foundation
import MLX

enum Gemma4MTPPullQualification {
    static func run(input: Gemma4RemoteMTPInput, group: Collective,
                    check: () throws -> Void) throws -> Data {
        guard input.benchmark.job.promptCount == 128, !input.local.job.captureEvidence,
              group.transport == .jaccl, group.size == 2, group.rank == input.job.rank else {
            throw ProbeError("Tiny remote pull qualification requires exact P128 metadata, no capture and actual JACCL role")
        }
        try Gemma4MTPPullQualificationRoots.requireAvailable()
        let roots = Gemma4MTPPullQualificationRoots(); roots.group = group
        let deadline = DispatchTime.now().uptimeNanoseconds + 55_000_000_000
        return try withoutActuallyEscaping(check) { outer in
            try MLX.withError { native in
                try QwenResidentAllocatorPolicy.disableFreedBufferCache.configure(setCacheLimit:{Memory.cacheLimit=$0},check:outer)
                Memory.clearCache(); try outer(); try native.check()
                let baseline = Memory.activeMemory, reserve = 128*1024*1024, host = 2*1024*1024
                var minimumFree = Int.max, peakExtra = 0, observations = 0
                func checked() throws {
                    try native.check(); try outer()
                    let os = try QwenResidentResourceEnvironment.observe(), now = DispatchTime.now().uptimeNanoseconds
                    let observed = QwenDenseStageLoadResources.observeNative()
                    guard now < deadline, os.pressureLevel == 1,
                          os.actualFreeBytes >= 10*1024*1024*1024+reserve+host,
                          observed.activeBytes >= baseline, observed.activeBytes <= baseline+reserve,
                          observed.cacheBytes == 0,
                          try QwenLongPrefillCheckedBytes.sum([observed.activeBytes,reserve,2*1024*1024*1024]) <= observed.allocatorLimitBytes else {
                        throw ProbeError("Tiny remote pull qualification resource/lifetime bound exceeded")
                    }
                    minimumFree = min(minimumFree,os.actualFreeBytes)
                    peakExtra = max(peakExtra,observed.activeBytes-baseline); observations += 1
                    try native.check(); try outer()
                }
                do {
                    try checked()
                    // Round every live receive/assembly and sender-pack term;
                    // this is a finite fixture allowance, not a serving profile.
                    let plan = try Gemma4MTPPullTransferPlan(frontier:1031,hiddenDType:1)
                    let named = try QwenLongPrefillCheckedBytes.sum((plan.receiverRoots+plan.senderAdditional).map {
                        try QwenResidentResourceEnvironment.allocationBound($0.bytes)
                    })
                    guard try QwenLongPrefillCheckedBytes.sum([named,plan.snapshotBytes,plan.hiddenBytes,16*1024*1024]) <= reserve else {
                        throw ProbeError("Tiny fixture allocator bounds exceed128MiB")
                    }
                    for ordinal in 0..<2 {
                        try autoreleasepool { try Gemma4MTPPullQualificationPipeline.run(ordinal,input:input,group:group,roots:roots,check:checked) }
                        try Gemma4MTPPullQualificationSupport.barrier("pipeline-\(ordinal)-retired",input:input,group:group,check:checked)
                    }
                    try autoreleasepool { try Gemma4MTPPullQualificationFaults.receiveRetention(input:input,group:group,roots:roots,check:checked) }
                    for ordinal in 0..<2 {
                        try autoreleasepool { try Gemma4MTPPullQualificationFaults.frame(ordinal,input:input,group:group,check:checked) }
                    }
                    try roots.releaseCompleted(check:checked)
                    guard roots.capture == nil, roots.staging == nil, roots.batch == nil else { throw ProbeError("Tiny pull roots did not retire") }
                    try Gemma4MTPPullQualificationSupport.barrier("all-fixture-roots-retired",input:input,group:group,check:checked)
                    roots.group = nil
                    Memory.clearCache(); try checked()
                    return try JSONSerialization.data(withJSONObject:[
                        "schema":"gemma4_remote_mtp_pull_qualification_v1","configuration":JSONSerialization.jsonObject(with:canonicalJSONData(input.job)),
                        "scopeSHA256":input.scopeSHA256,"role":input.job.role,"rank":group.rank,
                        "passed":true,"groups":Gemma4MTPPullQualificationSupport.labels,"groupCount":5,
                        "snapshotFrontiers":[3,1031,3],"completedSnapshotTransfers":21,"receiverRetainedRootLimit":9,
                        "queuedAcknowledgements":2,"completedPulls":1,"cancelledUnpulledProposals":2,
                        "staleSequenceRefused":true,"nonzeroPaddingRefused":true,"poisonedChannelReuseRefused":true,
                        "injectedPostReceiveCheckFailure":true,"actualGPUFaultInjected":false,
                        "nativeExecuted":true,"jacclExecuted":true,"gemmaWeightsExecuted":false,"assistantWeightsExecuted":false,
                        "targetForwardExecuted":false,"realAssistantProposalExecuted":false,"throughputMeasured":false,
                        "numericalComparisonPerformed":false,"servingEnabled":false,"encryptedRDMAEstablished":false,
                        "originalProcessRetirementEstablished":false,"allFixtureRootsRetired":true,
                        "nativeReserveBytes":reserve,"hostReserveBytes":host,"minimumActualFreeBytes":minimumFree,
                        "peakExtraActiveBytes":peakExtra,"resourceObservations":observations,
                        "wholeProcessPeakBoundEstablished":false],options:[.sortedKeys,.withoutEscapingSlashes])
                } catch { roots.retainFailure(); throw error }
            }
        }
    }
}
