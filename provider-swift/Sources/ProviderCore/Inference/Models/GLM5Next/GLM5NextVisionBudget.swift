import Foundation
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM

extension VisionTowerBudget {
    /// GLM tiles attention queries and attends within one temporal pair. Price
    /// that actual tile, plus linear tower buffers, rather than Qwen's full N²
    /// mask. This is an additional per-buffer check, not an activation/KV grant.
    static func glm5FrameLimits(
        grid: THW, configuration: GLM5NextVisionConfiguration,
        limits: Limits
    ) throws -> GLM5NextVisionLimits {
        guard grid.t == 1, grid.h > 0, grid.w > 0, grid.h.isMultiple(of: 2),
            grid.w.isMultiple(of: 2),
            let patches = patchCount(grid), patches > 0, limits.maxBufferBytes > 0
        else {
            throw EngineV2VisionPrefillError.invalidVisionGrid(mediaIndex: 0)
        }
        let maximumPatches = min(32_000, limits.operatorMaxPatches ?? 32_000)
        guard patches <= maximumPatches else {
            throw EngineV2VisionPrefillError.towerBudgetExceeded(
                "GLM frame exceeds native/operator patch limit")
        }
        func bytes(_ dimensions: [Int]) throws -> Int {
            var value = 4  // Conservative FP32 intermediates, including prepared pixels.
            for dimension in dimensions {
                let next = value.multipliedReportingOverflow(by: dimension)
                guard dimension > 0, !next.overflow else {
                    throw EngineV2VisionPrefillError.towerBudgetExceeded("GLM frame byte overflow")
                }
                value = next.partialValue
            }
            return value
        }
        let c = configuration
        let scoreElements = min(32_000_000, limits.maxBufferBytes / 4)
        guard c.numHeads > 0, scoreElements / c.numHeads / patches > 0 else {
            throw EngineV2VisionPrefillError.towerBudgetExceeded(
                "GLM attention query tile cannot fit")
        }
        let query = min(128, min(patches, scoreElements / c.numHeads / patches))
        let buffers = try [
            bytes([patches, c.inChannels, c.temporalPatchSize, c.patchSize, c.patchSize]),
            bytes([patches, c.hiddenSize, 3]),
            bytes([patches, c.intermediateSize, 2]),
            bytes([patches, c.hiddenSize / c.numHeads]),
            bytes([patches / 4, c.outHiddenSize]),
            bytes([c.numHeads, query, patches]),
        ]
        guard buffers.allSatisfy({ $0 <= limits.maxBufferBytes }) else {
            throw EngineV2VisionPrefillError.towerBudgetExceeded(
                "GLM tower buffer exceeds Metal limit")
        }
        return .init(
            maximumPatches: maximumPatches, maximumFramePatches: maximumPatches,
            maximumQueryTokens: query, maximumScoreElements: scoreElements)
    }
}

/// Unified-memory reservation for one GLM media preparation, charged by the
/// scheduler's `VisionMemoryGate` before decode and released after the tower.
enum GLM5NextVisionBudget {
    /// Native tower limit on one temporal pair (`GLM5NextVisionLimits`).
    static let maximumFramePatches = 32_000

    struct Reservation: Equatable {
        /// Prepared pixels plus the tower working set of the largest frame.
        let bytes: UInt64
        /// Prompt text plus every image at the processor's token cap, plus output.
        let kvTokens: Int
    }

    /// Conservative FP32 bytes live while the tower runs one frame of
    /// `patches` patches: input, residual stream, QKV and its head-major
    /// copies, one score plus one probability tile, attention output, the
    /// SwiGLU MLP and the merger. Frames run sequentially, so only one counts.
    static func towerWorkingSetBytes(
        configuration c: GLM5NextVisionConfiguration, patches: Int = maximumFramePatches,
        queryTile: Int = 128
    ) -> UInt64 {
        let n = UInt64(max(0, patches))
        let merged = n / 4
        let elements: [UInt64] = [
            n * UInt64(c.inChannels * c.temporalPatchSize * c.patchSize * c.patchSize),
            2 * n * UInt64(c.hiddenSize),
            6 * n * UInt64(c.hiddenSize),
            2 * UInt64(c.numHeads) * UInt64(min(queryTile, patches)) * n,
            2 * n * UInt64(c.hiddenSize),
            3 * n * UInt64(c.intermediateSize),
            3 * merged * UInt64(c.projectionIntermediateSize),
            2 * merged * UInt64(c.outHiddenSize),
        ]
        return elements.reduce(0) { $0.addingReportingOverflow($1 * 4).partialValue }
    }

    static func mediaReservation(
        container: ModelContainer, request: OpenAIChatCompletionRequest,
        defaultMaxTokens: Int, contextLength: Int
    ) async -> Reservation {
        let loaded = await container.perform { context
            -> (vision: GLM5NextVisionConfiguration, processor: GLM5NextProcessorConfiguration)? in
            guard let root = context.model as? GLM5NextModel,
                let processor = context.processor as? GLM5NextProcessor
            else { return nil }
            return (root.configuration.visionConfig, processor.configuration)
        }
        let base = MediaIngest.projectedKVTokens(
            request, defaultMaxTokens: defaultMaxTokens, contextLength: contextLength)
        guard let loaded else { return .init(bytes: 0, kvTokens: base) }
        return reservation(
            request: request, vision: loaded.vision, processor: loaded.processor,
            defaultMaxTokens: defaultMaxTokens, contextLength: contextLength)
    }

    static func reservation(
        request: OpenAIChatCompletionRequest, vision: GLM5NextVisionConfiguration,
        processor: GLM5NextProcessorConfiguration, defaultMaxTokens: Int, contextLength: Int
    ) -> Reservation {
        let images = request.messages.reduce(0) { count, message in
            guard case .parts(let parts) = message.content else { return count }
            return count + parts.filter { if case .imageURL = $0 { true } else { false } }.count
        }
        // `projectedKVTokens` allots `visionTokensPerImage` per image; a GLM
        // image renders begin/end tokens around up to `imageMaximumTokens`.
        let extraPerImage = max(0, processor.imageMaximumTokens + 2 - MediaIngest.visionTokensPerImage)
        let base = MediaIngest.projectedKVTokens(
            request, defaultMaxTokens: defaultMaxTokens, contextLength: contextLength)
        let (extra, extraOverflow) = images.multipliedReportingOverflow(by: extraPerImage)
        var (tokens, overflow) = base.addingReportingOverflow(extra)
        if extraOverflow || overflow { tokens = .max }
        if contextLength > 0 {
            let output = max(0, MediaIngest.resolveMaxOutputTokens(
                for: request, defaultMaxTokens: defaultMaxTokens))
            let (ceiling, ceilingOverflow) = contextLength.addingReportingOverflow(output)
            if !ceilingOverflow { tokens = min(tokens, ceiling) }
        }
        let (bytes, bytesOverflow) = UInt64(processor.maximumPreparedBytes)
            .addingReportingOverflow(towerWorkingSetBytes(configuration: vision))
        return .init(bytes: bytesOverflow ? .max : bytes, kvTokens: tokens)
    }
}
