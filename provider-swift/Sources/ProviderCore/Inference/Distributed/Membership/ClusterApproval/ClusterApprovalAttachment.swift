import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// One Mac's own half of saving a cluster approval. The Mac builds the roster registration (`nativeMember`, v2) from
/// its own installation and its own pairing, checks the approval against them, and saves it in its own setup, or
/// saves the setup without one. Nothing another Mac or a file says is taken on trust: the approval's digests must be
/// this Mac's cluster runtime facts (`ClusterRuntimeApprovalFacts`, every digest of the release's block), the roster
/// must be the one this Mac countersigned when it paired (S17), and the saved setup's own checks
/// (`ClusterNativeMemberAttachment.validate`) run as at every load.
enum ClusterApprovalAttachment {
    /// The block digests of `approval` that are not this Mac's facts, by their contract names; `model` when the facts
    /// describe no entry for the approval's model.
    static func mismatches(_ approval: ClusterRuntimeApproval, facts: ClusterRuntimeApprovalFacts) -> [String] {
        guard let entry = facts.models.first(where: { $0.model == approval.model }) else { return ["model"] }
        let pairs = [("native_runtime_sha256", approval.nativeRuntimeSHA256, facts.nativeRuntimeSHA256),
                     ("metallib_sha256", approval.metallibSHA256, facts.metallibSHA256),
                     ("resource_library_sha256", approval.resourceLibrarySHA256, facts.resourceLibrarySHA256),
                     ("placement_policy_sha256", approval.placementPolicySHA256, facts.placementPolicySHA256),
                     ("artifact_sha256", approval.artifactSHA256, entry.artifactSHA256),
                     ("capability_sha256", approval.capabilitySHA256, entry.capabilitySHA256),
                     ("profile_sha256", approval.profileSHA256, entry.profileSHA256),
                     ("resource_policy_sha256", approval.resourcePolicySHA256, entry.resourcePolicySHA256)]
        return pairs.filter { $0.1 != $0.2 }.map(\.0)
    }

    /// This Mac's cluster helpers: the files beside the worker its setup names (a release's `Contents/Helpers`).
    static func installation(_ configuration: ClusterConfiguration) -> ClusterRuntimeApprovalFacts.Installation {
        let worker = URL(fileURLWithPath: configuration.peers[configuration.localRank].workerExecutable)
        let helpers = worker.deletingLastPathComponent()
        return .init(worker: worker,
            placementTool: helpers.appendingPathComponent(ClusterRuntimeApprovalFacts.Installation.placementToolName),
            metallib: helpers.appendingPathComponent(ClusterRuntimeApprovalFacts.Installation.metallibName),
            resourceLibrary: helpers.appendingPathComponent(ClusterRuntimeApprovalFacts.Installation.resourceLibraryName))
    }

    /// The facts of this Mac's installation for its setup's model folder (metadata only, never the weights).
    static func installedFacts(_ configuration: ClusterConfiguration) throws -> ClusterRuntimeApprovalFacts {
        let folder = URL(fileURLWithPath: configuration.peers[configuration.localRank].modelDirectory, isDirectory: true)
        return try ClusterRuntimeApprovalFacts.compute(installation: installation(configuration), models: [.init(directory: folder)])
    }

    /// The link a member registers to the other Mac: the latest probe this Mac recorded for the pair (the serving
    /// leader records one per load), as `rdma`; nil when it has none.
    static func measuredEdge(peerPin: String, members: [String], homeDirectory: URL) -> ClusterEdge? {
        guard let probe = ClusterLinkProbeHistory.read(ClusterLinkProbeHistory.defaultFile(homeDirectory: homeDirectory))?
                .pairs[ClusterLinkProbeHistory.key(members: members)]?.probe,
              probe.pointToPointLargeMicroseconds > 0, probe.pointToPointSmallMicroseconds > 0 else { return nil }
        let megabits = Double(probe.pointToPointLargeBytes) * 8 / Double(probe.pointToPointLargeMicroseconds)
        let roundTrip = UInt64(probe.pointToPointSmallMicroseconds) * 2
        return ClusterEdge(peerPin: peerPin, transport: "rdma", measuredMbps: UInt32(min(megabits.rounded(), Double(UInt32.max))),
            measuredRTTMicros: UInt32(min(roundTrip, UInt64(UInt32.max))))
    }

