import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterRemote

/// Installed choices and exact capability values. There is deliberately no
/// Ready value or capacity field until both native children report readiness.
struct DistributedInstalledPlan: Sendable {
    let configuration: ClusterConfiguration
    let capability: ClusterRuntimeCapability
    let partition: ClusterRuntimePartition
    let paths: ClusterUserPaths
    /// The owner-side time budgets, derived from this setup (its request
    /// deadline, which the planner derived from the chosen placement's
    /// predicted speed, and its stage shares) and, once the manifest is
    /// verified, the artifact's size (`withArtifactBytes`); see
    /// `DistributedInstalledTimeBudgets.derived`.
    private(set) var budgets: DistributedInstalledTimeBudgets
    /// How each budget was derived, in plain words.
    private(set) var budgetBasis: [String]
    /// The owner's serving of the selected model (owner, 2026-10-14 08:45):
    /// refused only when no cluster stage adapter runs it. Its public grant,
    /// if any, is what the records qualify for public traffic.
    let serving: ClusterPairOwnerServing
    /// What the selected model's adapter adds to a rank's environment; see
    /// `adapterArithmeticEnvironment`.
    let adapterEnvironment: [String: String]

    /// The adapters this path starts workers for, each with what its
    /// arithmetic policy requires of a rank's environment beyond the three
    /// values every rank is given (the pair driver's own values for the same
    /// models, `QualificationRequest.registeredModels`). An adapter with no
    /// entry has not served on this path and is refused. A rank checks its
    /// environment against its own policy before it loads, so an entry here
    /// can stop a rank; it cannot change what the rank computes.
    static let adapterArithmeticEnvironment: [ClusterRuntimeAdapter: [String: String]] = [
        .qwen35Dense: [:],
        .qwen35RoutedExperts: ["MLX_GATHER_QMM_EXPERT_SLICES": "trust"],
        .qwen35PrismHadamard: ["DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC": "1", "DARKBLOOM_BONSAI_F16_CONSTANT_CACHE": "1"],
        .nemotronH: [:],
        // MiMo's contract is the product's defaults with no `DARKBLOOM_MIMO_*`
        // switch (`MiMoArithmeticEnvironment`): nothing beyond the three values.
        .mimoV26LayerStage: [:],
        .mimoV26ImageCandidate: [:],
        // GPT-OSS and Gemma 4: the pair driver's own values for the same
        // adapters (`QualificationRequest.registeredModels`), which their
        // cross-cable checks ran under.
        .gptossLayerStage: [:],
        .gemma4LayerStage: ["MLX_GATHER_QMM_EXPERT_SLICES": "trust", "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT": "1"],
        // GLM-5.3-Flash: the pair driver's own (empty) values its cross-cable check ran under.
        .glm5NextLayerStage: [:],
    ]

    init(saved: ClusterConfigurationStore.Saved, paths: ClusterUserPaths) throws {
        configuration = saved.configuration; capability = saved.capability; self.paths = paths
        // No plan exists for a model no cluster stage adapter runs, so nothing
        // below this point (owner, session, member registration) can start
        // one. Records never refuse the owner's serving; the public grant
        // rests only on records of the installed artifact.
        let observedServing = try ClusterPairServingGrants.ownerServing(runtimeModelID: capability.runtimeModelID,
            publicModelID: configuration.publicModelID, artifactSHA256: capability.artifactSHA256)
        // Text qualifications never become an image candidate's public grant.
        serving = !capability.hasPrivateImages ? observedServing : .init(runtimeModelID:capability.runtimeModelID,
            publicGrant:nil,records:observedServing.records)
        partition = try capability.selection(planSHA256: configuration.selectedPlanSHA256)
        (budgets, budgetBasis) = Self.budgets(configuration: configuration, capability: capability, partition: partition, artifactBytes: nil)
        try capability.requireSupport(for: configuration.selectedPrefillSchedule)
        try ClusterGenerationSelection.requireSupport(for: configuration.selectedGenerationMode, peers: configuration.peers, capability: capability)
        // The record's adapter must register this model, name its one
        // arithmetic policy, and be one this path gives a rank environment.
        let registered = saved.capability.runtimeModelID
        guard let adapter = ClusterRuntimeAdapter(rawValue: capability.adapterID),
              adapter.registeredProfiles.contains(where: { $0.runtimeModelID == registered }),
              capability.arithmeticPolicyID == adapter.arithmeticPolicyID,
              let environment = Self.adapterArithmeticEnvironment[adapter],
              capability.stateSemantics == "requestOwnedKVAndRecurrent",
              capability.schedulingPolicy == "serial", capability.selectionPolicy == "greedy",
              configuration.peers.allSatisfy({ $0.jacclDevice.utf8.count <= 63 }) else {
            throw ClusterConfigurationError.invalid("Installed worker policy or device geometry differs")
        }
        adapterEnvironment = environment
    }

