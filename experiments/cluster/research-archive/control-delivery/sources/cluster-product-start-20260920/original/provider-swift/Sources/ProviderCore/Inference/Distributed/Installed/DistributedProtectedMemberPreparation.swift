import Foundation
import DarkbloomClusterProtocol

/// Fresh read-only metadata for attaching to an existing protected member. It
/// never takes the already-owned device gate, loads payloads, or mints a policy.
struct DistributedProtectedMemberPreparation: Sendable {
    let validation: DistributedInstalledValidation
    let attachment: DistributedInstalledNativeAttachment
    let reference: ClusterConfigurationReference
    let providerConfiguration: URL

    static func prepare(reference: ClusterConfigurationReference, providerConfiguration: URL,
                        installation: NativePairMemberInstallation, deadline: UInt64) throws -> Self {
        try requireCurrent(reference, providerConfiguration)
        let validation = try DistributedInstalledValidation.validate(reference: reference,
            paths: ClusterUserPaths(), deadline: deadline)
        guard let attachment = try DistributedInstalledNativeAttachment.prepare(validation: validation, deadline: deadline) else {
            throw NativePairMemberError.unconfigured
        }
        let plan = validation.plan
        guard plan.configuration.role == .leader, plan.configuration.localRank == 0,
              installation.rank == 0, installation.bootstrapProfile == .nativeKeyPreludeMesh2,
              installation.clusterID == plan.configuration.clusterID,
              installation.identity == plan.identity(epoch: installation.identity.membershipEpoch),
              installation.profile == plan.capability.profile,
              installation.protectedRuntime?.attachment == attachment.attachment,
              try installation.policy.bytes == attachment.attachment.policyBytes,
              installation.ownerSHA256 == attachment.attachment.ownerSHA256,
              installation.localOwner.installedDarkbloom.path == plan.localPeer.ownerExecutable,
              installation.artifacts.map(\.path) == [plan.localPeer.workerExecutable,
                attachment.attachment.metallib.path, attachment.attachment.resourceLibrary.path] else {
            throw NativePairMemberError.binding
        }
        let result = Self(validation: validation, attachment: attachment,
            reference: reference, providerConfiguration: providerConfiguration)
        try result.requireUnchanged()
        return result
    }
    func requireUnchanged() throws {
        try Self.requireCurrent(reference, providerConfiguration)
        try validation.requireUnchanged(); try attachment.requireUnchanged()
    }
    private static func requireCurrent(_ reference: ClusterConfigurationReference, _ providerConfiguration: URL) throws {
        guard try ClusterConfigurationStore.installedReference(providerConfiguration: providerConfiguration) == reference,
              try ClusterConfigurationStore.installedReference(providerConfiguration: ConfigManager.defaultConfigPath()) == reference else {
            throw ClusterConfigurationError.invalid("Protected member and installed owner's current setup differ")
        }
    }
}
