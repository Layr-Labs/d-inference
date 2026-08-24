import Darwin
import Foundation

private let warmupRounds = 3
private let measuredRounds = 16
private let continuationThresholdTFLOPS = 24.0

// One [B=4,C=2048] pass. Routed rows are token rows times top-8 experts.
// Dispatch counts reproduce the E15 all-projection ledger; the scalar shared
// gate is the only omitted linear and accounts for 0.0034% of work.
private let shapes: [ProjectionShape] = [
    ProjectionShape(
        label: "gdn-attention-input", m: 8192, k: 2048, n: 8192,
        modelDispatches: 40),
    ProjectionShape(
        label: "gdn-wide", m: 8192, k: 2048, n: 4096,
        modelDispatches: 30),
    ProjectionShape(
        label: "gdn-attention-output", m: 8192, k: 4096, n: 2048,
        modelDispatches: 40),
    ProjectionShape(
        label: "attention-kv-shared-gate-up", m: 8192, k: 2048, n: 512,
        modelDispatches: 100),
    ProjectionShape(
        label: "router", m: 8192, k: 2048, n: 256,
        modelDispatches: 40),
    ProjectionShape(
        label: "gdn-small", m: 8192, k: 2048, n: 32,
        modelDispatches: 60),
    ProjectionShape(
        label: "shared-down", m: 8192, k: 512, n: 2048,
        modelDispatches: 40),
    ProjectionShape(
        label: "routed-gate-up", m: 65_536, k: 2048, n: 1024,
        modelDispatches: 40),
    ProjectionShape(
        label: "routed-down", m: 65_536, k: 512, n: 2048,
        modelDispatches: 40),
]

private struct ShapeResult {
    let shape: ProjectionShape
    let strict: TimingSummary
    let relaxed: TimingSummary
    let comparison: Comparison
}

private func format(_ value: Double, digits: Int) -> String {
    String(format: "%.\(digits)f", value)
}

private func comparisonLine(
    shape: ProjectionShape,
    comparison: Comparison
) -> String {
    [
        "NUMERICAL_DIAGNOSTIC",
        "shape=\(shape.label)",
        "reference=strict-f32-MPP",
        "candidate=relaxed-f32-MPP",
        "elements=\(comparison.elementCount)",
        "fp32_changed=\(comparison.fp32Changed)",
        "bf16_changed=\(comparison.bf16Changed)",
        "max_abs=\(String(format: "%.9g", comparison.maxAbsoluteError))",
        "max_rel=\(String(format: "%.9g", comparison.maxRelativeError))",
        "qmm_1e-3=\(comparison.qmmTolerancePassed ? "pass" : "fail")",
        "nonfinite=\(comparison.nonFinite)",
        "strict_hash=\(comparison.steelHash)",
        "relaxed_hash=\(comparison.mppHash)",
        "quality_gate_required=yes",
    ].joined(separator: " ")
}

private func sampleLine(shape: ProjectionShape, sample: TimingSample) -> String {
    [
        "SAMPLE",
        "shape=\(shape.label)",
        "variant=\(sample.variantID)",
        "round=\(sample.round)",
        "position=\(sample.position)",
        "gpu_complete=yes",
        "gpu_ms=\(format(sample.gpuSeconds * 1e3, digits: 6))",
        "kernel_ms=\(format(sample.kernelSeconds * 1e3, digits: 6))",
        "cpu_wall_ms=\(format(sample.cpuSeconds * 1e3, digits: 6))",
        "useful_gpu_tflops=\(format(
            usefulTFLOPS(
                operations: shape.usefulOperations,
                seconds: sample.gpuSeconds),
            digits: 4))",
    ].joined(separator: " ")
}

private func summaryLine(
    shape: ProjectionShape,
    variant: RelaxedVariant,
    summary: TimingSummary
) -> String {
    [
        "SUMMARY",
        "shape=\(shape.label)",
        "variant=\(variant.rawValue)",
        "samples=\(summary.sampleCount)",
        "gpu_complete_samples=\(summary.sampleCount)",
        "gpu_median_ms=\(format(summary.gpuMedianSeconds * 1e3, digits: 6))",
        "gpu_p10_ms=\(format(summary.gpuP10Seconds * 1e3, digits: 6))",
        "gpu_p90_ms=\(format(summary.gpuP90Seconds * 1e3, digits: 6))",
        "gpu_min_ms=\(format(summary.gpuMinimumSeconds * 1e3, digits: 6))",
        "gpu_max_ms=\(format(summary.gpuMaximumSeconds * 1e3, digits: 6))",
        "kernel_median_ms=\(format(summary.kernelMedianSeconds * 1e3, digits: 6))",
        "cpu_wall_median_ms=\(format(summary.cpuMedianSeconds * 1e3, digits: 6))",
        "useful_gpu_tflops=\(format(
            usefulTFLOPS(
                operations: shape.usefulOperations,
                seconds: summary.gpuMedianSeconds),
            digits: 4))",
    ].joined(separator: " ")
}

