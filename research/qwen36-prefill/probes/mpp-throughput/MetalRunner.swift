import Foundation
import Metal

struct PipelineStatus {
    let candidate: MPPCandidate
    let accepted: Bool
    let detail: String
}

final class PreparedShape {
    let shape: DenseShape
    let a: MTLBuffer
    let b: MTLBuffer
    let mppOutput: MTLBuffer
    let steelOutput: MTLBuffer

    init(device: MTLDevice, shape: DenseShape, seed: UInt64) throws {
        try shape.validateForSteel()
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

    func output(for variant: BenchmarkVariant) -> MTLBuffer {
        switch variant {
        case .steel:
            return steelOutput
        case .mpp:
            return mppOutput
        }
    }

    func poisonOutput(for variant: BenchmarkVariant) {
        let buffer = output(for: variant)
        memset(buffer.contents(), 0xff, buffer.length)
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
    let pipelineStatuses: [PipelineStatus]
    let executableCandidates: [MPPCandidate]

    private let queue: MTLCommandQueue
    private let steelPipeline: MTLComputePipelineState
    private let candidatePipelines: [String: MTLComputePipelineState]

    init(buildDirectory: String, candidates: [MPPCandidate]) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ProbeFailure.message("Metal device unavailable")
        }
        guard let queue = device.makeCommandQueue() else {
            throw ProbeFailure.message("Metal command queue unavailable")
        }

        let buildURL = URL(fileURLWithPath: buildDirectory, isDirectory: true)
        let steelLibrary = try device.makeLibrary(
            URL: buildURL.appendingPathComponent("steel.metallib"))
        guard let steelFunction = steelLibrary.makeFunction(
            name: "steel_simdgroup_fp32_reference")
        else {
            throw ProbeFailure.message("Steel metallib lacks reference function")
        }
        let steelPipeline = try device.makeComputePipelineState(function: steelFunction)
        try MetalRunner.validatePipeline(
            steelPipeline,
            functionName: "steel_simdgroup_fp32_reference",
            threadsPerThreadgroup: 128)

        var statuses: [PipelineStatus] = []
        var executable: [MPPCandidate] = []
        var pipelines: [String: MTLComputePipelineState] = [:]
        for candidate in candidates {
            do {
                let library = try device.makeLibrary(
                    URL: URL(fileURLWithPath: candidate.metallibPath))
                guard let function = library.makeFunction(name: candidate.id) else {
                    throw ProbeFailure.message(
                        "metallib lacks function \(candidate.id)")
                }
                let pipeline = try device.makeComputePipelineState(function: function)
                try MetalRunner.validatePipeline(
                    pipeline,
                    functionName: candidate.id,
                    threadsPerThreadgroup: candidate.threadsPerThreadgroup)
                pipelines[candidate.id] = pipeline
                executable.append(candidate)
                statuses.append(PipelineStatus(
                    candidate: candidate,
                    accepted: true,
                    detail: "thread_width=\(pipeline.threadExecutionWidth)"
                        + " max_threads=\(pipeline.maxTotalThreadsPerThreadgroup)"))
            } catch {
                statuses.append(PipelineStatus(
                    candidate: candidate,
                    accepted: false,
                    detail: String(describing: error)))
            }
        }

        self.device = device
        self.queue = queue
        self.steelPipeline = steelPipeline
        self.pipelineStatuses = statuses
        self.executableCandidates = executable
        self.candidatePipelines = pipelines
    }

    func execute(
        variant: BenchmarkVariant,
        prepared: PreparedShape,
        round: Int = 0,
        position: Int = 0
    ) throws -> TimingSample {
        let pipeline: MTLComputePipelineState
        let threadsPerThreadgroup: Int
        switch variant {
        case .steel:
            pipeline = steelPipeline
            threadsPerThreadgroup = 128
        case .mpp(let candidate):
            guard let candidatePipeline = candidatePipelines[candidate.id] else {
                throw ProbeFailure.message("missing pipeline for \(candidate.id)")
            }
            pipeline = candidatePipeline
            threadsPerThreadgroup = candidate.threadsPerThreadgroup
        }
        let threadgroupCount = try prepared.shape.threadgroupCount(for: variant)

        let cpuStart = DispatchTime.now().uptimeNanoseconds
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw ProbeFailure.message("failed to make \(variant.id) command buffer")
        }
        commandBuffer.label =
            "\(prepared.shape.label)-\(variant.id)-round\(round)-position\(position)"
        encoder.label = commandBuffer.label
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(prepared.a, offset: 0, index: 0)
        encoder.setBuffer(prepared.b, offset: 0, index: 1)
        encoder.setBuffer(prepared.output(for: variant), offset: 0, index: 2)
        var parameters = DenseShapeParameters(prepared.shape)
        encoder.setBytes(
            &parameters,
            length: MemoryLayout<DenseShapeParameters>.stride,
            index: 3)
        encoder.dispatchThreadgroups(
            MTLSize(width: threadgroupCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadsPerThreadgroup,
                height: 1,
                depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let cpuEnd = DispatchTime.now().uptimeNanoseconds

        guard commandBuffer.status == .completed else {
            let detail = commandBuffer.error?.localizedDescription
                ?? "no command-buffer error detail"
            throw ProbeFailure.message(
                "\(commandBuffer.label ?? variant.id) status="
                    + "\(commandBuffer.status.rawValue) error=\(detail)")
        }
        guard commandBuffer.gpuStartTime > 0,
              commandBuffer.gpuEndTime > commandBuffer.gpuStartTime
        else {
            throw ProbeFailure.message(
                "\(commandBuffer.label ?? variant.id) has invalid GPU timestamps "
                    + "start=\(commandBuffer.gpuStartTime) "
                    + "end=\(commandBuffer.gpuEndTime)")
        }
        guard commandBuffer.kernelStartTime > 0,
              commandBuffer.kernelEndTime > commandBuffer.kernelStartTime
        else {
            throw ProbeFailure.message(
                "\(commandBuffer.label ?? variant.id) has invalid kernel timestamps "
                    + "start=\(commandBuffer.kernelStartTime) "
                    + "end=\(commandBuffer.kernelEndTime)")
        }

        return TimingSample(
            variantID: variant.id,
            round: round,
            position: position,
            gpuStartSeconds: commandBuffer.gpuStartTime,
            gpuEndSeconds: commandBuffer.gpuEndTime,
            kernelStartSeconds: commandBuffer.kernelStartTime,
            kernelEndSeconds: commandBuffer.kernelEndTime,
            cpuSeconds: Double(cpuEnd - cpuStart) * 1e-9)
    }

    private static func validatePipeline(
        _ pipeline: MTLComputePipelineState,
        functionName: String,
        threadsPerThreadgroup: Int
    ) throws {
        guard pipeline.threadExecutionWidth == 32 else {
            throw ProbeFailure.message(
                "\(functionName) SIMD width is \(pipeline.threadExecutionWidth), expected 32")
        }
        guard pipeline.maxTotalThreadsPerThreadgroup >= threadsPerThreadgroup else {
            throw ProbeFailure.message(
                "\(functionName) permits only "
                    + "\(pipeline.maxTotalThreadsPerThreadgroup) threads; "
                    + "\(threadsPerThreadgroup) required")
        }
    }
}
