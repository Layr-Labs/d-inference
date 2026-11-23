// Test-only adapter: the interfaces the new tests call, with the behaviour of the code before the change
// (no admitted-token bound, no row reference, no switch).
import MLXLMCommon
@testable import ProviderCore

extension EngineV2Factory {
    static func glm5NextActivatableRows(
        maximumRows: Int, scratch: (Int) throws -> GLM5NextStepScratch?, tokenBytes: Int, context: Int,
        capacityBytes: Int, maximumScratchBytes: Int, boundedByAdmission: Bool
    ) rethrows -> Int {
        var rows = maximumRows
        while rows > 1 {
            guard let price = try scratch(rows) else { return rows }
            if glm5NextActivationAdmits(price, rows: rows, context: context, capacityBytes: capacityBytes,
                tokenBytes: tokenBytes, maximumScratchBytes: maximumScratchBytes,
                watermarkFraction: glm5NextAdmissionWatermarkFraction) { break }
            rows -= 1
        }
        return rows
    }

    static func glm5NextServingRows(
        maximumRows: Int, scratch: (Int) throws -> GLM5NextStepScratch?, tokenBytes: Int, context: Int,
        capacityBytes: Int, referenceBytes: Int, maximumBufferBytes: Int, boundedByAdmission: Bool
    ) rethrows -> Int {
        try glm5NextActivatableRows(maximumRows: maximumRows, scratch: scratch, tokenBytes: tokenBytes,
            context: context, capacityBytes: capacityBytes,
            maximumScratchBytes: min(capacityBytes, maximumBufferBytes), boundedByAdmission: false)
    }

    static func glm5NextActivationAdmits(
        _ scratch: GLM5NextStepScratch, rows: Int, context: Int, capacityBytes: Int,
        tokenBytes: Int, maximumScratchBytes: Int, watermarkFraction: Double, admittedBytesPerContextToken: Int?
    ) -> Bool {
        glm5NextActivationAdmits(scratch, rows: rows, context: context, capacityBytes: capacityBytes,
            tokenBytes: tokenBytes, maximumScratchBytes: maximumScratchBytes, watermarkFraction: watermarkFraction)
    }
}

extension GLM5NextGPULimitKVBudget {
    static let environmentName = "DARKBLOOM_GLM_GPU_LIMIT_KV"
    static func enabled(environment: [String: String] = [:]) -> Bool { true }
    static func budgetBytes(
        _ budget: UInt64, modelTypes: [String?], retainedGLMBytes: UInt64, residentWeightBytes: UInt64,
        activationReserveBytes: UInt64, limit: @autoclosure () -> GPULimit, enabled: Bool
    ) -> UInt64 {
        budgetBytes(budget, modelTypes: modelTypes, retainedGLMBytes: retainedGLMBytes,
            residentWeightBytes: residentWeightBytes, activationReserveBytes: activationReserveBytes, limit: limit())
    }
}

extension EngineV2 {
    /// Before the change the engine took no admitted-token charge.
    var glm5NextAdmittedBytesPerContextToken: Int? { nil }
}
