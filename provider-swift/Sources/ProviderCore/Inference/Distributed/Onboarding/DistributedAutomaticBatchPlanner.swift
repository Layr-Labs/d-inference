import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// Metadata and memory selection for a listener's drained replacement. This
/// does not start workers, change setup, recover a lease or claim batch speed.
/// The current full profile is priced because HTTP acquisition precedes exact
/// tokenizer work; a short raw body is never treated as a short token history.
struct DistributedAutomaticBatchPlanner {
    struct Snapshot: Sendable {
        let reference: ClusterConfigurationReference
        let configuration: ClusterConfiguration
        let capability: ClusterRuntimeCapability
        let setup: ClusterPlacementSetup
        let lanes: Int
        let peerPreviousSHA256: String
        let peerPreviousConfiguration: Data
        /// Proposed only because the running owner's weights were credited.
        var creditedIncumbentWeights = false
    }

    let providerConfiguration: URL
    let paths: ClusterUserPaths

    func context(configuration: ClusterConfiguration) -> LiveContext {
        var settings = ClusterSetupOperations.LiveSettings(providerConfiguration: providerConfiguration,
            darkbloomExecutable: URL(fileURLWithPath: configuration.peers[configuration.localRank].ownerExecutable),
            sessionArguments: [], pair: nil, dryRun: true, version: ProviderCore.version)
        settings.answersOverLink = false
        return LiveContext(paths: paths, store: ClusterSetupStore(paths: .init(paths: paths)),
            settings: settings, clean: ClusterConsoleFreeText(homeDirectory: paths.homeDirectory.path))
    }

    /// This Mac's profile as initial placement reads it (`ClusterLocalDeviceProfile`). A replacement is planned by
    /// the running part itself (previewed while its owner serves), so its speed index is the one this Mac last
    /// measured, never a GPU benchmark beside the model.
    static func deviceProfile(tool: URL, deadline: UInt64, homeDirectory: URL, modelLoaded: Bool) throws -> ClusterDeviceProfile {
        try ClusterLocalDeviceProfile.read(tool: tool, deadline: deadline, homeDirectory: homeDirectory, modelLoaded: modelLoaded)
    }

    /// Replacement must price the actual pair's recently recorded keyed link
    /// (its median), served requests and each Mac's share probes, just as initial placement does.
    /// Missing/stale/untrusted records retain the existing unmeasured fallback; no rate is invented.
    /// Served requests count only for the worker builds the saved setup pins (`description`'s members,
    /// checked against the installed binaries before this runs): `ClusterPlacementFlow.decide` keeps them.
    static func decide(description: ClusterPairDescription, capability: ClusterRuntimeCapability,
                       localMemberID: String, localProfile: ClusterDeviceProfile, peerProfile: ClusterDeviceProfile,
                       layout: ClusterModelLayout, scope: ClusterPlacementBatchScope, homeDirectory: URL,
                       incumbentTensorShares: [Int]? = nil) throws
        -> (lines: [String], result: ClusterPlacementResult, setup: ClusterPlacementSetup?) {
        try ClusterPlacementFlow.decide(description: description, capability: capability,
            localMemberID: localMemberID, localProfile: localProfile, peerProfile: peerProfile, layout: layout,
            promptTokens: scope.request.promptTokens, outputTokens: scope.request.outputTokens, batchScope: scope,
            leader: localMemberID,
            served: ClusterServedSpeedHistory.entries(homeDirectory: homeDirectory),
            link: ClusterLinkProbeHistory.costs(homeDirectory: homeDirectory, members: description.members.map(\.id)) ?? .unmeasured,
            shareProbes: ClusterShareProbeHistory.shareRates(homeDirectory: homeDirectory, artifactSHA256: capability.artifactSHA256,
                members: description.members.map(\.id)),
            incumbentTensorShares: incumbentTensorShares, assumeUnmeasuredLink: false, environment: [:], benchDebugBuild: false)
    }

    /// An automatic replacement cannot promise that unrelated memory will
    /// disappear. A present-fit preview uses the same bilateral predicate as
    /// the mandatory post-release recheck; hardware possibility alone is not
    /// current admission.
    static func accepts(_ candidate: ClusterPlacementCandidate, requireNow: Bool) -> Bool {
        candidate.possible && candidate.withinGPUWorkingSet
            && (!requireNow || candidate.ranks.allSatisfy { $0.fit == .now })
    }

