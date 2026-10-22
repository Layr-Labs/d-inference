import Foundation

extension ProviderLoop {
    /// Explicit development opt-in before serve(). The existing registration,
    /// challenge and heartbeat use this SAME signer and member role. It adds no
    /// solo capacity, native runtime approval, automatic model load or fallback.
    public func installNativePairMember(_ installation: NativePairMemberInstallation) throws {
        guard isClusterMember, !nativePairConfigurationClosed, coordinatorClient == nil, nativePairMemberControl == nil,
              let signer, loopConfig.hardware.chipName == installation.chip, loopConfig.models.contains(where: { $0.id == installation.policy.model }),
              ModelRuntimeRequirements.isEligible(modelID: installation.policy.model,
                  available: loopConfig.runtimeCapabilities) else { throw NativePairMemberError.unconfigured }
        nativePairMemberControl = NativePairMemberControl(installation: installation, signer: signer)
    }
    public var nativePairMemberStatus: String? { nativePairMemberControl?.status }
}
