import Foundation
import DarkbloomClusterProcess
import DarkbloomClusterRemote
import MLXLMCommon
import ProviderCoreFoundation

/// What a member's pair serving keeps open for the life of its process: the
/// leader's link listener, or the follower's link client and server.
public final class ClusterMemberPairLink: @unchecked Sendable {
    let leader: DistributedInstalledLinkLeader?
    let follower: DistributedMemberLinkFollower?
    init(leader: DistributedInstalledLinkLeader?, follower: DistributedMemberLinkFollower?) {
        self.leader = leader; self.follower = follower
    }
    /// After the loop stopped: fences what the follower serves and waits
    /// (bounded) for its release, then closes the edge.
    public func stop() { follower?.stop(); leader?.stop() }
    /// For the member's start line.
    public var role: String { leader != nil ? "leader (link listener)" : "follower (dials the leader)" }
}

extension ClusterMemberPreparation {
    /// The leader's serving context for its pair's committed starts (S10),
    /// from this Mac's verified setup: the pinned tokenizer (metadata only),
    /// EOS, request profile, first-token allowance and prefix evidence the
    /// installed session uses, and the pair owner over the session's endpoint
    /// and the follower's. `follower` supplies rank 1's endpoint for one start
    /// (the link endpoint, S08). Only the plan's rank 0 serves.
    public func pairServingContext(
        follower: @escaping @Sendable (NativePairMemberServingStart, ClusterOwnerBootstrapRelay?) throws -> any ClusterWorkerEndpoint
    ) async throws -> ClusterPairServingContext {
        let plan = validation.plan, installed = validation.model
        try ClusterMiMoPrivateImagePolicy.requireCoordinatorEligible(plan.capability)
        guard plan.configuration.localRank == 0 else {
            throw ClusterConfigurationError.invalid("Only the plan's rank-0 member serves the pair")
        }
        try requireUnchanged()
        let loaded = try await LocalTokenizerLoader().load(from: installed.directory)
        let tokenizer = try TokenizerHandle.pairServing(loaded, modelType: installed.modelType,
            modelDirectory: installed.directory)
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
            artifactBytes: max(0, Int(validation.manifest.totalSizeBytes)), modelDirectory: installed.directory,
            observabilityFacts: plan.observabilityFacts(membershipEpoch: nil),
            makeOwner: ClusterPairServingContext.pairOwner(profile: profile, chunkTokens: plan.configuration.chunkTokens,
                startupAllowanceNanoseconds: plan.budgets.startupAllowanceNanoseconds, timing: plan.budgets.pairTiming,
                lanes: plan.batchLanes() ?? 1, lanesRetireAlone: plan.lanesRetireAlone(),
                routing: {
                    ClusterRequestRoutingBasis.make(plan: plan, homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                        deadline: DispatchTime.now().uptimeNanoseconds + 15_000_000_000)
                }, follower: follower))
    }

    /// Installs this member's serving of its pair's committed starts (S10)
    /// on a member loop that has its pair installation, before `run()`. Only
    /// a setup saved for coordinator pairing whose follower is reached over
    /// the link control channel serves; any other returns nil. The leader
    /// hosts the link listener and publishes the pair slot; the follower dials
    /// the leader and serves its own owner over the link.
    public func installPairServing(on loop: ProviderLoop, followerEvents: @escaping @Sendable (String) -> Void = { _ in })
        async throws -> ClusterMemberPairLink? {
        let configuration = validation.plan.configuration
        guard configuration.nativeMember != nil, configuration.linkControl != nil else { return nil }
        try requireUnchanged()
        if configuration.localRank == 0 {
            let link = try DistributedInstalledLinkLeader(configuration: configuration)
            do {
                let clusterID = configuration.clusterID
                let context = try await pairServingContext { start, relay in
                    // The follower member dials in when it starts; a start
                    // never waits long on one that is not there.
                    try link.waitForFollower(until: DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
                    return try link.memberEndpoint(start: start, clusterID: clusterID, relay: relay)
                }
                try await loop.installClusterPairServing(context)
            } catch { link.stop(); throw error }
            return .init(leader: link, follower: nil)
        }
        let follower = try DistributedMemberLinkFollower(configuration: configuration) { event in
            switch event {
            case .connected: followerEvents("link connected")
            case .disconnected: followerEvents("link disconnected")
            case .opened: followerEvents("leader opened a session")
            case .refused(let reason): followerEvents("session refused: \(reason)")
            case .fenced(let reason): followerEvents("session fenced: \(reason)")
            case .cleanup: followerEvents("session cleanup observed")
            case .released(let cleanly): followerEvents("session released " + (cleanly ? "cleanly" : "without its owner's proof"))
            }
        }
        try await loop.installClusterPairFollower(follower)
        follower.start()
        return .init(leader: nil, follower: follower)
    }
}