    /// The budgets of a setup: see `DistributedInstalledTimeBudgets.derived`.
    static func budgets(configuration: ClusterConfiguration, capability: ClusterRuntimeCapability, partition: ClusterRuntimePartition,
                        artifactBytes: Int64?) -> (DistributedInstalledTimeBudgets, [String]) {
        let layers = max(1, partition.stages.map(\.sourceLayerEnd).max() ?? 1)
        let largest = partition.stages.map { $0.sourceLayerEnd - $0.sourceLayerStart }.max() ?? layers
        let derived = DistributedInstalledTimeBudgets.derived(requestTimeoutSeconds: configuration.requestTimeoutSeconds,
            maximumPromptTokens: capability.profile.maximumPromptTokens, artifactBytes: artifactBytes,
            largestStageShare: Double(largest) / Double(layers), lastRankLoadsEverything: configuration.selectedGenerationMode.isPhaseSplit)
        return (derived.budgets, derived.basis)
    }

    /// The same plan with its budgets derived from the verified manifest's
    /// artifact size.
    func withArtifactBytes(_ bytes: Int64) -> Self {
        var value = self
        (value.budgets, value.budgetBasis) = Self.budgets(configuration: configuration, capability: capability, partition: partition,
                                                          artifactBytes: bytes)
        return value
    }

    /// This Mac's rank, with this Mac's own chip class
    /// (`ClusterChipClass.local()` on a real Mac). Each Mac checks the rank
    /// it runs, right before it serves or launches it: any Apple silicon runs
    /// any rank of any mode the model's stage adapter has (records never
    /// refuse the owner's serving), and when the mode family has a diverged
    /// record this rank must not be a rank-shape that diverged (its class at
    /// its rank, the placement's cuts from the selected Plan).
    /// A capability record, a saved setup or a peer never supplies the class.
    func requireLocalRankGranted(chipClass: ClusterChipClass?) throws {
        try ClusterPairServingGrants.requireRank(configuration.localRank, of: configuration.peers.count,
            chipClass: chipClass, runtimeModelID: capability.runtimeModelID, publicModelID: configuration.publicModelID,
            artifactSHA256: capability.artifactSHA256, cuts: partition.stages.dropLast().map(\.sourceLayerEnd), mode: configuration.selectedGenerationMode)
    }

    /// How this build's native ranks find each other; see the type.
    var bootstrap: DistributedInstalledBootstrap { .installed }
    /// The collective progress limit every native rank is started with. A rank
    /// whose peer stops answering fails by itself after this long.
    static let collectiveProgressLimitMilliseconds = 60_000

    var localPeer: ClusterConfiguration.Peer { configuration.peers[configuration.localRank] }
    var configurationURL: URL { URL(fileURLWithPath: localPeer.modelDirectory).appendingPathComponent("config.json") }
    var manifestURL: URL { URL(fileURLWithPath: localPeer.modelDirectory).appendingPathComponent("manifest.json") }

    func identity(epoch: UUID) -> ClusterWorkerIdentity {
        .init(membershipEpoch: epoch, modelID: capability.runtimeModelID,
            artifactSHA256: capability.artifactSHA256, configurationSHA256: capability.configurationSHA256,
            peers: configuration.peers.map { .init(id: $0.id, buildSHA256: $0.runtimeBinarySHA256) })
    }

    func binding(epoch: UUID, lease: UUID, incarnation: UUID) throws -> ClusterOwnerBinding {
        try .init(clusterID: configuration.clusterID, ownerIncarnation: incarnation, leaseID: lease,
            identity: identity(epoch: epoch), profile: capability.profile, rank: configuration.localRank,
            executionPlanSHA256: partition.planSHA256)
    }

    func matrix() throws -> Data {
        let names = configuration.peers.map(\.jacclDevice)
        let rows: [[Any]] = [[NSNull(), names[0]], [names[1], NSNull()]]
        var result = try JSONSerialization.data(withJSONObject: rows,
            options: [.sortedKeys, .withoutEscapingSlashes])
        result.append(10)
        guard result.count <= 4096 else { throw ClusterConfigurationError.invalid("Installed matrix exceeds its bound") }
        return result
    }

