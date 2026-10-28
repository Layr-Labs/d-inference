import Darwin
import Foundation

/// One closed experimental scope; no caller-provided budget or model alias.
enum QwenResidentPhaseScope {
    static func require(_ admission: QwenResidentAdmission) throws {
        guard admission.configuration.nativeValidationModel == .qwen38TwentySevenB,
              admission.configuration.stageCut == 16, admission.plan.stages.count == 2,
              admission.plan.stages[0].sourceRange == 0..<16,
              admission.plan.stages[1].sourceRange == 16..<64,
              admission.profile.maximumPromptTokens == 8192,
              admission.profile.maximumChunkTokens == 512,
              admission.profile.maximumOutputTokens == 128,
              admission.profile.maximumContextTokens == 8320 else {
            throw ProbeError("Phase observation requires the admitted registered 27B 16/48 profile")
        }
    }

    static func require(_ request: QwenLayerStageGenerationRequest) throws {
        guard request.promptCount == 8192, request.chunkSize == 256,
              request.outputCount == 128, request.maximumTokens == 8320,
              request.stopTokenIDs.isEmpty else {
            throw ProbeError("Phase observation requires P8192/C256/O128 and no stop tokens")
        }
    }

    static func budget() throws -> QwenGenerationPhaseBudget {
        try .derive(promptCount: 8192, chunkSize: 256, hostAllocationBound: QwenGenerationPhaseHostAllocation.bound)
    }

    static func total(base: Int, prefill: QwenGenerationPrefillAllowance?,
                      budget: QwenGenerationPhaseBudget) throws -> Int {
        try QwenLongPrefillCheckedBytes.sum([base, prefill?.reservedBytes ?? 0,
            budget.requiredHostReservationBytes])
    }
}