private func runShape(
    runner: RelaxedMPPRunner,
    shape: ProjectionShape,
    index: Int
) throws -> ShapeResult {
    let seed = UInt64(0x6a09_e667_f3bc_c909)
        &+ UInt64(index) &* UInt64(0x1000_0000_01b3)
    let prepared = try PreparedFloatShape(
        device: runner.device,
        shape: shape,
        seed: seed)

    // Poison both destinations so a missing or partial dispatch fails the
    // finite-value safety gate before any timing.
    prepared.poisonOutput(for: .strict)
    _ = try runner.execute(variant: .strict, prepared: prepared)
    prepared.poisonOutput(for: .relaxed)
    _ = try runner.execute(variant: .relaxed, prepared: prepared)
    let comparison = prepared.comparison()
    print(comparisonLine(shape: shape, comparison: comparison))
    guard comparison.nonFinite == 0 else {
        throw ProbeFailure.message(
            "\(shape.label) relaxed/strict output contains non-finite values")
    }

    for round in 0..<warmupRounds {
        let order = balancedOrder(
            variants: RelaxedVariant.allCases,
            round: round)
        for (position, variant) in order.enumerated() {
            _ = try runner.execute(
                variant: variant,
                prepared: prepared,
                round: round + 1,
                position: position + 1)
        }
    }
    print(
        "WARMUP shape=\(shape.label)"
            + " rounds=\(warmupRounds)"
            + " order=balanced-rotating")

    var samples: [RelaxedVariant: [TimingSample]] = [:]
    for round in 0..<measuredRounds {
        let order = balancedOrder(
            variants: RelaxedVariant.allCases,
            round: round + warmupRounds)
        for (position, variant) in order.enumerated() {
            let sample = try runner.execute(
                variant: variant,
                prepared: prepared,
                round: round + 1,
                position: position + 1)
            samples[variant, default: []].append(sample)
            print(sampleLine(shape: shape, sample: sample))
        }
    }

    guard samples[.strict]?.count == measuredRounds,
          samples[.relaxed]?.count == measuredRounds
    else {
        throw ProbeFailure.message("\(shape.label) timing matrix is incomplete")
    }
    let strict = try summarize(samples[.strict]!)
    let relaxed = try summarize(samples[.relaxed]!)
    print(summaryLine(shape: shape, variant: .strict, summary: strict))
    print(summaryLine(shape: shape, variant: .relaxed, summary: relaxed))
    print(
        "COMPARISON shape=\(shape.label)"
            + " relaxed_over_strict="
            + "\(format(strict.gpuMedianSeconds / relaxed.gpuMedianSeconds, digits: 4))"
            + " strict_gpu_tflops="
            + "\(format(
                usefulTFLOPS(
                    operations: shape.usefulOperations,
                    seconds: strict.gpuMedianSeconds),
                digits: 4))"
            + " relaxed_gpu_tflops="
            + "\(format(
                usefulTFLOPS(
                    operations: shape.usefulOperations,
                    seconds: relaxed.gpuMedianSeconds),
                digits: 4))")
    return ShapeResult(
        shape: shape,
        strict: strict,
        relaxed: relaxed,
        comparison: comparison)
}

