import Darwin
import Foundation
import MLX

/// Private bounded benchmark only. No Provider registration or serving catalog.
@_spi(ClusterTesting) public enum GemmaResidentBenchmark {
    public static func run(arguments: [String]) throws -> Data {
        guard arguments.count == 2, ["--describe", "--check-arguments", "--execute"].contains(arguments[0]) else {
            throw ProbeError("Use --describe|--check-arguments|--execute with one Gemma resident benchmark job")
        }
        let input = try Gemma4BenchmarkInput(job: Gemma4BenchmarkJob.read(URL(fileURLWithPath: arguments[1])))
        if arguments[0] != "--execute" { return try input.description() }
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(
            UInt64(input.job.timeoutSeconds) * 1_000_000_000)
        guard !overflow else { throw ProbeError("Gemma benchmark deadline overflow") }
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(UInt32(input.job.timeoutSeconds))
        defer { alarm(0) }
        weak var releasedGroup: Collective?
        return try MLX.withError { native in
            func check() throws {
                try native.check()
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProbeError("Gemma benchmark lifetime expired") }
                try QwenResidentResourceEnvironment.require()
                let os = try QwenDenseStageLoadResources.requireInitial()
                guard os.pressureLevel == 1 else { throw ProbeError("Gemma benchmark requires pressure level1") }
                try native.check()
            }
            do {
                try check()
                let bytes: Data = try autoreleasepool {
                    let group: Collective? = input.job.rank == nil ? nil : try Collective(transport: .jaccl)
                    releasedGroup = group
                    let sidecars = try Gemma4BenchmarkSidecars(directory: input.job.outputDirectory)
                    return try Gemma4BenchmarkRuntime.execute(input, deadline: deadline, group: group, sidecars: sidecars, check: check)
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
                guard releasedGroup == nil else { throw ProbeError("Gemma benchmark collective remains retained") }
                Memory.clearCache(); try check()
                guard Memory.cacheMemory == 0,
                      var report = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                    throw ProbeError("Gemma benchmark release/report validation failed")
                }
                report["collectiveCreated"] = input.job.rank != nil
                report["collectiveReleased"] = input.job.rank != nil
                report["nativeCacheBytesAfterRelease"] = Memory.cacheMemory
                let result = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
                guard result.count <= 8_388_608 else { throw ProbeError("Gemma benchmark report exceeds8MiB") }
                return result
            } catch {
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache()
                try native.check(); throw error
            }
        }
    }
}
