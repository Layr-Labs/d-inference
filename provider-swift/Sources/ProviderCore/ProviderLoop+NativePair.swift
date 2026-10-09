import Foundation

extension ProviderLoop {
    /// Called before run() by a member whose saved setup carries a pair
    /// approval. The registration, challenge and heartbeat use this SAME signer
    /// and member role, and the registration carries this installation's
    /// membership. It adds no solo capacity, native runtime approval, automatic
    /// model load or fallback.
    public func installNativePairMember(_ installation: NativePairMemberInstallation) throws {
        guard isClusterMember, !nativePairConfigurationClosed, coordinatorClient == nil, nativePairMemberControl == nil,
              let signer, loopConfig.hardware.chipName == installation.chip, loopConfig.models.contains(where: { $0.id == installation.policy.model }),
              ModelRuntimeRequirements.isEligible(modelID: installation.policy.model,
                  available: loopConfig.runtimeCapabilities) else { throw NativePairMemberError.unconfigured }
        nativePairMemberControl = NativePairMemberControl(installation: installation, signer: signer)
    }
    public var nativePairMemberStatus: String? { nativePairMemberControl?.status }
}
