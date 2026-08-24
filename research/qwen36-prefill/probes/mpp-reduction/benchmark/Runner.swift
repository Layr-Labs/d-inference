import Foundation
import Metal

final class BenchmarkRunner {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelines: [KernelVariant: MTLComputePipelineState] = [:]

    init(metallibPath: String) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ProbeFailure.message("Metal device unavailable")
        }
        guard let queue = device.makeCommandQueue() else {
            throw ProbeFailure.message("Metal command queue unavailable")
        }
        self.device = device
        self.queue = queue
        library = try device.makeLibrary(URL: URL(fileURLWithPath: metallibPath))
    }

    func prepareAllPipelines() throws {
        for variant in KernelVariant.allCases {
            _ = try pipeline(for: variant)
        }
    }

    func makeOutputBuffer(cell: BenchmarkCell, label: String) throws -> MTLBuffer {
        try makeSharedBuffer(
            device: device,
            elementCount: cell.elementCountC,
            elementStride: MemoryLayout<Float>.stride,
            label: label)
    }

    private func pipeline(for variant: KernelVariant) throws -> MTLComputePipelineState {
        if let cached = pipelines[variant] {
            return cached
        }
        guard let function = library.makeFunction(name: variant.functionName) else {
            throw ProbeFailure.message(
                "metallib has no function \(variant.functionName)")
        }
        let pipeline = try device.makeComputePipelineState(function: function)
        guard pipeline.threadExecutionWidth == 32 else {
            throw ProbeFailure.message(
                "\(variant.rawValue): unexpected SIMD width "
                    + "\(pipeline.threadExecutionWidth)")
        }
        guard pipeline.maxTotalThreadsPerThreadgroup >= 32 else {
            throw ProbeFailure.message(
                "\(variant.rawValue): pipeline cannot dispatch one SIMD group")
        }
        pipelines[variant] = pipeline
        return pipeline
    }

    func execute(
        variant: KernelVariant,
        cell: BenchmarkCell,
        a: MTLBuffer,
        b: MTLBuffer,
        output: MTLBuffer,
        repeats: Int
    ) throws -> ExecutionTiming {
        guard repeats > 0 else {
            throw ProbeFailure.message("dispatch repeat count must be positive")
        }
        let pipeline = try pipeline(for: variant)
        var parameters = cell.parameters
        let cpuStart = DispatchTime.now().uptimeNanoseconds
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw ProbeFailure.message(
                "\(variant.rawValue): failed to create command buffer or encoder")
        }
        commandBuffer.label = "\(cell.name)-\(variant.rawValue)"
        encoder.label = variant.functionName
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(a, offset: 0, index: 0)
        encoder.setBuffer(b, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.setBytes(
            &parameters,
            length: MemoryLayout<ShapeParameters>.stride,
            index: 3)

        let groups = MTLSize(
            width: cell.n / 32,
            height: cell.m / 16,
            depth: 1)
        let threads = MTLSize(width: 32, height: 1, depth: 1)
        for _ in 0..<repeats {
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let cpuEnd = DispatchTime.now().uptimeNanoseconds

        guard commandBuffer.status == .completed else {
            let detail = commandBuffer.error?.localizedDescription
                ?? "no command-buffer error detail"
            throw ProbeFailure.message(
                "\(cell.name)/\(variant.rawValue): command status "
                    + "\(commandBuffer.status.rawValue): \(detail)")
        }
        let gpuStart = commandBuffer.gpuStartTime
        let gpuEnd = commandBuffer.gpuEndTime
        guard gpuStart > 0, gpuEnd > gpuStart else {
            throw ProbeFailure.message(
                "\(cell.name)/\(variant.rawValue): invalid GPU timestamps "
                    + "start=\(gpuStart) end=\(gpuEnd)")
        }

        let divisor = Double(repeats)
        return ExecutionTiming(
            gpuMilliseconds: (gpuEnd - gpuStart) * 1_000.0 / divisor,
            cpuMilliseconds:
                Double(cpuEnd - cpuStart) / 1_000_000.0 / divisor)
    }
}
