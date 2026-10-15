import Foundation
import DarkbloomClusterProcess
import ProviderCoreFoundation

/// Validates this Mac's installed setup without retaining a device lease. The
/// future native owner must acquire its own canonical lease before it starts.
/// An empty journal alone is insufficient: startup briefly takes the exact
/// existing exclusive gate, so live solo/native ownership and sticky journals
/// refuse member startup. No recovery or journal clearing occurs here.
public struct ClusterMemberPreparation: Sendable {
    public let model: ModelInfo
    private let validation: DistributedInstalledValidation
    private let nativeAttachment: DistributedInstalledNativeAttachment?

    public static func prepare(reference: ClusterConfigurationReference) throws -> Self {
        let paths = try ClusterUserPaths()
        let gate = try ClusterDeviceExclusion(directoryURL: paths.deviceDirectory)
        return try withExtendedLifetime(gate) {
            let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
            let validation = try DistributedInstalledValidation.validate(reference: reference, paths: paths, deadline: deadline)
            let nativeAttachment = try DistributedInstalledNativeAttachment.prepare(validation: validation, deadline: deadline)
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
            try nativeAttachment?.requireUnchanged()
            return Self(model: model, validation: validation, nativeAttachment: nativeAttachment)
        }
    }

    public func requireUnchanged() throws {
        try validation.requireUnchanged(); try nativeAttachment?.requireUnchanged()
    }
    /// Construct only from this Mac's verified saved installation. The loop
    /// installs it with the same signer before connecting; no grant is created.
    public func nativeMemberInstallation(chip: String) throws -> NativePairMemberInstallation? {
        guard let nativeAttachment else { return nil }
        try requireUnchanged()
        let plan = validation.plan, attachment = nativeAttachment.attachment
        return try NativePairMemberInstallation(expectedCoordinatorPolicy: attachment.policyBytes,
            rank: plan.configuration.localRank, clusterID: plan.configuration.clusterID,
            identity: plan.identity(epoch: UUID()), profile: plan.capability.profile,
            installedOwner: URL(fileURLWithPath: plan.localPeer.ownerExecutable), ownerSHA256: attachment.ownerSHA256,
            nativeExecutable: URL(fileURLWithPath: plan.localPeer.workerExecutable),
            metallib: URL(fileURLWithPath: attachment.metallib.path),
            resourceLibrary: URL(fileURLWithPath: attachment.resourceLibrary.path), chip: chip,
            bootstrapProfile: .nativeKeyPreludeMesh2)
    }
}
