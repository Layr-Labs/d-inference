import Darwin
import Foundation

private let warmupRounds = 3
private let measuredRounds = 16
private let continuationThresholdTFLOPS = 22.0

// These are complete Qwen projection matrices, not repeated cache-resident
// microtiles. The set includes the threshold-defining routed gate/up shape, the
// widest dense projection (the fastest E14 cell), and the routed/shared down
// shape with the model's other reduction length.
private let shapes: [DenseShape] = [
    DenseShape(
        label: "gdn-attention-wide",
        m: 2048,
        k: 2048,
        n: 8192),
    DenseShape(
        label: "routed-gate-up-primary",
        m: 2048,
        k: 2048,
        n: 1024),
    DenseShape(
        label: "shared-routed-down",
        m: 2048,
        k: 512,
        n: 2048),
]

private func format(_ value: Double, digits: Int) -> String {
    String(format: "%.\(digits)f", value)
}

private func fieldSafe(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\n", with: "|")
        .replacingOccurrences(of: "\r", with: "|")
        .replacingOccurrences(of: " ", with: "_")
        .replacingOccurrences(of: "\t", with: "_")
}

private func candidateFields(_ candidate: MPPCandidate) -> [String] {
    [
        "candidate=\(candidate.id)",
        "tile=M\(candidate.tileM)N\(candidate.tileN)K\(candidate.tileK)",
        "scope=\(candidate.scope)",
        "scope_simdgroups=\(candidate.scopeSIMDGroups)",
        "input_mode=\(candidate.inputMode)",
    ]
}

private func comparisonLine(
    shape: DenseShape,
    candidate: MPPCandidate,
    comparison: Comparison
) -> String {
    ([
        "CORRECTNESS",
        "shape=\(shape.label)",
    ] + candidateFields(candidate) + [
        "status=\(comparison.passed ? "pass" : "fail")",
        "elements=\(comparison.elementCount)",
        "fp32_changed=\(comparison.fp32Changed)",
        "bf16_changed=\(comparison.bf16Changed)",
        "max_abs=\(String(format: "%.9g", comparison.maxAbsoluteError))",
        "max_rel=\(String(format: "%.9g", comparison.maxRelativeError))",
        "qmm_1e-3=\(comparison.qmmTolerancePassed ? "pass" : "fail")",
        "nonfinite=\(comparison.nonFinite)",
        "steel_hash=\(comparison.steelHash)",
        "mpp_hash=\(comparison.mppHash)",
    ]).joined(separator: " ")
}

private func sampleLine(shape: DenseShape, sample: TimingSample) -> String {
    let gpuTFLOPS = usefulTFLOPS(
        operations: shape.usefulOperations,
        seconds: sample.gpuSeconds)
    let cpuTFLOPS = usefulTFLOPS(
        operations: shape.usefulOperations,
        seconds: sample.cpuSeconds)
    return [
        "SAMPLE",
        "shape=\(shape.label)",
        "variant=\(sample.variantID)",
        "round=\(sample.round)",
        "position=\(sample.position)",
        "gpu_complete=yes",
        "gpu_start_s=\(format(sample.gpuStartSeconds, digits: 9))",
        "gpu_end_s=\(format(sample.gpuEndSeconds, digits: 9))",
        "gpu_ms=\(format(sample.gpuSeconds * 1e3, digits: 6))",
        "kernel_start_s=\(format(sample.kernelStartSeconds, digits: 9))",
        "kernel_end_s=\(format(sample.kernelEndSeconds, digits: 9))",
        "kernel_ms=\(format(sample.kernelSeconds * 1e3, digits: 6))",
        "cpu_wall_ms=\(format(sample.cpuSeconds * 1e3, digits: 6))",
        "useful_gpu_tflops=\(format(gpuTFLOPS, digits: 4))",
        "useful_cpu_tflops=\(format(cpuTFLOPS, digits: 4))",
    ].joined(separator: " ")
}