private func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw ProbeFailure.message(
            "usage: mpp-relaxed-float-probe <metallib>")
    }
    guard measuredRounds >= 15 else {
        throw ProbeFailure.message("at least 15 measured rounds are required")
    }
    guard ProcessInfo.processInfo.environment["MPP_POWER_GATE"] == "ac-high" else {
        throw ProbeFailure.message("MPP_POWER_GATE=ac-high is required")
    }

    let runner = try RelaxedMPPRunner(metallibPath: CommandLine.arguments[1])
    guard runner.device.name == "Apple M3 Max" else {
        throw ProbeFailure.message(
            "probe requires Apple M3 Max, found \(runner.device.name)")
    }
    print("DEVICE=\(runner.device.name)")
    print("OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    print(
        "CONTRACT=F32xF32-to-FP32"
            + " values=BF16-representable-promoted-to-F32"
            + " strict_relaxed_pair=true"
            + " tile=M32N32K32"
            + " scope=execution_simdgroup"
            + " simdgroups_per_threadgroup=4")
    print(
        "RELAXED_SEMANTICS=permission-to-truncate-float-mantissa-before-multiply"
            + " accumulator_width=not-assumed"
            + " quality_gate_required=yes")
    print(
        "LEDGER=B4xC2048"
            + " coverage_linear_work=99.9966-percent"
            + " routed_rows=65536"
            + " dense_rows=8192")
    print(
        "MEASUREMENT=complete-matrix-dispatch"
            + " warmup_rounds=\(warmupRounds)"
            + " measured_rounds=\(measuredRounds)"
            + " order=balanced-rotating"
            + " timestamps=gpu-kernel-cpu")

    var results: [ShapeResult] = []
    results.reserveCapacity(shapes.count)
    for (index, shape) in shapes.enumerated() {
        print(
            "SHAPE name=\(shape.label)"
                + " M=\(shape.m) K=\(shape.k) N=\(shape.n)"
                + " model_dispatches=\(shape.modelDispatches)"
                + " useful_gflop="
                + "\(format(shape.usefulOperations / 1e9, digits: 6))")
        results.append(
            try autoreleasepool {
                try runShape(runner: runner, shape: shape, index: index)
            })
    }

    let weightedOperations = results.reduce(0.0) {
        $0 + $1.shape.usefulOperations * Double($1.shape.modelDispatches)
    }
    let strictGPUSeconds = results.reduce(0.0) {
        $0 + $1.strict.gpuMedianSeconds * Double($1.shape.modelDispatches)
    }
    let relaxedGPUSeconds = results.reduce(0.0) {
        $0 + $1.relaxed.gpuMedianSeconds * Double($1.shape.modelDispatches)
    }
    let strictCPUSeconds = results.reduce(0.0) {
        $0 + $1.strict.cpuMedianSeconds * Double($1.shape.modelDispatches)
    }
    let relaxedCPUSeconds = results.reduce(0.0) {
        $0 + $1.relaxed.cpuMedianSeconds * Double($1.shape.modelDispatches)
    }
    let strictGPU = usefulTFLOPS(
        operations: weightedOperations,
        seconds: strictGPUSeconds)
    let relaxedGPU = usefulTFLOPS(
        operations: weightedOperations,
        seconds: relaxedGPUSeconds)
    let strictCPU = usefulTFLOPS(
        operations: weightedOperations,
        seconds: strictCPUSeconds)
    let relaxedCPU = usefulTFLOPS(
        operations: weightedOperations,
        seconds: relaxedCPUSeconds)
    let changed = results.reduce(0) { $0 + $1.comparison.fp32Changed }
    let elements = results.reduce(0) { $0 + $1.comparison.elementCount }

    print(
        "WEIGHTED_RESULT variant=strict"
            + " modeled_tflop=\(format(weightedOperations / 1e12, digits: 6))"
            + " gpu_seconds=\(format(strictGPUSeconds, digits: 6))"
            + " useful_gpu_tflops=\(format(strictGPU, digits: 4))"
            + " useful_cpu_tflops=\(format(strictCPU, digits: 4))")
    print(
        "WEIGHTED_RESULT variant=relaxed"
            + " modeled_tflop=\(format(weightedOperations / 1e12, digits: 6))"
            + " gpu_seconds=\(format(relaxedGPUSeconds, digits: 6))"
            + " useful_gpu_tflops=\(format(relaxedGPU, digits: 4))"
            + " useful_cpu_tflops=\(format(relaxedCPU, digits: 4))")
    print(
        "NUMERICAL_TOTAL fp32_changed=\(changed)/\(elements)"
            + " exact_checksum_required=no"
            + " model_quality_gate_required=yes")
    print(
        "PERF_GATE relaxed_gpu_tflops=\(format(relaxedGPU, digits: 4))"
            + " strict_gpu_tflops=\(format(strictGPU, digits: 4))"
            + " relaxed_over_strict=\(format(relaxedGPU / strictGPU, digits: 4))"
            + " threshold_tflops=\(format(continuationThresholdTFLOPS, digits: 1))")
    if relaxedGPU >= continuationThresholdTFLOPS {
        print(
            "VERDICT=continue"
                + " next=serving-shaped-W4-loader-and-full-model-quality-gate"
                + " performance_only=true"
                + " no_serving_integration=true")
    } else {
        print(
            "VERDICT=stop"
                + " reason=relaxed-float-MPP-below-composition-threshold"
                + " performance_only=true"
                + " no_serving_integration=true")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
    exit(1)
}