    /// The pins of a setup's two members in rank order, from this Mac's pairing: the record of the pairing whose
    /// link edge the setup names. Throws when the setup does not belong to that pairing.
    static func pairing(_ configuration: ClusterConfiguration, store: ClusterPairingStore)
        throws -> (roster: ClusterRoster, localPin: String, pins: [String]) {
        guard let link = configuration.linkControl else {
            throw ClusterConfigurationError.invalid("this setup does not reach the other Mac over the cable")
        }
        let records: ClusterPairingRecords?
        do { records = try store.load() } catch {
            throw ClusterConfigurationError.invalid("\(ClusterPairingRosterCheck.Refusal.storeUnreadable("\(error)"))")
        }
        guard let records, let record = records.pairings.first(where: { $0.link.edgeID == link.edgeID }),
              record.clusterID == configuration.clusterID else {
            throw ClusterConfigurationError.invalid("\(ClusterPairingRosterCheck.Refusal.notPaired)")
        }
        let byMember = Dictionary([records.localPin, record.peerPin].map { (ClusterSetupMemberFacts.memberID(pin: $0), $0) },
                                  uniquingKeysWith: { first, _ in first })
        let pins = configuration.peers.compactMap { byMember[$0.id] }
        guard pins.count == configuration.peers.count, Set(pins).count == pins.count else {
            throw ClusterConfigurationError.invalid("this setup's members are not the two Macs of this pairing")
        }
        let roster = ClusterPairingRosterCheck.roster(of: record)
        do { try ClusterPairingRosterCheck.verify(roster: roster, localPin: records.localPin, store: store) }
        catch { throw ClusterConfigurationError.invalid("\(error)") }
        return (roster, records.localPin, pins)
    }

    /// This Mac's roster registration for `approval`, built and checked from its own files and pairing. `edge` is the
    /// link to the other Mac (its pin names that Mac). Throws one plain reason when the approval is not for this Mac.
    static func attachment(for approval: ClusterRuntimeApproval, saved: ClusterConfigurationStore.Saved, paths: ClusterUserPaths,
                           pairingStore: ClusterPairingStore, edge: ClusterEdge?, now: Double,
                           chipClass: ClusterChipClass? = ClusterChipClass.local(),
                           facts: (ClusterConfiguration) throws -> ClusterRuntimeApprovalFacts = ClusterApprovalAttachment.installedFacts) throws
        -> ClusterNativeMemberAttachment {
        let configuration = saved.configuration
        guard approval.model == configuration.publicModelID,
              approval.schedule == ClusterApprovalLifetime.schedule(configuration.selectedPrefillSchedule) else {
            throw ClusterConfigurationError.invalid("the approval is for another model or prefill schedule")
        }
        guard ClusterApprovalLifetime.current(approval, now: now) else {
            throw ClusterConfigurationError.invalid("the approval expired at \(approval.notAfter)")
        }
        let installed: ClusterRuntimeApprovalFacts
        do { installed = try facts(configuration) } catch {
            throw ClusterConfigurationError.invalid("this Mac's cluster runtime could not be described: \(error)")
        }
        let differing = mismatches(approval, facts: installed)
        guard differing.isEmpty else {
            throw ClusterConfigurationError.invalid("the approval's \(differing.joined(separator: ", ")) differ from this Mac's installation")
        }
        // The member's own start refusals (`ClusterMemberPreparation.prepare`), from the metadata: a setup is never
        // saved for pairing when its member would refuse to start, which would leave the pair serving nowhere.
        do {
            let plan = try DistributedInstalledPlan(saved: saved, paths: paths)
            try ClusterMiMoPrivateImagePolicy.requireCoordinatorEligible(plan.capability)
            try plan.requireLocalRankGranted(chipClass: chipClass)
        } catch {
            throw ClusterConfigurationError.invalid("this Mac's rank of this placement is not granted for pairing: \(ClusterApprovalSync.refusal(error))")
        }
        let paired = try pairing(configuration, store: pairingStore)
        if let edge, edge.peerPin == paired.localPin || !paired.pins.contains(edge.peerPin) {
            throw ClusterConfigurationError.invalid("the measured link names no other member of this pairing")
        }
        let local = configuration.peers[configuration.localRank], tools = installation(configuration)
        let owner = try DistributedInstalledFiles.digest(URL(fileURLWithPath: local.ownerExecutable),
            maximumBytes: 256 * 1024 * 1024, executable: true, deadline: DispatchTime.now().uptimeNanoseconds + 30_000_000_000).sha256
        let attachment = ClusterNativeMemberAttachment(ownerSHA256: owner, metallibPath: tools.metallib.path,
            resourceLibraryPath: tools.resourceLibrary.path, clusterApproval: approval, roster: paired.roster,
            memberPins: paired.pins, edges: edge.map { [$0] })
        // The saved setup's own checks, as at every load: the approval names this setup's model, runtime, capability,
        // profile and schedule, and the roster's pins are its members in rank order.
        try attachment.validate(configuration: configuration.replacingNativeMember(attachment), capability: saved.capability)
        return attachment
    }

