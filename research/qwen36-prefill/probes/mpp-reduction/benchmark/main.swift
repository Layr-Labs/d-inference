import Darwin
import Foundation
import Metal

private let thresholdTFLOPS = 22.0

private struct ProbeConfiguration {
    let warmups: Int
    let samples: Int
    let repeatsPerSample: Int

    static func load() throws -> ProbeConfiguration {
        let environment = ProcessInfo.processInfo.environment

        func integer(_ name: String, default defaultValue: Int) throws -> Int {
            guard let raw = environment[name] else {
                return defaultValue
            }
            guard let value = Int(raw) else {
                throw ProbeFailure.message("\(name) must be an integer")
            }
            return value
        }

        let configuration = ProbeConfiguration(
            warmups: try integer("MPP_BENCH_WARMUPS", default: 5),
            samples: try integer("MPP_BENCH_SAMPLES", default: 21),
            repeatsPerSample: try integer("MPP_BENCH_REPEATS", default: 2))
        guard configuration.warmups >= 1 else {
            throw ProbeFailure.message("MPP_BENCH_WARMUPS must be at least 1")
        }
        guard configuration.samples >= 15 else {
            throw ProbeFailure.message(
                "MPP_BENCH_SAMPLES must be at least 15 for a decision run")
        }
        guard configuration.repeatsPerSample >= 1 else {
            throw ProbeFailure.message("MPP_BENCH_REPEATS must be at least 1")
        }
        return configuration
    }
}

private struct VariantTimingSummary {
    let gpu: TimingSummary
    let cpu: TimingSummary
}

private struct CellTimingResult {
    let cell: BenchmarkCell
    let summaries: [KernelVariant: VariantTimingSummary]
}

private let adversaryCells = [
    BenchmarkCell(
        name: "adversary-k512",
        m: 64,
        n: 64,
        k: 512,
        modelDispatchCount: 0),
    BenchmarkCell(
        name: "adversary-k2048",
        m: 64,
        n: 64,
        k: 2048,
        modelDispatchCount: 0),
]

// This dispatch-count ledger covers the Qwen 3.6 35B A3B token-linear
// projections for one 2,048-row pass. Routed rows already include top-8
// expansion (M=16,384). Only the scalar shared-expert gate (0.0034% of linear
// FLOPs, N=1 and outside this full-tile probe) is omitted.
private let benchmarkCells = [
    BenchmarkCell(
        name: "gdn-attention-input",
        m: 2_048,
        n: 8_192,
        k: 2_048,
        modelDispatchCount: 40),
    BenchmarkCell(
        name: "gdn-wide",
        m: 2_048,
        n: 4_096,
        k: 2_048,
        modelDispatchCount: 30),
    BenchmarkCell(
        name: "gdn-attention-output",
        m: 2_048,
        n: 2_048,
        k: 4_096,
        modelDispatchCount: 40),
    BenchmarkCell(
        name: "attention-kv-shared-up",
        m: 2_048,
        n: 512,
        k: 2_048,
        modelDispatchCount: 100),
    BenchmarkCell(
        name: "router",
        m: 2_048,
        n: 256,
        k: 2_048,
        modelDispatchCount: 40),
    BenchmarkCell(
        name: "gdn-small",
        m: 2_048,
        n: 32,
        k: 2_048,
        modelDispatchCount: 60),
    BenchmarkCell(
        name: "shared-down",
        m: 2_048,
        n: 2_048,
        k: 512,
        modelDispatchCount: 40),
    BenchmarkCell(
        name: "routed-gate-up",
        m: 16_384,
        n: 1_024,
        k: 2_048,
        modelDispatchCount: 40),
    BenchmarkCell(
        name: "routed-down",
        m: 16_384,
        n: 2_048,
        k: 512,
        modelDispatchCount: 40),
]

