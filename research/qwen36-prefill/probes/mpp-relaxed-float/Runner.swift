import Foundation
import Metal

enum RelaxedVariant: String, CaseIterable {
    case strict
    case relaxed

    var functionName: String {
        switch self {
        case .strict:
            return "mpp_f32_strict_m32_n32_k32"
        case .relaxed:
            return "mpp_f32_relaxed_m32_n32_k32"
        }
    }
}

struct ProjectionShape {
    let label: String
    let m: Int
    let k: Int
    let n: Int
    let modelDispatches: Int

    var outputElementCount: Int {
        m * n
    }

    var usefulOperations: Double {
        2.0 * Double(m) * Double(k) * Double(n)
    }

    func validate(device: MTLDevice) throws {
        guard m > 0, k > 0, n > 0, modelDispatches > 0,
              m.isMultiple(of: 32),
              k.isMultiple(of: 32),
              n.isMultiple(of: 32)
        else {
            throw ProbeFailure.message(
                "\(label) must be positive and divisible by M32/K32/N32")
        }
        let outputTiles = try checkedProduct(
            [m / 32, n / 32],
            label: "\(label) output tile count")
        guard outputTiles.isMultiple(of: 4) else {
            throw ProbeFailure.message(
                "\(label) output tile count must divide four SIMD groups")
        }
        for (name, elements) in [
            ("A", try checkedProduct([m, k], label: "\(label) A elements")),
            ("B", try checkedProduct([k, n], label: "\(label) B elements")),
            ("output", try checkedProduct([m, n], label: "\(label) output elements")),
        ] {
            let bytes = try checkedProduct(
                [elements, MemoryLayout<Float>.stride],
                label: "\(label) \(name) bytes")
            guard UInt64(bytes) <= device.maxBufferLength else {
                throw ProbeFailure.message(
                    "\(label) \(name) needs \(bytes) bytes; "
                        + "device maxBufferLength is \(device.maxBufferLength)")
            }
        }
    }

    var threadgroupCount: Int {
        ((m / 32) * (n / 32)) / 4
    }
}

private func checkedProduct(_ factors: [Int], label: String) throws -> Int {
    var result = 1
    for factor in factors {
        let (next, overflow) = result.multipliedReportingOverflow(by: factor)
        guard !overflow else {
            throw ProbeFailure.message("\(label) overflow")
        }
        result = next
    }
    return result
}

struct ProblemShapeParameters {
    var m: UInt32
    var k: UInt32
    var n: UInt32

    init(_ shape: ProjectionShape) throws {
        guard let m = UInt32(exactly: shape.m),
              let k = UInt32(exactly: shape.k),
              let n = UInt32(exactly: shape.n)
        else {
            throw ProbeFailure.message("\(shape.label) exceeds UInt32 dimensions")
        }
        self.m = m
        self.k = k
        self.n = n
    }
}

final class PreparedFloatShape {
    let shape: ProjectionShape
    let a: MTLBuffer
    let b: MTLBuffer
    let strictOutput: MTLBuffer
    let relaxedOutput: MTLBuffer

    init(device: MTLDevice, shape: ProjectionShape, seed: UInt64) throws {
        try shape.validate(device: device)
        self.shape = shape
        a = try PreparedFloatShape.makeInputBuffer(
            device: device,
            count: try checkedProduct([shape.m, shape.k], label: "\(shape.label) A"),
            seed: seed,
            label: "\(shape.label)-a-f32-bf16-values")
        b = try PreparedFloatShape.makeInputBuffer(
            device: device,
            count: try checkedProduct([shape.k, shape.n], label: "\(shape.label) B"),
            seed: seed ^ 0x9e37_79b9_7f4a_7c15,
            label: "\(shape.label)-b-f32-bf16-values")
        strictOutput = try PreparedFloatShape.makeOutputBuffer(
            device: device,
            count: shape.outputElementCount,
            label: "\(shape.label)-strict-output")
        relaxedOutput = try PreparedFloatShape.makeOutputBuffer(
            device: device,
            count: shape.outputElementCount,
            label: "\(shape.label)-relaxed-output")
    }

    func output(for variant: RelaxedVariant) -> MTLBuffer {
        switch variant {
        case .strict:
            return strictOutput
        case .relaxed:
            return relaxedOutput
        }
    }

    func poisonOutput(for variant: RelaxedVariant) {
        let buffer = output(for: variant)
        memset(buffer.contents(), 0xff, buffer.length)
    }

    func comparison() -> Comparison {
        let strict = strictOutput.contents().bindMemory(
            to: Float.self,
            capacity: shape.outputElementCount)
        let relaxed = relaxedOutput.contents().bindMemory(
            to: Float.self,
            capacity: shape.outputElementCount)
        return compareOutputs(
            steel: strict,
            mpp: relaxed,
            count: shape.outputElementCount)
    }

