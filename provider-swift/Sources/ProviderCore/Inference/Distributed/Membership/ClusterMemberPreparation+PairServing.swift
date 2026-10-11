import Foundation
import DarkbloomClusterProcess
import MLXLMCommon
import ProviderCoreFoundation

extension ClusterMemberPreparation {
    /// The leader's serving context for its pair's committed starts (S10),
    /// from this Mac's verified setup: the pinned tokenizer (metadata only),
    /// EOS, request profile, first-token allowance and prefix evidence the
    /// installed session uses, and the pair owner over the session's endpoint
    /// and the follower's. `follower` supplies rank 1's endpoint for one start
    /// (the link endpoint, S08). Only the plan's rank 0 serves.
    public func pairServingContext(
        follower: @escaping @Sendable (NativePairMemberServingStart) throws -> any ClusterWorkerEndpoint
    ) async throws -> ClusterPairServingContext {
        let plan = validation.plan, installed = validation.model
        guard plan.configuration.localRank == 0 else {
            throw ClusterConfigurationError.invalid("Only the plan's rank-0 member serves the pair")
        }
        try requireUnchanged()
        let tokenizer = TokenizerHandle(try await LocalTokenizerLoader().load(from: installed.directory))
        try requireUnchanged()
        let wire = plan.capability.profile
        let profile = try DistributedResidentExecutionProfile(id: wire.id, vocabularySize: wire.vocabularySize,
            maxPromptTokens: wire.maximumPromptTokens, maxOutputTokens: wire.maximumOutputTokens,
            maxContextTokens: wire.maximumContextTokens, requestTimeout: .seconds(plan.configuration.requestTimeoutSeconds))
        let budget = try DistributedFirstTokenBudgetPolicy(baseMilliseconds: plan.budgets.firstTokenBaseMilliseconds,
            millisecondsPerInputToken: plan.budgets.firstTokenMillisecondsPerPromptToken)
        try budget.validate(maximumPromptTokens: profile.maxPromptTokens)
        let evidence = (try? PromptContractIdentity.compute(modelDirectory: installed.directory)).flatMap {
            ResidentPrefixCacheEvidence(modelId: installed.publicModelID,
                modelAggregateHash: plan.identity(epoch: UUID()).artifactSHA256, promptContractID: $0)
        }
        return .init(publicModelID: installed.publicModelID, modelType: installed.modelType, tokenizer: tokenizer,
            eosTokenIDs: try installed.stopTokenIDs(tokenizerEOS: tokenizer.inner.eosTokenId), profile: profile,
            firstTokenBudgetPolicy: budget, residentPrefixEvidence: evidence,
            artifactBytes: max(0, Int(validation.manifest.totalSizeBytes)),
            makeOwner: ClusterPairServingContext.pairOwner(profile: profile, chunkTokens: plan.configuration.chunkTokens,
                startupAllowanceNanoseconds: plan.budgets.startupAllowanceNanoseconds, timing: plan.budgets.pairTiming,
                follower: follower))
    }
}