    /// Preview only, for a request-owned TP owner whose replacement keeps its
    /// shares: a rank that does not fit now may still be proposed when it
    /// would once the running owner's own resident weights on that Mac (the
    /// same split, so `weightsBytes`) are free, as they are before the
    /// replacement loads. Only a tensor-parallel candidate with exactly the
    /// running shares qualifies; only weights are credited, never the owner's
    /// unallocated request reservation, and no hardware bound moves. The
    /// mandatory post-release `requireNow` recheck, uncredited, still gates
    /// the load; a refusal there is remembered so it is not proposed again.
    static func acceptsCreditingIncumbentWeights(_ candidate: ClusterPlacementCandidate, incumbentShares: [Int]) -> Bool {
        candidate.mode == .tensorParallel && (candidate.tensorShares ?? [1, 1]) == incumbentShares
            && candidate.possible && candidate.withinGPUWorkingSet && candidate.ranks.allSatisfy { rank in
            if rank.fit == .now { return true }
            if case .never = rank.fit { return false }
            let credited = rank.admissibleNowBytes.addingReportingOverflow(rank.weightsBytes)
            return !credited.overflow && rank.needBytes <= credited.partialValue
        }
    }

    /// One refused width's evidence for `cluster.batch_replan refused`, one
    /// log line: the phase (preview, or the post-release recheck), the
    /// predicate that failed and each rank's need, load need, admissible-now,
    /// shortfall, weights and fit, in bytes (nil candidate: the planner
    /// offered no placement at all).
    static func refusalFields(_ candidate: ClusterPlacementCandidate?, lanes: Int, previous: Int,
                              requireNow: Bool, planned: Bool, phase: String = "preview") -> [String: String] {
        var fields = ["requested_lanes": String(lanes), "previous_lanes": String(previous),
                      "require_now": requireNow ? "1" : "0", "phase": phase]
        guard let candidate else { fields["reason"] = "no_placement"; return fields }
        fields["reason"] = !candidate.possible ? "not_possible" : !candidate.withinGPUWorkingSet ? "outside_gpu_working_set"
            : requireNow && !candidate.ranks.allSatisfy({ $0.fit == .now }) ? "not_now" : planned ? "not_accepted" : "no_setup"
        fields["mode"] = candidate.mode.rawValue
        if let shares = candidate.tensorShares { fields["tensor_shares"] = shares.map(String.init).joined(separator: ":") }
        for rank in candidate.ranks {
            let prefix = "rank\(rank.rank)_"
            fields[prefix + "device"] = rank.device
            fields[prefix + "need_bytes"] = String(rank.needBytes)
            fields[prefix + "load_need_bytes"] = String(rank.loadNeedBytes)
            fields[prefix + "request_need_bytes"] = String(rank.requestNeedBytes)
            fields[prefix + "weights_bytes"] = String(rank.weightsBytes)
            fields[prefix + "admissible_now_bytes"] = String(rank.admissibleNowBytes)
            let short = rank.needBytes.subtractingReportingOverflow(rank.admissibleNowBytes)
            fields[prefix + "short_bytes"] = short.overflow ? "overflow" : String(max(0, short.partialValue))
            fields[prefix + "fit"] = rank.fit == .now ? "now" : "tier\(rank.fit.tier)"
        }
        return fields
    }

