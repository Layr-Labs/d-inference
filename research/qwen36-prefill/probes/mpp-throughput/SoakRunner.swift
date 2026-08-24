import Foundation
import Metal

private func soakFieldSafe(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\n", with: "|")
        .replacingOccurrences(of: "\r", with: "|")
        .replacingOccurrences(of: " ", with: "_")
        .replacingOccurrences(of: "\t", with: "_")
}

struct RepeatedTimingSample {
    let label: String
    let dispatchCount: Int
    let gpuStartSeconds: Double
    let gpuEndSeconds: Double
    let kernelStartSeconds: Double
    let kernelEndSeconds: Double
    let cpuSeconds: Double

    var gpuSeconds: Double {
        gpuEndSeconds - gpuStartSeconds
    }

    var kernelSeconds: Double {
        kernelEndSeconds - kernelStartSeconds
    }
}

struct TimestampCounterObservation {
    let start: UInt64
    let end: UInt64
    let commandBufferGPUSeconds: Double
    let commandBufferKernelSeconds: Double

    var delta: UInt64 {
        end - start
    }
}

enum SoakVariant {
    case steel
    case candidate
}

final class SustainedMetalRunner {
    let device: MTLDevice
    let candidate: MPPCandidate

    private let queue: MTLCommandQueue
    private let steelPipeline: MTLComputePipelineState
    private let candidatePipeline: MTLComputePipelineState

    init(buildDirectory: String, candidate: MPPCandidate) throws {
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

        let candidateLibrary = try device.makeLibrary(
            URL: URL(fileURLWithPath: candidate.metallibPath))
        guard let candidateFunction = candidateLibrary.makeFunction(name: candidate.id) else {
            throw ProbeFailure.message(
                "candidate metallib lacks function \(candidate.id)")
        }

        let steelPipeline = try device.makeComputePipelineState(function: steelFunction)
        let candidatePipeline = try device.makeComputePipelineState(
            function: candidateFunction)
        try SustainedMetalRunner.validatePipeline(
            steelPipeline,
            functionName: "steel_simdgroup_fp32_reference",
            threadsPerThreadgroup: 128)
        try SustainedMetalRunner.validatePipeline(
            candidatePipeline,
            functionName: candidate.id,
            threadsPerThreadgroup: candidate.threadsPerThreadgroup)

        self.device = device
        self.queue = queue
        self.steelPipeline = steelPipeline
        self.candidatePipeline = candidatePipeline
        self.candidate = candidate
    }

    func pipelineFacts() -> String {
        [
            "PIPELINE_FACTS",
            "candidate=\(candidate.id)",
            "thread_execution_width=\(candidatePipeline.threadExecutionWidth)",
            "max_threads_per_threadgroup="
                + "\(candidatePipeline.maxTotalThreadsPerThreadgroup)",
            "static_threadgroup_memory_bytes="
                + "\(candidatePipeline.staticThreadgroupMemoryLength)",
            "support_indirect_command_buffers="
                + "\(candidatePipeline.supportIndirectCommandBuffers)",
            "register_count=unavailable",
            "occupancy=unavailable",
            "native_pipeline_statistics=unavailable",
        ].joined(separator: " ")
    }

    func counterCapabilityLines() -> [String] {
        let samplingPoints: [(String, MTLCounterSamplingPoint)] = [
            ("stage_boundary", .atStageBoundary),
            ("draw_boundary", .atDrawBoundary),
            ("dispatch_boundary", .atDispatchBoundary),
            ("blit_boundary", .atBlitBoundary),
        ]
        var lines = samplingPoints.map { name, point in
            "COUNTER_SAMPLING point=\(name)"
                + " supported=\(device.supportsCounterSampling(point))"
        }
        let sets = device.counterSets ?? []
        lines.append("COUNTER_SET_COUNT=\(sets.count)")
        for set in sets {
            let counters = set.counters.map(\.name).joined(separator: ",")
            let descriptor = MTLCounterSampleBufferDescriptor()
            descriptor.counterSet = set
            descriptor.storageMode = .shared
            descriptor.sampleCount = 2
            do {
                _ = try device.makeCounterSampleBuffer(descriptor: descriptor)
                lines.append(
                    "COUNTER_SET name=\(set.name) counters=\(counters)"
                        + " allocation=pass")
            } catch {
                lines.append(
                    "COUNTER_SET name=\(set.name) counters=\(counters)"
                        + " allocation=fail detail="
                        + "\(soakFieldSafe(String(describing: error)))")
            }
        }
        return lines
    }

    func execute(
        variant: SoakVariant,
        prepared: PreparedShape,
        dispatchCount: Int,
        label: String
    ) throws -> RepeatedTimingSample {
        guard dispatchCount > 0 else {
            throw ProbeFailure.message("dispatch count must be positive")
        }
        let resources = try executionResources(
            variant: variant,
            prepared: prepared)
        let cpuStart = DispatchTime.now().uptimeNanoseconds
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw ProbeFailure.message("failed to create command buffer for \(label)")
        }
        commandBuffer.label = label
        encoder.label = label
        encode(
            encoder: encoder,
            prepared: prepared,
            resources: resources,
            dispatchCount: dispatchCount)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let cpuEnd = DispatchTime.now().uptimeNanoseconds
        try validateCompleted(commandBuffer, label: label)

