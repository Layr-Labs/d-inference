import Foundation
import MLX

/// Private opt-in authority derived from the actual resident reservation. This
/// consumes only its named convolution allowance; it grants no workspace credit.
struct QwenConvolutionCompaction {
    let rows: QwenConvolutionCompactionRows
    private let rank: Int
    private let configurationSHA256: String
    private let artifactSHA256: String
    private let planSHA256: String
    private let stageSHA256: String
    private let requestFingerprint: String

    init(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
         rank: Int, request: QwenLayerStageGenerationRequest,
         allowance: QwenResidentRequestAllowance) throws {
        guard profile.model == .qwen38TwentySevenB, (0...1).contains(rank),
              plan.stages.count == 2, plan.stages[0].sourceRange == 0..<16,
              plan.stages[1].sourceRange == 16..<64,
              plan.originalConfiguration == profile.configuration,
              request.profile.hiddenSize == profile.geometry.hiddenSize,
              request.profile.vocabularySize == profile.vocabularySize,
              request.profile.activationDType == "bfloat16", request.stopTokenIDs.isEmpty else {
            throw ProbeError("Convolution compaction requires the registered plain 27B 16/48 reservation")
        }
        let actual = try QwenResidentRequestAllowance.derive(profile: profile, plan: plan, rank: rank,
            maximumTokens: request.maximumTokens, chunkSize: min(request.chunkSize, request.promptCount),
            bound: QwenResidentResourceEnvironment.allocationBound)
        guard actual.stateBytes == allowance.stateBytes, actual.fusionBytes == allowance.fusionBytes,
              actual.reservedBytes == allowance.reservedBytes else {
            throw ProbeError("Convolution compaction differs from the charged request allowance")
        }
        rows = try .init(rank: rank, bound: QwenResidentResourceEnvironment.allocationBound)
        guard rows.namedConvolutionBytes <= actual.stateBytes else {
            throw ProbeError("Convolution copy allowance is absent from the admitted state ledger")
        }
        self.rank = rank; configurationSHA256 = profile.configurationSHA256
        artifactSHA256 = profile.artifactAggregateSHA256; planSHA256 = plan.fingerprint
        stageSHA256 = plan.stages[rank].fingerprint; requestFingerprint = request.fingerprint
    }

    func require(stage: LoadedQwenLayerStage, plan: QwenLayerStagePlan,
                 request: QwenLayerStageAdmittedRequest) throws {
        guard case .generation(let generation) = request,
              generation.fingerprint == requestFingerprint, stage.stageIndex == rank,
              stage.plan.fingerprint == planSHA256, plan.fingerprint == planSHA256,
              stage.receipt.stagePlanSHA256 == stageSHA256,
              stage.receipt.sourceConfigurationSHA256 == configurationSHA256,
              stage.receipt.verifiedAggregateSHA256 == artifactSHA256 else {
            throw ProbeError("Convolution compaction does not belong to this loaded request/stage")
        }
    }
}
