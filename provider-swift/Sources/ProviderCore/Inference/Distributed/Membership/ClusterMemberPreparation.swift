import Foundation
import DarkbloomClusterProcess
import DarkbloomClusterSecurity
import ProviderCoreFoundation

/// Validates this Mac's installed setup without retaining a device lease. The
/// future native owner must acquire its own canonical lease before it starts.
/// An empty journal alone is insufficient: startup briefly takes the exact
/// existing exclusive gate, so live solo/native ownership and sticky journals
/// refuse member startup. No recovery or journal clearing occurs here.
public struct ClusterMemberPreparation: Sendable {
    public let model: ModelInfo
    let validation: DistributedInstalledValidation

    /// `localChipClass` is this Mac's own class
    /// (`ClusterChipClass.local()`): the rank this Mac runs must not be a
    /// rank-shape that diverged on that class, and the model must have a
    /// cluster stage adapter (owner, 2026-10-14 08:45). The single-Mac
    /// requirements of the model are not applied to a member: see
    /// DistributedServingEligibility. This is decided from the verified
    /// metadata, before the model's weights are read: a start that policy
    /// refuses costs no pass over tens of gigabytes.
    public static func prepare(reference: ClusterConfigurationReference,
                               localChipClass: ClusterChipClass?) throws -> Self {
        let paths = try ClusterUserPaths()
        let gate = try ClusterDeviceExclusion(directoryURL: paths.deviceDirectory)
        return try withExtendedLifetime(gate) {
            let validation = try DistributedInstalledValidation.validate(reference: reference,
                paths: paths, deadline: DispatchTime.now().uptimeNanoseconds + 15_000_000_000)
            try ClusterMiMoPrivateImagePolicy.requireCoordinatorEligible(validation.plan.capability)
            try validation.plan.requireLocalRankGranted(chipClass: localChipClass)
            let installed = validation.model
            guard var model = ModelScanner.parseModelInfo(snapshotDir: installed.directory,
                    modelName: installed.publicModelID) else {
                throw ClusterMemberControlError.incompatibleConfiguration
            }
            // Same on-demand integrity hasher as ordinary registration. This is
            // the ONE selected cluster model, not a discovery-wide payload scan.
            // WeightHasher is synchronous and has no cancellation/deadline API.
            // This full read is outside the metadata probe's 15-second budget;
            // the CLI owns/awaits it before any native owner or ACK timer starts.
            guard let hash = WeightHasher.computeHash(snapshotDir: installed.directory,
                    modelID: installed.publicModelID), hash == validation.manifest.aggregateSHA256 else {
                throw ClusterConfigurationError.invalid("Cluster member model integrity differs from the pinned product manifest")
            }
            model.weightHash = hash
            try validation.requireUnchanged()
            return Self(model: model, validation: validation)
        }
    }

    public func requireUnchanged() throws { try validation.requireUnchanged() }

    /// DEBUG builds only: a harness that shuttles the members' public roster
    /// values by hand (`darkbloom cluster member-identity`) may skip the
    /// pairing check with `DARKBLOOM_DEBUG_ROSTER_UNPAIRED=1`. A release build
    /// always requires the pairing.
    static var rosterWithoutPairingAllowed: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DARKBLOOM_DEBUG_ROSTER_UNPAIRED"] == "1"
        #else
        return false
        #endif
    }

    /// Nil unless the saved setup carries a pair approval. Built only from
    /// this Mac's verified installation: the approval must be unexpired and
    /// cover this chip, and the owner, native executable, metallib and
    /// resource library must hash to their pins, so a member never registers
    /// a policy it did not install. The loop installs the result with its own
    /// signer before connecting; nothing is granted here.
    ///
    /// A setup saved with a cluster approval (`darkbloom_cluster_native_member_v2`)
    /// registers the roster registration instead: `device` gives this Mac's
    /// device profile v2 for the approval's metallib, and the plan is derived from the setup's selected
    /// partition and rank order, so both members register the same plan.
    public func nativeMemberInstallation(chip: String,
                                         device: ((_ metallibSHA256: String) throws -> ClusterRegisteredDeviceProfile)? = nil) throws -> NativePairMemberInstallation? {
        let plan = validation.plan
        guard let attachment = plan.configuration.nativeMember else { return nil }
        try requireUnchanged()
        let policy = try NativePairMemberPolicy(attachment.policyBytes)
        guard Date().timeIntervalSince1970 * 1_000_000_000 < Double(policy.notAfter) else {
            throw ClusterConfigurationError.invalid("Saved pair approval has expired")
        }
        var roster: NativePairMemberRoster?
        if attachment.isRoster, let saved = attachment.roster, let pins = attachment.memberPins {
            guard let device else { throw ClusterConfigurationError.invalid("A roster registration needs this Mac's device profile") }
            let configuration = plan.configuration
            // The roster's other members must be the keys this Mac pinned in the
            // pairing ceremony (S17): a setup file alone never adds trust.
            if !Self.rosterWithoutPairingAllowed {
                guard pins.indices.contains(configuration.localRank) else {
                    throw ClusterConfigurationError.invalid("The saved roster pins do not name this Mac's rank")
                }
                do {
                    try ClusterPairingRosterCheck.verify(roster: saved, localPin: pins[configuration.localRank], store: .default())
                } catch {
                    throw ClusterConfigurationError.invalid("The saved roster is not backed by this Mac's pairing: \(error)")
                }
            }
            do {
                roster = try NativePairMemberRoster(clusterID: configuration.clusterID, rank: configuration.localRank,
                    roster: saved, rankPins: pins, policyBytes: policy.bytes, model: policy.model,
                    artifactSHA256: plan.identity(epoch: UUID()).artifactSHA256, planSHA256: plan.partition.planSHA256,
                    cut: plan.partition.stages[0].sourceLayerEnd, mode: configuration.selectedGenerationMode,
                    deviceProfile: try device(NativePairMemberInstallation.hex(policy.hashes[3])), edges: attachment.edges ?? [])
            } catch {
                throw ClusterConfigurationError.invalid("The saved roster registration is not valid for this Mac: \(error)")
            }
        }
        guard let installation = try? NativePairMemberInstallation(expectedCoordinatorPolicy: policy.bytes,
                rank: plan.configuration.localRank, clusterID: plan.configuration.clusterID,
                identity: plan.identity(epoch: UUID()), profile: plan.capability.profile,
                installedOwner: URL(fileURLWithPath: plan.localPeer.ownerExecutable), ownerSHA256: attachment.ownerSHA256,
                nativeExecutable: URL(fileURLWithPath: plan.localPeer.workerExecutable),
                metallib: URL(fileURLWithPath: attachment.metallibPath),
                resourceLibrary: URL(fileURLWithPath: attachment.resourceLibraryPath), chip: chip,
                meshOverLink: plan.configuration.linkControl != nil, roster: roster) else {
            throw ClusterConfigurationError.invalid(roster == nil
                ? "Saved pair approval does not cover this Mac's chip, artifact or native build"
                : "Saved cluster approval does not cover this Mac's numerics class, usable memory, artifact or native build")
        }
        _ = try installation.verifyInstalledFiles(deadline: DispatchTime.now().uptimeNanoseconds + 15_000_000_000)
        return installation
    }
}
