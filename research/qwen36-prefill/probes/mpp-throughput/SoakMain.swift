import Darwin
import Foundation

private let shortWarmups = 3
private let shortSamples = 16
private let soakDispatchesPerCommandBuffer = 32
private let priorBoundedShortTFLOPS = 13.4182

private let soakShape = DenseShape(
    label: "gdn-attention-wide",
    m: 2048,
    k: 2048,
    n: 8192)

private struct SoakRecord {
    let sample: RepeatedTimingSample
    let wallStartSeconds: Double
    let wallEndSeconds: Double
}

private struct RateSummary {
    let sampleCount: Int
    let dispatchCount: Int
    let gpuSeconds: Double
    let kernelSeconds: Double
    let cpuSeconds: Double
    let effectiveTFLOPS: Double
    let medianCommandBufferTFLOPS: Double
    let minimumCommandBufferTFLOPS: Double
    let maximumCommandBufferTFLOPS: Double
}

private func format(_ value: Double, digits: Int) -> String {
    String(format: "%.\(digits)f", value)
}

private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal:
        return "nominal"
    case .fair:
        return "fair"
    case .serious:
        return "serious"
    case .critical:
        return "critical"
    @unknown default:
        return "unknown-\(state.rawValue)"
    }
}

private func percentile(_ sorted: [Double], fraction: Double) -> Double {
    precondition(!sorted.isEmpty)
    let index = Int((fraction * Double(sorted.count - 1)).rounded())
    return sorted[max(0, min(sorted.count - 1, index))]
}