private func summaryLine(
    shape: DenseShape,
    variant: BenchmarkVariant,
    summary: TimingSummary
) -> String {
    let gpuTFLOPS = usefulTFLOPS(
        operations: shape.usefulOperations,
        seconds: summary.gpuMedianSeconds)
    let fastestGPU = usefulTFLOPS(
        operations: shape.usefulOperations,
        seconds: summary.gpuMinimumSeconds)
    let cpuTFLOPS = usefulTFLOPS(
        operations: shape.usefulOperations,
        seconds: summary.cpuMedianSeconds)
    var fields = [
        "SUMMARY",
        "shape=\(shape.label)",
        "variant=\(variant.id)",
        "samples=\(summary.sampleCount)",
        "gpu_complete_samples=\(summary.sampleCount)",
        "gpu_median_ms=\(format(summary.gpuMedianSeconds * 1e3, digits: 6))",
        "gpu_p10_ms=\(format(summary.gpuP10Seconds * 1e3, digits: 6))",
        "gpu_p90_ms=\(format(summary.gpuP90Seconds * 1e3, digits: 6))",
        "gpu_min_ms=\(format(summary.gpuMinimumSeconds * 1e3, digits: 6))",
        "gpu_max_ms=\(format(summary.gpuMaximumSeconds * 1e3, digits: 6))",
        "kernel_median_ms=\(format(summary.kernelMedianSeconds * 1e3, digits: 6))",
        "cpu_wall_median_ms=\(format(summary.cpuMedianSeconds * 1e3, digits: 6))",
        "useful_gpu_tflops=\(format(gpuTFLOPS, digits: 4))",
        "fastest_sample_gpu_tflops=\(format(fastestGPU, digits: 4))",
        "useful_cpu_tflops=\(format(cpuTFLOPS, digits: 4))",
    ]
    if let candidate = variant.candidate {
        fields += candidateFields(candidate)
    } else {
        fields += [
            "tile=M16N32K8",
            "scope=execution_simdgroup",
            "scope_simdgroups=1",
        ]
    }
    return fields.joined(separator: " ")
}

private func balancedOrder(
    variants: [BenchmarkVariant],
    round: Int
) -> [BenchmarkVariant] {
    var result = rotated(variants, by: round)
    if round.isMultiple(of: 2) == false {
        result.reverse()
    }
    return result
}

private struct RateCell {
    let candidate: MPPCandidate
    let shape: DenseShape
    let medianTFLOPS: Double
    let fastestSampleTFLOPS: Double
}

