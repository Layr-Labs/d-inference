import Foundation
import MLXLLM
import MLXLMCommon
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