    func nativeEnvironment(matrix: URL,
                           ownerEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = baseNativeEnvironment(matrix: matrix)
        let prefixCacheOff = prefixCacheOff(ownerEnvironment)
        if prefixCacheOff { environment[Self.prefixCacheSwitch] = "off" }
        // The prefix cache's SSD tier (on with the cache; see the type). Its
        // directory and budgets only: the key goes on the worker's input
        // (`nativePrefixSSDKey`), never into this environment.
        environment.merge(DistributedInstalledPrefixSSD.environment(home: paths.homeDirectory,
            deviceDirectory: paths.deviceDirectory, ownerEnvironment: ownerEnvironment,
            prefixCacheOff: prefixCacheOff, stopMarginNanoseconds: budgets.stopMarginNanoseconds)) { current, _ in current }
        // Continuous batching (pipeline mode only): both owners must give their
        // workers the same lane count (the workers' load agreement refuses a
        // mismatch). A setup in a phase-split mode keeps one request at a time.
        if let lanes = batchLanes(ownerEnvironment), lanes > 1 {
            environment[Self.batchLanesSwitch] = String(lanes)
            if let adapter = ClusterRuntimeAdapter(rawValue: capability.adapterID), Self.contiguousLaneAdapters.contains(adapter) {
                environment[Self.kvBackendSwitch] = "contiguous"
            }
        }
        // Diagnosis only: the stages' KV storage (paged unless contiguous is named).
        if let value = ownerEnvironment[Self.kvBackendSwitch]?.lowercased(), ["paged", "contiguous"].contains(value) {
            environment[Self.kvBackendSwitch] = value
        }
        // The owner's rank-environment guards (Metal command-buffer bounds),
        // each yielding to a value the operator pinned in this owner's own
        // environment.
        return ClusterWorkerEnvironmentGuards.apply(to: environment, ownerEnvironment: ownerEnvironment)
    }
    /// The key of the native rank's prefix-SSD tier, which the owner sends as
    /// a bound line of the worker's input (`--prefix-ssd-key`); nil when the
    /// tier is off (the prefix cache off, the product's gate, or the diagnosis
    /// switch), and then the worker is started without the argument.
    func nativePrefixSSDKey(ownerEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> Data? {
        DistributedInstalledPrefixSSD.key(home: paths.homeDirectory, deviceDirectory: paths.deviceDirectory,
            ownerEnvironment: ownerEnvironment, prefixCacheOff: prefixCacheOff(ownerEnvironment))
    }

    /// Diagnosis only: this owner's worker keeps no prompt prefixes and asks
    /// its peer for none, so the pair prefills every request from zero. The
    /// product's prefix-cache gate (`DARKBLOOM_PREFIX_CACHE`, resolved into the
    /// installed settings) turns the pair's cache off the same way.
    private func prefixCacheOff(_ ownerEnvironment: [String: String]) -> Bool {
        ownerEnvironment[Self.prefixCacheSwitch]?.lowercased() == "off"
            || !DistributedInstalledPrefixSSD.productSettings(home: paths.homeDirectory).prefixCacheEnabled
    }
    static let prefixCacheSwitch = "DARKBLOOM_CLUSTER_PREFIX_CACHE"
    static let batchLanesSwitch = "DARKBLOOM_CLUSTER_BATCH_LANES"
    static let kvBackendSwitch = "DARKBLOOM_CLUSTER_KV_BACKEND"

    /// The pair's batch lanes in the pipeline mode: `defaultBatchLanes` for a
    /// family whose workers serve lanes, unless the owner's environment names
    /// 1...8 (1 serves one request at a time). Nil in a phase-split or
    /// speculative mode, with media, or for a family whose workers serve one
    /// request at a time, so no worker is asked for lanes it refuses. Both
    /// owners derive it from the same saved setup; the installed owner runs
    /// with a fixed environment, so the default is what a user's pair serves.
    func batchLanes(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Int? {
        guard !capability.hasPrivateImages, configuration.selectedGenerationMode == .pipeline,
              let adapter = ClusterRuntimeAdapter(rawValue: capability.adapterID), Self.laneAdapters.contains(adapter) else {
            return nil
        }
        guard let raw = environment[Self.batchLanesSwitch] else { return Self.defaultBatchLanes }
        guard let value = Int(raw), (1...8).contains(value) else { return nil }
        return value
    }

    /// Concurrent requests a lane-serving pair batches by default. Both
    /// owners serve them (`ClusterOwnerLeaseState.lanes`), and the leader's
    /// session, bridge and local API admit as many; more requests wait in the
    /// API's queue. One until a lane can join a batch that is already
    /// decoding: measured on the pair (Qwen 3.5 35B A3B, 2026-10-19), two
    /// requests that start together batch at 1.7x one's aggregate, but a
    /// request that arrives while another decodes, or a third at once, ends
    /// the pair.
    static let defaultBatchLanes = 1

    /// The adapters whose workers serve batch lanes (`CBv2StageKVHost.supports`).
    static let laneAdapters: Set<ClusterRuntimeAdapter> = [.qwen35Dense, .qwen35RoutedExperts, .qwen35PrismHadamard,
                                                           .gemma4LayerStage]
    /// Lanes whose stages keep contiguous KV storage (sliding-window rings).
    static let contiguousLaneAdapters: Set<ClusterRuntimeAdapter> = [.gemma4LayerStage]

    private func baseNativeEnvironment(matrix: URL) -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
         "DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1",
         "JACCL_RANK": String(configuration.localRank), "JACCL_IBV_DEVICES": matrix.path,
         "JACCL_COORDINATOR": "\(configuration.coordinator.address):\(configuration.coordinator.port)",
         DistributedInstalledWorkerFeatures.progressGuardMarker: String(Self.collectiveProgressLimitMilliseconds)]
            // The adapter's own values; none of them may replace one above.
            .merging(adapterEnvironment) { fixed, _ in fixed }
    }

