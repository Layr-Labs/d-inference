import Darwin
import Foundation
import Metal

private let tileM = 16
private let tileN = 32
private let tileK = 16
private let repeats = 128
private let tileCount = 8_192
private let warmups = 3
private let iterations = 15

private enum PerfFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value): return value
        }
    }
}

private struct Variant {
    let label: String
    let function: String
    let groupsPerTile: Int
}

private struct Sample {
    let wallMs: Double
    let gpuMs: Double
}

private func bfloatBits(_ value: Float) -> UInt16 {
    if value.isNaN {
        return UInt16(value.bitPattern >> 16) | 0x0040
    }
    var bits = value.bitPattern
    bits &+= 0x7fff &+ ((bits >> 16) & 1)
    return UInt16(bits >> 16)
}

private func makeBuffer<T>(
    device: MTLDevice,
    values: [T]
) throws -> MTLBuffer {
    try values.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress,
              let buffer = device.makeBuffer(
                  bytes: base,
                  length: bytes.count,
                  options: .storageModeShared)
        else {
            throw PerfFailure.message("failed to allocate \(bytes.count)-byte buffer")
        }
        return buffer
    }
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

private func percentile(_ values: [Double], numerator: Int, denominator: Int) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, sorted.count * numerator / denominator)]
}

private final class Runner {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelines: [String: MTLComputePipelineState] = [:]

