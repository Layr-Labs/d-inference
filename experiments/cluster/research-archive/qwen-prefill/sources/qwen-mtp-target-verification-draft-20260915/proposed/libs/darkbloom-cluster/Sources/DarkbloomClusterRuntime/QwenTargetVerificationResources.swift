import MLX

/// Rederives the base reservation from actual loaded source/Plan/request/rank;
/// a caller-provided byte count is not accepted as a permit.
final class QwenTargetVerificationResources {
    let budget: QwenTargetVerificationBudget
    private let base: QwenResidentRequestAllowance

    init(loaded: LoadedQwenLayerStage, profile: QwenRegisteredDenseModelProfile,
         request: QwenTargetVerificationRequest) throws {
        let plan = loaded.plan, rank = loaded.stageIndex, r = request.agreement.request
        guard (0...1).contains(rank), plan.stages.count == 2,
              profile.configuration == plan.originalConfiguration,
              profile.configurationSHA256 == loaded.receipt.sourceConfigurationSHA256,
              profile.artifactAggregateSHA256 == loaded.receipt.verifiedAggregateSHA256,
              loaded.receipt.planSHA256 == plan.fingerprint,
              loaded.receipt.stagePlanSHA256 == plan.stages[rank].fingerprint,
              profile.vocabularySize == r.profile.vocabularySize,
              profile.geometry.hiddenSize == r.profile.hiddenSize,
              profile.requiredNativeDType == r.profile.activationDType,
              profile.requiredNativeDType == String(describing: loaded.activationDType),
              loaded.receipt.bf16ConversionEnabled == profile.requiredBF16ConversionPolicy,
              try profile.makePlanningPlan(stageCut: plan.stages[0].sourceRange.upperBound).fingerprint == plan.fingerprint else {
            throw ProbeError("Target verification profile does not describe the loaded source and cut")
        }
        base = try .derive(profile: profile, plan: plan, rank: rank, maximumTokens: r.maximumTokens,
            chunkSize: min(r.chunkSize, r.promptCount), bound: QwenResidentResourceEnvironment.allocationBound)
        budget = try .derive(hiddenSize: r.profile.hiddenSize, vocabularySize: r.profile.vocabularySize,
            dtypeBytes: loaded.activationDType.size, rank: rank, steps: request.maximumSteps,
            bound: QwenResidentResourceEnvironment.allocationBound)
    }

    /// Mandatory owner callback must retain/charge this increment along with
    /// its existing assistant and transport reservations until outputs release.
    /// It is called before construction and throughout native work; no default.
    func requireLive(ownerCheck: (QwenTargetVerificationBudget) throws -> Void) throws {
        try base.requireLive(additionalNativeBytes: budget.additionalNativeBytes,
                             additionalHostBytes: budget.additionalHostBytes)
        try ownerCheck(budget)
    }
}
