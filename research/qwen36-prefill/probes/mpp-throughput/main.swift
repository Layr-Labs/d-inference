import Darwin
import Foundation

private let warmupBlocks = 3
private let measuredBlocks = 8
private let samplesPerArm = measuredBlocks * 2
private let continuationThresholdTFLOPS = 22.0
private let fullModelLinearGFLOPsPerToken = 4.8734208

// All cells use the requested dense M=2048 row count. Weights collapse the
// real 40-layer Qwen projection ledger into unique K/N shapes. The omitted
// scalar shared-expert gate is 0.00016384 GFLOP/token (0.0034%).
private let shapes: [DenseShape] = [
    DenseShape(
        label: "gdn-attention-wide",
        m: 2048,
        k: 2048,
        n: 8192,
        modelGFLOPsPerToken: 1.34217728),
    DenseShape(
        label: "gdn-z",
        m: 2048,
        k: 2048,
        n: 4096,
        modelGFLOPsPerToken: 0.50331648),
    DenseShape(
        label: "gdn-a-b",
        m: 2048,
        k: 2048,
        n: 32,
        modelGFLOPsPerToken: 0.00786432),
    DenseShape(
        label: "gdn-attention-output",
        m: 2048,
        k: 4096,
        n: 2048,
        modelGFLOPsPerToken: 0.67108864),
    DenseShape(
        label: "attention-kv-shared-gate-up",
        m: 2048,
        k: 2048,
        n: 512,
        modelGFLOPsPerToken: 0.20971520),
    DenseShape(
        label: "shared-routed-down",
        m: 2048,
        k: 512,
        n: 2048,
        modelGFLOPsPerToken: 0.75497472),
    DenseShape(
        label: "router",
        m: 2048,
        k: 2048,
        n: 256,
        modelGFLOPsPerToken: 0.04194304),
    DenseShape(
        label: "routed-gate-up-primary",
        m: 2048,
        k: 2048,
        n: 1024,
        modelGFLOPsPerToken: 1.34217728),
]

private func format(_ value: Double, digits: Int) -> String {
    String(format: "%.\(digits)f", value)
}

private func comparisonLine(shape: DenseShape, comparison: Comparison) -> String {
    [
        "CORRECTNESS",
        "shape=\(shape.label)",
        "M=\(shape.m)",
        "K=\(shape.k)",
        "N=\(shape.n)",
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
    ].joined(separator: " ")
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
        "arm=\(sample.arm.rawValue)",
        "block=\(sample.block)",
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
    arm: Arm,
    summary: TimingSummary
) -> String {
    let gpuTFLOPS = usefulTFLOPS(
        operations: shape.usefulOperations,
        seconds: summary.gpuMedianSeconds)
    let cpuTFLOPS = usefulTFLOPS(
        operations: shape.usefulOperations,
        seconds: summary.cpuMedianSeconds)
    return [
        "SUMMARY",
        "shape=\(shape.label)",
        "arm=\(arm.rawValue)",
        "samples=\(summary.sampleCount)",
        "gpu_complete_samples=\(summary.sampleCount)",
        "gpu_median_ms=\(format(summary.gpuMedianSeconds * 1e3, digits: 6))",
        "gpu_p10_ms=\(format(summary.gpuP10Seconds * 1e3, digits: 6))",
        "gpu_p90_ms=\(format(summary.gpuP90Seconds * 1e3, digits: 6))",
        "gpu_min_ms=\(format(summary.gpuMinimumSeconds * 1e3, digits: 6))",
        "gpu_max_ms=\(format(summary.gpuMaximumSeconds * 1e3, digits: 6))",
        "cpu_wall_median_ms=\(format(summary.cpuMedianSeconds * 1e3, digits: 6))",
        "useful_gpu_tflops=\(format(gpuTFLOPS, digits: 4))",
        "useful_cpu_tflops=\(format(cpuTFLOPS, digits: 4))",
        "model_weight_gflop_per_token=\(format(shape.modelGFLOPsPerToken, digits: 8))",
    ].joined(separator: " ")
}