    /// Saves this Mac's setup with `attachment`, or without one (nil). False when the saved setup already is that,
    /// so nothing is written. The device journal must be empty (no part running), as for every saved setup.
    @discardableResult
    static func save(_ attachment: ClusterNativeMemberAttachment?, saved: ClusterConfigurationStore.Saved,
                     paths: ClusterUserPaths, providerConfiguration: URL, scratch: URL) throws -> Bool {
        let configuration = saved.configuration, capabilitySHA256 = configuration.capabilitySHA256
        let current = try ClusterConfigurationCodec.encode(configuration, capability: saved.capability, capabilitySHA256: capabilitySHA256)
        let next = try ClusterConfigurationCodec.encode(configuration.replacingNativeMember(attachment),
            capability: saved.capability, capabilitySHA256: capabilitySHA256)
        guard next != current else { return false }
        try ClusterConfigurationFiles.ensureDirectory(scratch, create: true, privateMode: true)
        let input = scratch.appendingPathComponent("approval-" + UUID().uuidString.lowercased() + ".json")
        try ClusterConfigurationFiles.update(input, maximum: ClusterConfigurationCodec.maximumBytes) { _ in next }
        defer { try? FileManager.default.removeItem(at: input) }
        _ = try ClusterConfigurationStore(paths: paths).configure(configurationInput: input,
            capabilityInput: try paths.capabilityURL(sha256: capabilitySHA256), capabilitySHA256: capabilitySHA256,
            providerConfiguration: providerConfiguration)
        return true
    }

    /// This Mac's saved setup, as the provider configuration points to it; nil without one.
    static func savedSetup(paths: ClusterUserPaths, providerConfiguration: URL) throws -> ClusterConfigurationStore.Saved? {
        guard let reference = try ClusterConfigurationStore.optionalInstalledReference(providerConfiguration: providerConfiguration) else {
            return nil
        }
        return try ClusterConfigurationStore(paths: paths).load(reference: reference)
    }

    /// The step a Mac takes for an approval its leader sent (nil: save the setup without one): checked against this
    /// Mac's own files and pairing before anything is written. A line for the log; throws the reason it refused.
    static func apply(_ approval: ClusterRuntimeApproval?, edge: ClusterEdge?, paths: ClusterUserPaths,
                      providerConfiguration: URL, pairingStore: ClusterPairingStore, scratch: URL, now: Double,
                      chipClass: ClusterChipClass? = ClusterChipClass.local(),
                      facts: (ClusterConfiguration) throws -> ClusterRuntimeApprovalFacts = ClusterApprovalAttachment.installedFacts) throws -> String {
        guard let saved = try savedSetup(paths: paths, providerConfiguration: providerConfiguration) else {
            throw ClusterConfigurationError.invalid("this Mac has no saved cluster setup")
        }
        guard let approval else {
            let written = try save(nil, saved: saved, paths: paths, providerConfiguration: providerConfiguration, scratch: scratch)
            return written ? "saved the setup without a cluster approval" : "the setup has no cluster approval"
        }
        let attachment = try self.attachment(for: approval, saved: saved, paths: paths, pairingStore: pairingStore, edge: edge,
                                             now: now, chipClass: chipClass, facts: facts)
        try save(attachment, saved: saved, paths: paths, providerConfiguration: providerConfiguration, scratch: scratch)
        return "saved cluster approval \(approval.id) (until \(approval.notAfter)) after checking it against this Mac's files"
    }
}
