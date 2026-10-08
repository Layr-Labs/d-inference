import Darwin
import Foundation
import MLX

/// Private correctness SPI. This does not add a worker registration or serving path.
@_spi(ClusterTesting) public enum GemmaShortCorrectnessCheck {
    public static func run(arguments: [String]) throws -> Data {
        if arguments == ["--check-attention-identity", "cpu"] {
            return try Gemma4AttentionIdentityCheck.run()
        }
        guard arguments.count == 2, ["--describe", "--check-arguments", "--execute", "--check-local-fixtures"].contains(arguments[0]) else {
            throw ProbeError("Use --describe|--check-arguments|--execute with one exact Gemma short job")
        }
        if arguments[0] == "--check-local-fixtures" { return try Gemma4ShortLocalChecks.run(directory: arguments[1]) }
        let job = try Gemma4ShortCheckJob.read(URL(fileURLWithPath: arguments[1]))
        let input = try Gemma4ShortCheckInput(job: job)
        let description = try input.description()
        if arguments[0] != "--execute" { return try canonicalJSONData(description) }
        let start = DispatchTime.now().uptimeNanoseconds
        let delta = UInt64(job.timeoutSeconds) * 1_000_000_000
        let (deadline, overflow) = start.addingReportingOverflow(delta)
        guard !overflow else { throw ProbeError("Gemma native deadline overflow") }
        // Last resort for a blocked native call. It makes no cleanup/lease claim;
        // the canonical root supervisor still owns process fencing and journals.
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(UInt32(job.timeoutSeconds))
        defer { alarm(0) }
        weak var releasedGroup: Collective?
        let result: Data = try MLX.withError { native in
            func check() throws {
                try native.check()
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProbeError("Gemma native deadline expired") }
                try QwenResidentResourceEnvironment.require()
                _ = try QwenDenseStageLoadResources.requireInitial()
                try native.check()
            }
            do {
                try check()
                let output: Data = try autoreleasepool {
                    let group: Collective? = job.rank == nil ? nil : try Collective(transport: .jaccl)
                    releasedGroup = group
                    let wire = try group.map { try Gemma4ShortWire(input: input, group: $0) }
                    let sidecars = try Gemma4ShortSidecars(directory: job.outputDirectory)
                    do {
                        try wire?.checkpoint("begin", check: check)
                        let value = try withRegisteredGemma4ShortCorrectness(
                            directory: URL(fileURLWithPath: job.modelDirectory, isDirectory: true),
                            artifact: input.artifact, target: job.target, request: input.request,
                            residualDType: job.dtype, deadline: deadline,
                            probeInput: job.rank == 1 ? { phase, count in
                                try wire!.receiveProbe(phase: phase, count: count, check: check)
                            } : nil,
                            observeProbeOutput: job.rank == 0 ? { phase, array in
                                try wire!.sendProbe(array, phase: phase, check: check)
                            } : nil,
                            check: check, body: { session, checked in
                                try Gemma4ShortDriver.execute(input, session: session, sidecars: sidecars,
                                    wire: wire, check: checked)
                            })
                        guard let execution = try JSONSerialization.jsonObject(with: value.data) as? [String: Any],
                              let tokens = execution["selectedTokenIDs"] as? [Int], tokens.count == 2 else {
                            throw ProbeError("Gemma bounded body returned malformed completion metadata")
                        }
                        try wire?.checkpoint("model-released", tokenIDs: tokens, check: check)
                        let report: [String: Any] = ["schema": "gemma4_short_result_v1", "mode": job.mode,
                            "expected": try JSONSerialization.jsonObject(with: canonicalJSONData(description)),
                            "execution": execution,
                            "resources": try JSONSerialization.jsonObject(with: canonicalJSONData(value.resources)),
                            "modelReleased": true, "nativeExecuted": true,
                            "collectiveCreated": job.rank != nil,
                            "physicalProcessOrLeaseRetirementEstablished": false,
                            "runtimeServingEnabled": false, "numericalComparisonPerformed": false,
                            "throughputMeasurementValid": false, "encryptedRDMAEstablished": false]
                        return try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
                    } catch { wire?.poison(); throw error }
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
                guard releasedGroup == nil else { throw ProbeError("Gemma collective escaped its bounded scope") }
                Memory.clearCache(); try check()
                guard Memory.cacheMemory == 0 else { throw ProbeError("Gemma native freed-buffer cache did not retire") }
                guard var report = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
                    throw ProbeError("Gemma final report object differs")
                }
                report["collectiveReleased"] = job.rank != nil
                report["nativeCacheBytesAfterRelease"] = Memory.cacheMemory
                let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
                guard bytes.count <= 1_048_576 else { throw ProbeError("Gemma final report exceeds its fixed output bound") }
                return bytes
            } catch {
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache()
                try native.check(); throw error
            }
        }
        return result
    }
}