private func run() throws {
    guard CommandLine.arguments.count == 3 else {
        throw ProbeFailure.message(
            "usage: mpp-throughput-probe <build-dir> <accepted-manifest>")
    }
    guard measuredRounds >= 15 else {
        throw ProbeFailure.message("probe configuration has fewer than 15 samples")
    }

    let candidates = try MPPCandidate.loadManifest(path: CommandLine.arguments[2])
    guard !candidates.isEmpty else {
        throw ProbeFailure.message("compile matrix produced no linkable MPP candidate")
    }
    let runner = try MetalRunner(
        buildDirectory: CommandLine.arguments[1],
        candidates: candidates)
    guard runner.device.name == "Apple M3 Max" else {
        throw ProbeFailure.message(
            "probe is preregistered for Apple M3 Max, found \(runner.device.name)")
    }

    print("DEVICE=\(runner.device.name)")
    print("OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    print(
        "CONTRACT=BF16xBF16-to-FP32"
            + " relaxed_precision=false"
            + " mode=multiply_accumulate"
            + " inputs=supported-cooperative-load"
            + " output=supported-cooperative-store"
            + " accumulator=one-cooperative-FP32-across-logical-K"
            + " steel=simdgroup-8x8x8-FP32")
    print(
        "SWEEP=tiles-M16N16-M16N32-M16N64-M32N32-M64N32"
            + " tile_k=K16-K32"
            + " scopes=execution_simdgroup-execution_simdgroups_2-execution_simdgroups_4"
            + " input_modes=cooperative-tensor"
            + " compiler_link_accepted=\(candidates.count)")
    print(
        "MEASUREMENT=one-full-matrix-dispatch-per-command-buffer"
            + " warmup_rounds=\(warmupRounds)"
            + " measured_rounds=\(measuredRounds)"
            + " samples_per_valid_variant_per_shape=\(measuredRounds)"
            + " order=balanced-rotating"
            + " timestamps=command-buffer-gpu-plus-kernel-plus-cpu-wall")

    for status in runner.pipelineStatuses {
        print(
            ([
                "PIPELINE",
            ] + candidateFields(status.candidate) + [
                "status=\(status.accepted ? "pass" : "reject")",
                "detail=\(fieldSafe(status.detail))",
            ]).joined(separator: " "))
    }
    print(
        "PIPELINE_MATRIX linked=\(candidates.count)"
            + " executable=\(runner.executableCandidates.count)"
            + " rejected=\(candidates.count - runner.executableCandidates.count)")

    let currentScheduleID = "mpp_m16_n32_k16_sg1_coop"
    guard runner.executableCandidates.contains(where: { $0.id == currentScheduleID }) else {
        throw ProbeFailure.message(
            "known M16N32K16 execution_simdgroup control is not executable")
    }

    for shape in shapes {
        try shape.validateForSteel()
        print(
            "SHAPE name=\(shape.label)"
                + " M=\(shape.m) K=\(shape.k) N=\(shape.n)"
                + " useful_gflop=\(format(shape.usefulOperations / 1e9, digits: 6))")
    }

    var preparedShapes: [PreparedShape] = []
    for (index, shape) in shapes.enumerated() {
        let seed = UInt64(0x6a09_e667_f3bc_c909)
            &+ UInt64(index) &* UInt64(0x1000_0000_01b3)
        preparedShapes.append(
            try PreparedShape(device: runner.device, shape: shape, seed: seed))
    }

    // Produce each full Steel output before invoking any MPP candidate. Every
    // destination is first filled with an all-ones NaN bit pattern so a partial
    // or no-op dispatch cannot inherit a valid output from a prior candidate.
    // Every executable candidate must pass every shape before timing begins.
    for prepared in preparedShapes {
        prepared.poisonOutput(for: .steel)
        _ = try runner.execute(variant: .steel, prepared: prepared)
        print(
            "STEEL_REFERENCE shape=\(prepared.shape.label)"
                + " elements=\(prepared.shape.elementCount)"
                + " status=complete-before-mpp")
    }

    var runtimeRejected: Set<String> = []
    var numericalRejected: Set<String> = []
    for candidate in runner.executableCandidates {
        for prepared in preparedShapes {
            if runtimeRejected.contains(candidate.id) {
                print(
                    "CORRECTNESS shape=\(prepared.shape.label)"
                        + " candidate=\(candidate.id)"
                        + " status=skipped reason=prior-runtime-rejection")
                continue
            }
            do {
                prepared.poisonOutput(for: .mpp(candidate))
                _ = try runner.execute(
                    variant: .mpp(candidate),
                    prepared: prepared)
                let comparison = prepared.comparison()
                print(comparisonLine(
                    shape: prepared.shape,
                    candidate: candidate,
                    comparison: comparison))
                if !comparison.passed {
                    numericalRejected.insert(candidate.id)
                }
            } catch {
                runtimeRejected.insert(candidate.id)
                print(
                    ([
                        "EXECUTION",
                    ] + candidateFields(candidate) + [
                        "shape=\(prepared.shape.label)",
                        "status=reject",
                        "detail=\(fieldSafe(String(describing: error)))",
                    ]).joined(separator: " "))
            }
        }
    }

    let validCandidates = runner.executableCandidates.filter {
        !runtimeRejected.contains($0.id) && !numericalRejected.contains($0.id)
    }
    print(
        "CORRECTNESS_GATE executable=\(runner.executableCandidates.count)"
            + " runtime_rejected=\(runtimeRejected.count)"
            + " numerical_rejected=\(numericalRejected.count)"
            + " valid=\(validCandidates.count)")
    guard validCandidates.contains(where: { $0.id == currentScheduleID }) else {
        throw ProbeFailure.message(
            "known M16N32K16 execution_simdgroup control failed correctness")
    }
    guard !validCandidates.isEmpty else {
        print("TIMING=skipped reason=no-valid-MPP-candidates")
        print(
            "VERDICT=reject reason=no-valid-candidate"
                + " bounded_sweep_only=true hardware_theorem=false"
                + " no_serving_integration=true")
        return
    }

    guard ProcessInfo.processInfo.environment["MPP_POWER_GATE"] == "ac-high" else {
        print("TIMING=skipped reason=ac_high_power_gate_not_validated")
        print(
            "VERDICT=correctness-pass timing=not-run"
                + " bounded_sweep_only=true hardware_theorem=false"
                + " no_serving_integration=true")
        return
    }

    let variants: [BenchmarkVariant] =
        [.steel] + validCandidates.map(BenchmarkVariant.mpp)
    var timingRejected: Set<String> = []
    var samplesByShape: [String: [String: [TimingSample]]] = [:]

    for prepared in preparedShapes {
        for round in 0..<warmupRounds {
            let order = balancedOrder(variants: variants, round: round)
            for (position, variant) in order.enumerated() {
                if timingRejected.contains(variant.id) {
                    continue
                }
                do {
                    _ = try runner.execute(
                        variant: variant,
                        prepared: prepared,
                        round: round + 1,
                        position: position + 1)
                } catch {
                    guard variant != .steel else {
                        throw error
                    }
                    timingRejected.insert(variant.id)
                    print(
                        "TIMING_REJECTION phase=warmup"
                            + " shape=\(prepared.shape.label)"
                            + " variant=\(variant.id)"
                            + " detail=\(fieldSafe(String(describing: error)))")
                }
            }
        }
        print(
            "WARMUP shape=\(prepared.shape.label)"
                + " rounds=\(warmupRounds)"
                + " order=balanced-rotating"
                + " timing_rejected_so_far=\(timingRejected.count)")

        for round in 0..<measuredRounds {
            let order = balancedOrder(
                variants: variants,
                round: round + warmupRounds)
            for (position, variant) in order.enumerated() {
                if timingRejected.contains(variant.id) {
                    continue
                }
                do {
                    let sample = try runner.execute(
                        variant: variant,
                        prepared: prepared,
                        round: round + 1,
                        position: position + 1)
                    samplesByShape[
                        prepared.shape.label,
                        default: [:]
                    ][
                        variant.id,
                        default: []
                    ].append(sample)
                    print(sampleLine(shape: prepared.shape, sample: sample))
                } catch {
                    guard variant != .steel else {
                        throw error
                    }
                    timingRejected.insert(variant.id)
                    print(
                        "TIMING_REJECTION phase=measured"
                            + " shape=\(prepared.shape.label)"
                            + " variant=\(variant.id)"
                            + " round=\(round + 1)"
                            + " detail=\(fieldSafe(String(describing: error)))")
                }
            }
        }
    }

    let timedCandidates = validCandidates.filter {
        !timingRejected.contains($0.id)
    }
    var summaries: [String: [String: TimingSummary]] = [:]
    var rateCells: [RateCell] = []

    for shape in shapes {
        let shapeSamples = samplesByShape[shape.label, default: [:]]
        let timedVariants: [BenchmarkVariant] =
            [.steel] + timedCandidates.map(BenchmarkVariant.mpp)
        for variant in timedVariants {
            let samples = shapeSamples[variant.id, default: []]
            guard samples.count == measuredRounds else {
                throw ProbeFailure.message(
                    "\(shape.label)/\(variant.id) has \(samples.count) samples; "
                        + "\(measuredRounds) required")
            }
            let summary = try summarize(samples)
            summaries[shape.label, default: [:]][variant.id] = summary
            print(summaryLine(shape: shape, variant: variant, summary: summary))
            if let candidate = variant.candidate {
                rateCells.append(RateCell(
                    candidate: candidate,
                    shape: shape,
                    medianTFLOPS: usefulTFLOPS(
                        operations: shape.usefulOperations,
                        seconds: summary.gpuMedianSeconds),
                    fastestSampleTFLOPS: usefulTFLOPS(
                        operations: shape.usefulOperations,
                        seconds: summary.gpuMinimumSeconds)))
            }
        }
    }

    for cell in rateCells {
        guard let steelSummary = summaries[cell.shape.label]?[
            BenchmarkVariant.steel.id
        ] else {
            throw ProbeFailure.message(
                "missing Steel summary for \(cell.shape.label)")
        }
        let steelRate = usefulTFLOPS(
            operations: cell.shape.usefulOperations,
            seconds: steelSummary.gpuMedianSeconds)
        print(
            "COMPARISON shape=\(cell.shape.label)"
                + " candidate=\(cell.candidate.id)"
                + " mpp_over_steel=\(format(cell.medianTFLOPS / steelRate, digits: 4))"
                + " mpp_gpu_tflops=\(format(cell.medianTFLOPS, digits: 4))"
                + " steel_gpu_tflops=\(format(steelRate, digits: 4))")
    }

    guard let bestMedian = rateCells.max(by: {
        $0.medianTFLOPS < $1.medianTFLOPS
    }), let bestSample = rateCells.max(by: {
        $0.fastestSampleTFLOPS < $1.fastestSampleTFLOPS
    }) else {
        throw ProbeFailure.message("no candidate completed the timing matrix")
    }

    print(
        "BOUNDED_MAX_VALID_MEDIAN"
            + " candidate=\(bestMedian.candidate.id)"
            + " shape=\(bestMedian.shape.label)"
            + " useful_gpu_tflops=\(format(bestMedian.medianTFLOPS, digits: 4))"
            + " threshold_tflops=\(format(continuationThresholdTFLOPS, digits: 1))"
            + " threshold_fraction="
            + "\(format(bestMedian.medianTFLOPS / continuationThresholdTFLOPS, digits: 4))"
            + " scope=enumerated-matrix-only"
            + " hardware_theorem=false")
    print(
        "BOUNDED_MAX_VALID_SAMPLE"
            + " candidate=\(bestSample.candidate.id)"
            + " shape=\(bestSample.shape.label)"
            + " useful_gpu_tflops=\(format(bestSample.fastestSampleTFLOPS, digits: 4))"
            + " threshold_tflops=\(format(continuationThresholdTFLOPS, digits: 1))"
            + " scope=enumerated-matrix-only"
            + " hardware_theorem=false")
    print(
        "TIMING_GATE valid_before_timing=\(validCandidates.count)"
            + " timing_rejected=\(timingRejected.count)"
            + " fully_timed=\(timedCandidates.count)"
            + " samples_per_candidate_shape=\(measuredRounds)")

    if bestMedian.medianTFLOPS >= continuationThresholdTFLOPS {
        print(
            "VERDICT=continue bounded_max_valid_gpu_tflops="
                + "\(format(bestMedian.medianTFLOPS, digits: 4))"
                + " threshold=\(format(continuationThresholdTFLOPS, digits: 1))"
                + " next=integration-correctness-ratchet"
                + " bounded_sweep_only=true hardware_theorem=false"
                + " no_serving_integration=true")
    } else {
        print(
            "VERDICT=stop bounded_max_valid_gpu_tflops="
                + "\(format(bestMedian.medianTFLOPS, digits: 4))"
                + " threshold=\(format(continuationThresholdTFLOPS, digits: 1))"
                + " reason=all-enumerated-valid-medians-below-M3-gate"
                + " bounded_sweep_only=true hardware_theorem=false"
                + " no_serving_integration=true")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
    exit(1)
}