private func balancedOrder(round: Int) -> [KernelVariant] {
    switch round % 3 {
    case 0:
        return [.steelK8, .mppStaticK16, .mppDynamicK8]
    case 1:
        return [.mppDynamicK8, .steelK8, .mppStaticK16]
    default:
        return [.mppStaticK16, .mppDynamicK8, .steelK8]
    }
}

private func runAdversaryCorrectness(
    runner: BenchmarkRunner
) throws -> [KernelVariant: Bool] {
    var legal: [KernelVariant: Bool] = [
        .steelK8: true,
        .mppStaticK16: true,
        .mppDynamicK8: true,
    ]

    for cell in adversaryCells {
        try cell.validate()
        for fixture in InputFixture.allCases {
            let inputs = try makeInputBuffers(
                device: runner.device, cell: cell, fixture: fixture)
            let reference = try runner.makeOutputBuffer(
                cell: cell, label: "\(cell.name)-\(fixture.rawValue)-reference")
            let actual = try runner.makeOutputBuffer(
                cell: cell, label: "\(cell.name)-\(fixture.rawValue)-actual")
            _ = try runner.execute(
                variant: .steelK8,
                cell: cell,
                a: inputs.a,
                b: inputs.b,
                output: reference,
                repeats: 1)

            for variant in [KernelVariant.mppStaticK16, .mppDynamicK8] {
                _ = try runner.execute(
                    variant: variant,
                    cell: cell,
                    a: inputs.a,
                    b: inputs.b,
                    output: actual,
                    repeats: 1)
                let comparison = compareOutputs(
                    reference: reference,
                    actual: actual,
                    elementCount: cell.elementCountC)
                legal[variant] = (legal[variant] ?? true) && comparison.legal
                print(comparison.line(
                    prefix:
                        "CORRECTNESS scope=adversary cell=\(cell.name) "
                        + "fixture=\(fixture.rawValue) variant=\(variant.rawValue)",
                    elementCount: cell.elementCountC))
            }
        }
    }

    for variant in [KernelVariant.mppStaticK16, .mppDynamicK8] {
        print(
            "CORRECTNESS_GATE scope=adversary variant=\(variant.rawValue) "
                + "status=\((legal[variant] ?? false) ? "pass" : "fail")")
    }
    return legal
}

private func verifyFullCell(
    runner: BenchmarkRunner,
    cell: BenchmarkCell,
    a: MTLBuffer,
    b: MTLBuffer,
    reference: MTLBuffer,
    actual: MTLBuffer
) throws -> [KernelVariant: Bool] {
    _ = try runner.execute(
        variant: .steelK8,
        cell: cell,
        a: a,
        b: b,
        output: reference,
        repeats: 1)
    var legal: [KernelVariant: Bool] = [.steelK8: true]
    for variant in [KernelVariant.mppStaticK16, .mppDynamicK8] {
        _ = try runner.execute(
            variant: variant,
            cell: cell,
            a: a,
            b: b,
            output: actual,
            repeats: 1)
        let comparison = compareOutputs(
            reference: reference,
            actual: actual,
            elementCount: cell.elementCountC)
        legal[variant] = comparison.legal
        print(comparison.line(
            prefix:
                "CORRECTNESS scope=full cell=\(cell.name) "
                + "fixture=\(InputFixture.qmmScale.rawValue) "
                + "variant=\(variant.rawValue)",
            elementCount: cell.elementCountC))
    }
    return legal
}