    /// `attachment` is present exactly when the selected bootstrap is the
    /// owner-authenticated one; its three arguments are appended unchanged.
    /// `startupDeadline` is passed only to a worker that knows the argument.
    /// `dataPlane`: the owner received this worker's credential line (S16);
    /// the worker then keys its data plane and expects that line first.
    /// `prefixSSDKey`: the owner sends the rank's prefix-SSD key as the next
    /// line; the argument names the scheme, never the key.
    func nativeArguments(binding: ClusterOwnerBinding, deadline: UInt64, startupDeadline: UInt64?,
                         attachment: ClusterOwnerBootstrapAttachment?, dataPlane: Bool = false,
                         prefixSSDKey: Bool = false) throws -> [String] {
        guard binding.identity == identity(epoch: binding.identity.membershipEpoch),
              binding.rank == configuration.localRank, binding.profile == capability.profile,
              binding.executionPlanSHA256 == partition.planSHA256,
              deadline > DispatchTime.now().uptimeNanoseconds,
              deadline - DispatchTime.now().uptimeNanoseconds <= ClusterWorkerLease.maximumNanoseconds,
              // The worker's rank lease is renewed while it loads, so its
              // startup deadline may outlast the first grant (never an hour).
              startupDeadline.map({ $0 > DispatchTime.now().uptimeNanoseconds
                  && $0 - DispatchTime.now().uptimeNanoseconds <= ClusterWorkerLimits.deadlineNanoseconds }) ?? true,
              attachment?.profile == bootstrap.ownerProfile else {
            throw ClusterConfigurationError.invalid("Native launch differs from installed owner binding")
        }
        let mediaArguments = try ClusterMiMoPrivateImagePolicy.launchArguments(capability,keyed:dataPlane,startupGuard:startupDeadline != nil)
        let id = binding.identity
        return ["--model-dir", localPeer.modelDirectory, "--rank", String(binding.rank),
            "--stage-cut", String(partition.stages[0].sourceLayerEnd),
            "--membership-epoch", id.membershipEpoch.uuidString.lowercased(), "--model-id", id.modelID,
            "--artifact-sha256", id.artifactSHA256, "--configuration-sha256", id.configurationSHA256,
            "--peer0-id", id.peers[0].id, "--peer0-build-sha256", id.peers[0].buildSHA256,
            "--peer1-id", id.peers[1].id, "--peer1-build-sha256", id.peers[1].buildSHA256,
            "--deadline-uptime-nanoseconds", String(deadline)]
            + (try DistributedInstalledPrefillSelection.workerArguments(capability: capability,
                schedule: configuration.selectedPrefillSchedule))
            + (try DistributedInstalledGenerationSelection.workerArguments(configuration: configuration, capability: capability))
            + (startupDeadline.map { [DistributedInstalledWorkerFeatures.startupDeadlineArgument, String($0)] } ?? [])
            + (dataPlane ? ["--data-plane", ClusterWorkerDataPlaneTrust.argument] : [])
            + (prefixSSDKey ? ["--prefix-ssd-key", ClusterWorkerPrefixSSDKey.argument] : [])
            + mediaArguments
            + (attachment?.workerArguments ?? [])
    }
}