private func median(_ sorted: [Double]) -> Double {
    precondition(!sorted.isEmpty)
    if sorted.count.isMultiple(of: 2) {
        return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
    return sorted[sorted.count / 2]
}

private func rateSummary(
    records: [SoakRecord],
    operationsPerDispatch: Double
) throws -> RateSummary {
    guard !records.isEmpty else {
        throw ProbeFailure.message("cannot summarize an empty soak interval")
    }
    let dispatchCount = records.reduce(0) {
        $0 + $1.sample.dispatchCount
    }
    let gpuSeconds = records.reduce(0.0) {
        $0 + $1.sample.gpuSeconds
    }
    let kernelSeconds = records.reduce(0.0) {
        $0 + $1.sample.kernelSeconds
    }
    let cpuSeconds = records.reduce(0.0) {
        $0 + $1.sample.cpuSeconds
    }
    let commandBufferRates = records.map {
        usefulTFLOPS(
            operations: operationsPerDispatch * Double($0.sample.dispatchCount),
            seconds: $0.sample.gpuSeconds)
    }.sorted()
    return RateSummary(
        sampleCount: records.count,
        dispatchCount: dispatchCount,
        gpuSeconds: gpuSeconds,
        kernelSeconds: kernelSeconds,
        cpuSeconds: cpuSeconds,
        effectiveTFLOPS: usefulTFLOPS(
            operations: operationsPerDispatch * Double(dispatchCount),
            seconds: gpuSeconds),
        medianCommandBufferTFLOPS: median(commandBufferRates),
        minimumCommandBufferTFLOPS: commandBufferRates.first!,
        maximumCommandBufferTFLOPS: commandBufferRates.last!)
}

private func printShortSummary(
    phase: String,
    samples: [RepeatedTimingSample],
    operationsPerDispatch: Double
) throws -> Double {
    guard samples.count == shortSamples else {
        throw ProbeFailure.message(
            "\(phase) has \(samples.count) samples; \(shortSamples) required")
    }
    let gpu = samples.map(\.gpuSeconds).sorted()
    let kernel = samples.map(\.kernelSeconds).sorted()
    let cpu = samples.map(\.cpuSeconds).sorted()
    let medianGPU = median(gpu)
    let medianTFLOPS = usefulTFLOPS(
        operations: operationsPerDispatch,
        seconds: medianGPU)
    print(
        "SHORT_SUMMARY phase=\(phase)"
            + " samples=\(samples.count)"
            + " gpu_median_ms=\(format(medianGPU * 1e3, digits: 6))"
            + " gpu_p10_ms=\(format(percentile(gpu, fraction: 0.10) * 1e3, digits: 6))"
            + " gpu_p90_ms=\(format(percentile(gpu, fraction: 0.90) * 1e3, digits: 6))"
            + " gpu_min_ms=\(format(gpu.first! * 1e3, digits: 6))"
            + " gpu_max_ms=\(format(gpu.last! * 1e3, digits: 6))"
            + " kernel_median_ms=\(format(median(kernel) * 1e3, digits: 6))"
            + " cpu_median_ms=\(format(median(cpu) * 1e3, digits: 6))"
            + " useful_gpu_tflops=\(format(medianTFLOPS, digits: 4))")
    return medianTFLOPS
}

private func printRateSummary(
    label: String,
    startSeconds: Double,
    endSeconds: Double,
    summary: RateSummary
) {
    print(
        "SUSTAIN_SUMMARY label=\(label)"
            + " wall_start_s=\(format(startSeconds, digits: 3))"
            + " wall_end_s=\(format(endSeconds, digits: 3))"
            + " command_buffers=\(summary.sampleCount)"
            + " dispatches=\(summary.dispatchCount)"
            + " gpu_s=\(format(summary.gpuSeconds, digits: 6))"
            + " kernel_s=\(format(summary.kernelSeconds, digits: 6))"
            + " cpu_s=\(format(summary.cpuSeconds, digits: 6))"
            + " effective_gpu_tflops=\(format(summary.effectiveTFLOPS, digits: 4))"
            + " command_buffer_median_tflops="
            + "\(format(summary.medianCommandBufferTFLOPS, digits: 4))"
            + " command_buffer_min_tflops="
            + "\(format(summary.minimumCommandBufferTFLOPS, digits: 4))"
            + " command_buffer_max_tflops="
            + "\(format(summary.maximumCommandBufferTFLOPS, digits: 4))")
}

private func runShortSamples(
    runner: SustainedMetalRunner,
    prepared: PreparedShape,
    phase: String
) throws -> [RepeatedTimingSample] {
    for index in 0..<shortWarmups {
        _ = try runner.execute(
            variant: .candidate,
            prepared: prepared,
            dispatchCount: 1,
            label: "\(phase)-warmup-\(index + 1)")
    }
    var samples: [RepeatedTimingSample] = []
    for index in 0..<shortSamples {
        let sample = try runner.execute(
            variant: .candidate,
            prepared: prepared,
            dispatchCount: 1,
            label: "\(phase)-sample-\(index + 1)")
        samples.append(sample)
        let rate = usefulTFLOPS(
            operations: soakShape.usefulOperations,
            seconds: sample.gpuSeconds)
        print(
            "SHORT_SAMPLE phase=\(phase)"
                + " index=\(index + 1)"
                + " gpu_start_s=\(format(sample.gpuStartSeconds, digits: 9))"
                + " gpu_end_s=\(format(sample.gpuEndSeconds, digits: 9))"
                + " gpu_ms=\(format(sample.gpuSeconds * 1e3, digits: 6))"
                + " kernel_ms=\(format(sample.kernelSeconds * 1e3, digits: 6))"
                + " cpu_ms=\(format(sample.cpuSeconds * 1e3, digits: 6))"
                + " useful_gpu_tflops=\(format(rate, digits: 4))")
    }
    return samples
}

private func run() throws {
    guard CommandLine.arguments.count == 4,
          let soakSeconds = Double(CommandLine.arguments[3]),
          soakSeconds > 0
    else {
        throw ProbeFailure.message(
            "usage: mpp-soak-probe <build-dir> <accepted-manifest> <seconds>")
    }
    try soakShape.validateForSteel()

    let candidates = try MPPCandidate.loadManifest(path: CommandLine.arguments[2])
    guard candidates.count == 1, let candidate = candidates.first else {
        throw ProbeFailure.message(
            "soak manifest must contain exactly one candidate")
    }
    let expectedCandidate = "mpp_m32_n32_k32_sg1_coop"
    guard candidate.id == expectedCandidate else {
        throw ProbeFailure.message(
            "soak requires \(expectedCandidate), found \(candidate.id)")
    }

    let runner = try SustainedMetalRunner(
        buildDirectory: CommandLine.arguments[1],
        candidate: candidate)
    guard runner.device.name == "Apple M3 Max" else {
        throw ProbeFailure.message(
            "probe requires Apple M3 Max, found \(runner.device.name)")
    }
    let decisionGrade = soakSeconds >= 300
    print("PROBE=mpp-fastest-valid-physical-soak")
    print("DEVICE=\(runner.device.name)")
    print("OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    print(
        "SCHEDULE candidate=\(candidate.id)"
            + " tile=M\(candidate.tileM)N\(candidate.tileN)K\(candidate.tileK)"
            + " scope=\(candidate.scope)"
            + " input_mode=\(candidate.inputMode)"
            + " source=note-046-bounded-fastest-valid-median")
    print(
        "SHAPE name=\(soakShape.label)"
            + " M=\(soakShape.m) K=\(soakShape.k) N=\(soakShape.n)"
            + " useful_gflop=\(format(soakShape.usefulOperations / 1e9, digits: 6))")
    print(
        "SOAK_PLAN requested_seconds=\(format(soakSeconds, digits: 3))"
            + " dispatches_per_command_buffer=\(soakDispatchesPerCommandBuffer)"
            + " short_samples_before=\(shortSamples)"
            + " short_samples_after=\(shortSamples)"
            + " decision_grade=\(decisionGrade ? "yes" : "no")"
            + " hardware_theorem=false")
    print(runner.pipelineFacts())
    for line in runner.counterCapabilityLines() {
        print(line)
    }

    let prepared = try PreparedShape(
        device: runner.device,
        shape: soakShape,
        seed: 0x6a09_e667_f3bc_c909)
    prepared.poisonOutput(for: .steel)
    _ = try runner.execute(
        variant: .steel,
        prepared: prepared,
        dispatchCount: 1,
        label: "correctness-steel")
    prepared.poisonOutput(for: .mpp(candidate))
    _ = try runner.execute(
        variant: .candidate,
        prepared: prepared,
        dispatchCount: 1,
        label: "correctness-candidate")
    let comparison = prepared.comparison()
    print(
        "CORRECTNESS status=\(comparison.passed ? "pass" : "fail")"
            + " elements=\(comparison.elementCount)"
            + " fp32_changed=\(comparison.fp32Changed)"
            + " bf16_changed=\(comparison.bf16Changed)"
            + " qmm_1e-3=\(comparison.qmmTolerancePassed ? "pass" : "fail")"
            + " nonfinite=\(comparison.nonFinite)"
            + " max_abs=\(String(format: "%.9g", comparison.maxAbsoluteError))"
            + " steel_hash=\(comparison.steelHash)"
            + " mpp_hash=\(comparison.mppHash)")
    guard comparison.passed else {
        throw ProbeFailure.message("winner failed correctness before soak")
    }

    if let counter = try runner.timestampCounterProbe(prepared: prepared) {
        print(
            "TIMESTAMP_COUNTER_SAMPLE status=pass"
                + " start=\(counter.start)"
                + " end=\(counter.end)"
                + " delta_ticks=\(counter.delta)"
                + " command_buffer_gpu_ms="
                + "\(format(counter.commandBufferGPUSeconds * 1e3, digits: 6))"
                + " command_buffer_kernel_ms="
                + "\(format(counter.commandBufferKernelSeconds * 1e3, digits: 6))"
                + " units=implementation_defined_gpu_timestamp_ticks")
    } else {
        print("TIMESTAMP_COUNTER_SAMPLE status=unavailable")
    }

    print(
        "THERMAL phase=before-short"
            + " state=\(thermalStateName(ProcessInfo.processInfo.thermalState))")
    let preShort = try runShortSamples(
        runner: runner,
        prepared: prepared,
        phase: "pre-soak")
    let preShortTFLOPS = try printShortSummary(
        phase: "pre-soak",
        samples: preShort,
        operationsPerDispatch: soakShape.usefulOperations)

    var records: [SoakRecord] = []
    let start = DispatchTime.now().uptimeNanoseconds
    var lastProgressSeconds = 0.0
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        let wallStart = Double(now - start) * 1e-9
        if wallStart >= soakSeconds {
            break
        }
        let sample = try runner.execute(
            variant: .candidate,
            prepared: prepared,
            dispatchCount: soakDispatchesPerCommandBuffer,
            label: "soak-\(records.count + 1)")
        let wallEnd = Double(DispatchTime.now().uptimeNanoseconds - start) * 1e-9
        records.append(SoakRecord(
            sample: sample,
            wallStartSeconds: wallStart,
            wallEndSeconds: wallEnd))
        if wallEnd - lastProgressSeconds >= 5 {
            let rate = usefulTFLOPS(
                operations: soakShape.usefulOperations
                    * Double(sample.dispatchCount),
                seconds: sample.gpuSeconds)
            let dispatchCount = records.reduce(0) {
                $0 + $1.sample.dispatchCount
            }
            print(
                "SOAK_PROGRESS wall_s=\(format(wallEnd, digits: 3))"
                    + " command_buffers=\(records.count)"
                    + " dispatches=\(dispatchCount)"
                    + " latest_gpu_tflops=\(format(rate, digits: 4))"
                    + " thermal="
                    + "\(thermalStateName(ProcessInfo.processInfo.thermalState))")
            fflush(stdout)
            lastProgressSeconds = wallEnd
        }
    }
    guard let finalWallSeconds = records.last?.wallEndSeconds,
          finalWallSeconds >= soakSeconds
    else {
        throw ProbeFailure.message("soak did not reach requested duration")
    }

    for (index, record) in records.enumerated() {
        let rate = usefulTFLOPS(
            operations: soakShape.usefulOperations
                * Double(record.sample.dispatchCount),
            seconds: record.sample.gpuSeconds)
        print(
            "SOAK_SAMPLE index=\(index + 1)"
                + " wall_start_s=\(format(record.wallStartSeconds, digits: 6))"
                + " wall_end_s=\(format(record.wallEndSeconds, digits: 6))"
                + " dispatches=\(record.sample.dispatchCount)"
                + " gpu_start_s=\(format(record.sample.gpuStartSeconds, digits: 9))"
                + " gpu_end_s=\(format(record.sample.gpuEndSeconds, digits: 9))"
                + " gpu_ms=\(format(record.sample.gpuSeconds * 1e3, digits: 6))"
                + " kernel_ms=\(format(record.sample.kernelSeconds * 1e3, digits: 6))"
                + " cpu_ms=\(format(record.sample.cpuSeconds * 1e3, digits: 6))"
                + " useful_gpu_tflops=\(format(rate, digits: 4))")
    }

    let overall = try rateSummary(
        records: records,
        operationsPerDispatch: soakShape.usefulOperations)
    printRateSummary(
        label: "all",
        startSeconds: 0,
        endSeconds: finalWallSeconds,
        summary: overall)

    let firstWindowEnd = min(30.0, finalWallSeconds)
    let firstWindow = records.filter {
        $0.wallStartSeconds < firstWindowEnd
    }
    printRateSummary(
        label: "first-30s",
        startSeconds: 0,
        endSeconds: firstWindowEnd,
        summary: try rateSummary(
            records: firstWindow,
            operationsPerDispatch: soakShape.usefulOperations))

    let finalWindowStart = max(0, finalWallSeconds - 60)
    let finalWindow = records.filter {
        $0.wallEndSeconds > finalWindowStart
    }
    let finalSummary = try rateSummary(
        records: finalWindow,
        operationsPerDispatch: soakShape.usefulOperations)
    printRateSummary(
        label: "final-60s",
        startSeconds: finalWindowStart,
        endSeconds: finalWallSeconds,
        summary: finalSummary)

    var bucketStart = 0.0
    var bucketIndex = 1
    while bucketStart < finalWallSeconds {
        let bucketEnd = min(bucketStart + 30, finalWallSeconds)
        let bucketRecords = records.filter {
            let midpoint = ($0.wallStartSeconds + $0.wallEndSeconds) / 2
            return midpoint >= bucketStart && midpoint < bucketEnd
        }
        if !bucketRecords.isEmpty {
            printRateSummary(
                label: "bucket-\(bucketIndex)",
                startSeconds: bucketStart,
                endSeconds: bucketEnd,
                summary: try rateSummary(
                    records: bucketRecords,
                    operationsPerDispatch: soakShape.usefulOperations))
        }
        bucketStart = bucketEnd
        bucketIndex += 1
    }

    print(
        "THERMAL phase=after-soak"
            + " state=\(thermalStateName(ProcessInfo.processInfo.thermalState))")
    let postShort = try runShortSamples(
        runner: runner,
        prepared: prepared,
        phase: "post-soak")
    let postShortTFLOPS = try printShortSummary(
        phase: "post-soak",
        samples: postShort,
        operationsPerDispatch: soakShape.usefulOperations)
    print(
        "SUSTAINED_COMPARISON"
            + " prior_note046_short_tflops="
            + "\(format(priorBoundedShortTFLOPS, digits: 4))"
            + " pre_soak_short_tflops=\(format(preShortTFLOPS, digits: 4))"
            + " sustained_all_tflops=\(format(overall.effectiveTFLOPS, digits: 4))"
            + " sustained_final60_tflops="
            + "\(format(finalSummary.effectiveTFLOPS, digits: 4))"
            + " post_soak_short_tflops=\(format(postShortTFLOPS, digits: 4))"
            + " sustained_over_prior="
            + "\(format(overall.effectiveTFLOPS / priorBoundedShortTFLOPS, digits: 4))"
            + " final60_over_prior="
            + "\(format(finalSummary.effectiveTFLOPS / priorBoundedShortTFLOPS, digits: 4))")
    print(
        "VERDICT=measured-sustained-schedule"
            + " fastest_valid_schedule_from_note046=true"
            + " counters_sufficient_for_physical_roof=false"
            + " hardware_theorem=false")
    print("RUN_COMPLETE=yes")
}

@main
struct MPPPhysicalSoak {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
            exit(1)
        }
    }
}