private func benchmark(
    runner: BenchmarkRunner,
    cell: BenchmarkCell,
    configuration: ProbeConfiguration
) throws -> CellTimingResult {
    try cell.validate()
    print(
        "CELL name=\(cell.name) M=\(cell.m) N=\(cell.n) K=\(cell.k) "
            + "tile=M16xN32 reduction_k=8/16 "
            + "flops=\(String(format: "%.0f", cell.flops)) "
            + "model_dispatches=\(cell.modelDispatchCount)")

    let inputs = try makeInputBuffers(
        device: runner.device, cell: cell, fixture: .qmmScale)
    let output = try runner.makeOutputBuffer(
        cell: cell, label: "\(cell.name)-shared-timed-output")
    let reference = try runner.makeOutputBuffer(
        cell: cell, label: "\(cell.name)-steel-reference")

    let fullLegality = try verifyFullCell(
        runner: runner,
        cell: cell,
        a: inputs.a,
        b: inputs.b,
        reference: reference,
        actual: output)
    guard fullLegality[.mppDynamicK8] == true else {
        throw ProbeFailure.message(
            "\(cell.name): dynamic K=8 failed full-shape QMM correctness")
    }

    for warmup in 0..<configuration.warmups {
        for variant in balancedOrder(round: warmup) {
            _ = try runner.execute(
                variant: variant,
                cell: cell,
                a: inputs.a,
                b: inputs.b,
                output: output,
                repeats: configuration.repeatsPerSample)
        }
    }
    print(
        "WARMUPS cell=\(cell.name) per_variant=\(configuration.warmups) "
            + "dispatches_per_warmup=\(configuration.repeatsPerSample)")

    var timings: [KernelVariant: [ExecutionTiming]] = [:]
    for variant in KernelVariant.allCases {
        timings[variant] = []
    }

    for sample in 0..<configuration.samples {
        let order = balancedOrder(round: sample)
        print(
            "ORDER cell=\(cell.name) sample=\(sample + 1) "
                + "variants=\(order.map(\.rawValue).joined(separator: ","))")
        for variant in order {
            let timing = try runner.execute(
                variant: variant,
                cell: cell,
                a: inputs.a,
                b: inputs.b,
                output: output,
                repeats: configuration.repeatsPerSample)
            timings[variant, default: []].append(timing)
            print(
                "SAMPLE cell=\(cell.name) variant=\(variant.rawValue) "
                    + "index=\(sample + 1)/\(configuration.samples) "
                    + "gpu_ms=\(formatMilliseconds(timing.gpuMilliseconds)) "
                    + "cpu_ms=\(formatMilliseconds(timing.cpuMilliseconds)) "
                    + "gpu_tflops=\(formatTFLOPS(deliveredTFLOPS("
                    + "flops: cell.flops, milliseconds: timing.gpuMilliseconds)))")
        }
    }

    var summaries: [KernelVariant: VariantTimingSummary] = [:]
    for variant in KernelVariant.allCases {
        guard let variantTimings = timings[variant],
              variantTimings.count == configuration.samples
        else {
            throw ProbeFailure.message(
                "\(cell.name)/\(variant.rawValue): incomplete timing samples")
        }
        let gpu = try summarize(variantTimings.map(\.gpuMilliseconds))
        let cpu = try summarize(variantTimings.map(\.cpuMilliseconds))
        summaries[variant] = VariantTimingSummary(gpu: gpu, cpu: cpu)
        print(
            "SUMMARY cell=\(cell.name) variant=\(variant.rawValue) "
                + "samples=\(variantTimings.count) "
                + "gpu_min_ms=\(formatMilliseconds(gpu.minimum)) "
                + "gpu_p10_ms=\(formatMilliseconds(gpu.p10)) "
                + "gpu_median_ms=\(formatMilliseconds(gpu.median)) "
                + "gpu_p90_ms=\(formatMilliseconds(gpu.p90)) "
                + "gpu_max_ms=\(formatMilliseconds(gpu.maximum)) "
                + "cpu_median_ms=\(formatMilliseconds(cpu.median)) "
                + "gpu_median_tflops=\(formatTFLOPS(deliveredTFLOPS("
                + "flops: cell.flops, milliseconds: gpu.median))) "
                + "gpu_best_sample_tflops=\(formatTFLOPS(deliveredTFLOPS("
                + "flops: cell.flops, milliseconds: gpu.minimum)))")
    }
    return CellTimingResult(cell: cell, summaries: summaries)
}

