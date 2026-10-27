import Darwin
import Foundation
import MLX

@_spi(ClusterTesting) public enum GemmaExpertRDMACheck {
    public static func run(arguments: [String]) throws -> Data {
        if arguments == ["--check-local"] { return try ExpertAxisRDMALocalChecks.run() }
        guard arguments.count == 2, ["--describe", "--check-arguments", "--execute"].contains(arguments[0]) else {
            throw ProbeError("Use --describe|--check-arguments|--execute JOB, or --check-local")
        }
        let job = try ExpertAxisRDMAJob.decode(BoundedProbeInput.data(URL(fileURLWithPath: arguments[1]), maximumBytes: 16_384))
        if arguments[0] != "--execute" {
            return try JSONSerialization.data(withJSONObject: [
                "schema": "gemma4_expert_rdma_capability_v1", "scopeSHA256": job.scopeSHA256,
                "rank": job.rank, "globalLayerIndex": job.layer,
                "globalExpertIDsByRank": job.expertOwnership().globalIDsByRank,
                "tokenCounts": job.tokenCounts, "topK": 8, "hiddenSize": 2816, "intermediateSize": 704,
                "dtype": "bfloat16", "maximumAssignments": ExpertAxisQualificationLimits.maximumAssignments,
                "maximumControlBytes": ExpertAxisRDMACodec.controlLimit,
                "maximumTensorBytes": ExpertAxisRDMACodec.payloadLimit,
                "maximumRecordsPerDirection": ExpertAxisRDMACodec.recordLimit,
                "extraNativeStagingBytes": ExpertAxisRDMAResources.extraNativeBytes,
                "extraHostStagingBytes": ExpertAxisRDMAResources.extraHostBytes,
                "minimumActualFreeBytes": 6 * 1_073_741_824, "requiresAC": true,
                "requiredPressureLevel": 1, "maximumSwapBytes": 0,
                "metadataOnly": true, "nativeExecuted": false, "sourcePayloadVerified": false,
                "deviceOnlyDynamicRoutingQualified": false, "encryptedRDMA": false,
                "runtimeServingEnabled": false, "buildIdentityRequiresParentVerification": true],
                options: [.sortedKeys, .withoutEscapingSlashes])
        }
        guard URL(fileURLWithPath: job.modelDirectory).resolvingSymlinksInPath().path == job.modelDirectory else {
            throw ProbeError("Expert RDMA checkpoint must use its canonical source path")
        }
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(UInt64(job.timeoutSeconds)*1_000_000_000)
        guard !overflow else { throw ProbeError("Expert RDMA deadline overflow") }
        // The executable's SIGALRM handler remains live through final stdout.
        alarm(UInt32(job.timeoutSeconds))
        weak var releasedGroup: Collective?
        return try MLX.withError { native in
            func initialCheck() throws {
                try native.check()
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProbeError("Expert RDMA lifetime expired") }
                try QwenResidentResourceEnvironment.require()
                guard try QwenDenseStageLoadResources.requireInitial().pressureLevel == 1 else {
                    throw ProbeError("Expert RDMA requires pressure level1")
                }
                try native.check()
            }
            do {
                let environment = ProcessInfo.processInfo.environment
                _ = try QwenLongPrefillArithmeticEnvironment.admit(environment)
                for name in ["MLX_QUANTIZED_CONSTANT_CACHE", "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT",
                    "MLX_GATHER_QMM_EXPERT_SLICES", "MLX_COMPILED_DECODE",
                    "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL", "DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS",
                    "DARKBLOOM_GEMMA4_PREFILL_TAIL_MIN_CHUNK", "DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY"] {
                    guard environment[name] == nil else { throw ProbeError("Expert RDMA requires ordinary default " + name) }
                }
                try initialCheck()
                try QwenResidentAllocatorPolicy.disableFreedBufferCache.configure(setCacheLimit: { Memory.cacheLimit = $0 }, check: initialCheck)
                Memory.clearCache(); try initialCheck()
                let geometry = try ExpertAxisGeometry(hidden: 2816, intermediate: 704, experts: 128, metadataDType: .bfloat16)
                let resources = try ExpertAxisRDMAResources(geometry: geometry, ownership: job.expertOwnership(), deadline: deadline)
                func checked() throws { try resources.check(native: { try native.check() }); try initialCheck() }
                try checked()
                let bytes: Data = try autoreleasepool {
                    let group = try Collective(transport: .jaccl); releasedGroup = group
                    try checked()
                    return try ExpertAxisRDMARuntime.run(job: job, group: group, resources: resources, check: checked)
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                guard releasedGroup == nil else { throw ProbeError("Expert RDMA group escaped original scope") }
                Memory.clearCache(); try checked()
                guard Memory.cacheMemory == 0, var value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                    throw ProbeError("Expert RDMA cache/report retirement failed")
                }
                value["collectiveReleased"] = true; value["nativeCacheBytesAfterRelease"] = 0
                value["nativeExecuted"] = true
                let result = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
                guard result.count <= 2_097_152 else { throw ProbeError("Expert RDMA report exceeds2MiB") }
                return result
            } catch {
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache()
                try native.check(); throw error
            }
        }
    }
}