        return RepeatedTimingSample(
            label: label,
            dispatchCount: dispatchCount,
            gpuStartSeconds: commandBuffer.gpuStartTime,
            gpuEndSeconds: commandBuffer.gpuEndTime,
            kernelStartSeconds: commandBuffer.kernelStartTime,
            kernelEndSeconds: commandBuffer.kernelEndTime,
            cpuSeconds: Double(cpuEnd - cpuStart) * 1e-9)
    }

    func timestampCounterProbe(
        prepared: PreparedShape
    ) throws -> TimestampCounterObservation? {
        guard device.supportsCounterSampling(.atStageBoundary) else {
            return nil
        }
        guard let counterSet = (device.counterSets ?? []).first(where: {
            $0.name == "timestamp"
        }) else {
            return nil
        }

        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = counterSet
        descriptor.storageMode = .shared
        descriptor.sampleCount = 2
        descriptor.label = "mpp-soak-timestamp-counter"
        let sampleBuffer = try device.makeCounterSampleBuffer(descriptor: descriptor)

        let pass = MTLComputePassDescriptor()
        guard let attachment = pass.sampleBufferAttachments[0] else {
            throw ProbeFailure.message(
                "timestamp counter attachment descriptor unavailable")
        }
        attachment.sampleBuffer = sampleBuffer
        attachment.startOfEncoderSampleIndex = 0
        attachment.endOfEncoderSampleIndex = 1

        let resources = try executionResources(
            variant: .candidate,
            prepared: prepared)
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder(descriptor: pass)
        else {
            throw ProbeFailure.message(
                "failed to create timestamp-counter command buffer")
        }
        commandBuffer.label = "mpp-soak-timestamp-counter"
        encoder.label = commandBuffer.label
        encode(
            encoder: encoder,
            prepared: prepared,
            resources: resources,
            dispatchCount: 1)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try validateCompleted(
            commandBuffer,
            label: "mpp-soak-timestamp-counter")

        guard let data = sampleBuffer.resolveCounterRange(0..<2)
        else {
            throw ProbeFailure.message("timestamp counter resolution returned nil")
        }
        let requiredBytes = 2 * MemoryLayout<MTLCounterResultTimestamp>.stride
        guard data.count >= requiredBytes else {
            throw ProbeFailure.message(
                "timestamp counter resolution returned \(data.count) bytes;"
                    + " \(requiredBytes) required")
        }
        let values = data.withUnsafeBytes {
            Array($0.bindMemory(to: MTLCounterResultTimestamp.self).prefix(2))
        }
        let start = values[0].timestamp
        let end = values[1].timestamp
        guard start != UInt64.max, end != UInt64.max, end > start else {
            throw ProbeFailure.message(
                "invalid timestamp counter values start=\(start) end=\(end)")
        }
        return TimestampCounterObservation(
            start: start,
            end: end,
            commandBufferGPUSeconds:
                commandBuffer.gpuEndTime - commandBuffer.gpuStartTime,
            commandBufferKernelSeconds:
                commandBuffer.kernelEndTime - commandBuffer.kernelStartTime)
    }

    private struct ExecutionResources {
        let pipeline: MTLComputePipelineState
        let threadsPerThreadgroup: Int
        let threadgroupCount: Int
        let output: MTLBuffer
    }

    private func executionResources(
        variant: SoakVariant,
        prepared: PreparedShape
    ) throws -> ExecutionResources {
        switch variant {
        case .steel:
            return ExecutionResources(
                pipeline: steelPipeline,
                threadsPerThreadgroup: 128,
                threadgroupCount: try prepared.shape.threadgroupCount(for: .steel),
                output: prepared.steelOutput)
        case .candidate:
            return ExecutionResources(
                pipeline: candidatePipeline,
                threadsPerThreadgroup: candidate.threadsPerThreadgroup,
                threadgroupCount: try prepared.shape.threadgroupCount(
                    for: .mpp(candidate)),
                output: prepared.mppOutput)
        }
    }

    private func encode(
        encoder: MTLComputeCommandEncoder,
        prepared: PreparedShape,
        resources: ExecutionResources,
        dispatchCount: Int
    ) {
        encoder.setComputePipelineState(resources.pipeline)
        encoder.setBuffer(prepared.a, offset: 0, index: 0)
        encoder.setBuffer(prepared.b, offset: 0, index: 1)
        encoder.setBuffer(resources.output, offset: 0, index: 2)
        var parameters = DenseShapeParameters(prepared.shape)
        encoder.setBytes(
            &parameters,
            length: MemoryLayout<DenseShapeParameters>.stride,
            index: 3)
        let threadgroups = MTLSize(
            width: resources.threadgroupCount,
            height: 1,
            depth: 1)
        let threads = MTLSize(
            width: resources.threadsPerThreadgroup,
            height: 1,
            depth: 1)
        for _ in 0..<dispatchCount {
            encoder.dispatchThreadgroups(
                threadgroups,
                threadsPerThreadgroup: threads)
        }
    }

    private func validateCompleted(
        _ commandBuffer: MTLCommandBuffer,
        label: String
    ) throws {
        guard commandBuffer.status == .completed else {
            let detail = commandBuffer.error?.localizedDescription
                ?? "no command-buffer error detail"
            throw ProbeFailure.message(
                "\(label) status=\(commandBuffer.status.rawValue) error=\(detail)")
        }
        guard commandBuffer.gpuStartTime > 0,
              commandBuffer.gpuEndTime > commandBuffer.gpuStartTime
        else {
            throw ProbeFailure.message(
                "\(label) has invalid GPU timestamps"
                    + " start=\(commandBuffer.gpuStartTime)"
                    + " end=\(commandBuffer.gpuEndTime)")
        }
        guard commandBuffer.kernelStartTime > 0,
              commandBuffer.kernelEndTime > commandBuffer.kernelStartTime
        else {
            throw ProbeFailure.message(
                "\(label) has invalid kernel timestamps"
                    + " start=\(commandBuffer.kernelStartTime)"
                    + " end=\(commandBuffer.kernelEndTime)")
        }
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
                    + "\(pipeline.maxTotalThreadsPerThreadgroup) threads;"
                    + " \(threadsPerThreadgroup) required")
        }
    }
}