private func printWeightedResults(_ results: [CellTimingResult]) throws -> Bool {
    let modelFlops = results.reduce(0.0) {
        $0 + $1.cell.flops * Double($1.cell.modelDispatchCount)
    }
    var dynamicPass = false

    for variant in KernelVariant.allCases {
        var medianGPUTime = 0.0
        var bestSampleGPUTime = 0.0
        var medianCPUTime = 0.0
        for result in results {
            guard let summary = result.summaries[variant] else {
                throw ProbeFailure.message(
                    "\(result.cell.name): missing \(variant.rawValue) summary")
            }
            let count = Double(result.cell.modelDispatchCount)
            medianGPUTime += summary.gpu.median * count
            bestSampleGPUTime += summary.gpu.minimum * count
            medianCPUTime += summary.cpu.median * count
        }
        let medianGPUThroughput = deliveredTFLOPS(
            flops: modelFlops, milliseconds: medianGPUTime)
        let bestSampleGPUThroughput = deliveredTFLOPS(
            flops: modelFlops, milliseconds: bestSampleGPUTime)
        let medianCPUThroughput = deliveredTFLOPS(
            flops: modelFlops, milliseconds: medianCPUTime)
        let status = medianGPUThroughput >= thresholdTFLOPS ? "pass" : "fail"
        print(
            "WEIGHTED variant=\(variant.rawValue) "
                + "coverage=qwen-all-linear-except-scalar-gate "
                + "model_flops=\(String(format: "%.0f", modelFlops)) "
                + "gpu_model_median_ms=\(formatMilliseconds(medianGPUTime)) "
                + "gpu_effective_tflops=\(formatTFLOPS(medianGPUThroughput)) "
                + "gpu_best_sample_effective_tflops="
                + "\(formatTFLOPS(bestSampleGPUThroughput)) "
                + "cpu_model_median_ms=\(formatMilliseconds(medianCPUTime)) "
                + "cpu_effective_tflops=\(formatTFLOPS(medianCPUThroughput)) "
                + "threshold_tflops=\(formatTFLOPS(thresholdTFLOPS)) "
                + "status=\(status)")
        if variant == .mppDynamicK8 {
            dynamicPass = medianGPUThroughput >= thresholdTFLOPS
        }
    }
    return dynamicPass
}

private func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw ProbeFailure.message(
            "usage: mpp-reduction-benchmark <benchmark.metallib>")
    }
    let configuration = try ProbeConfiguration.load()
    let runner = try BenchmarkRunner(metallibPath: CommandLine.arguments[1])
    try runner.prepareAllPipelines()
    for cell in adversaryCells + benchmarkCells {
        try cell.validate()
    }

    print("DEVICE=\(runner.device.name)")
    print("OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    print(
        "CONFIG warmups=\(configuration.warmups) "
            + "samples=\(configuration.samples) "
            + "repeats_per_sample=\(configuration.repeatsPerSample) "
            + "input=bf16 output=fp32 accumulation=explicit-fp32 "
            + "relaxed_precision=false gpu_timestamps=true cpu_wall=true")
    print(
        "LEDGER cells=\(benchmarkCells.count) "
            + "coverage=qwen-all-linear-except-scalar-gate "
            + "omitted_scalar_gate_fraction=0.000034")

    let adversaryLegality = try runAdversaryCorrectness(runner: runner)
    guard adversaryLegality[.mppDynamicK8] == true else {
        print("TIMING=skipped reason=dynamic-k8-adversary-correctness")
        print("RESULT=reject threshold_status=not-run")
        return
    }

    var results: [CellTimingResult] = []
    for cell in benchmarkCells {
        results.append(try benchmark(
            runner: runner, cell: cell, configuration: configuration))
    }
    let thresholdPass = try printWeightedResults(results)
    print(
        "RESULT=complete dynamic_k8_correctness=pass "
            + "threshold_status=\(thresholdPass ? "pass" : "fail")")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
    exit(1)
}