    private static func makeInputBuffer(
        device: MTLDevice,
        count: Int,
        seed: UInt64,
        label: String
    ) throws -> MTLBuffer {
        // Store BF16-representable values in float buffers. This isolates what
        // relaxed_precision does to float MPP arithmetic without adding input
        // quantization that the serving model does not already have.
        let bits = makeBF16Fixture(count: count, seed: seed)
        var values = [Float](repeating: 0, count: count)
        for index in values.indices {
            values[index] = Float(bitPattern: UInt32(bits[index]) << 16)
        }
        return try values.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress,
                  let buffer = device.makeBuffer(
                      bytes: baseAddress,
                      length: bytes.count,
                      options: .storageModeShared)
            else {
                throw ProbeFailure.message("failed to allocate \(label)")
            }
            buffer.label = label
            return buffer
        }
    }

    private static func makeOutputBuffer(
        device: MTLDevice,
        count: Int,
        label: String
    ) throws -> MTLBuffer {
        let bytes = try checkedProduct(
            [count, MemoryLayout<Float>.stride],
            label: "\(label) bytes")
        guard let buffer = device.makeBuffer(
            length: bytes,
            options: .storageModeShared)
        else {
            throw ProbeFailure.message("failed to allocate \(label)")
        }
        buffer.label = label
        memset(buffer.contents(), 0, bytes)
        return buffer
    }
}

final class RelaxedMPPRunner {
    let device: MTLDevice

    private let queue: MTLCommandQueue
    private let pipelines: [RelaxedVariant: MTLComputePipelineState]

    init(metallibPath: String) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else {
            throw ProbeFailure.message("Metal device or command queue unavailable")
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: metallibPath))
        var pipelines: [RelaxedVariant: MTLComputePipelineState] = [:]
        for variant in RelaxedVariant.allCases {
            guard let function = library.makeFunction(name: variant.functionName) else {
                throw ProbeFailure.message(
                    "metallib lacks \(variant.functionName)")
            }
            let pipeline = try device.makeComputePipelineState(function: function)
            guard pipeline.threadExecutionWidth == 32,
                  pipeline.maxTotalThreadsPerThreadgroup >= 128
            else {
                throw ProbeFailure.message(
                    "\(variant.rawValue) pipeline cannot run four SIMD groups")
            }
            pipelines[variant] = pipeline
        }
        self.device = device
        self.queue = queue
        self.pipelines = pipelines
    }

    func execute(
        variant: RelaxedVariant,
        prepared: PreparedFloatShape,
        round: Int = 0,
        position: Int = 0
    ) throws -> TimingSample {
        guard let pipeline = pipelines[variant] else {
            throw ProbeFailure.message("missing \(variant.rawValue) pipeline")
        }
        var parameters = try ProblemShapeParameters(prepared.shape)
        let cpuStart = DispatchTime.now().uptimeNanoseconds
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw ProbeFailure.message("failed to make \(variant.rawValue) command buffer")
        }
        commandBuffer.label =
            "\(prepared.shape.label)-\(variant.rawValue)-r\(round)-p\(position)"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(prepared.a, offset: 0, index: 0)
        encoder.setBuffer(prepared.b, offset: 0, index: 1)
        encoder.setBuffer(prepared.output(for: variant), offset: 0, index: 2)
        encoder.setBytes(
            &parameters,
            length: MemoryLayout<ProblemShapeParameters>.stride,
            index: 3)
        encoder.dispatchThreadgroups(
            MTLSize(width: prepared.shape.threadgroupCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let cpuEnd = DispatchTime.now().uptimeNanoseconds

        guard commandBuffer.status == .completed else {
            throw ProbeFailure.message(
                "\(commandBuffer.label ?? variant.rawValue) failed: "
                    + "\(commandBuffer.error?.localizedDescription ?? "unknown error")")
        }
        guard commandBuffer.gpuStartTime > 0,
              commandBuffer.gpuEndTime > commandBuffer.gpuStartTime,
              commandBuffer.kernelStartTime > 0,
              commandBuffer.kernelEndTime > commandBuffer.kernelStartTime
        else {
            throw ProbeFailure.message(
                "\(commandBuffer.label ?? variant.rawValue) lacks valid GPU timestamps")
        }
        return TimingSample(
            variantID: variant.rawValue,
            round: round,
            position: position,
            gpuStartSeconds: commandBuffer.gpuStartTime,
            gpuEndSeconds: commandBuffer.gpuEndTime,
            kernelStartSeconds: commandBuffer.kernelStartTime,
            kernelEndSeconds: commandBuffer.kernelEndTime,
            cpuSeconds: Double(cpuEnd - cpuStart) * 1e-9)
    }
}
