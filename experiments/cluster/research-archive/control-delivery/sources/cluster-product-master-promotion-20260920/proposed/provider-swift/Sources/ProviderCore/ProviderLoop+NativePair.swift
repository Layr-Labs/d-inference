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
    /// Explicit experiment request attachment to the original member session.
    /// No inference engine/device/SSH owner is created. Callers retain this loop
    /// through all request retirement and actual bilateral owner cleanup.
    public func nativePairRequestOwner(profile:DistributedResidentExecutionProfile,
                                       deadlineUptimeNanoseconds:UInt64) async throws -> NativePairRequestExecutionOwner {
        guard isClusterMember,let control=nativePairMemberControl else {throw NativePairMemberError.unconfigured}
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached {
                try control.requestOwner(profile:profile,until:deadlineUptimeNanoseconds)
            }.value
        } onCancel: {control.cancelRequests()}
    }
    public var nativePairMemberStatus: String? { nativePairMemberControl?.status }
}