    func snapshot(reference: ClusterConfigurationReference, demand: DistributedLocalBatchDemand,
                  widths: [Int], requireNow: Bool,
                  creditsIncumbentWeights: (Int) -> Bool = { _ in false },
                  phase: String = "preview") throws -> Snapshot? {
        let saved = try ClusterConfigurationStore(paths: paths).load(reference: reference)
        let configuration = saved.configuration, capability = saved.capability
        guard configuration.role == .leader, configuration.nativeMember == nil,
              configuration.linkControl != nil, !capability.hasPrivateImages,
              configuration.publicModelID == demand.publicModelID,
              capability.runtimeModelID == demand.runtimeModelID,
              capability.artifactSHA256 == demand.artifactSHA256,
              capability.configurationSHA256 == demand.configurationSHA256,
              capability.profile.maximumPromptTokens == demand.maximumPromptTokens,
              capability.profile.maximumOutputTokens == demand.maximumOutputTokens,
              capability.profile.maximumContextTokens == demand.maximumContextTokens else { return nil }
        // The current metadata and installed binary are checked before asking
        // helper children for any new layout. No file is read as a model load.
        let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        let verified = try DistributedInstalledValidation.validate(reference: reference, paths: paths, deadline: deadline)
        let context = context(configuration: configuration)
        guard case .reached(let peerReport, _) = context.reachPeer(), let peerFacts = context.peerFacts,
              let peerProfile = peerReport.mac.profile, let peerSummary = peerReport.saved.setup,
              peerSummary.configurationSHA256.count == 64 else {
            throw ClusterConfigurationError.invalid("The paired Mac did not provide a fresh batch-planning profile")
        }
        let local = configuration.peers[0], remote = configuration.peers[1]
        guard peerFacts.memberID == remote.id, peerFacts.workerExecutable == remote.workerExecutable,
              peerFacts.ownerExecutable == remote.ownerExecutable,
              peerFacts.runtimeBinarySHA256 == remote.runtimeBinarySHA256,
              peerFacts.jacclDevice == remote.jacclDevice, peerFacts.linkAddress == remote.host,
              peerSummary.localRank == 1, peerSummary.memberID == remote.id,
              peerSummary.clusterID == configuration.clusterID else {
            throw ClusterConfigurationError.invalid("The paired installation changed before batch planning")
        }
        let tool = URL(fileURLWithPath: local.workerExecutable).deletingLastPathComponent()
            .appendingPathComponent(ClusterPlacementFlow.toolName)
        func run(_ arguments: [String], maximum: Int) throws -> Data {
            try DistributedCapabilityProbe.run(executable: tool, arguments: arguments,
                deadline: DispatchTime.now().uptimeNanoseconds + 30_000_000_000, maximumOutputBytes: maximum)
        }
        let profile = try Self.deviceProfile(tool: tool, deadline: DispatchTime.now().uptimeNanoseconds + 30_000_000_000,
            homeDirectory: paths.homeDirectory, modelLoaded: ClusterService.modelLoaded())
        let layout = try ClusterModelLayout.decode(run(["layout", "--model-dir", local.modelDirectory, "--json"],
            maximum: ClusterModelLayout.maximumEncodedBytes))
        let usesNativeBatchQuote = [.gptossLayerStage, .mimoV26LayerStage].contains(
            ClusterRuntimeAdapter.registering(runtimeModelID: capability.runtimeModelID))
        let request = usesNativeBatchQuote ? nil : try ClusterPlacementRequestScope.decode(run(
            ["request-scope", "--model-dir", local.modelDirectory,
             "--prompt-tokens", String(demand.maximumPromptTokens), "--output-tokens", String(demand.maximumOutputTokens)],
            maximum: ClusterPlacementRequestScope.maximumEncodedBytes))
        guard let link = configuration.linkControl else { return nil }
        let members = configuration.peers.map { peer in
            ClusterPairDescription.Member(id: peer.id, host: peer.host, port: peer.port, user: peer.user,
                ownerExecutable: peer.ownerExecutable, workerExecutable: peer.workerExecutable,
                modelDirectory: peer.modelDirectory, runtimeBinarySHA256: peer.runtimeBinarySHA256,
                jacclDevice: peer.jacclDevice,
                linkAddress: peer.rank == 0 ? configuration.coordinator.address : peerFacts.linkAddress,
                trust: nil, linkSecretFile: peer.rank == 0 ? link.secretFile : peerFacts.linkSecretFile)
        }
        let description = ClusterPairDescription(schema: ClusterPairDescription.schemaName,
            clusterID: configuration.clusterID, publicModelID: configuration.publicModelID,
            capabilitySHA256: configuration.capabilitySHA256, chunkTokens: configuration.chunkTokens,
            requestTimeoutSeconds: configuration.requestTimeoutSeconds, coordinatorPort: configuration.coordinator.port,
            members: members, tokenizerFiles: configuration.tokenizerFiles,
            linkControl: .init(port: link.port, linkEpoch: link.linkEpoch, edgeID: link.edgeID))
        // Reconstruct only the peer's unchanged original role/secret path.
        // Its freshly reported exact digest must match before any transition.
        var oldPeer = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as! [String: Any]
        oldPeer["role"] = "follower"; oldPeer["memberID"] = remote.id
        var peerLink = oldPeer["linkControl"] as! [String: Any]; peerLink["secretFile"] = peerFacts.linkSecretFile
        oldPeer["linkControl"] = peerLink
        let previousPeer = try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject: oldPeer),
            capability: capability, capabilitySHA256: configuration.capabilitySHA256)
        let previousPeerBytes = try ClusterConfigurationCodec.encode(previousPeer,
            capability: capability, capabilitySHA256: configuration.capabilitySHA256)
        guard ClusterConfigurationCodec.sha256(previousPeerBytes) == peerSummary.configurationSHA256 else {
            throw ClusterConfigurationError.invalid("The paired setup differs from the serving generation")
        }
        for lanes in widths {
            let scope: ClusterPlacementBatchScope
            if usesNativeBatchQuote {
                let quote = try ClusterPlacementBatchQuote.decode(run(["batch-scope", "--model-dir", local.modelDirectory,
                    "--prompt-tokens", String(demand.maximumPromptTokens), "--output-tokens", String(demand.maximumOutputTokens),
                    "--batch-lanes", String(lanes), "--chunk-size", String(configuration.chunkTokens)],
                    maximum: ClusterPlacementBatchQuote.maximumEncodedBytes))
                try quote.requireRequest(promptTokens: demand.maximumPromptTokens,
                    outputTokens: demand.maximumOutputTokens, lanes: lanes, chunkTokens: configuration.chunkTokens)
                scope = try ClusterPlacementBatchScope(quote: quote)
            } else {
                let tensorQuote: ClusterPlacementTensorBatchQuote?
                if ClusterPlacementTensorBatchQuote.runtimeModelIDs.contains(capability.runtimeModelID) {
                    let quote = try ClusterPlacementTensorBatchQuote.decode(run(["tensor-batch-scope", "--model-dir", local.modelDirectory,
                        "--prompt-tokens", String(demand.maximumPromptTokens), "--output-tokens", String(demand.maximumOutputTokens),
                        "--batch-lanes", String(lanes), "--chunk-size", String(configuration.chunkTokens)]
                        + (configuration.tensorAssistant.map { ["--mtp-depth", String($0.depth)] + $0.verificationArguments } ?? []),
                        maximum: ClusterPlacementTensorBatchQuote.maximumEncodedBytes))
                    try quote.requireRequest(promptTokens: demand.maximumPromptTokens,
                        outputTokens: demand.maximumOutputTokens, lanes: lanes, chunkTokens: configuration.chunkTokens)
                    try quote.requireAssistant(configuration.tensorAssistant)
                    tensorQuote = quote
                } else { tensorQuote = nil }
                scope = try ClusterPlacementBatchScope(request: request!, lanes: lanes, tensorParallelQuote: tensorQuote)
            }
            let incumbentShares: [Int]? = ClusterPlacementTensorBatchQuote.runtimeModelIDs.contains(capability.runtimeModelID)
                && configuration.selectedGenerationMode == .tensorParallel ? (configuration.tensorShares ?? [1, 1]) : nil
            let decision = try Self.decide(description: description, capability: capability,
                localMemberID: configuration.memberID, localProfile: profile, peerProfile: peerProfile,
                layout: layout, scope: scope, homeDirectory: paths.homeDirectory,
                incumbentTensorShares: incumbentShares)
            // Credit only a replacement that keeps the running TP shares, so each
            // rank's weights are the running owner's own weights on that Mac.
            let creditedShares = requireNow && creditsIncumbentWeights(lanes) ? incumbentShares : nil
            let credited = creditedShares != nil
            guard let chosen = decision.result.chosen, let setup = decision.setup,
                  creditedShares.map({ Self.acceptsCreditingIncumbentWeights(chosen, incumbentShares: $0) })
                    ?? Self.accepts(chosen, requireNow: requireNow) else {
                // A refused width is otherwise silent: say why, with each rank's numbers.
                var fields = Self.refusalFields(decision.result.chosen ?? decision.result.alternatives.first,
                    lanes: lanes, previous: demand.currentCapacity, requireNow: requireNow, planned: decision.setup != nil,
                    phase: phase)
                fields["credits_incumbent_weights"] = credited ? "1" : "0"
                clusterObservabilityLog(.info, "cluster.batch_replan refused lanes=\(lanes)", fields)
                continue
            }
            for peer in configuration.peers {
                guard let bytes = setup.configurations[peer.id] else { return nil }
                let after = try ClusterConfigurationCodec.decode(bytes, capability: capability,
                    capabilitySHA256: configuration.capabilitySHA256)
                try ClusterAutomaticSetupHandoff.requireCompatible(peer.rank == 0 ? configuration : previousPeer, after,
                    runtimeModelID: capability.runtimeModelID)
            }
            try verified.requireUnchanged()
            return Snapshot(reference: reference, configuration: configuration, capability: capability, setup: setup,
                lanes: lanes, peerPreviousSHA256: peerSummary.configurationSHA256,
                peerPreviousConfiguration: previousPeerBytes,
                creditedIncumbentWeights: credited && !Self.accepts(chosen, requireNow: true))
        }
        return nil
    }
}