    init(metallib: String) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else {
            throw PerfFailure.message("Metal device or queue unavailable")
        }
        self.device = device
        self.queue = queue
        self.library = try device.makeLibrary(URL: URL(fileURLWithPath: metallib))
    }

    private func pipeline(_ name: String) throws -> MTLComputePipelineState {
        if let cached = pipelines[name] { return cached }
        guard let function = library.makeFunction(name: name) else {
            throw PerfFailure.message("missing Metal function \(name)")
        }
        let result = try device.makeComputePipelineState(function: function)
        guard result.threadExecutionWidth == 32 else {
            throw PerfFailure.message(
                "\(name) SIMD width \(result.threadExecutionWidth), expected 32")
        }
        pipelines[name] = result
        return result
    }

    func execute(
        variant: Variant,
        a: MTLBuffer,
        b: MTLBuffer,
        output: MTLBuffer
    ) throws -> Sample {
        let state = try pipeline(variant.function)
        let wallStart = DispatchTime.now().uptimeNanoseconds
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder()
        else {
            throw PerfFailure.message("failed to create command for \(variant.label)")
        }
        command.label = variant.label
        encoder.label = variant.label
        encoder.setComputePipelineState(state)
        encoder.setBuffer(a, offset: 0, index: 0)
        encoder.setBuffer(b, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.dispatchThreadgroups(
            MTLSize(
                width: tileCount * variant.groupsPerTile,
                height: 1,
                depth: 1),
            threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        let wallEnd = DispatchTime.now().uptimeNanoseconds
        guard command.status == .completed else {
            throw PerfFailure.message(
                "\(variant.label) failed: "
                    + (command.error?.localizedDescription ?? "unknown command error"))
        }
        let gpuSeconds = command.gpuEndTime - command.gpuStartTime
        guard gpuSeconds.isFinite, gpuSeconds > 0 else {
            throw PerfFailure.message("\(variant.label) has no valid GPU timestamp")
        }
        return Sample(
            wallMs: Double(wallEnd - wallStart) / 1e6,
            gpuMs: gpuSeconds * 1e3)
    }
}

private func firstTile(_ buffer: MTLBuffer) -> [Float] {
    let pointer = buffer.contents().bindMemory(to: Float.self, capacity: tileM * tileN)
    return Array(UnsafeBufferPointer(start: pointer, count: tileM * tileN))
}

private func compare(reference: [Float], candidate: [Float]) -> String {
    var fp32Changed = 0
    var bf16Changed = 0
    var maxAbsolute: Float = 0
    for (expected, actual) in zip(reference, candidate) {
        if expected.bitPattern != actual.bitPattern { fp32Changed += 1 }
        if bfloatBits(expected) != bfloatBits(actual) { bf16Changed += 1 }
        maxAbsolute = max(maxAbsolute, abs(expected - actual))
    }
    return "fp32_changed=\(fp32Changed)/\(reference.count) "
        + "bf16_changed=\(bf16Changed)/\(reference.count) "
        + "max_abs=\(String(format: "%.9g", maxAbsolute))"
}

private func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw PerfFailure.message("usage: mpp-perf <perf.metallib>")
    }
    let runner = try Runner(metallib: CommandLine.arguments[1])
    let aValues = (0 ..< tileM * tileK).map {
        bfloatBits(Float(($0 * 17) % 31 - 15) / 128)
    }
    let bValues = (0 ..< tileK * tileN).map {
        bfloatBits(Float(($0 * 29) % 37 - 18) / 128)
    }
    let a = try makeBuffer(device: runner.device, values: aValues)
    let b = try makeBuffer(device: runner.device, values: bValues)
    let outputBytes = tileCount * tileM * tileN * MemoryLayout<Float>.stride

    let variants = [
        Variant(
            label: "steel-k8x2",
            function: "perf_steel_k8x2",
            groupsPerTile: 8),
        Variant(
            label: "mpp-static-k16",
            function: "perf_mpp_static_k16",
            groupsPerTile: 1),
        Variant(
            label: "mpp-dynamic-k8",
            function: "perf_mpp_dynamic_k8",
            groupsPerTile: 1),
    ]
    var outputs: [String: MTLBuffer] = [:]
    for variant in variants {
        guard let output = runner.device.makeBuffer(
            length: outputBytes, options: .storageModeShared)
        else {
            throw PerfFailure.message("failed to allocate output for \(variant.label)")
        }
        outputs[variant.label] = output
        for _ in 0 ..< warmups {
            _ = try runner.execute(variant: variant, a: a, b: b, output: output)
        }
    }

    let steel = firstTile(outputs["steel-k8x2"]!)
    for variant in variants.dropFirst() {
        print(
            "CORRECTNESS variant=\(variant.label) "
                + compare(reference: steel, candidate: firstTile(outputs[variant.label]!)))
    }

    var samples: [String: [Sample]] = [:]
    let orders = [
        [0, 1, 2],
        [2, 1, 0],
        [1, 0, 2],
    ]
    for round in 0 ..< iterations {
        for index in orders[round % orders.count] {
            let variant = variants[index]
            samples[variant.label, default: []].append(
                try runner.execute(
                    variant: variant,
                    a: a,
                    b: b,
                    output: outputs[variant.label]!
                ))
        }
    }

    let operations =
        Double(tileCount) * Double(repeats)
        * 2.0 * Double(tileM * tileN * tileK)
    print("DEVICE=\(runner.device.name)")
    print(
        "WORK tiles=\(tileCount) repeats=\(repeats) "
            + "useful_flops=\(String(format: "%.0f", operations))")
    for variant in variants {
        let values = samples[variant.label]!
        let gpu = values.map(\.gpuMs)
        let wall = values.map(\.wallMs)
        let gpuMedian = median(gpu)
        let wallMedian = median(wall)
        let tflops = operations / (gpuMedian / 1e3) / 1e12
        print(
            "PERF variant=\(variant.label) "
                + "gpu_median_ms=\(String(format: "%.4f", gpuMedian)) "
                + "gpu_p10_ms=\(String(format: "%.4f", percentile(gpu, numerator: 1, denominator: 10))) "
                + "gpu_p90_ms=\(String(format: "%.4f", percentile(gpu, numerator: 9, denominator: 10))) "
                + "wall_median_ms=\(String(format: "%.4f", wallMedian)) "
                + "tflops=\(String(format: "%.2f", tflops)) "
                + "n=\(values.count)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
    exit(1)
}