private func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw ProbeFailure.message(
            "usage: mpp-throughput-probe <kernel.metallib>")
    }
    guard samplesPerArm >= 15 else {
        throw ProbeFailure.message("probe configuration has fewer than 15 samples")
    }

    let runner = try MetalRunner(metallibPath: CommandLine.arguments[1])
    guard runner.device.name == "Apple M3 Max" else {
        throw ProbeFailure.message(
            "probe is preregistered for Apple M3 Max, found \(runner.device.name)")
    }

    let measuredModelWeight = shapes.reduce(0.0) {
        $0 + $1.modelGFLOPsPerToken
    }
    print("DEVICE=\(runner.device.name)")
    print("OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    print(
        "CONTRACT=BF16xBF16-to-FP32"
            + " mpp_descriptor=M16N32K16"
            + " relaxed_precision=false"
            + " accumulator=one-cooperative-FP32-across-K"
            + " steel=simdgroup-8x8x8-FP32")
    print(
        "MEASUREMENT=one-full-matrix-dispatch-per-command-buffer"
            + " simdgroups_per_threadgroup=4"
            + " warmup_blocks=\(warmupBlocks)"
            + " measured_blocks=\(measuredBlocks)"
            + " samples_per_arm=\(samplesPerArm)"
            + " order=ABBA"
            + " timestamps=command-buffer-gpu-plus-cpu-wall")
    print(
        "WEIGHT_LEDGER measured_gflop_per_token="
            + "\(format(measuredModelWeight, digits: 8))"
            + " full_linear_gflop_per_token="
            + "\(format(fullModelLinearGFLOPsPerToken, digits: 8))"
            + " coverage_percent="
            + "\(format(100 * measuredModelWeight / fullModelLinearGFLOPsPerToken, digits: 5))")

    for shape in shapes {
        try shape.validate()
        print(
            "SHAPE name=\(shape.label)"
                + " M=\(shape.m) K=\(shape.k) N=\(shape.n)"
                + " useful_gflop=\(format(shape.usefulOperations / 1e9, digits: 6))"
                + " threadgroups=\(shape.threadgroupCount)"
                + " model_weight_gflop_per_token="
                + "\(format(shape.modelGFLOPsPerToken, digits: 8))")
    }

    var preparedShapes: [PreparedShape] = []
    for (index, shape) in shapes.enumerated() {
        let seed = UInt64(0x6a09_e667_f3bc_c909)
            &+ UInt64(index) &* UInt64(0x1000_0000_01b3)
        preparedShapes.append(
            try PreparedShape(device: runner.device, shape: shape, seed: seed))
    }

    // Every full measured shape must pass the Steel comparison before any
    // warmup or timing command buffer is submitted.
    var failedShapes: [String] = []
    for prepared in preparedShapes {
        _ = try runner.execute(arm: .steel, prepared: prepared)
        _ = try runner.execute(arm: .mpp, prepared: prepared)
        let comparison = prepared.comparison()
        print(comparisonLine(shape: prepared.shape, comparison: comparison))
        if !comparison.passed {
            failedShapes.append(prepared.shape.label)
        }
    }
    guard failedShapes.isEmpty else {
        print("CORRECTNESS_GATE=fail shapes=\(failedShapes.joined(separator: ","))")
        print("TIMING=skipped reason=steel_correctness_gate")
        print("VERDICT=reject reason=numerical_contract no_serving_integration=true")
        exit(2)
    }
    print("CORRECTNESS_GATE=pass shapes=\(preparedShapes.count)")

    guard ProcessInfo.processInfo.environment["MPP_POWER_GATE"] == "ac-high" else {
        print("TIMING=skipped reason=ac_high_power_gate_not_validated")
        print("VERDICT=correctness-pass timing=not-run no_serving_integration=true")
        return
    }

    var summariesByArm: [Arm: [String: TimingSummary]] = [
        .mpp: [:],
        .steel: [:],
    ]
    let order: [(position: String, arm: Arm)] = [
        ("A1", .mpp),
        ("B1", .steel),
        ("B2", .steel),
        ("A2", .mpp),
    ]

    for prepared in preparedShapes {
        for block in 1...warmupBlocks {
            for entry in order {
                _ = try runner.execute(
                    arm: entry.arm,
                    prepared: prepared,
                    block: block,
                    position: "warmup-\(entry.position)")
            }
        }
        print(
            "WARMUP shape=\(prepared.shape.label)"
                + " blocks=\(warmupBlocks)"
                + " gpu_complete_per_arm=\(warmupBlocks * 2)"
                + " order=ABBA")

        var samplesByArm: [Arm: [TimingSample]] = [
            .mpp: [],
            .steel: [],
        ]
        for block in 1...measuredBlocks {
            for entry in order {
                let sample = try runner.execute(
                    arm: entry.arm,
                    prepared: prepared,
                    block: block,
                    position: entry.position)
                samplesByArm[entry.arm, default: []].append(sample)
                print(sampleLine(shape: prepared.shape, sample: sample))
            }
        }

        for arm in Arm.allCases {
            guard let samples = samplesByArm[arm] else {
                throw ProbeFailure.message(
                    "missing \(arm.rawValue) samples for \(prepared.shape.label)")
            }
            let summary = try summarize(samples)
            summariesByArm[arm]?[prepared.shape.label] = summary
            print(summaryLine(shape: prepared.shape, arm: arm, summary: summary))
        }

        guard let mppSummary = summariesByArm[.mpp]?[prepared.shape.label],
              let steelSummary = summariesByArm[.steel]?[prepared.shape.label]
        else {
            throw ProbeFailure.message(
                "missing A/B summary for \(prepared.shape.label)")
        }
        let mppRate = usefulTFLOPS(
            operations: prepared.shape.usefulOperations,
            seconds: mppSummary.gpuMedianSeconds)
        let steelRate = usefulTFLOPS(
            operations: prepared.shape.usefulOperations,
            seconds: steelSummary.gpuMedianSeconds)
        print(
            "COMPARISON shape=\(prepared.shape.label)"
                + " mpp_over_steel=\(format(mppRate / steelRate, digits: 4))"
                + " mpp_gpu_tflops=\(format(mppRate, digits: 4))"
                + " steel_gpu_tflops=\(format(steelRate, digits: 4))")
    }

    guard let mppSummaries = summariesByArm[.mpp],
          let steelSummaries = summariesByArm[.steel]
    else {
        throw ProbeFailure.message("missing weighted summaries")
    }
    let mppWeightedGPU = try weightedEffectiveTFLOPS(
        shapes: shapes,
        summaries: mppSummaries,
        useGPU: true)
    let mppWeightedCPU = try weightedEffectiveTFLOPS(
        shapes: shapes,
        summaries: mppSummaries,
        useGPU: false)
    let steelWeightedGPU = try weightedEffectiveTFLOPS(
        shapes: shapes,
        summaries: steelSummaries,
        useGPU: true)
    let steelWeightedCPU = try weightedEffectiveTFLOPS(
        shapes: shapes,
        summaries: steelSummaries,
        useGPU: false)

    print(
        "WEIGHTED arm=mpp method=real-model-work-harmonic"
            + " useful_gpu_tflops=\(format(mppWeightedGPU, digits: 4))"
            + " useful_cpu_tflops=\(format(mppWeightedCPU, digits: 4))"
            + " represented_gflop_per_token=\(format(measuredModelWeight, digits: 8))")
    print(
        "WEIGHTED arm=steel method=real-model-work-harmonic"
            + " useful_gpu_tflops=\(format(steelWeightedGPU, digits: 4))"
            + " useful_cpu_tflops=\(format(steelWeightedCPU, digits: 4))"
            + " represented_gflop_per_token=\(format(measuredModelWeight, digits: 8))")
    print(
        "WEIGHTED_COMPARISON mpp_over_steel="
            + "\(format(mppWeightedGPU / steelWeightedGPU, digits: 4))"
            + " continuation_threshold_tflops="
            + "\(format(continuationThresholdTFLOPS, digits: 1))")

    if mppWeightedGPU >= continuationThresholdTFLOPS {
        print(
            "VERDICT=continue weighted_gpu_tflops="
                + "\(format(mppWeightedGPU, digits: 4))"
                + " threshold=\(format(continuationThresholdTFLOPS, digits: 1))"
                + " next=integration-correctness-ratchet"
                + " no_serving_integration=true")
    } else {
        print(
            "VERDICT=stop weighted_gpu_tflops="
                + "\(format(mppWeightedGPU, digits: 4))"
                + " threshold=\(format(continuationThresholdTFLOPS, digits: 1))"
                + " reason=below-weighted-M3-gate"
                + " no_serving_integration=true")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
    exit(1)
}
