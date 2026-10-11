import Foundation
import DarkbloomClusterProcess

// The leader member serving the pair's committed starts (S10).
//
// The coordinator commits a start; each member's session launches its own
// owner (`NativePairMemberSession`). On the leader, this loop is the
// session's serving host: it builds the pair's execution owner from the
// session's endpoint and the follower's, and publishes it as the pair slot
// (`ProviderLoop+ClusterPairSlot`), so the coordinator sees one loaded slot and
// a member that is not draining and routes `inference_request` here. When the
// session ends, or the pair loses a rank, the slot retires; the session then
// waits for its owner's release and only then sends its receipt.

/// What the leader member needs to serve its pair's committed starts: the
/// pair's one model as the installed setup describes it, and how to build the
/// pair's execution owner for one start.
public struct ClusterPairServingContext: Sendable {
    public let publicModelID: String
    public let modelType: String?
    public let tokenizer: TokenizerHandle
    public let eosTokenIDs: Set<Int>
    public let profile: DistributedResidentExecutionProfile
    public let firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy?
    public let residentPrefixEvidence: ResidentPrefixCacheEvidence?
    public let artifactBytes: Int
    /// Builds the pair's execution owner for one committed start from the
    /// session's own endpoint. Blocking: it waits for both ranks' readiness.
    /// Throws when the pair cannot form; the session keeps its endpoint's
    /// cleanup either way.
    public let makeOwner: @Sendable (NativePairMemberServingStart) throws -> any DistributedResidentExecutionOwner

    public init(publicModelID: String, modelType: String?, tokenizer: TokenizerHandle, eosTokenIDs: Set<Int>,
                profile: DistributedResidentExecutionProfile, firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy? = nil,
                residentPrefixEvidence: ResidentPrefixCacheEvidence? = nil, artifactBytes: Int = 0,
                makeOwner: @escaping @Sendable (NativePairMemberServingStart) throws -> any DistributedResidentExecutionOwner) {
        self.publicModelID = publicModelID; self.modelType = modelType; self.tokenizer = tokenizer
        self.eosTokenIDs = eosTokenIDs; self.profile = profile; self.firstTokenBudgetPolicy = firstTokenBudgetPolicy
        self.residentPrefixEvidence = residentPrefixEvidence; self.artifactBytes = artifactBytes; self.makeOwner = makeOwner
    }

    /// The production owner: `ClusterWorkerPair` over the session's endpoint
    /// (rank 0) and the follower's (`follower`: the link endpoint, S08), with
    /// keep-warm on, under the pipe owner the installed session uses.
    public static func pairOwner(
        profile: DistributedResidentExecutionProfile, chunkTokens: Int, startupAllowanceNanoseconds: UInt64,
        timing: ClusterWorkerPairTiming = .standard,
        follower: @escaping @Sendable (NativePairMemberServingStart) throws -> any ClusterWorkerEndpoint
    ) -> @Sendable (NativePairMemberServingStart) throws -> any DistributedResidentExecutionOwner {
        { start in
            guard start.rank == 0 else { throw ClusterPairSlotError.notServing("only the leader builds the pair") }
            let peer = try follower(start)
            // A failed wait for readiness already asked both ranks to clean up.
            let pair = try ClusterWorkerPair(workers: [start.endpoint, peer],
                startupDeadline: DispatchTime.now().uptimeNanoseconds + startupAllowanceNanoseconds,
                timing: timing, keepWarm: .standard)
            do { return try DistributedPipeExecutionOwner(pair: pair, profile: profile, chunkSize: chunkTokens) }
            catch { Task { await pair.shutdown() }; throw error }
        }
    }
}

extension ProviderLoop: NativePairMemberServingHost {
    /// Installs the leader's serving context before `run()`, after the
    /// member's pair installation. Only a rank-0 installation serves.
    public func installClusterPairServing(_ context: ClusterPairServingContext) throws {
        guard isClusterMember, coordinatorClient == nil, clusterPairServing == nil,
              let control = nativePairMemberControl, control.installation.rank == 0,
              control.installation.policy.model == context.publicModelID,
              loopConfig.models.contains(where: { $0.id == context.publicModelID }) else {
            throw ClusterPairSlotError.notServing("no leader pair installation for this model")
        }
        clusterPairServing = context
        control.servingHost = self
    }

    public func serveCommittedStart(_ start: NativePairMemberServingStart) async throws {
        guard let context = clusterPairServing, start.rank == 0 else {
            throw ClusterPairSlotError.notServing("this member serves no committed start")
        }
        guard clusterPairServingEpoch == nil else { throw ClusterPairSlotError.notServing("a committed start is already served") }
        let epoch = start.membershipEpoch
        clusterPairServingEpoch = epoch; clusterPairServingStopped = false; clusterPairServingForming = true
        defer { clusterPairServingForming = false }
        let owner: any DistributedResidentExecutionOwner
        do { owner = try await Task.detached { try context.makeOwner(start) }.value }
        catch { endClusterPairServing(epoch); throw error }
        // A stop that arrived while the pair formed wins: nothing publishes.
        guard clusterPairServingEpoch == epoch, !clusterPairServingStopped else {
            await owner.shutdown(); endClusterPairServing(epoch)
            throw ClusterPairSlotError.notServing("the committed start ended while the pair formed")
        }
        let wire = start.identity
        let identity = DistributedResidentIdentity(membershipEpoch: epoch, modelID: wire.modelID,
            artifactSHA256: wire.artifactSHA256, configurationSHA256: wire.configurationSHA256,
            peers: wire.peers.map { .init(id: $0.id, buildSHA256: $0.buildSHA256) })
        let specification = ClusterPairSlotSpecification(publicModelID: context.publicModelID,
            modelType: context.modelType, tokenizer: context.tokenizer, eosTokenIDs: context.eosTokenIDs,
            expectedIdentity: identity, profile: context.profile, firstTokenBudgetPolicy: context.firstTokenBudgetPolicy,
            residentPrefixEvidence: context.residentPrefixEvidence, artifactBytes: context.artifactBytes)
        do { try await publishClusterPairSlot(specification, owner: owner) }
        catch { await owner.shutdown(); endClusterPairServing(epoch); throw error }
        clusterPairServingForming = false
        // A stop during the publication hops retires what was just published.
        if clusterPairServingStopped { await stopServingCommittedStart(epoch: epoch) }
    }

    public func stopServingCommittedStart(epoch: UUID) async {
        guard clusterPairServingEpoch == epoch else { return }
        clusterPairServingStopped = true
        // A serve still forming the pair sees the stop and ends it itself.
        guard !clusterPairServingForming else { return }
        if let handle = clusterPairSlot, handle.membershipEpoch == epoch {
            await retireClusterPairSlot(handle.id, reason: "committed start ended")
        }
        endClusterPairServing(epoch)
    }

    /// Clears the served epoch, once, for this epoch only.
    func endClusterPairServing(_ epoch: UUID) {
        guard clusterPairServingEpoch == epoch else { return }
        clusterPairServingEpoch = nil; clusterPairServingStopped = false; clusterPairServingForming = false
    }
}
