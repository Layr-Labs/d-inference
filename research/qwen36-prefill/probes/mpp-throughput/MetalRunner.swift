import Foundation
import Metal

final class PreparedShape {
    let shape: DenseShape
    let a: MTLBuffer
    let b: MTLBuffer
    let mppOutput: MTLBuffer
    let steelOutput: MTLBuffer

    init(device: MTLDevice, shape: DenseShape, seed: UInt64) throws {
        try shape.validate()
        self.shape = shape
        a = try PreparedShape.makeInputBuffer(
            device: device,
            values: makeBF16Fixture(count: shape.m * shape.k, seed: seed),
            label: "\(shape.label)-a-bf16")
        b = try PreparedShape.makeInputBuffer(
            device: device,
            values: makeBF16Fixture(
                count: shape.k * shape.n,
                seed: seed ^ 0x9e37_79b9_7f4a_7c15),
            label: "\(shape.label)-b-bf16")
        mppOutput = try PreparedShape.makeOutputBuffer(
            device: device,
            elementCount: shape.elementCount,
            label: "\(shape.label)-mpp-output-fp32")
        steelOutput = try PreparedShape.makeOutputBuffer(
            device: device,
            elementCount: shape.elementCount,
            label: "\(shape.label)-steel-output-fp32")
    }

    func output(for arm: Arm) -> MTLBuffer {
        switch arm {
        case .mpp:
            return mppOutput
        case .steel:
            return steelOutput
        }
    }

    func comparison() -> Comparison {
        let steel = steelOutput.contents().bindMemory(
            to: Float.self,
            capacity: shape.elementCount)
        let mpp = mppOutput.contents().bindMemory(
            to: Float.self,
            capacity: shape.elementCount)
        return compareOutputs(steel: steel, mpp: mpp, count: shape.elementCount)
    }

    private static func makeInputBuffer(
        device: MTLDevice,
        values: [UInt16],
        label: String
    ) throws -> MTLBuffer {
        try values.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress,
                  let buffer = device.makeBuffer(
                      bytes: address,
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
        elementCount: Int,
        label: String
    ) throws -> MTLBuffer {
        let byteCount = elementCount * MemoryLayout<Float>.stride
        guard let buffer = device.makeBuffer(
            length: byteCount,
            options: .storageModeShared)
        else {
            throw ProbeFailure.message("failed to allocate \(label)")
        }
        buffer.label = label
        memset(buffer.contents(), 0, byteCount)
        return buffer
    }
}

final class MetalRunner {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [Arm: MTLComputePipelineState]
    private let threadsPerThreadgroup = MTLSize(width: 128, height: 1, depth: 1)

    init(metallibPath: String) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ProbeFailure.message("Metal device unavailable")
        }
        guard let queue = device.makeCommandQueue() else {
            throw ProbeFailure.message("Metal command queue unavailable")
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: metallibPath))
        let functionNames: [Arm: String] = [
            .mpp: "mpp_bf16_fp32_static_k16",
            .steel: "steel_simdgroup_fp32_reference",
        ]
        var pipelines: [Arm: MTLComputePipelineState] = [:]
        for arm in Arm.allCases {
            guard let functionName = functionNames[arm],
                  let function = library.makeFunction(name: functionName)
            else {
                throw ProbeFailure.message("metallib lacks \(arm.rawValue) function")
            }
            let pipeline = try device.makeComputePipelineState(function: function)
            guard pipeline.threadExecutionWidth == 32 else {
                throw ProbeFailure.message(
                    "\(functionName) SIMD width is \(pipeline.threadExecutionWidth), expected 32")
            }
            guard pipeline.maxTotalThreadsPerThreadgroup >= threadsPerThreadgroup.width else {
                throw ProbeFailure.message(
                    "\(functionName) permits only \(pipeline.maxTotalThreadsPerThreadgroup) threads")
            }
            pipelines[arm] = pipeline
        }

        self.device = device
        self.queue = queue
        self.pipelines = pipelines
    }

    func execute(
        arm: Arm,
        prepared: PreparedShape,
        block: Int = 0,
        position: String = "correctness"
    ) throws -> TimingSample {
        guard let pipeline = pipelines[arm] else {
            throw ProbeFailure.message("missing pipeline for \(arm.rawValue)")
        }

        let cpuStart = DispatchTime.now().uptimeNanoseconds
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw ProbeFailure.message("failed to make \(arm.rawValue) command buffer")
        }
        commandBuffer.label =
            "\(prepared.shape.label)-\(arm.rawValue)-block\(block)-\(position)"
        encoder.label = commandBuffer.label
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(prepared.a, offset: 0, index: 0)
        encoder.setBuffer(prepared.b, offset: 0, index: 1)
        encoder.setBuffer(prepared.output(for: arm), offset: 0, index: 2)
        var parameters = DenseShapeParameters(prepared.shape)
        encoder.setBytes(
            &parameters,
            length: MemoryLayout<DenseShapeParameters>.stride,
            index: 3)
        encoder.dispatchThreadgroups(
            MTLSize(
                width: prepared.shape.threadgroupCount,
                height: 1,
                depth: 1),
            threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let cpuEnd = DispatchTime.now().uptimeNanoseconds

        guard commandBuffer.status == .completed else {
            let detail = commandBuffer.error?.localizedDescription
                ?? "no command-buffer error detail"
            throw ProbeFailure.message(
                "\(commandBuffer.label ?? arm.rawValue) status="
                    + "\(commandBuffer.status.rawValue) error=\(detail)")
        }
        guard commandBuffer.gpuStartTime > 0,
              commandBuffer.gpuEndTime > commandBuffer.gpuStartTime
        else {
            throw ProbeFailure.message(
                "\(commandBuffer.label ?? arm.rawValue) has invalid GPU timestamps "
                    + "start=\(commandBuffer.gpuStartTime) end=\(commandBuffer.gpuEndTime)")
        }

        return TimingSample(
            arm: arm,
            block: block,
            position: position,
            gpuStartSeconds: commandBuffer.gpuStartTime,
            gpuEndSeconds: commandBuffer.gpuEndTime,
            kernelStartSeconds: commandBuffer.kernelStartTime,
            kernelEndSeconds: commandBuffer.kernelEndTime,
            cpuSeconds: Double(cpuEnd - cpuStart) * 1e-9
        )
    }
}
