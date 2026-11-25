import Darwin
import Foundation
import MLX

/// Private bounded benchmark only. No Provider registration or serving catalog.
@_spi(ClusterTesting) public enum GemmaResidentBenchmark {
    public static func run(arguments: [String]) throws -> Data {
        guard arguments.count == 2, ["--describe", "--check-arguments", "--execute", "--qualify-mtp-state", "--qualify-mtp-target-width", "--qualify-mtp-target-width-dense",
            "--describe-local-mtp", "--execute-local-mtp", "--qualify-mtp-conditioning", "--qualify-small-qmv",
            "--describe-local-mtp-dense", "--execute-local-mtp-dense", "--qualify-mtp-conditioning-dense",
            "--describe-remote-mtp-dense", "--execute-remote-mtp-dense",
            "--describe-remote-mtp", "--execute-remote-mtp", "--qualify-remote-mtp"].contains(arguments[0]) else {
            throw ProbeError("Use --describe|--check-arguments|--execute with one Gemma resident benchmark job")
        }
        let remote: Gemma4RemoteMTPInput?
        if ["--describe-remote-mtp", "--execute-remote-mtp", "--qualify-remote-mtp",
            "--describe-remote-mtp-dense", "--execute-remote-mtp-dense"].contains(arguments[0]) {
            remote = try Gemma4RemoteMTPInput(url:URL(fileURLWithPath:arguments[1]),
                denseProjectionEnabled:arguments[0].hasSuffix("-dense"))
        } else { remote = nil }
        if arguments[0] == "--qualify-small-qmv" {
            guard ["dense", "gathered"].contains(arguments[1]) else {
                throw ProbeError("Small QMV qualification requires dense or gathered")
            }
            signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(300)
            defer { alarm(0) }
            return try GemmaSmallQMVCheck.run(arguments: ["--" + arguments[1]])
        }
        let local: Gemma4LocalMTPInput?
        if ["--describe-local-mtp", "--execute-local-mtp", "--qualify-mtp-conditioning",
            "--describe-local-mtp-dense", "--execute-local-mtp-dense", "--qualify-mtp-conditioning-dense"].contains(arguments[0]) {
            local = try Gemma4LocalMTPInput(url: URL(fileURLWithPath: arguments[1]),
                qualifyConditioning: ["--qualify-mtp-conditioning", "--qualify-mtp-conditioning-dense"].contains(arguments[0]),
                denseProjectionEnabled:arguments[0].hasSuffix("-dense"))
        } else { local = nil }
        let input: Gemma4BenchmarkInput
        if let remote { input = remote.benchmark }
        else if let local { input = local.benchmark }
        else { input = try Gemma4BenchmarkInput(job: Gemma4BenchmarkJob.read(URL(fileURLWithPath: arguments[1]))) }
        if ["--describe-remote-mtp", "--describe-remote-mtp-dense"].contains(arguments[0]) { return try remote!.description() }
        if ["--describe-local-mtp", "--describe-local-mtp-dense"].contains(arguments[0]) { return try local!.description() }
        if ["--describe", "--check-arguments"].contains(arguments[0]) { return try input.description() }
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(
            UInt64(input.job.timeoutSeconds) * 1_000_000_000)
        guard !overflow else { throw ProbeError("Gemma benchmark deadline overflow") }
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(UInt32(input.job.timeoutSeconds))
        defer { alarm(0) }
        let guardMetrics = Gemma4BenchmarkGuardMetrics()
        weak var releasedGroup: Collective?
        return try MLX.withError { native in
            func check(_ supplied: Gemma4BenchmarkGuardObservation?) throws {
                let owned = supplied == nil ? Gemma4BenchmarkGuardObservation(mode: .entry, deadline: deadline) : nil
                defer { owned?.close() }
                let observation = supplied ?? owned!
                try guardMetrics.measure(.entryGuard) {
                    try guardMetrics.measure(.outerNativeFault) { try native.check() }
                    guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProbeError("Gemma benchmark lifetime expired") }
                    let os = try guardMetrics.measure(.environmentGuard) {
                        try observation.read(for: .entry, deadline: deadline, observationTiming: guardMetrics.observeOS)
                    }
                    try QwenDenseStageLoadPolicy.requireInitial(os, now: DispatchTime.now().uptimeNanoseconds)
                    guard os.pressureLevel == 1 else { throw ProbeError("Gemma benchmark requires pressure level1") }
                    try guardMetrics.measure(.outerNativeFault) { try native.check() }
                }
                try owned?.finish(deadline: deadline)
            }
            func freshCheck() throws { try check(nil) }
            do {
                try freshCheck()
                let bytes: Data = try autoreleasepool {
                    if let remote {
                        let group = try Collective(transport:.jaccl)
                        releasedGroup = group
                        let sidecars = try Gemma4BenchmarkSidecars(directory:input.job.outputDirectory)
                        if arguments[0] == "--qualify-remote-mtp" {
                            return try Gemma4MTPPullQualification.run(input:remote,group:group,check:freshCheck)
                        }
                        return try Gemma4RemoteMTPRuntime.execute(remote,deadline:deadline,group:group,sidecars:sidecars,
                            guardMetrics:guardMetrics,check:check)
                    }
                    if let local {
                        let sidecars = try Gemma4BenchmarkSidecars(directory: input.job.outputDirectory)
                        return try Gemma4LocalMTPRuntime.execute(local, deadline: deadline, sidecars: sidecars,
                            guardMetrics: guardMetrics, check: check)
                    }
                    if ["--qualify-mtp-target-width", "--qualify-mtp-target-width-dense"].contains(arguments[0]) {
                        try Gemma4TargetWidthRuntime.validate(input)
                        let sidecars = try Gemma4BenchmarkSidecars(directory: input.job.outputDirectory)
                        return try Gemma4TargetWidthRuntime.execute(input,
                            denseProjectionEnabled: arguments[0] == "--qualify-mtp-target-width-dense",
                            deadline: deadline, sidecars: sidecars,
                            guardMetrics: guardMetrics, check: check)
                    }
                    if arguments[0] == "--qualify-mtp-state" {
                        #if CBV2_WINDOW_STATE_FIXTURE
                        return try Gemma4MTPStateQualification.run(input: input, check: freshCheck)
                        #else
                        throw ProbeError("This native build excludes MTP state qualification")
                        #endif
                    }
                    let group: Collective? = input.job.rank == nil ? nil : try Collective(transport: .jaccl)
                    releasedGroup = group
                    let sidecars = try Gemma4BenchmarkSidecars(directory: input.job.outputDirectory)
                    return try Gemma4BenchmarkRuntime.execute(input, deadline: deadline, group: group, sidecars: sidecars, guardMetrics: guardMetrics, check: check)
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try freshCheck()
                guard releasedGroup == nil else { throw ProbeError("Gemma benchmark collective remains retained") }
                Memory.clearCache(); try freshCheck()
                guard Memory.cacheMemory == 0,
                      var report = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                    throw ProbeError("Gemma benchmark release/report validation failed")
                }
                report["collectiveCreated"] = remote != nil || input.job.rank != nil
                report["collectiveReleased"] = remote != nil || input.job.rank != nil
                report["nativeCacheBytesAfterRelease"] = Memory.cacheMemory
                report["guardMetrics"] = try JSONSerialization.jsonObject(with: canonicalJSONData(guardMetrics.snapshot()))
                report["guardObservationPolicy"] = Gemma4BenchmarkGuardInvocation.schema
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
